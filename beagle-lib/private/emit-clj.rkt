#lang racket/base

;; Clojure emitter backend.
;;
;; Registers the 'clj target.
;;
;; Surface decisions:
;;
;;  - Structural type annotations are lowered to Clojure-family `^Tag`
;;    metadata at emit time. Each outer parameter-vector entry remains one
;;    binding: a bare binding requests inference, while `(binding-form Type)`
;;    and `(binding-form Type constraint)` own their local metadata. The type
;;    info lives directly on the def-form / defonce-form / defn-form / param
;;    structs; no separate claim-env or pre-pass is needed.
;;
;;        (def x String "ready")              -> (def ^String x "ready")
;;        (defn join [(a String) (b String)]
;;          String
;;          (str a b))                        -> (defn ^String join
;;                                                   [^String a ^String b]
;;                                                   (str a b))
;;        (defn mixed [a (b String)] Any b)    -> (defn mixed
;;                                                   [a ^String b]
;;                                                   b)
;;
;;    Param-level tags only emit when the type is a simple primitive or
;;    user record name (Clojure cannot tag with generic/parametric
;;    types as primitive hints). Untyped params emit bare.
;;
;;  - kw-access (canonical static-key access): emits identity. The
;;    (C)-canonicalization at parse time routes (:name target) to a
;;    kw-access node, which prints back as (:name target). 3-arity
;;    with default emits (:name target default) — Clojure accepts this.
;;
;;  - defmacro: parse-time only. Macros expand at parse time and never
;;    appear in program-forms, so the emitter never sees them. (To emit
;;    native Clojure defmacros we'd retain defmacro-form in
;;    program-forms — that's a parse change, not an emit change.)
;;
;;  - Threading family (->, ->>, as->, cond->, cond->>, some->, some->>)
;;    and accepted-by-canonicalize forms (if-let-style flatteners, when,
;;    cond flat-pair): lowered to call/let/if composition at parse time.
;;    The emitter sees the lowered AST. Trade-off: emitted Clojure is
;;    uglier than the surface, but always correct. Reconstructing the
;;    surface threading expression is a follow-up.
;;
;;  - Quoted containers ('[…] / '{…} / '#{…}): emit identity via the
;;    `quoted` AST node + datum->clj. Clojure reads these natively.
;;
;;  - Nix-only forms (nix-with, nix-assert, nix-fn-set, nix-derivation,
;;    nix-flake, nix-with-cfg, nix-inherit*, nix-rec-attrs, nix-get-or,
;;    nix-has-attr, nix-search-path, nix-interpolated-string,
;;    nix-multiline-string, nix-path): rejected with a target-mismatch
;;    error naming the form. Better to fail loud than emit garbage that
;;    babashka silently runs the wrong way.

(require racket/match
         racket/string
         racket/format
         racket/set
         racket/list
         "parse.rkt"
         "types.rkt"
         "emit-dispatch.rkt")

(define (reference-key ref)
  (if (qualified-ref? ref)
      (cons (qualified-ref-qualifier ref) (qualified-ref-name ref))
      ref))

(define (qualified-ref->clj ref)
  (string-append (symbol->string (qualified-ref-qualifier ref))
                 "/"
                 (symbol->string (qualified-ref-name ref))))

(define (reference->clj ref)
  (cond
    [(resolved-ref? ref) (symbol->string (resolved-ref-output-symbol ref))]
    [(qualified-ref? ref) (qualified-ref->clj ref)]
    [(symbol? ref) (symbol->string ref)]
    [else (emit-expr ref)]))

(define (qualified-reference=? ref qualifier name)
  (and (qualified-ref? ref)
       (eq? (qualified-ref-qualifier ref) qualifier)
       (eq? (qualified-ref-name ref) name)))

;; --- special float values ---------------------------------------------------

(define (emit-clj-number n)
  (cond
    [(eqv? n +inf.0) "##Inf"]
    [(eqv? n -inf.0) "##-Inf"]
    [(eqv? n +nan.0) "##NaN"]
    [else (number->string n)]))

;; --- source-location metadata -----------------------------------------------

(define current-emit-src-table (make-parameter #f))
(define current-emit-record-fields (make-parameter (hasheq)))
(define current-emit-record-ns (make-parameter (hasheq)))
(define current-emit-target (make-parameter 'clj))
(define current-clj-semantic-contracts (make-parameter #f))

(define (error-payload-keyword field)
  (define contract
    (and (current-clj-semantic-contracts)
         (hash-ref (current-clj-semantic-contracts) field #f)))
  (if (error-payload-key-contract? contract)
      (error-payload-key-contract-keyword contract)
      (string->symbol (format ":~a" (param-name field)))))
;; Scalar constructors/accessors that erase to identity at runtime
(define current-emit-scalar-fns (make-parameter (set)))
;; Unqualified imported symbol → module prefix (for qualifying in output)
(define current-emit-symbol-ns (make-parameter (hasheq)))
(define current-emit-local-names (make-parameter (set)))
(define current-clj-loop-recur-context (make-parameter #f))

;; Clojure binds `& rest` as a seq, while Beagle's rest binding is the
;; aggregate `(Vec Element)` seen by the checker, constraints, and body. Keep
;; the host sequence compiler-owned and normalize it exactly once at every
;; callable boundary.
(define CLJ-HOST-REST "$beagle$rest$host")

(define clj-sha256-runtime
  #<<CLJ
(defn- beagle$sha256_bytes_v0 [values]
  (when-not (vector? values)
    (throw (ex-info "sha256-bytes requires a Vec Int"
                    {:value values})))
  (let [raw (byte-array
             (map-indexed
              (fn [index value]
                (if (and (integer? value) (<= 0 value 255))
                  (unchecked-byte value)
                  (throw
                   (ex-info "sha256-bytes requires byte values from 0 through 255"
                            {:index index :value value}))))
              values))
        digest (.digest (java.security.MessageDigest/getInstance "SHA-256") raw)]
    (apply str
           (map (fn [value]
                  (format "%02x" (bit-and (int value) 255)))
                digest))))
CLJ
  )

(define (emit-srcloc loc)
  (define src (src-loc-source loc))
  (define file (and src (if (path? src) (path->string src) (~a src))))
  (cond
    [(and (src-loc-line loc) file) (format "^{:line ~a :file ~v} " (src-loc-line loc) file)]
    [(src-loc-line loc)            (format "^{:line ~a} " (src-loc-line loc))]
    [else                         ""]))

(define (metadatable? s)
  (and (> (string-length s) 0)
       (let ([c (string-ref s 0)])
         (or (char=? c #\() (char=? c #\[) (char=? c #\{)
             ;; #{...} sets carry metadata; #"..." regex literals are
             ;; java.util.regex.Pattern — not IObj, meta crashes at read.
             (and (char=? c #\#)
                  (not (and (> (string-length s) 1)
                            (char=? (string-ref s 1) #\"))))))))

;; Per-form `^{:line :file}` metadata is pure debug provenance — it carries
;; no runtime semantics, but on a real corpus it dominates emitted size
;; (los-bb: 96% of bytes, plan.clj 153KB -> 32KB without it) and that bloat
;; is re-parsed by SCI on every babashka launch. Release builds that don't
;; need source-mapped stack traces can suppress it with BEAGLE_EMIT_SRCLOC=0.
;; Default is on, so beagle's own goldens and error provenance are unchanged.
(define emit-srcloc?
  (not (member (getenv "BEAGLE_EMIT_SRCLOC") '("0" "off" "false" "no"))))

;; Prepend Clojure metadata to a raw emission string when the source-location
;; table has an entry for the AST node `e` and the emission starts with a
;; collection delimiter (metadata only attaches to forms in Clojure).
(define (with-srcloc-meta e raw)
  (cond
    [(not emit-srcloc?) raw]
    [else
     (define tbl (current-emit-src-table))
     (define loc (and tbl (hash-ref tbl e #f)))
     (if (and loc (metadatable? raw))
       (string-append (emit-srcloc loc) raw)
       raw)]))

;; --- top-level -------------------------------------------------------------

(define (build-record-field-table prog)
  (define local
    (for/fold ([h (hash)]) ([f (in-list (program-forms prog))])
      (cond
        [(record-form? f)
         (hash-set h (record-form-name f)
                     (map (lambda (p) (symbol->string (param-name p)))
                          (record-form-fields f)))]
        [(and (defunion-form? f) (defunion-form-member-fields f))
         (for/fold ([h2 h]) ([m (in-list (defunion-form-members f))])
           (define fields (hash-ref (defunion-form-member-fields f) m '()))
           (hash-set h2 m (map (lambda (p) (symbol->string (param-name p))) fields)))]
        [(deferror-form? f)
         (for/fold ([h2 h]) ([m (in-list (deferror-form-members f))])
           (define fields (hash-ref (deferror-form-member-fields f) m '()))
           (hash-set h2 m (map (lambda (p) (symbol->string (param-name p))) fields)))]
        [else h])))
  (define legacy-imported
    (for/fold ([h local])
              ([(rec-name field-names)
                (in-hash (program-imported-record-field-order prog))])
      (hash-set h rec-name field-names)))
  (for*/fold ([h legacy-imported])
             ([import (in-list (program-imported-module-interfaces prog))]
              [(name contract)
               (in-hash
                (module-interface-record-contracts
                 (module-import-interface import)))]
              [qualifier
               (in-list
                (remove-duplicates
                 (list
                  (module-import-prefix import)
                  (module-interface-namespace
                   (module-import-interface import)))
                 eq?))])
    (hash-set
     h
     (reference-key (qualified-ref qualifier name #f))
     (map (lambda (field) (symbol->string (param-name field)))
          (interface-record-contract-fields contract)))))

(define (build-record-ns-table prog)
  (define legacy-imported
    (for/fold ([h (hash)])
              ([(name namespace) (in-hash (program-imported-record-ns prog))])
      (hash-set h name namespace)))
  (for*/fold ([h legacy-imported])
             ([import (in-list (program-imported-module-interfaces prog))]
              [name
               (in-hash-keys
                (module-interface-record-contracts
                 (module-import-interface import)))]
              [qualifier
               (in-list
                (remove-duplicates
                 (list
                  (module-import-prefix import)
                  (module-interface-namespace
                   (module-import-interface import)))
                 eq?))])
    (hash-set
     h
     (reference-key (qualified-ref qualifier name #f))
     (module-interface-namespace (module-import-interface import)))))

(define (build-scalar-fns prog)
  (define predicated
    (for/fold ([h (hash)]) ([f (in-list (program-forms prog))])
      (if (and (defscalar-form? f) (not (null? (defscalar-form-predicates f))))
          (hash-set h (defscalar-form-name f) #t)
          h)))
  (define local
    (for/fold ([s (set)]) ([f (in-list (program-forms prog))])
      (if (defscalar-form? f)
          (let* ([name (defscalar-form-name f)]
                 [name-str (symbol->string name)]
                 [name-lower (string-downcase name-str)]
                 [ctor (string->symbol (string-append "->" name-str))]
                 [accessor (string->symbol (string-append name-lower "-value"))])
            (if (hash-has-key? predicated name)
                (set-add s accessor)
                (set-add (set-add s ctor) accessor)))
          s)))
  (define legacy-imported
    (for/fold ([s local])
              ([sym (in-list (program-imported-scalar-fns prog))])
      (set-add s sym)))
  (for*/fold ([s legacy-imported])
             ([import (in-list (program-imported-module-interfaces prog))]
              [(name declaration)
               (in-hash
                (module-interface-type-declarations
                 (module-import-interface import)))]
              [runtime-name
               (in-list
                (match (interface-type-declaration-details declaration)
                  [`(backing ,_ predicates ,_)
                   (define name-string (symbol->string name))
                   (list
                    (string->symbol (string-append "->" name-string))
                    (string->symbol
                     (string-append
                      (string-downcase name-string)
                      "-value")))]
                  [_ '()]))]
              [qualifier
               (in-list
                (remove-duplicates
                 (list
                  (module-import-prefix import)
                  (module-interface-namespace
                   (module-import-interface import)))
                 eq?))])
    (set-add
     s
     (reference-key (qualified-ref qualifier runtime-name #f)))))

(define (build-local-names prog)
  (for/fold ([names (set)]) ([form (in-list (program-forms prog))])
    (cond
      [(def-form? form) (set-add names (def-form-name form))]
      [(defonce-form? form) (set-add names (defonce-form-name form))]
      [(defn-form? form) (set-add names (defn-form-name form))]
      [(defn-multi? form) (set-add names (defn-multi-name form))]
      [(defmulti-form? form) (set-add names (defmulti-form-name form))]
      [else names])))

;; --- structural type-hint lowering ----------------------------------------
;;
;; Type information lives directly on def-form / defonce-form / defn-form /
;; param structs. The emitter reads that binding-local slot and lowers it to
;; Clojure-family `^Tag` metadata. No separate environment or adjacency pass is
;; involved.

;; Translate a Beagle type to a Clojure tag string, or #f when the type
;; has no useful primitive hint. Clojure type-hint metadata is used by
;; the JVM compiler for primitive avoidance and reflection skips —
;; arbitrary types (Vec, Map, user records) don't help and are noisy,
;; so we skip them. Records emit as the bare record name.
(define (clj-tag-for-type t)
  (cond
    [(type-prim? t)
     (case (type-prim-name t)
       ;; ^long / ^double are pure JVM-perf hints: babashka ignores them
       ;; outright, and GraalVM AOT keeps rejecting them (primitive-return
       ;; resolution, the 4-primitive-arg cap). beagle's clj output runs on
       ;; babashka or `clojure -M` scripting where they never pay off, so
       ;; emit none — Int/Float go unhinted, like Any.
       [(Int) #f]
       [(Float) #f]
       [(Bool) "Boolean"]
       [(String) "String"]
       [(Char) "Character"]
       [(Nil) #f]
       [(Any) #f]
       [else
        ;; A bare-name hint (`^Rec`) only resolves if the defrecord that
        ;; creates the class is emitted in THIS file. So hint only records
        ;; defined in this same module — in the field table but NOT imported.
        ;; Imported records (in record-ns) would need an (:import ...) the
        ;; emitter doesn't produce, and opaque `declare-extern` types
        ;; (los.json/Json, los.yaml/Yaml — in neither table) have no class at
        ;; all. SCI tolerates such dangling hints, but the JVM/GraalVM AOT
        ;; compiler rejects them ("Unable to resolve classname"). A missing
        ;; hint is always safe; a wrong one breaks the load.
        (define nm (type-prim-name t))
        (if (and (hash-has-key? (current-emit-record-fields) nm)
                 (not (hash-has-key? (current-emit-record-ns) nm)))
          (symbol->string nm)
          #f)])]
    ;; Parametric / function / union types: no useful hint.
    [else #f]))

;; Format a binding's tag prefix: `^Tag ` (short form) or empty when no
;; useful hint. Used for both def-level and param-level metadata.
(define (clj-tag-prefix t)
  (define tag (and t (clj-tag-for-type t)))
  (if tag (format "^~a " tag) ""))

(define (clj-emit-program prog)
  (parameterize ([current-emit-src-table (program-src-table prog)]
                 [current-type-table (program-type-table prog)]
                 [current-emit-record-fields (build-record-field-table prog)]
                 [current-emit-record-ns (build-record-ns-table prog)]
                 [current-emit-target (program-target prog)]
                 [current-clj-semantic-contracts
                  (program-semantic-contracts prog)]
                 [current-emit-scalar-fns (build-scalar-fns prog)]
                 [current-emit-symbol-ns (program-imported-symbol-ns prog)]
                 [current-emit-local-names (build-local-names prog)]
                 [match-counter (box 0)])   ; fresh per program -> deterministic match temps
    ;; Emit body first so we can detect str/ usage for auto-requires.
    (define body
      (string-join
       (for/list ([form (in-list (program-forms prog))])
         (with-srcloc-meta form (emit-form form)))
       "\n\n"))
    (define needs-clj-string?
      (regexp-match? #rx"[( \t\n]str/" body))
    (define needs-sha256-runtime?
      (string-contains? body "beagle$sha256_bytes_v0"))
    (string-append
     (emit-ns prog #:needs-clj-string? needs-clj-string?)
     "\n\n"
     (if needs-sha256-runtime?
         (string-append clj-sha256-runtime "\n")
         "")
     body
     "\n")))

(define (emit-ns prog #:needs-clj-string? [needs-clj-string? #f])
  (define ns (program-namespace prog))
  (define rs (auto-inject-clj-string (program-requires prog) needs-clj-string?))
  (define is (program-imports prog))
  (define emitted-requires
    (filter-map (lambda (entry) (emit-require prog entry)) rs))
  (define clauses
    (filter values
      (list
       ;; (:gen-class) — AOT / GraalVM-native entry; babashka treats it as a
       ;; no-op.
       (and (program-gen-class? prog)
            "(:gen-class)")
       (and (not (null? emitted-requires))
            (format "(:require ~a)"
                    (string-join emitted-requires "\n            ")))
       (and (not (null? is))
            (format "(:import ~a)"
                    (string-join (map emit-import is) "\n           "))))))
  (if (null? clauses)
      (format "(ns ~a)" ns)
      (format "(ns ~a\n  ~a)" ns (string-join clauses "\n  "))))

;; Inject [clojure.string :as str] when the body uses `str/foo` and the user
;; didn't already require clojure.string.
(define (auto-inject-clj-string base-rs needs-clj-string?)
  (cond
    [(not needs-clj-string?) base-rs]
    [(for/or ([r (in-list base-rs)])
       (eq? (require-entry-ns r) 'clojure.string))
     base-rs]
    [else (append base-rs (list (require-entry 'clojure.string 'str #f)))]))

;; Find the index of the last `.` in s, or #f if none.
(define (string-last-dot s)
  (let loop ([i (- (string-length s) 1)])
    (cond
      [(< i 0) #f]
      [(char=? (string-ref s i) #\.) i]
      [else (loop (- i 1))])))

(define (qualified-binding prefix name)
  (qualified-ref prefix name #f))

(define (require-prefix entry)
  (or (require-entry-alias entry)
      (string->symbol
       (last (string-split (symbol->string (require-entry-ns entry)) ".")))))

(define (require-module-import prog entry)
  (for/first ([import (in-list (program-imported-module-interfaces prog))]
              #:when
              (eq? (module-interface-namespace
                    (module-import-interface import))
                   (require-entry-ns entry)))
    import))

(define (used-unqualified-record-validators prog)
  (for/set ([(node contract)
             (in-hash (program-semantic-contracts prog))]
            #:when
            (and (record-update-contract? contract)
                 (symbol?
                  (record-update-contract-validator-symbol contract))))
    (record-update-contract-validator-symbol contract)))

(define (referred-record-validators prog entry refer)
  (define import (require-module-import prog entry))
  (define interface (and import (module-import-interface import)))
  (define used (used-unqualified-record-validators prog))
  (if (not interface)
      '()
      (for/list
          ([(record-name contract)
            (in-hash (module-interface-record-contracts interface))]
           #:when
           (let ([validator
                  (interface-record-contract-validator-symbol contract)])
             (and validator
                  (set-member? used validator)
                  (or (memq record-name refer)
                      (memq
                       (string->symbol (format "->~a" record-name))
                       refer)))))
        (interface-record-contract-validator-symbol contract))))

(define (runtime-refer-name prog entry name)
  (define import (require-module-import prog entry))
  (define interface (and import (module-import-interface import)))
  (define binding
    (and interface (module-interface-binding-ref interface name #f)))
  (cond
    ;; Type declarations and macros exist only during Beagle compilation; a
    ;; Clojure namespace cannot refer them as Vars.
    [(and interface
          (module-interface-type-export? interface name)
          (not binding))
     #f]
    [(hash-ref (program-macros prog) name #f) #f]
    [(and binding (eq? (interface-binding-kind binding) 'extern)) #f]
    [else name]))

(define (emit-require prog r)
  (define ns (require-entry-ns r))
  (define refer-syms (require-entry-refer r))
  (define runtime-refer
    (and refer-syms
         (remove-duplicates
          (append
           (filter-map
            (lambda (name) (runtime-refer-name prog r name))
            refer-syms)
           (referred-record-validators prog r refer-syms)))))
  (define alias
    (or (require-entry-alias r)
        ;; Default alias: the last `.`-separated segment of the namespace.
        ;; Suppressed for refer-only requires (no alias requested).
        (and (not refer-syms)
             (let* ([ns-str (symbol->string ns)]
                    [idx (string-last-dot ns-str)])
               (if idx (substring ns-str (+ idx 1)) ns-str)))))
  (cond
    [(and refer-syms (null? runtime-refer)) #f]
    [else
     (format "[~a~a~a]"
             ns
             (if alias (format " :as ~a" alias) "")
             (if (and runtime-refer (pair? runtime-refer))
                 (format " :refer [~a]"
                         (string-join (map symbol->string runtime-refer) " "))
                 ""))]))

;; Split a fully-qualified Java class symbol like 'java.io.File into
;; package ("java.io") and class name ("File"), then emit Clojure-style
;; [package ClassName]. Bare classes (no dot) emit as a plain symbol.
(define (emit-import class-sym)
  (define s (symbol->string class-sym))
  (define idx (string-last-dot s))
  (cond
    [idx (format "[~a ~a]" (substring s 0 idx) (substring s (+ idx 1)))]
    [else s]))

;; --- per-form emission -----------------------------------------------------

(define (emit-form f)
  (cond
    [(def-form? f)
     (format "(def ~a~a~a~a ~a)"
             (if (def-form-dynamic? f) "^:dynamic " "")
             (clj-tag-prefix (def-form-type f))
             (def-form-name f)
             (if (def-form-doc f) (format " ~v" (def-form-doc f)) "")
             (emit-expr (def-form-value f)))]

    [(defonce-form? f)
     (format "(defonce ~a~a~a ~a)"
             (clj-tag-prefix (defonce-form-type f))
             (defonce-form-name f)
             (if (defonce-form-doc f) (format " ~v" (defonce-form-doc f)) "")
             (emit-expr (defonce-form-value f)))]

    [(defn-form? f)
     (define kw (if (defn-form-private? f) "defn-" "defn"))
     (define name-tag (clj-tag-prefix (defn-form-return-type f)))
     (define-values (params-str body-str)
       (emit-callable-signature+body
        (defn-form-params f)
        (defn-form-rest-param f)
        (emit-body (defn-form-body f) "  ")))
     (format "(~a ~a~a~a [~a]\n  ~a)"
             kw
             name-tag
             (defn-form-name f)
             (if (defn-form-doc f)
                 (format "\n  ~v" (defn-form-doc f))
                 "")
             params-str
             body-str)]

    [(defn-multi? f)
     (define kw (if (defn-multi-private? f) "defn-" "defn"))
     (define arity-strs
       (for/list ([a (in-list (defn-multi-arities f))])
         (define-values (params-str body-str)
           (emit-callable-signature+body
            (arity-clause-params a)
            (arity-clause-rest-param a)
            (emit-body (arity-clause-body a) "    ")))
         (format "  ([~a]\n    ~a)"
                 params-str body-str)))
     (format "(~a ~a~a\n~a)"
             kw
             (defn-multi-name f)
             (if (defn-multi-doc f) (format "\n  ~v" (defn-multi-doc f)) "")
             (string-join arity-strs "\n"))]

    [(record-form? f)
     (emit-record f)]

    [(protocol-form? f)
     (emit-protocol f)]

    [(defmulti-form? f)
     (format "(defmulti ~a ~a)" (defmulti-form-name f) (emit-expr (defmulti-form-dispatch-fn f)))]

    [(defmethod-form? f)
     (define-values (params-str body-str)
       (emit-callable-signature+body
        (defmethod-form-params f) #f
        (emit-body (defmethod-form-body f) "  ")))
     (format "(defmethod ~a ~a [~a]\n  ~a)"
             (defmethod-form-name f)
             (emit-expr (defmethod-form-dispatch-val f))
             params-str
             body-str)]

    [(extend-type-form? f)
     (emit-extend-type f)]

    [(defenum-form? f)
     (emit-defenum f)]

    [(defunion-form? f)
     (emit-defunion f)]

    [(deferror-form? f)
     (emit-deferror f)]

    [(defscalar-form? f)
     (emit-defscalar f)]

    [else (emit-expr-core f)]))

;; --- expressions -----------------------------------------------------------

;; Emit a Racket char? as a Clojure character literal (\tab, \z, A, …).
;; Named chars use their Clojure spelling; printable ASCII use bare \X;
;; everything else gets a \uNNNN hex escape (zero-padded to 4 digits).
(define (emit-clj-char c)
  (case c
    [(#\space)     "\\space"]
    [(#\tab)       "\\tab"]
    [(#\newline)   "\\newline"]
    [(#\return)    "\\return"]
    [(#\page)      "\\formfeed"]
    [(#\backspace) "\\backspace"]
    [else
     (define n (char->integer c))
     (if (and (>= n 33) (<= n 126))
       ;; printable ASCII (excluding space, which is named above)
       (string #\\ c)
       ;; non-printable / non-ASCII → \uNNNN
       (string-append "\\u"
                      (let ([h (number->string n 16)])
                        (string-append (make-string (max 0 (- 4 (string-length h))) #\0)
                                       h))))]))

;; Clojure's reader accepts a NARROWER escape set than Racket's writer emits:
;; Racket spells VT/BEL/ESC as \v \a \e, none of which Clojure reads. Every
;; other control byte falls through to \uNNNN, which both accept.
(define (emit-clj-string s)
  (string-append
   "\""
   (apply
    string-append
    (for/list ([ch (in-string s)])
      (cond
        [(char=? ch #\")         "\\\""]
        [(char=? ch #\\)         "\\\\"]
        [(char=? ch #\tab)       "\\t"]
        [(char=? ch #\newline)   "\\n"]
        [(char=? ch #\return)    "\\r"]
        [(char=? ch #\page)      "\\f"]
        [(char=? ch #\backspace) "\\b"]
        [else
         (define n (char->integer ch))
         (if (or (< n #x20) (= n #x7f))
           (string-append "\\u"
                          (let ([h (number->string n 16)])
                            (string-append
                             (make-string (max 0 (- 4 (string-length h))) #\0)
                             h)))
           (string ch))])))
   "\""))

(define (emit-expr e)
  (with-srcloc-meta e (emit-expr-core e)))

;; Shared scaffolding for `when-let`/`when-some` (single binding + body block).
(define (emit-when-binding kw name expr body)
  (format "(~a [~a ~a]\n  ~a)"
          kw name (emit-expr expr) (emit-body body "  ")))

;; Shared scaffolding for `if-let`/`if-some` (single binding + then expr, optional else).
(define (emit-if-binding kw name expr then else)
  (if else
    (format "(~a [~a ~a]\n  ~a\n  ~a)"
            kw name (emit-expr expr) (emit-expr then) (emit-expr else))
    (format "(~a [~a ~a]\n  ~a)"
            kw name (emit-expr expr) (emit-expr then))))

(define (emit-expr-core e)
  (cond
    [(resolved-ref? e) (symbol->string (resolved-ref-output-symbol e))]
    [(qualified-ref? e) (qualified-ref->clj e)]
    [(string? e)        (emit-clj-string e)]
    [(boolean? e)       (if e "true" "false")]
    [(exact-integer? e) (number->string e)]
    [(real? e)          (emit-clj-number e)]
    [(char? e)          (emit-clj-char e)]
    [(symbol? e)        (symbol->string e)]
    [(quoted? e)
     ;; '[…] / '{…} / '#{…} containers are self-evaluating in Clojure
     ;; (the inner items become literal data because vectors/maps/sets
     ;; are inert collections at read time). Drop the leading `'` for
     ;; these — emitting `[1 2 3]` is idiomatic; `'[1 2 3]` is legal but
     ;; redundant. Lists ('(1 2 3)) and symbols ('foo) keep the quote
     ;; because bare `(1 2 3)` would be a call form and bare `foo` a
     ;; binding reference.
     (let ([d (quoted-datum e)])
       (cond
         [(or (bracketed? d) (map-tagged? d) (set-tagged? d))
          (datum->clj d)]
         [else (format "'~a" (datum->clj d))]))]
    ;; Native regex literal — the pattern is reproduced verbatim (the
    ;; reader preserved backslashes raw). (re-pattern "...") would need
    ;; string-escaping and broke every pattern containing \d, \w, etc.
    [(regex-lit? e)     (format "#\"~a\"" (regex-lit-pattern e))]
    [(vec-form? e)
     (format "[~a]"
             (string-join (map emit-expr (vec-form-items e)) " "))]
    [(map-form? e)
     (format "{~a}"
             (string-join
              (map (lambda (p) (format "~a ~a" (emit-expr (car p)) (emit-expr (cdr p))))
                   (map-form-pairs e))
              " "))]
    [(set-form? e)
     (format "#{~a}"
             (string-join (map emit-expr (set-form-items e)) " "))]
    [(with-meta? e)
     (format "^~a ~a"
             (emit-expr-core (with-meta-metadata e))
             (emit-expr (with-meta-expr e)))]
    ;; threading-marker preserves the surface form for idiomatic Clojure
    ;; emit. The seven Clojure threaders (->, ->>, as->, cond->, cond->>,
    ;; some->, some->>) all reconstruct via the same shape: emit the kind
    ;; symbol followed by each of orig-args (which were already parsed by
    ;; the parser into call-form / symbol / literal AST nodes). For ->
    ;; and ->> a bare-symbol step like `f` stays as `f` (Clojure's auto-
    ;; wrap surface accepts that); call-form steps like `(foo)` parse to
    ;; a zero-arg call-form and emit back as `(foo)`. as->'s placeholder
    ;; is parsed as a plain symbol and re-emits as such. cond-> /
    ;; cond->>'s clauses are a flat (test step test step …) sequence —
    ;; orig-args preserves that flatness, so the generic emit works.
    ;; The desugared inner is not emitted; downstream type-check &
    ;; emit-nix continue to walk it, but for clj we want the
    ;; idiomatic surface.
    [(threading-marker? e)
     (define kind (threading-marker-kind e))
     (define args (threading-marker-orig-args e))
     (cond
       [(null? args) (format "(~a)" kind)]
       [else
        (format "(~a ~a)"
                kind
                (string-join (map emit-expr args) " "))])]
    [(if-form? e)
     (cond
       [(if-form-else-expr e)
        (format "(if ~a ~a ~a)"
                (emit-expr (if-form-cond-expr e))
                (emit-expr (if-form-then-expr e))
                (emit-expr (if-form-else-expr e)))]
       [else
        (format "(if ~a ~a)"
                (emit-expr (if-form-cond-expr e))
                (emit-expr (if-form-then-expr e)))])]
    [(when-form? e)
     (format "(when ~a\n  ~a)"
             (emit-expr (when-form-cond-expr e))
             (emit-body (when-form-body e) "  "))]
    [(when-let-form? e)
     (emit-when-binding "when-let"
                        (when-let-form-name e)
                        (when-let-form-expr e)
                        (when-let-form-body e))]
    [(if-let-form? e)
     (emit-if-binding "if-let"
                      (if-let-form-name e)
                      (if-let-form-expr e)
                      (if-let-form-then-body e)
                      (if-let-form-else-body e))]
    [(when-some-form? e)
     (emit-when-binding "when-some"
                        (when-some-form-name e)
                        (when-some-form-expr e)
                        (when-some-form-body e))]
    [(if-some-form? e)
     (emit-if-binding "if-some"
                      (if-some-form-name e)
                      (if-some-form-expr e)
                      (if-some-form-then-body e)
                      (if-some-form-else-body e))]
    [(with-open-form? e)
     (define bindings (with-open-form-bindings e))
     (if (bindings-have-constraints? bindings)
         (emit-with-open-chain
          bindings (emit-body (with-open-form-body e) "  "))
         (format "(with-open [~a]\n  ~a)"
                 (emit-let-bindings bindings)
                 (emit-body (with-open-form-body e) "  ")))]
    [(binding-form? e)
     (define bindings (binding-form-bindings e))
     (if (bindings-have-constraints? bindings)
         (emit-dynamic-binding-chain
          bindings (emit-body (binding-form-body e) "  "))
         (format "(binding [~a]\n  ~a)"
                 (emit-let-bindings bindings)
                 (emit-body (binding-form-body e) "  ")))]
    [(doto-form? e)
     (format "(doto ~a\n  ~a)"
             (emit-expr (doto-form-target e))
             (string-join (map emit-expr (doto-form-forms e)) "\n  "))]
    [(do-form? e)
     (format "(do\n  ~a)"
             (emit-body (do-form-body e) "  "))]
    [(cond-form? e)
     (format "(cond\n  ~a)"
             (string-join
              (for/list ([c (in-list (cond-form-clauses e))])
                (define test (cond-clause-test c))
                (format "~a ~a"
                        (if (and (symbol? test) (eq? test 'else))
                            ":else"
                            (emit-expr test))
                        (emit-body (cond-clause-body c) "  ")))
              "\n  "))]
    [(let-form? e)
     (format "(let [~a]\n  ~a)"
             (emit-let-bindings (let-form-bindings e))
             (emit-body (let-form-body e) "  "))]
    [(letfn-form? e)
     (define fn-strs
       (for/list ([f (in-list (letfn-form-fns e))])
         (define-values (params-str body-str)
           (emit-callable-signature+body
            (letfn-fn-params f)
            (letfn-fn-rest-param f)
            (parameterize ([current-clj-loop-recur-context #f])
              (emit-body (letfn-fn-body f) "    "))))
         (format "(~a [~a] ~a)"
                 (symbol->string
                  (binder-output-symbol f (letfn-fn-name f)))
                 params-str
                 body-str)))
     (format "(letfn [~a]\n  ~a)"
             (string-join fn-strs "\n          ")
             (emit-body (letfn-form-body e) "  "))]
    [(loop-form? e)
     (emit-loop-with-constraints e)]
    [(recur-form? e)
     (define args (recur-form-args e))
     (define context (current-clj-loop-recur-context))
     (format "(recur~a~a)"
             (emit-args args)
             (if (and context (= (length args) context)) " false" ""))]
    [(for-form? e)
     (format "(for [~a]\n  ~a)"
             (emit-for-clauses (for-form-clauses e))
             (emit-body (for-form-body e) "  "))]
    [(fn-form? e)
     (define-values (params-str body-str)
       (emit-callable-signature+body
        (fn-form-params e)
        (fn-form-rest-param e)
        (parameterize ([current-clj-loop-recur-context #f])
          (emit-body (fn-form-body e) "  "))))
     (format "(fn [~a] ~a)"
             params-str body-str)]
    [(method-call? e)
     (format "(~a ~a~a)"
             (symbol->string (method-call-method-name e))
             (emit-expr (method-call-target e))
             (emit-args (method-call-args e)))]
    [(static-call? e)
     (format "(~a~a)"
             (reference->clj (static-call-class+method e))
             (emit-args (static-call-args e)))]
    [(dynamic-var? e)
     (symbol->string (dynamic-var-name e))]
    [(ascription? e) (emit-expr (ascription-expr e))]
    [(check-expr? e)
     (define inner (emit-expr (check-expr-expr e)))
     (define contract
       (and (current-clj-semantic-contracts)
            (hash-ref (current-clj-semantic-contracts) e #f)))
     (if (error-contract? contract)
         inner
         (format
          (string-append
           "(let [r__check ~a]\n"
           "  (if (instance? Ok r__check)\n"
           "    (ok-value r__check)\n"
           "    (throw (ex-info (str \"check failed: \" (err-error r__check)) {:error r__check}))))")
          inner))]
    [(rescue-form? e)
     (define inner (emit-expr (rescue-form-expr e)))
     (define fallback (emit-expr (rescue-form-fallback e)))
     (define err-name (or (rescue-form-err-name e) '_))
     (define contract
       (and (current-clj-semantic-contracts)
            (hash-ref (current-clj-semantic-contracts) e #f)))
     (if (error-contract? contract)
         (let* ([variant (car (error-contract-payload-layout contract))]
                [member (car variant)]
                [fields (cdr variant)]
                [payload
                 (format
                  "(->~a ~a)"
                  member
                  (string-join
                   (for/list ([field (in-list fields)])
                     (if (eq? (param-name field) 'message)
                         "(ex-message err__exception)"
                         (format "(~a (ex-data err__exception))"
                                 (error-payload-keyword field))))
                   " "))])
           (format
            (string-append
             "(try\n"
             "  ~a\n"
             "  (catch clojure.lang.ExceptionInfo err__exception\n"
             "    (let [~a ~a]\n"
             "      ~a)))")
            inner err-name payload fallback))
         (format
          (string-append
           "(let [r__rescue ~a]\n"
           "  (if (instance? Ok r__rescue)\n"
           "    (ok-value r__rescue)\n"
           "    (let [~a r__rescue] ~a)))")
          inner err-name fallback))]
    [(target-case-form? e)
     (define target (current-emit-target))
     (define cases (target-case-form-cases e))
     (define branch (or (hash-ref cases target #f)
                        (hash-ref cases 'clj #f)))
     (unless branch
       (error 'beagle "target-case: no branch for target ~a" target))
     (emit-expr branch)]
    [(try-form? e)
     (format "(try\n  ~a~a~a)"
             (emit-body (try-form-body e) "  ")
             (string-join (for/list ([c (try-form-catches e)])
                 (format "\n  (catch ~a ~a\n    ~a)"
                         (catch-clause-exception-type c)
                         (binder-output-symbol c (catch-clause-name c))
                         (emit-body (catch-clause-body c) "    "))) "")
             (if (try-form-finally-body e)
               (format "\n  (finally\n    ~a)" (emit-body (try-form-finally-body e) "    "))
               ""))]
    [(doseq-form? e)
     (format "(doseq [~a]\n  ~a)"
             (emit-for-clauses (doseq-form-clauses e))
             (emit-body (doseq-form-body e) "  "))]
    [(dotimes-form? e)
     (format "(dotimes [~a ~a]\n  ~a)"
             (dotimes-form-name e)
             (emit-expr (dotimes-form-count-expr e))
             (emit-body (dotimes-form-body e) "  "))]
    [(condp-form? e)
     (define clause-strs
       (for/list ([c (condp-form-clauses e)])
         (format "~a ~a" (emit-expr (car c)) (emit-expr (cdr c)))))
     (define body (string-join clause-strs "\n  "))
     (if (condp-form-default e)
       (format "(condp ~a ~a\n  ~a\n  ~a)"
               (emit-expr (condp-form-pred-fn e))
               (emit-expr (condp-form-test-expr e))
               body
               (emit-expr (condp-form-default e)))
       (format "(condp ~a ~a\n  ~a)"
               (emit-expr (condp-form-pred-fn e))
               (emit-expr (condp-form-test-expr e))
               body))]
    [(case-form? e)
     (define clause-strs (for/list ([c (case-form-clauses e)])
       (format "~a ~a" (emit-expr (case-clause-value c)) (emit-expr (case-clause-body c)))))
     (define body (string-join clause-strs "\n  "))
     (if (case-form-default e)
       (format "(case ~a\n  ~a\n  ~a)" (emit-expr (case-form-test e)) body (emit-expr (case-form-default e)))
       (format "(case ~a\n  ~a)" (emit-expr (case-form-test e)) body))]
    [(new-form? e)
     (format "(~a~a)" (symbol->string (new-form-class-name e)) (emit-args (new-form-args e)))]
    [(kw-access? e)
     (if (kw-access-default e)
       (format "(~a ~a ~a)" (symbol->string (kw-access-kw e)) (emit-expr (kw-access-target e)) (emit-expr (kw-access-default e)))
       (format "(~a ~a)" (symbol->string (kw-access-kw e)) (emit-expr (kw-access-target e))))]
    [(match-form? e)
     (emit-match e)]
    [(with-form? e)
     (emit-with e)]
    [(call-form? e)
     (define fn-ref (call-form-fn e))
     (define fn-key (reference-key fn-ref))
     (cond
       ;; Scalar constructors/accessors erase to identity (zero runtime cost)
       [(and (set-member? (current-emit-scalar-fns) fn-key)
             (= 1 (length (call-form-args e))))
        (emit-expr (car (call-form-args e)))]
       ;; `bgl/promote` copies a value into an older epoch's arena. A hosted
       ;; target has one GC-owned heap and no epochs, so the value already
       ;; outlives every scope that could name it: the form erases, the same
       ;; way a type annotation does.
       [(and (qualified-reference=? fn-ref 'bgl 'promote)
             (= 1 (length (call-form-args e))))
        (emit-expr (car (call-form-args e)))]
       [(and (eq? fn-ref 'sha256-bytes)
             (= 1 (length (call-form-args e)))
             (not (set-member? (current-emit-local-names) fn-ref)))
        (format "(beagle$sha256_bytes_v0 ~a)"
                (emit-expr (car (call-form-args e))))]
       [(and (eq? fn-ref 'monotonic-nanoseconds)
             (= 0 (length (call-form-args e)))
             (not (set-member? (current-emit-local-names) fn-ref)))
        "(System/nanoTime)"]
       [else
        (define output-ref
          (if (symbol? fn-ref)
              (let ([mod-prefix
                     (hash-ref (current-emit-symbol-ns) fn-ref #f)])
                (if mod-prefix
                    (qualified-binding mod-prefix fn-ref)
                    fn-ref))
              fn-ref))
        (format "(~a~a)"
                (reference->clj output-ref)
                (emit-args (call-form-args e)))])]
    [(set!-form? e)
     (define target (set!-form-target e))
     (define val (emit-expr (set!-form-value e)))
     (cond
       [(method-call? target)
        (format "(set! (~a ~a) ~a)"
                (symbol->string (method-call-method-name target))
                (emit-expr (method-call-target target))
                val)]
       [(symbol? target)
        (format "(set! ~a ~a)" target val)]
       [else
        (format "(set! ~a ~a)" (emit-expr target) val)])]
    [(await-form? e)
     (error 'beagle-clj "await is only supported for JS target")]
    ;; --- Nix-only forms ---------------------------------------------------
    ;; These AST nodes only have well-defined semantics in the Nix target.
    ;; Reject them loudly here rather than fall through to the generic
    ;; "don't know how to emit" — the named-form error tells the user
    ;; exactly which Beagle construct doesn't have a Clojure equivalent.
    [(nix-with? e)              (reject-nix-form 'nix/with e)]
    [(nix-assert? e)            (reject-nix-form 'nix/assert e)]
    [(nix-with-cfg? e)          (reject-nix-form 'nix/with-cfg e)]
    [(nix-fn-set? e)            (reject-nix-form 'nix/fn-set e)]
    [(nix-derivation? e)        (reject-nix-form 'derivation e)]
    [(nix-flake? e)             (reject-nix-form 'flake e)]
    [(nix-inherit? e)           (reject-nix-form 'inherit e)]
    [(nix-inherit-from? e)      (reject-nix-form 'inherit-from e)]
    [(nix-rec-attrs? e)         (reject-nix-form 'rec-attrs e)]
    [(nix-get-or? e)            (reject-nix-form 'nix/get-or e)]
    [(nix-has-attr? e)          (reject-nix-form 'nix/has-attr e)]
    [(nix-search-path? e)       (reject-nix-form 'nix/search-path e)]
    [(nix-interpolated-string? e) (reject-nix-form 'nix/interpolated-string e)]
    [(nix-multiline-string? e)  (reject-nix-form 'nix/multiline-string e)]
    [(nix-path? e)              (reject-nix-form 'nix/path e)]
    [else (error 'beagle-emit "don't know how to emit: ~v" e)]))

;; Raise a pointed target-mismatch error. The form-name is the Beagle
;; surface spelling (`nix/with`, `derivation`, etc.) — not the Racket
;; struct name — so the diagnostic matches what the user typed.
(define (reject-nix-form form-name node)
  (error 'beagle-clj
         (string-append
          "(~a ...) is a Nix-only form; the ~a target rejects it. "
          "Move the form behind (target-case nix ...) if the call site "
          "is cross-target, or set the program target to nix.")
         form-name (current-emit-target)))

(define (emit-record f)
  (define name (record-form-name f))
  (define fields (record-form-fields f))
  (define name-str (symbol->string name))
  (define name-lower (string-downcase name-str))
  (define record-line
    (format "(defrecord ~a [~a])"
            name
            (string-join (map (lambda (p) (symbol->string (param-name p))) fields) " ")))
  (define accessor-lines
    (for/list ([p (in-list fields)])
      (define fname (symbol->string (param-name p)))
      (format "(defn ~a-~a [r] (:~a r))" name-lower fname fname)))
  (string-join
   (append (list record-line)
           (emit-record-constructor-guards name fields)
           accessor-lines)
   "\n\n"))

;; `defrecord` publishes both a positional factory and a map factory.  Snapshot
;; those generated factories before replacing them, and publish one validator
;; ABI used by both constructor wrappers and by cross-module `with` updates.
(define (record-validator-name name)
  (format "$beagle$record$~a$validate" (unqualify-type-name name)))

(define (statically-known-record-type? type)
  (define name
    (cond
      [(type-prim? type) (type-prim-name type)]
      [(type-app? type) (type-app-ctor type)]
      [else #f]))
  (and name (hash-has-key? (current-emit-record-fields) name)))

(define (emit-record-constructor-guards name fields)
  (define constrained
    (for/list ([field (in-list fields)] [index (in-naturals)]
               #:when (param-constraint field))
      (cons index field)))
  (cond
    [(null? constrained) '()]
    [else
     (define name-str (symbol->string name))
     (define positional (format "->~a" name-str))
     (define map-factory (format "map->~a" name-str))
     (define raw-positional
       (format "$beagle$record$~a$raw-constructor" name-str))
     (define raw-map
       (format "$beagle$record$~a$raw-map-constructor" name-str))
     (define validator (record-validator-name name))
     (define-values (guarded-positional-params guarded-positional-body)
       (emit-callable-signature+body
        fields
        #f
        (format
         "(~a~a)"
         raw-positional
         (if (null? fields)
             ""
             (string-append
              " "
              (string-join
               (for/list ([field (in-list fields)])
                 (symbol->string (param-name field)))
               " "))))))
     (define validation-bindings
       (apply
        append
        (for/list ([entry (in-list constrained)])
          (define index (car entry))
          (define field (cdr entry))
          (define field-name (symbol->string (param-name field)))
          (define raw-name (format "$beagle$record$field$~a" index))
          (define predicate-name
            (format "$beagle$record$constraint$~a" index))
          (define checked-name
            (format "$beagle$record$checked-field$~a" index))
          (list
           (format "~a (:~a $beagle$record$value)" raw-name field-name)
           (format "~a ~a" predicate-name
                   (emit-expr (param-constraint field)))
           (format "~a ~a" checked-name
                   (emit-guarded-binding-value
                    field predicate-name raw-name))))))
     (list
      (format "(def ^:private ~a ~a)" raw-positional positional)
      (format "(def ^:private ~a ~a)" raw-map map-factory)
      (format
       "(defn ~a [$beagle$record$value]\n  (let [~a]\n    $beagle$record$value))"
       validator
       (string-join validation-bindings "\n       "))
      (format
       "(defn ~a [~a]\n  ~a)"
       positional
       guarded-positional-params
       guarded-positional-body)
      (format
       "(defn ~a [$beagle$record$raw-map]\n  (~a (~a $beagle$record$raw-map)))"
       map-factory
       raw-map
       validator))]))

(define (emit-with e)
  (define target-str (emit-expr (with-form-target e)))
  (define update-strs
    (for/list ([u (in-list (with-form-updates e))])
      (format "~a ~a" (symbol->string (with-update-field-kw u))
                       (emit-expr (with-update-value u)))))
  (define updated
    (format "(assoc ~a ~a)" target-str (string-join update-strs " ")))
  (define missing-contract (gensym 'missing-record-update-contract))
  (define contract
    (hash-ref
     (current-clj-semantic-contracts)
     e
     missing-contract))
  (cond
    [(record-update-contract? contract)
     (define record-name (record-update-contract-record-name contract))
     (define field-order (record-update-contract-field-order contract))
     (unless (and (or (symbol? record-name) (qualified-ref? record-name))
                  (list? field-order)
                  (andmap
                   (lambda (field)
                     (and (symbol? field)
                          (string-prefix? (symbol->string field) ":")))
                   field-order))
       (error
        'beagle-clj
        "with-form has malformed checked record-update contract: ~v"
        contract))
     (define validator (record-update-contract-validator-symbol contract))
     (if validator
         ;; A persistent assoc may privately construct the complete candidate,
         ;; but that candidate must cross the provider-owned aggregate
         ;; validator before any authored return, projection, or use can see
         ;; it. The compiler-owned let makes that boundary explicit and keeps
         ;; target/update expressions single-evaluation.
         (format
          "(let [$beagle$record$update$candidate ~a]\n  (~a $beagle$record$update$candidate))"
          updated
          (reference->clj validator))
         updated)]
    [(eq? contract missing-contract)
     ;; Direct emitter-unit callers historically omit the checker entirely.
     ;; Production compilation supplies a type table; a typed update in that
     ;; mode must never guess record ownership or silently skip validation.
     (define type-table (current-type-table))
     (if (and type-table
              (statically-known-record-type? (hash-ref type-table e #f)))
         (error
          'beagle-clj
          "typed with-form lacks its checked record-update contract")
         updated)]
    [else
     (error 'beagle-clj
            "with-form has invalid record-update contract: ~v"
            contract)]))

(define (emit-defenum f)
  (define name (defenum-form-name f))
  (define vals (defenum-form-values f))
  (define val-strs (map (lambda (v) (format ":~a" v)) vals))
  (format "(def ~a-values #{~a})" name (string-join val-strs " ")))

;; Emit `(defrecord Name [f1 f2 ...])` plus its `name-f1` accessors from a
;; member symbol + its field params. The accessors are not optional: check.rkt
;; registers `circle-radius` for every variant field, so omitting them emits
;; calls to an undefined symbol.
(define (emit-variant-defrecord name fields)
  (cond
    [(null? fields)
     (format "(defrecord ~a [])" name)]
    [else
     (define name-lower (string-downcase (symbol->string name)))
     (string-join
      (append
       (list (format "(defrecord ~a [~a])"
                     name
                     (string-join
                      (map (lambda (p) (symbol->string (param-name p))) fields)
                      " ")))
       (emit-record-constructor-guards name fields)
       (for/list ([p (in-list fields)])
         (define fname (symbol->string (param-name p)))
         (format "(defn ~a-~a [r] (:~a r))" name-lower fname fname)))
      "\n\n")]))

(define (emit-defunion f)
  (define name (defunion-form-name f))
  (define members (defunion-form-members f))
  (define member-fields (defunion-form-member-fields f))
  (define comment
    (format ";; ~a = ~a" name (string-join (map symbol->string members) " | ")))
  (cond
    [(not member-fields) comment]
    [else
     (string-append
      comment "\n"
      (string-join
       (for/list ([m (in-list members)])
         (emit-variant-defrecord m (hash-ref member-fields m '())))
       "\n"))]))

(define (emit-deferror f)
  (define name (deferror-form-name f))
  (define members (deferror-form-members f))
  (define mf (deferror-form-member-fields f))
  (define comment
    (format ";; error ~a = ~a" name (string-join (map symbol->string members) " | ")))
  (string-append
   comment "\n"
   (string-join
    (for/list ([m (in-list members)])
      (emit-variant-defrecord m (hash-ref mf m '())))
    "\n")))

(define (emit-defscalar f)
  (define name (defscalar-form-name f))
  (define backing (defscalar-form-backing-type f))
  (define preds (defscalar-form-predicates f))
  (if (null? preds)
    (format ";; ~a : ~a (scalar)" name backing)
    (let ([ctor (string-append "->" (symbol->string name))]
          [pre-exprs (string-join
                       (for/list ([p (in-list preds)])
                         (format "(~a v ~a)" (scalar-predicate-op p) (scalar-predicate-value p)))
                       " ")])
      (format "(defn ~a [v]\n  {:pre [~a]}\n  v)" ctor pre-exprs))))

;; Case-fold optimization: if every match clause is a literal-dispatch
;; pattern (pat-literal, or pat-or with all-literal alternatives) with
;; optional wildcard/var as the final clause, emit Clojure's `case`
;; form for O(1) dispatch. Otherwise fall through to the general
;; (let ... (cond ...)) emission.
;;
;; This preserves the perf characteristic of the dropped `case` form
;; after it gets folded into match + or-pattern (see design-principle.md
;; "Emit-layer obligations for surface drops").
(define (case-foldable-pattern? pat)
  (cond
    [(pat-literal? pat) #t]
    [(pat-or? pat)
     (andmap (lambda (alt) (or (pat-literal? alt) (pat-wildcard? alt)))
             (pat-or-alternatives pat))]
    [else #f]))

(define (case-foldable-match? clauses)
  (cond
    [(null? clauses) #f]
    [else
     (define non-tail (drop-right clauses 1))
     (define tail (last clauses))
     (define tail-pat (match-clause-pattern tail))
     (and (andmap (lambda (c) (case-foldable-pattern? (match-clause-pattern c)))
                  non-tail)
          (or (case-foldable-pattern? tail-pat)
              (pat-wildcard? tail-pat)
              (pat-var? tail-pat)))]))

(define (emit-case-folded-match clauses target-sym target-str)
  ;; Each non-default clause becomes `(value or value-list) body`.
  ;; Final wildcard/var becomes the case default (no key).
  (define-values (dispatch-clauses default-clause)
    (let* ([tail (last clauses)]
           [tail-pat (match-clause-pattern tail)])
      (cond
        [(or (pat-wildcard? tail-pat) (pat-var? tail-pat))
         (values (drop-right clauses 1) tail)]
        [else (values clauses #f)])))
  (define clause-strs
    (for/list ([c (in-list dispatch-clauses)])
      (define pat (match-clause-pattern c))
      (define body-str (emit-body (match-clause-body c) "      "))
      (define key-str
        (cond
          [(pat-literal? pat) (emit-pat-literal-value pat)]
          [(pat-or? pat)
           (define vals
             (for/list ([alt (in-list (pat-or-alternatives pat))]
                        #:when (pat-literal? alt))
               (emit-pat-literal-value alt)))
           (format "(~a)" (string-join vals " "))]))
      (format "~a ~a" key-str body-str)))
  (define default-str
    (cond
      [(not default-clause) ""]
      [(pat-wildcard? (match-clause-pattern default-clause))
       (format "\n    ~a" (emit-body (match-clause-body default-clause) "      "))]
      [(pat-var? (match-clause-pattern default-clause))
       (define var (pat-var-name default-clause))
       (format "\n    (let [~a ~a] ~a)"
               (binder-output-symbol
                (match-clause-pattern default-clause)
                (pat-var-name (match-clause-pattern default-clause)))
               target-sym
               (emit-body (match-clause-body default-clause) "      "))]))
  (format "(case ~a\n    ~a~a)"
          target-str
          (string-join clause-strs "\n    ")
          default-str))

(define (emit-pat-literal-value pat)
  (define val (pat-literal-value pat))
  (cond
    [(eq? val 'nil) "nil"]
    [(string? val) (emit-clj-string val)]
    [(boolean? val) (if val "true" "false")]
    [(char? val) (emit-clj-char val)]
    [(and (symbol? val) (char=? (string-ref (symbol->string val) 0) #\:))
     (symbol->string val)]
    [else (format "~a" val)]))

;; Deterministic match temp names: a per-program counter (parameterized fresh in
;; clj-emit-program), NOT (random ...). The same source must compile BYTE-IDENTICALLY
;; every build — `random` made `match` build-nondeterministic, breaking reproducible
;; builds (and forcing the code-as-facts recompile gate to guard around it).
(define match-counter (make-parameter (box 0)))
(define (fresh-match-sym!)
  (define b (match-counter))
  (define n (unbox b))
  (set-box! b (add1 n))
  (format "match__~a" n))

(define (emit-match e)
  (define target-str (emit-expr (match-form-target e)))
  (define clauses (match-form-clauses e))
  (cond
    [(case-foldable-match? clauses)
     ;; Optimization: pure literal dispatch → Clojure `case` (O(1)).
     (define target-sym (fresh-match-sym!))
     (emit-case-folded-match clauses target-sym target-str)]
    [else
     ;; General path: (let [tmp target] (cond ...))
     (define target-sym (fresh-match-sym!))
     (define cond-pairs
       (for/list ([c (in-list clauses)])
         (emit-match-arm c target-sym)))
     (format "(let [~a ~a]\n  (cond\n    ~a))"
             target-sym target-str
             (string-join cond-pairs "\n    "))]))

;; Pattern test expression for a literal pattern. Extracted so or-pattern
;; can compose tests across alternatives. Returns a Clojure boolean
;; expression that evaluates to true if `target-sym` matches `pat`.
(define (emit-pat-literal-test pat target-sym)
  (define val (pat-literal-value pat))
  (cond
    [(eq? val 'nil) (format "(nil? ~a)" target-sym)]
    [(string? val)  (format "(= ~a ~a)" target-sym (emit-clj-string val))]
    [(boolean? val) (format "(~a ~a)" (if val "true?" "false?") target-sym)]
    [(char? val)    (format "(= ~a ~a)" target-sym (emit-clj-char val))]
    [(and (symbol? val) (char=? (string-ref (symbol->string val) 0) #\:))
     (format "(= ~a ~a)" target-sym (symbol->string val))]
    [else (format "(= ~a ~a)" target-sym val)]))

(define (emit-match-arm clause target-sym)
  (define pat (match-clause-pattern clause))
  (define body-str (emit-body (match-clause-body clause) "      "))
  (cond
    [(pat-wildcard? pat)
     (format ":else ~a" body-str)]
    [(pat-var? pat)
     (format ":else (let [~a ~a] ~a)"
             (binder-output-symbol pat (pat-var-name pat)) target-sym body-str)]
    [(pat-literal? pat)
     (format "~a ~a" (emit-pat-literal-test pat target-sym) body-str)]
    ;; or-pattern (v1: literal-only alternatives). Combines per-alternative
    ;; tests with `or`. Future operators (and, not, guards) would slot in
    ;; as sibling cases here.
    [(pat-or? pat)
     (define tests
       (for/list ([alt (in-list (pat-or-alternatives pat))])
         (cond
           [(pat-literal? alt) (emit-pat-literal-test alt target-sym)]
           [(pat-wildcard? alt) "true"]
           [else (error 'emit-clj
                        "or-pattern (v1) supports literal alternatives only; got: ~v"
                        alt)])))
     (format "(or ~a) ~a" (string-join tests " ") body-str)]
    [(pat-record? pat)
     (define rec-ref (pat-record-type-name pat))
     (define rec-key (reference-key rec-ref))
     (define rec-name
       (if (qualified-ref? rec-ref)
           (qualified-ref-name rec-ref)
           rec-ref))
     (define bindings (pat-record-bindings pat))
     (define direct-fields
       (hash-ref (current-emit-record-fields) rec-key #f))
     (define direct-ns
       (or (hash-ref (current-emit-record-ns) rec-key #f)
           (and (qualified-ref? rec-ref)
                (qualified-ref-provider-id rec-ref))))
     (define candidates
       (if direct-fields
           '()
           (for/list ([candidate
                       (in-hash-keys (current-emit-record-fields))]
                      #:when
                      (eq? (if (pair? candidate)
                               (cdr candidate)
                               (unqualify-type-name candidate))
                           rec-name))
             (cons
              (hash-ref (current-emit-record-fields) candidate)
              (hash-ref (current-emit-record-ns) candidate #f)))))
     (define resolutions (remove-duplicates candidates equal?))
     (when (> (length resolutions) 1)
       (error 'emit-clj "ambiguous imported record pattern: ~a" rec-name))
     (define resolved (and (pair? resolutions) (car resolutions)))
     (define fields (or direct-fields (and resolved (car resolved))))
     (define rec-ns (or direct-ns (and resolved (cdr resolved))))
     (define qualified-name
       (if rec-ns
         (format "~a.~a" rec-ns rec-name)
         (reference->clj rec-ref)))
     (define test (format "(instance? ~a ~a)" qualified-name target-sym))
     (cond
       [(or (null? bindings) (not fields))
        (format "~a ~a" test body-str)]
       [else
        (define let-pairs
          (for/list ([b (in-list bindings)]
                     [fname (in-list fields)])
            (format "~a (:~a ~a)"
                    (binder-output-symbol pat b) fname target-sym)))
        (format "~a (let [~a] ~a)" test (string-join let-pairs " ") body-str)])]
    [(pat-map? pat)
     (define tests
       (for/list ([entry (in-list (pat-map-entries pat))])
         (define k (symbol->string (car entry)))
         (define v (cdr entry))
         (cond
           [(pat-literal? v)
            (define val (pat-literal-value v))
            (cond
              [(string? val) (format "(= (~a ~a) ~a)" k target-sym (emit-clj-string val))]
              [(eq? val 'nil) (format "(nil? (~a ~a))" k target-sym)]
              [else (format "(= (~a ~a) ~a)" k target-sym val)])]
           [(pat-wildcard? v) "true"]
           [else (format "(some? (~a ~a))" k target-sym)])))
     (define test
       (if (= (length tests) 1) (car tests)
           (format "(and ~a)" (string-join tests " "))))
     ;; G4-emit: bind each VAR entry to (:k target) so the arm body can reference it.
     ;; Previously the var was emitted FREE (undefined at runtime) — a latent bug.
     (define binds
       (for/list ([entry (in-list (pat-map-entries pat))]
                  #:when (pat-var? (cdr entry)))
         (format "~a (~a ~a)"
                 (binder-output-symbol pat (pat-var-name (cdr entry)))
                 (symbol->string (car entry)) target-sym)))
     (if (null? binds)
         (format "~a ~a" test body-str)
         (format "~a (let [~a] ~a)" test (string-join binds " ") body-str))]))

(define (protocol-raw-method-name protocol-name method-name)
  (format "$beagle$protocol$~a$~a"
          (unqualify-type-name protocol-name)
          method-name))

(define (emit-protocol-wrapper protocol-name method)
  (define params (protocol-method-params method))
  (define rest-p (protocol-method-rest-param method))
  (define all-params (params+rest params rest-p))
  (define raw-names
    (for/list ([param (in-list all-params)] [index (in-naturals)])
      (if (= index (length params))
          "$beagle$constraint$raw-rest"
          (format "$beagle$constraint$raw-param$~a" index))))
  (define rest-normalization
    (if rest-p
        (list
         (format "~a (vec ~a)" (last raw-names) CLJ-HOST-REST))
        '()))
  (define predicate-bindings
    (for/list ([param (in-list all-params)]
               [index (in-naturals)]
               #:when (param-constraint param))
      (format "$beagle$constraint$predicate$~a ~a"
              index (emit-expr (param-constraint param)))))
  (define checked-names
    (for/list ([param (in-list all-params)] [index (in-naturals)])
      (format "$beagle$constraint$checked-param$~a" index)))
  (define checked-bindings
    (for/list ([param (in-list all-params)]
               [raw (in-list raw-names)]
               [checked (in-list checked-names)]
               [index (in-naturals)])
      (format
       "~a ~a"
       checked
       (if (param-constraint param)
           (emit-guarded-binding-value
            param (format "$beagle$constraint$predicate$~a" index) raw)
           raw))))
  (define call-args
    (if (null? predicate-bindings) raw-names checked-names))
  (define call
    (if rest-p
        (format "(apply ~a ~a)"
                (protocol-raw-method-name
                 protocol-name (protocol-method-name method))
                (string-join call-args " "))
        (format "(~a~a)"
                (protocol-raw-method-name
                 protocol-name (protocol-method-name method))
                (if (null? call-args)
                    ""
                    (string-append " " (string-join call-args " "))))))
  (format
   "(defn ~a [~a]\n  ~a)"
   (protocol-method-name method)
   (string-join
    (append (take raw-names (length params))
            (if rest-p (list "&" CLJ-HOST-REST) '()))
    " ")
   (cond
     [(and (null? rest-normalization) (null? predicate-bindings)) call]
     [(null? predicate-bindings)
      (format "(let [~a]\n    ~a)"
              (string-join rest-normalization "\n       ")
              call)]
     [else
      (format "(let [~a]\n    (let [~a]\n      ~a))"
              (string-join
               (append rest-normalization predicate-bindings)
               "\n       ")
              (string-join checked-bindings "\n         ")
              call)])))

(define (emit-protocol f)
  (define protocol-name (protocol-form-name f))
  (define methods (protocol-form-methods f))
  (define raw-sigs
    (for/list ([method (in-list methods)])
      (format
       "(~a [~a])"
       (protocol-raw-method-name protocol-name (protocol-method-name method))
       (string-join
        (append
         (for/list ([param (in-list (protocol-method-params method))]
                    [index (in-naturals)])
           (format "$beagle$constraint$raw-param$~a" index))
         (if (protocol-method-rest-param method)
             (list "&" "$beagle$constraint$raw-rest")
             '()))
        " "))))
  (string-append
   (format "(defprotocol ~a\n  ~a)"
           protocol-name (string-join raw-sigs "\n  "))
   "\n\n"
   (string-join
    (for/list ([method (in-list methods)])
      (emit-protocol-wrapper protocol-name method))
    "\n\n")))

(define (emit-extend-type f)
  (define impl-strs (map emit-type-impl (extend-type-form-impls f)))
  (format "(extend-type ~a\n  ~a)"
          (extend-type-form-type-name f)
          (string-join impl-strs "\n  ")))

(define (emit-type-impl impl)
  (define proto-line (symbol->string (type-impl-protocol-name impl)))
  (define method-lines
    (for/list ([m (type-impl-methods impl)])
      (define-values (params-str body-str)
        (emit-callable-signature+body
         (impl-method-params m) (impl-method-rest-param m)
         (emit-body (impl-method-body m) "    ")))
      (format "(~a [~a]\n    ~a)"
              (protocol-raw-method-name
               (type-impl-protocol-name impl) (impl-method-name m))
              params-str
              body-str)))
  (string-append proto-line "\n  " (string-join method-lines "\n  ")))

(define (emit-seq-destructure d [owner #f])
  ;; Entries are symbols or nested destructure patterns — recurse through
  ;; emit-binding-name so [[k v] m]-style nesting round-trips.
  (define names-str
    (string-join
     (for/list ([n (in-list (seq-destructure-names d))])
       (emit-binding-name n owner))
     " "))
  (if (seq-destructure-rest-name d)
    (format "[~a & ~a]"
            names-str
            (binder-output-symbol owner (seq-destructure-rest-name d)))
    (format "[~a]" names-str)))

(define (emit-map-destructure d [owner #f])
  (define keys-str
    (string-join
     (map (lambda (name)
            (symbol->string (binder-output-symbol owner name)))
          (map-destructure-keys d))
     " "))
  (define or-str
    (if (null? (map-destructure-or-defaults d))
        ""
        (format " :or {~a}"
                (string-join
                 (for/list ([od (in-list (map-destructure-or-defaults d))])
                   (format "~a ~a" (car od) (emit-expr (cdr od))))
                 " "))))
  (define as-str
    (if (map-destructure-as-name d)
        (format " :as ~a"
                (binder-output-symbol owner (map-destructure-as-name d)))
        ""))
  (format "{:keys [~a]~a~a}" keys-str or-str as-str))

;; Emit any binding name target — plain symbol, map destructure, or seq destructure.
;; Used by params, let-bindings, for-bindings.
(define (emit-binding-name name [owner #f])
  (cond
    [(param? name)           (emit-binding-name (param-name name) name)]
    [(map-destructure? name) (emit-map-destructure name owner)]
    [(seq-destructure? name) (emit-seq-destructure name owner)]
    [(symbol? name)
     (symbol->string (if owner (binder-output-symbol owner name) name))]
    [else (error 'beagle-clj "unsupported binding target: ~v" name)]))

(define (emit-args args)
  (cond
    [(null? args) ""]
    [else (string-append " " (string-join (map emit-expr args) " "))]))

(define (emit-param p) (emit-binding-name p p))

;; --- binding constraints ---------------------------------------------------

(define (binding-target binding)
  (cond
    [(param? binding) (param-name binding)]
    [(let-binding? binding) (let-binding-name binding)]
    [(for-binding? binding) (for-binding-name binding)]
    [else (param-binding-target binding)]))

(define (binding-constraint binding)
  (cond
    [(param? binding) (param-constraint binding)]
    [(let-binding? binding) (let-binding-constraint binding)]
    [(for-binding? binding) (for-binding-constraint binding)]
    [else #f]))

(define (binding-target-label binding)
  (define target (binding-target binding))
  (cond
    [(symbol? target) (symbol->string target)]
    [else (emit-binding-name target)]))

(define (binding-constraint-failure binding raw-name)
  (define label (binding-target-label binding))
  (format
   (string-append
    "(throw (ex-info ~a {:binding ~a :value ~a}))")
   (emit-clj-string (format "Binding constraint failed: ~a" label))
   (emit-clj-string label)
   raw-name))

(define (binding-constraint-proof binding)
  (and (current-clj-semantic-contracts)
       (hash-ref (current-clj-semantic-contracts) binding #f)))

(define (emit-guarded-binding-value binding predicate-name raw-name)
  (define proof (binding-constraint-proof binding))
  (unless (and (binding-constraint-contract? proof)
               (binding-constraint-contract-synchronous? proof))
    (error
     'beagle-clj
     (string-append
      "binding constraint for ~a lacks the compiler's positive "
      "synchronization proof; checked emission refuses to call it")
     (binding-target-label binding)))
  (format "(if (~a ~a) ~a ~a)"
          predicate-name raw-name raw-name
          (binding-constraint-failure binding raw-name)))

(define (bindings-have-constraints? bindings)
  (for/or ([binding (in-list bindings)])
    (and (binding-constraint binding) #t)))

(define (params+rest params rest-p)
  (if rest-p (append params (list rest-p)) params))

(define (callable-has-constraints? params rest-p)
  (bindings-have-constraints? (params+rest params rest-p)))

(define (param-tag-prefix p)
  ;; Clojure type hints attach only to identifier binders. An annotation on a
  ;; destructuring pattern remains a Beagle checking boundary, not a JVM tag.
  (if (and (param? p) (symbol? (param-binding-target p)))
      (clj-tag-prefix (param-type p))
      ""))

;; A constrained callable cannot expose any authored parameter name before all
;; parameter predicates have been captured. Otherwise a predicate expression
;; that resolved to an outer name could be captured accidentally by a sibling
;; or its own parameter. Every source parameter therefore receives a reserved
;; raw slot; an outer let captures predicates, and an inner let guards then
;; binds/projects the source targets.
(define (emit-constrained-callable params rest-p body-str)
  (define all (params+rest params rest-p))
  (define fixed-count (length params))
  (define raw-names
    (for/list ([binding (in-list all)] [index (in-naturals)])
      (if (= index fixed-count)
          "$beagle$constraint$raw-rest"
          (format "$beagle$constraint$raw-param$~a" index))))
  (define fixed-raw
    (for/list ([raw (in-list (take raw-names fixed-count))]
               [binding (in-list params)])
      (string-append (param-tag-prefix binding) raw)))
  (define params-str
    (string-join
     (append fixed-raw
             (if rest-p
                 (list "&" CLJ-HOST-REST)
                 '()))
     " "))
  (define rest-normalization
    (if rest-p
        (list
         (format "~a (vec ~a)" (last raw-names) CLJ-HOST-REST))
        '()))
  (define predicate-bindings
    (for/list ([binding (in-list all)]
               [index (in-naturals)]
               #:when (binding-constraint binding))
      (format "$beagle$constraint$predicate$~a ~a"
              index (emit-expr (binding-constraint binding)))))
  (define checked-names
    (for/list ([binding (in-list all)] [index (in-naturals)])
      (format "$beagle$constraint$checked-param$~a" index)))
  (define checked-bindings
    (for/list ([binding (in-list all)]
               [raw (in-list raw-names)]
               [checked (in-list checked-names)]
               [index (in-naturals)])
      (format
       "~a ~a"
       checked
       (if (binding-constraint binding)
           (emit-guarded-binding-value
            binding (format "$beagle$constraint$predicate$~a" index) raw)
           raw))))
  (define target-bindings
    (for/list ([binding (in-list all)]
               [checked (in-list checked-names)])
      (format "~a ~a"
              (emit-binding-name (binding-target binding))
              checked)))
  (values
   params-str
   (format "(let [~a]\n  (let [~a]\n    (let [~a]\n      ~a)))"
           (string-join
            (append rest-normalization predicate-bindings)
            "\n       ")
           (string-join checked-bindings "\n       ")
           (string-join target-bindings "\n       ")
           body-str)))

(define (emit-unconstrained-callable params rest-p body-str)
  (define params-str
    (emit-params-with-rest
     params rest-p
     #:rest-name (and rest-p CLJ-HOST-REST)))
  (values
   params-str
   (if rest-p
       (format "(let [~a (vec ~a)]\n  ~a)"
               (emit-binding-name (param-binding-target rest-p))
               CLJ-HOST-REST
               body-str)
       body-str)))

(define (emit-callable-signature+body params rest-p body-str)
  (if (callable-has-constraints? params rest-p)
      (emit-constrained-callable params rest-p body-str)
      (emit-unconstrained-callable params rest-p body-str)))

;; Emit one param with an optional type-hint prefix. tag-prefix is a
;; pre-formatted string like "^Int " or "" — see clj-tag-prefix.
(define (emit-param/tag p tag-prefix)
  ;; Clojure type hints attach to identifier binders.  An aggregate annotation
  ;; on a destructuring pattern is a Beagle checking boundary, not a JVM local
  ;; tag, so emitting it on `[...]` / `{...}` would be invalid host syntax.
  (if (symbol? (param-binding-target p))
      (string-append tag-prefix (emit-param p))
      (emit-param p)))

;; Rest params remain untagged because Clojure rest args are heterogeneous.
(define (emit-params-with-rest params rest-p
                               #:rest-name [rest-name #f])
  (define fixed
    (string-join
     (for/list ([p (in-list params)])
       (emit-param/tag p (param-tag-prefix p)))
     " "))
  (if rest-p
      (let ([emitted-rest (or rest-name (emit-param rest-p))])
      (if (string=? fixed "")
          (format "& ~a" emitted-rest)
          (format "~a & ~a" fixed emitted-rest)))
      fixed))

(define (emit-let-bindings bindings)
  (string-join
   (apply
    append
    (for/list ([b (in-list bindings)] [index (in-naturals)])
      (define target (emit-binding-name (let-binding-name b) b))
      (define value (emit-expr (let-binding-value b)))
      (define constraint (let-binding-constraint b))
      (cond
        [constraint
         (define raw-name (format "$beagle$constraint$raw-binding$~a" index))
         (define predicate-name
           (format "$beagle$constraint$predicate$~a" index))
         (list
          (format "~a ~a" raw-name value)
          (format "~a ~a" predicate-name (emit-expr constraint))
          (format "~a ~a" target
                  (emit-guarded-binding-value b predicate-name raw-name)))]
        [else (list (format "~a ~a" target value))])))
   "\n   "))

(define (emit-with-open-chain bindings body-str [index 0])
  (cond
    [(null? bindings) body-str]
    [else
     (define b (car bindings))
     (define target (emit-binding-name (let-binding-name b) b))
     (define value (emit-expr (let-binding-value b)))
     (define inner
       (emit-with-open-chain (cdr bindings) body-str (add1 index)))
     (define constraint (let-binding-constraint b))
     (if constraint
         (let ([predicate-name
                (format "$beagle$constraint$predicate$~a" index)]
               [raw-name (format "$beagle$constraint$raw-open$~a" index)])
           (format
            "(with-open [~a ~a]\n  (let [~a ~a\n        ~a ~a]\n    ~a))"
            raw-name value
            predicate-name (emit-expr constraint)
            target (emit-guarded-binding-value b predicate-name raw-name)
            inner))
         (format "(with-open [~a ~a]\n  ~a)" target value inner))]))

(define (emit-dynamic-binding-chain bindings body-str)
  (define capture-bindings
    (apply
     append
     (for/list ([binding (in-list bindings)] [index (in-naturals)])
       (define raw-name
         (format "$beagle$constraint$raw-dynamic$~a" index))
       (define constraint (let-binding-constraint binding))
       (append
        (list (format "~a ~a" raw-name
                      (emit-expr (let-binding-value binding))))
        (if constraint
            (list
             (format "$beagle$constraint$predicate$~a ~a"
                     index (emit-expr constraint))
             (format "$beagle$constraint$checked-dynamic$~a ~a"
                     index
                     (emit-guarded-binding-value
                      binding
                      (format "$beagle$constraint$predicate$~a" index)
                      raw-name)))
            '())))))
  (define dynamic-bindings
    (for/list ([binding (in-list bindings)] [index (in-naturals)])
      (define raw-name
        (format "$beagle$constraint$raw-dynamic$~a" index))
      (define constraint (let-binding-constraint binding))
      (format
       "~a ~a"
       (emit-binding-name (let-binding-name binding) binding)
       (if constraint
           (format "$beagle$constraint$checked-dynamic$~a" index)
           raw-name))))
  (format "(let [~a]\n  (binding [~a]\n    ~a))"
          (string-join capture-bindings "\n       ")
          (string-join dynamic-bindings "\n            ")
          body-str))

(define (emit-loop-with-constraints e)
  (define bindings (loop-form-bindings e))
  (cond
    [(not (bindings-have-constraints? bindings))
     (format "(loop [~a]\n  ~a)"
             (emit-let-bindings bindings)
             (parameterize ([current-clj-loop-recur-context #f])
               (emit-body (loop-form-body e) "  ")))]
    [else
     (define raw-names
       (for/list ([binding (in-list bindings)] [index (in-naturals)])
         (format "$beagle$constraint$raw-loop$~a" index)))
     (define init-bindings
       (apply
        append
        (for/list ([binding (in-list bindings)]
                   [raw (in-list raw-names)]
                   [index (in-naturals)])
          (define constraint (let-binding-constraint binding))
          (define target (emit-binding-name (let-binding-name binding) binding))
          (append
           (list (format "~a ~a" raw
                         (emit-expr (let-binding-value binding))))
           (if constraint
               (list
                (format "$beagle$constraint$init-predicate$~a ~a"
                        index (emit-expr constraint)))
               '())
           (list
            (format
             "~a ~a"
             target
             (if constraint
                 (emit-guarded-binding-value
                  binding
                  (format "$beagle$constraint$init-predicate$~a" index)
                  raw)
                 raw)))))))
     (define iteration-bindings
       (for/list ([binding (in-list bindings)]
                  [raw (in-list raw-names)]
                  [index (in-naturals)])
         (define constraint (let-binding-constraint binding))
         (format
          "~a ~a"
          (emit-binding-name (let-binding-name binding) binding)
          (if constraint
              (format
               (string-append
                "(if $beagle$constraint$first-iteration ~a "
                "(let [$beagle$constraint$predicate$~a ~a] ~a))")
               raw index (emit-expr constraint)
               (emit-guarded-binding-value
                binding (format "$beagle$constraint$predicate$~a" index) raw))
              raw))))
     (define body-str
       (parameterize ([current-clj-loop-recur-context (length bindings)])
         (emit-body (loop-form-body e) "    ")))
     (format
      (string-append
       "(let [$beagle$constraint$initial-values (let [~a] [~a])]\n"
       "  (loop [~a $beagle$constraint$first-iteration true]\n"
       "    (let [~a]\n"
       "      ~a)))")
      (string-join init-bindings "\n       ")
      (string-join raw-names " ")
      (string-join
       (for/list ([raw (in-list raw-names)] [index (in-naturals)])
         (format "~a (nth $beagle$constraint$initial-values ~a)" raw index))
       " ")
      (string-join iteration-bindings "\n         ")
      body-str)]))

(define (emit-for-clauses clauses)
  (string-join
   (apply
    append
    (for/list ([c (in-list clauses)] [index (in-naturals)])
      (cond
        [(for-binding? c)
         (define constraint (for-binding-constraint c))
         (if constraint
             (let ([raw-name (format "$beagle$constraint$raw-for$~a" index)]
                   [predicate-name
                    (format "$beagle$constraint$predicate$~a" index)])
               (list
                (format "~a ~a" raw-name (emit-expr (for-binding-expr c)))
                (format
                 ":let [~a ~a\n         ~a ~a]"
                 predicate-name (emit-expr constraint)
                 (emit-binding-name (for-binding-name c) c)
                 (emit-guarded-binding-value c predicate-name raw-name))))
             (list
              (format "~a ~a"
                      (emit-binding-name (for-binding-name c) c)
                      (emit-expr (for-binding-expr c)))))]
        [(for-when? c)
         (list (format ":when ~a" (emit-expr (for-when-test c))))]
        [(for-let? c)
         (list
          (format ":let [~a]"
                  (emit-let-bindings (for-let-bindings c))))]
        [else '()])))
   "\n   "))

(define (emit-body exprs indent)
  (string-join (map emit-expr exprs) (string-append "\n" indent)))

(define (datum->clj d)
  (cond
    [(string? d)        (emit-clj-string d)]
    [(boolean? d)       (if d "true" "false")]
    [(exact-integer? d) (number->string d)]
    [(real? d)          (emit-clj-number d)]
    [(char? d)          (emit-clj-char d)]
    [(symbol? d)        (symbol->string d)]
    [(null? d)          "()"]
    [(bracketed? d)
     ;; '[a b c] -> [a b c] (Clojure vector literal — quote-stable)
     (format "[~a]"
             (string-join (map datum->clj (bracket-body d)) " "))]
    [(map-tagged? d)
     ;; '{:k v ...} -> {:k v ...} (Clojure map literal)
     (format "{~a}"
             (string-join (map datum->clj (map-body d)) " "))]
    [(set-tagged? d)
     ;; '#{a b c} -> #{a b c} (Clojure set literal)
     (format "#{~a}"
             (string-join (map datum->clj (set-body d)) " "))]
    [(pair? d)
     (format "(~a)"
             (string-join
              (let loop ([d d] [acc '()])
                (cond
                  [(null? d) (reverse acc)]
                  [(pair? d) (loop (cdr d) (cons (datum->clj (car d)) acc))]
                  [else (reverse (cons (string-append ". " (datum->clj d)) acc))]))
              " "))]
    [else (~v d)]))

(define clj-backend
  (emitter-backend 'clj clj-emit-program))

(register-backend! 'clj clj-backend)

(provide clj-backend
         clj-emit-program
         current-emit-target)
