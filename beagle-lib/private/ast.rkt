#lang racket/base

;; AST struct definitions and shared utilities for beagle's parse pipeline.
;; Extracted from parse.rkt to reduce module size and allow direct struct imports.

(require "types.rkt")

;; --- tag aliases -----------------------------------------------------------
(define BT BRACKET-TAG)
(define MT MAP-TAG)
(define ST SET-TAG)

(define (bracketed? d)        (and (pair? d) (eq? (car d) BT)))
(define (bracket-body d)      (cdr d))

(define (map-tagged? d)       (and (pair? d) (eq? (car d) MT)))
(define (map-body d)          (cdr d))

(define (set-tagged? d)       (and (pair? d) (eq? (car d) ST)))
(define (set-body d)          (cdr d))

(define (unwrap-items d what)
  (cond
    [(bracketed? d) (bracket-body d)]
    [(list? d)      d]
    [else (error 'beagle "expected ~a, got: ~v" what d)]))

(define (unwrap-stxs psubs d)
  (cond
    [(and psubs (bracketed? d)) (cdr psubs)]
    [psubs psubs]
    [else #f]))

;; --- identifier safety -----------------------------------------------------
(define unsafe-ident-rx #rx"[;'\"` \t\n\r(){}\\[\\]\\\\,]")

(define (validate-identifier! sym [context "identifier"])
  (when (symbol? sym)
    (define s (symbol->string sym))
    (when (regexp-match? unsafe-ident-rx s)
      (error 'beagle
             "~a '~a' contains characters that would inject code in target output"
             context s))))

;; A leading `@` is allowed exactly once, matching npm's scoped-package
;; specifier shape (`@scope/pkg`, `@scope/pkg/sub`) — emit-js.rkt's
;; `emit-module-header` already special-cases an `@`-prefixed namespace
;; (passes it through verbatim as the JS import specifier), so this validator
;; must accept what that emission path already handles. `@` is restricted to
;; the first character only; the character class for the remainder is
;; unchanged, so this stays exactly as strict against injection as before.
(define valid-module-path-rx #rx"^@?[a-zA-Z0-9._/-]+$")
(define (validate-module-path! sym)
  (when (symbol? sym)
    (define s (symbol->string sym))
    (unless (regexp-match? valid-module-path-rx s)
      (error 'beagle
             "require namespace '~a' contains invalid characters"
             s))
    (when (regexp-match? #rx"(^|[./])\\.\\.($|[./])" s)
      (error 'beagle
             "require namespace '~a' contains '..' path traversal"
             s))))

;; --- source locations ------------------------------------------------------
;; A position carries line/col/source PLUS an origin tag and a canonical
;; flag, mirroring Lean's SourceInfo (original / synthetic(canonical?) /
;; none). `origin` is one of:
;;   'original  — built straight from the author's syntax object.
;;   'synthetic — produced by a desugar/macro expansion (generated code).
;;   'none      — no real position.
;; `canonical` only matters for synthetic positions: when #t, the position
;; is to be trusted for blame *as if the user wrote it* (Lean's `canonical`
;; flag), so canonical-aware blame can skip incidental synthetic glue while
;; still pointing at a synthetic-but-trustworthy spot (e.g. a macro call
;; site that a generated node should be blamed on). Original positions are
;; always blamable; canonical synthetic ones are too.
;;
;; `pos` is the 1-based absolute CHARACTER offset (syntax-position). Unlike
;; `col` (syntax-column, which expands tabs to tab-stops and so is NOT a
;; codepoint index), `pos` is a true codepoint offset and is the right thing
;; for slicing/injecting into source text. #f when unavailable.
;; `span` (syntax-span, char count) added for #33 typed-AST facts: the (pos,span)
;; pair is the join key between check's per-node types and the datum facts (pos
;; alone collides — a node + its first child share a start pos). #f when unknown.
(struct src-loc (line col source origin canonical pos span) #:transparent)

(define (stx->src-loc s)
  (and (syntax? s)
       (let ([line (syntax-line s)]
             [src  (syntax-source s)])
         (and line (src-loc line (syntax-column s) src 'original #f
                            (syntax-position s) (syntax-span s))))))

;; Derive a synthetic position from a base (a src-loc or a syntax object),
;; optionally flagged canonical. This is the analog of Lean's
;; `SourceInfo.fromRef … (canonical := …)`: a generated node borrows a real
;; span but records that it is generated. Returns #f if no base position.
(define (synthetic-src-loc base #:canonical? [canonical? #f])
  (define l (cond [(src-loc? base) base]
                  [(syntax? base) (stx->src-loc base)]
                  [else #f]))
  (and l (src-loc (src-loc-line l) (src-loc-col l) (src-loc-source l)
                  'synthetic canonical? (src-loc-pos l) (src-loc-span l))))

;; Blame predicate for canonical-aware lookup: an original position, or a
;; synthetic one explicitly marked canonical, is trustworthy to blame.
;; Non-canonical synthetic glue is not. (Lean's `canonicalOnly` lookup.)
(define (loc-blamable? loc)
  (and (src-loc? loc)
       (or (eq? (src-loc-origin loc) 'original)
           (src-loc-canonical loc))))

(define (->datum x) (if (syntax? x) (syntax->datum x) x))
(define (stx-subs x) (and (syntax? x) (syntax->list x)))
(define (stx-ref subs n) (and subs (> (length subs) n) (list-ref subs n)))
(define (stx-tail subs n) (and subs (>= (length subs) n) (list-tail subs n)))

(define current-registry (make-parameter #f))
(define current-src-table (make-parameter #f))
;; Side-table mapping the eq?-identity of a body list (e.g. defn-form's
;; body) to a parallel list of src-loc for each body element. Populated by
;; parse-body. Lets diagnostics that fire on bare-symbol body elements
;; (where src-for returns #f because symbols can't be stored in src-table)
;; recover positional srcloc. See store-src! comment for the underlying
;; symbol-storage limitation this side-table works around.
(define current-body-locs-table (make-parameter #f))

;; Look up the src-loc of an AST node, falling back to body-list positional
;; metadata when the node is a bare symbol/literal that store-src! refuses.
;; BODY-LIST + POS form a positional anchor recoverable from any code that
;; holds the list and an index — see check.rkt's return-type diag.
(define (body-loc-at body-list pos)
  (define tbl (current-body-locs-table))
  (and tbl (let ([locs (hash-ref tbl body-list #f)])
             (and locs (>= pos 0) (< pos (length locs))
                  (list-ref locs pos)))))

;; Cross-pass storage for the body-locs-table, keyed by program identity.
;; parse.rkt populates this after parse-program completes; check.rkt
;; recovers it via program-body-locs-table to keep current-body-locs-table
;; set during the type-check pass (where the parse-time parameter is no
;; longer in scope).
(define PROGRAM->BODY-LOCS (make-weak-hasheq))
(define (register-program-body-locs-table! prog tbl)
  (hash-set! PROGRAM->BODY-LOCS prog tbl))
(define (program-body-locs-table prog)
  (hash-ref PROGRAM->BODY-LOCS prog #f))

(define (store-src! node loc)
  ;; Only the FIRST write for a node wins. Parse-time rewrites
  ;; (when/->/-if-let/...) call (parse-expr synthesized-syntax) from
  ;; inside the surface form's parse-expr frame; the inner parse-expr
  ;; populates the table with the synthesized form's srcloc (which is
  ;; the operative blame position), and the outer parse-expr's
  ;; store-src! must NOT clobber it with the surface sugar's loc.
  ;; The `hash-has-key?` guard preserves this innermost-wins invariant.
  ;;
  ;; Symbols, strings, booleans, and numbers are EXCLUDED — they're
  ;; interned/shared, so storing per occurrence would cross-pollute
  ;; (the same `'x` symbol appears in many positions; the FIRST
  ;; occurrence's loc would shadow all others). The downside: when a
  ;; diagnostic fires on a bare-symbol AST leaf (e.g. defn body =
  ;; just `x`), src-for returns #f and the diagnostic falls back to
  ;; the parent form's loc. That's a known limitation tracked in
  ;; sourcemap-fidelity.rkt — closing it requires either (a) symbol
  ;; uninterning at parse time, (b) a position-keyed side-table, or
  ;; (c) syntax-walking inside check.rkt's return-type diag.
  (when (and loc (current-src-table)
             (not (string? node)) (not (boolean? node))
             (not (number? node)) (not (symbol? node))
             (not (hash-has-key? (current-src-table) node)))
    (hash-set! (current-src-table) node loc))
  node)

;; --- per-node inferred-type capture (the delaborator's input) ----------------
;; Mirrors the src-table: the checker records each expression node's INFERRED
;; type here, so a renderer (types-as-view / beagle-explain-type) can PROJECT
;; "doubled :- (Vec Int)" with no type living in the source. This is the
;; anti-reification half of types-as-view — a pure side-channel derived from
;; the check pass, never stored in or drifting from the program. Same
;; interned-leaf exclusion as store-src! (bare symbols/literals are shared,
;; so they can't be keyed by identity); non-leaf nodes (call-form, …) are
;; captured. Populated at the infer-expr choke point in check.rkt.
(define current-type-table (make-parameter #f))

(define (store-type! node ty)
  ;; Last-write-wins: a node may be inferred more than once (and/or args,
  ;; narrowed branches) but its type is stable, so overwriting is harmless.
  (when (and ty (current-type-table)
             (not (string? node)) (not (boolean? node))
             (not (number? node)) (not (symbol? node)))
    (hash-set! (current-type-table) node ty))
  ty)

;; Cross-pass storage for the type-table, keyed by program identity (mirrors
;; PROGRAM->BODY-LOCS): type-check-with-locs! registers the populated table so
;; tools can read per-node inferred types after the check pass completes.
(define PROGRAM->TYPES (make-weak-hasheq))
(define (register-program-type-table! prog tbl)
  (hash-set! PROGRAM->TYPES prog tbl))
(define (program-type-table prog)
  (hash-ref PROGRAM->TYPES prog #f))

;; --- symbol predicates -----------------------------------------------------
(define (dot-method-sym? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 1)
              (char=? (string-ref s 0) #\.)))))

(define (static-method-sym? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (define slash-pos
           (let loop ([i 0])
             (cond [(= i (string-length s)) #f]
                   [(char=? (string-ref s i) #\/) i]
                   [else (loop (+ i 1))])))
         (and slash-pos
              (> slash-pos 0)
              (< (+ slash-pos 1) (string-length s))
              (or (char-upper-case? (string-ref s 0))
                  (string=? (substring s 0 (min 3 (string-length s))) "js/"))))))

(define (dynamic-var-sym? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (>= (string-length s) 3)
              (char=? (string-ref s 0) #\*)
              (char=? (string-ref s (- (string-length s) 1)) #\*)))))

(define (constructor-sym? sym)
  ;; `Foo.` (bare) or `java.io.FileOutputStream.` (FQCN). A trailing `.`, and the
  ;; CLASS segment (last dotted segment before the trailing dot) is capitalized —
  ;; so an FQCN ctor (lowercase package prefix) is recognized too, while a plain
  ;; lowercase dotted name (x.foo.) is not.
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 1)
              (char=? (string-ref s (- (string-length s) 1)) #\.)
              (let* ([body (substring s 0 (- (string-length s) 1))]
                     [cls-start
                      (let loop ([i (- (string-length body) 1)])
                        (cond [(< i 0) 0]
                              [(char=? (string-ref body i) #\.) (+ i 1)]
                              [else (loop (- i 1))]))])
                (and (< cls-start (string-length body))
                     (char-upper-case? (string-ref body cls-start))))))))

(define (keyword-sym? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 1)
              (char=? (string-ref s 0) #\:)))))

;; --- parse-expr / parse-params injection -----------------------------------
(define current-parse-expr (make-parameter #f))
(define current-parse-params (make-parameter #f))

;; --- AST -------------------------------------------------------------------

(struct ns-decl     (name)                                  #:transparent)
(struct mode-decl   (mode)                                  #:transparent)
;; doc: optional docstring (String or #f). Real Clojure surface — carried
;; through to clj emit; ignored by nix emit and the checker.
;; dynamic?: #t when defined `(def ^:dynamic *x* …)` — a dynamic (rebindable)
;; var. Drives the `^:dynamic` metadata in clj emit and gates `binding`
;; targets in the checker. #f for ordinary defs.
(struct def-form    (name type value doc dynamic?)          #:transparent)
(struct defn-form   (name params rest-param return-type body private? raises doc) #:transparent)
(struct defn-multi  (name arities private? doc)               #:transparent)
(struct arity-clause (params rest-param return-type body)    #:transparent)
(struct fn-form     (params rest-param return-type body)    #:transparent)
(struct let-form    (bindings body)                         #:transparent)
;; binding-form: Clojure `(binding [*x* v …] body…)` — dynamic-extent
;; rebinding of dynamic vars. bindings is a list of let-binding (type #f);
;; each name must reference a `^:dynamic` var (enforced in check). Distinct
;; from let-form: targets are existing dynamic vars, not new lexical locals.
(struct binding-form (bindings body)                        #:transparent)
(struct if-form     (cond-expr then-expr else-expr)         #:transparent)
(struct cond-form   (clauses)                               #:transparent)
(struct cond-clause (test body)                             #:transparent)
(struct when-form   (cond-expr body)                        #:transparent)
(struct do-form     (body)                                  #:transparent)
(struct call-form   (fn args)                               #:transparent)
(struct vec-form    (items)                                 #:transparent)
(struct quoted      (datum)                                 #:transparent)
(struct regex-lit  (pattern)                                #:transparent)
(struct loop-form  (bindings body)                          #:transparent)
(struct recur-form (args)                                   #:transparent)
(struct for-form   (clauses body)                           #:transparent)
(struct for-binding (name expr type)                        #:transparent)  ; G7: type = #f | a :- T annotation
(struct for-when   (test)                                   #:transparent)
(struct record-form (name fields)                           #:transparent)
(struct method-call (method-name target args)               #:transparent)
(struct static-call (class+method args)                     #:transparent)
(struct dynamic-var (name)                                  #:transparent)
(struct map-form   (pairs)                                  #:transparent)
(struct set-form   (items)                                  #:transparent)
(struct kw-access  (kw target default)                       #:transparent)
(struct try-form    (body catches finally-body)             #:transparent)
(struct catch-clause (exception-type name body)            #:transparent)
(struct doseq-form  (clauses body)                         #:transparent)
(struct case-form   (test clauses default)                 #:transparent)
(struct case-clause (value body)                           #:transparent)
(struct new-form    (class-name args)                      #:transparent)
(struct protocol-form (name methods)                       #:transparent)
(struct protocol-method (name params return-type)          #:transparent)
(struct defmulti-form (name dispatch-fn)                   #:transparent)
(struct defmethod-form (name dispatch-val params body)     #:transparent)

(struct with-form   (target updates)                          #:transparent)
(struct with-update (field-kw value)                          #:transparent)
(struct defenum-form (name values)                            #:transparent)
(struct defunion-form (name members type-params member-fields) #:transparent)
(struct deferror-form (name members member-fields)            #:transparent)
(struct defscalar-form (name backing-type predicates)         #:transparent)
(struct scalar-predicate (op value)                           #:transparent)

(struct match-form  (target clauses)                         #:transparent)
(struct match-clause (pattern body)                          #:transparent)
(struct pat-wildcard ()                                      #:transparent)
(struct pat-literal  (value)                                 #:transparent)
(struct pat-record   (type-name bindings)                    #:transparent)
(struct pat-map      (entries)                               #:transparent)
(struct pat-var      (name)                                  #:transparent)
;; Pattern combinators. pat-or holds a list of alternative sub-patterns;
;; matches if any alternative matches. Designed as a combinator (sub-pattern
;; list) so future operators (pat-and, pat-not, pat-guard) slot in as
;; sibling structs without restructuring the match parser or evaluator.
(struct pat-or       (alternatives)                          #:transparent)

(struct check-expr  (expr)                                   #:transparent)
(struct rescue-form (expr fallback err-name)                 #:transparent)
(struct target-case-form (cases)                             #:transparent)

(struct with-meta   (metadata expr)                          #:transparent)
;; threading-marker: a transparent wrapper produced by the threading-family
;; parse-time rewrites (->, ->>, as->, cond->, cond->>, some->, some->>).
;; KIND is the surface symbol (e.g. '->); ORIG-ARGS is the list of parsed
;; surface arg AST nodes; DESUGARED is the rewritten AST that downstream
;; passes (check, emit-nix) walk through. emit-clj recognizes the marker
;; and emits the surface threading form instead of the desugared call chain.
(struct threading-marker (kind orig-args desugared)           #:transparent)
(struct when-let-form  (name expr body)                      #:transparent)
(struct if-let-form    (name expr then-body else-body)       #:transparent)
(struct when-some-form (name expr body)                      #:transparent)
(struct if-some-form   (name expr then-body else-body)       #:transparent)
(struct with-open-form (bindings body)                       #:transparent)
(struct doto-form      (target forms)                        #:transparent)
(struct for-let        (bindings)                            #:transparent)
(struct dotimes-form   (name count-expr body)                #:transparent)
(struct condp-form     (pred-fn test-expr clauses default)   #:transparent)
(struct defonce-form   (name type value doc)                 #:transparent)
(struct await-form    (expr)                                 #:transparent)
(struct set!-form    (target value)                           #:transparent)
(struct letfn-form   (fns body)                              #:transparent)
(struct letfn-fn     (name params rest-param return-type body) #:transparent)

;; --- Generic block string --------------------------------------------------
(struct block-string (text tag) #:transparent)

;; --- Nix-specific AST nodes ------------------------------------------------
(struct nix-inherit        (names)                            #:transparent)
(struct nix-inherit-from   (ns-expr names)                    #:transparent)
(struct nix-with           (ns-expr body)                     #:transparent)
(struct nix-rec-attrs      (pairs)                            #:transparent)
(struct nix-assert         (cond-expr body)                   #:transparent)
(struct nix-get-or         (base-expr path default)           #:transparent)
(struct nix-has-attr       (base-expr path)                   #:transparent)
(struct nix-search-path    (name)                             #:transparent)
(struct nix-interpolated-string (parts)                       #:transparent)
(struct nix-multiline-string (lines)                          #:transparent)
(struct nix-path           (path-string)                      #:transparent)
(struct nix-fn-set         (formals rest? at-name body)       #:transparent)
(struct nix-fn-set-formal  (name default)                     #:transparent)
;; nix-pipe (pipe-to / pipe-from) and nix-impl (implies) removed —
;; the pipe family was an Elixir/F# import dropped per CLAUDE.md
;; "Beagle is Clojure plus types, nothing else." Use Clojure threading
;; (`->`, `->>`) instead.
(struct nix-derivation     (attrs)                            #:transparent)
(struct nix-flake          (attrs)                            #:transparent)
(struct nix-with-cfg       (path body)                        #:transparent)

;; --- JS/quote AST nodes ---------------------------------------------------
(struct js-quote-form    (body)                               #:transparent)

(struct js-ast-block     (stmts)                              #:transparent)
(struct js-ast-const     (name value)                         #:transparent)
(struct js-ast-let       (name value)                         #:transparent)
(struct js-ast-assign    (target value)                       #:transparent)
(struct js-ast-return    (expr)                               #:transparent)
(struct js-ast-if        (test then else-branch)              #:transparent)
(struct js-ast-for-of    (binding iterable body)              #:transparent)
(struct js-ast-while     (test body)                          #:transparent)
(struct js-ast-throw     (expr)                               #:transparent)
(struct js-ast-try       (body catch-name catch-body finally-body) #:transparent)
(struct js-ast-expr-stmt (expr)                               #:transparent)

(struct js-ast-function  (name params body async? export?)    #:transparent)
(struct js-ast-class     (name extends-expr methods)          #:transparent)
(struct js-ast-method    (name params body static? async? kind) #:transparent)

(struct js-ast-call      (callee args)                        #:transparent)
(struct js-ast-member    (object property computed?)          #:transparent)
(struct js-ast-index     (object index-expr)                  #:transparent)
(struct js-ast-arrow     (params body)                        #:transparent)
(struct js-ast-ternary   (test then else-expr)                #:transparent)
(struct js-ast-binary    (op left right)                      #:transparent)
(struct js-ast-unary     (op expr prefix?)                    #:transparent)
(struct js-ast-template  (parts)                              #:transparent)
(struct js-ast-array     (items)                              #:transparent)
(struct js-ast-object    (pairs)                              #:transparent)
(struct js-ast-spread    (expr)                               #:transparent)
(struct js-ast-await     (expr)                               #:transparent)
(struct js-ast-new       (callee args)                        #:transparent)
(struct js-ast-typeof    (expr)                               #:transparent)
(struct js-ast-ident     (name)                               #:transparent)
(struct js-ast-literal   (value)                              #:transparent)
(struct js-ast-splice-expr (beagle-expr)                      #:transparent)
(struct js-ast-splice-stmts (beagle-expr)                     #:transparent)
(struct js-ast-splice-json (beagle-expr)                      #:transparent)

;; --- Typed JS target AST (js/* forms) — minimal set -------------------------
;; Only forms with no core beagle equivalent.
(struct jst-return   (expr)                                       #:transparent)
(struct jst-class    (name extends methods export?)               #:transparent)
(struct jst-method   (name params rest-param return-type body static? async? kind) #:transparent)
(struct jst-dot      (object property)                            #:transparent)
(struct jst-spread   (expr)                                       #:transparent)
(struct jst-typeof   (expr)                                       #:transparent)
(struct jst-template (parts)                                      #:transparent)
(struct jst-binary   (op left right)                              #:transparent)
(struct jst-unary    (op expr)                                    #:transparent)
(struct jst-export   (form)                                       #:transparent)
(struct jst-export-default (form)                                 #:transparent)
(struct jst-import-meta ()                                        #:transparent)

;; --- Shared utility structs ------------------------------------------------
(struct param       (name type)                             #:transparent)
;; or-defaults: alist of (key-sym . default-AST) from {:keys [...] :or {...}};
;; '() when absent. keys/as-name as before. seq-destructure names may contain
;; nested map-destructure/seq-destructure structs (Clojure nested binding).
(struct map-destructure (keys as-name or-defaults)          #:transparent)

;; All symbols bound by a destructure pattern, flattened through nesting.
;; The canonical walk for scope/binding consumers (check, lint, emit-scope).
(define (destructure-bound-names p)
  (cond
    [(map-destructure? p)
     (append (map-destructure-keys p)
             (if (map-destructure-as-name p)
                 (list (map-destructure-as-name p))
                 '()))]
    [(seq-destructure? p)
     (append
      (apply append
             (for/list ([n (in-list (seq-destructure-names p))])
               (if (symbol? n) (list n) (destructure-bound-names n))))
      (if (seq-destructure-rest-name p)
          (list (seq-destructure-rest-name p))
          '()))]
    [else '()]))

;; All :or default expression ASTs in a destructure pattern, recursively.
;; Consumers infer/lint these so errors inside defaults surface normally.
(define (destructure-or-default-exprs p)
  (cond
    [(map-destructure? p)
     (map cdr (map-destructure-or-defaults p))]
    [(seq-destructure? p)
     (apply append
            (for/list ([n (in-list (seq-destructure-names p))])
              (if (symbol? n) '() (destructure-or-default-exprs n))))]
    [else '()]))
(struct seq-destructure (names rest-name)                    #:transparent)
;; deftype surface removed (2026-05). The canonical decomposition is defrecord
;; (data shape) + extend-type (protocol impls); parse.rkt rejects deftype at the
;; surface.
(struct extend-type-form (type-name impls)                   #:transparent)
(struct flake-input-form (input-name namespace path-segments) #:transparent)

;; `claim-form` removed. The (claim NAME TYPE) surface was deleted under
;; the Zero-users rule — the parser now rejects it with a pointed error
;; naming `:-` as the inline-annotation replacement. There is no AST node
;; for claim; downstream consumers must not pattern-match on one.

(struct type-impl    (protocol-name methods)                 #:transparent)
(struct impl-method  (name params body)                      #:transparent)
(struct let-binding (name type value)                       #:transparent)
(struct require-entry (ns alias refer) #:transparent)

;; --- program structure -----------------------------------------------------
(struct program (mode
                 namespace
                 forms
                 macros
                 externs
                 requires
                 imports
                 form-stxs
                 src-table
                 imported-record-fields
                 imported-record-field-order
                 imported-record-ns
                 imported-scalar-fns
                 imported-scalar-preds
                 imported-symbol-ns
                 imported-union-members
                 imported-parametric-unions
                 imported-enums
                 imported-dynamic-vars
                 target
                 gen-class?)
  #:transparent)

(define DEFAULT-MODE      'strict)
(define DEFAULT-TARGET    'clj)
(define DEFAULT-NAMESPACE 'beagle.user)

;; --- provide ---------------------------------------------------------------
(provide
 ;; Tag utilities
 bracketed? bracket-body map-tagged? map-body set-tagged? set-body
 unwrap-items unwrap-stxs
 ;; Identifier safety
 validate-identifier! unsafe-ident-rx validate-module-path! valid-module-path-rx
 ;; Source locations
 (struct-out src-loc) stx->src-loc synthetic-src-loc loc-blamable?
 ->datum stx-subs stx-ref stx-tail
 current-registry current-src-table store-src!
 current-body-locs-table body-loc-at
 register-program-body-locs-table! program-body-locs-table
 current-type-table store-type!
 register-program-type-table! program-type-table
 ;; Symbol predicates
 dot-method-sym? static-method-sym? dynamic-var-sym? constructor-sym? keyword-sym?
 ;; Parse injection
 current-parse-expr current-parse-params
 ;; Constants
 DEFAULT-MODE DEFAULT-TARGET DEFAULT-NAMESPACE
 ;; Core AST
 (struct-out ns-decl) (struct-out mode-decl)
 (struct-out def-form) (struct-out defn-form) (struct-out fn-form)
 (struct-out let-form) (struct-out binding-form) (struct-out if-form) (struct-out cond-form) (struct-out cond-clause)
 (struct-out when-form) (struct-out do-form) (struct-out call-form) (struct-out vec-form)
 (struct-out quoted) (struct-out regex-lit)
 (struct-out loop-form) (struct-out recur-form)
 (struct-out for-form) (struct-out for-binding) (struct-out for-when)
 (struct-out record-form) (struct-out method-call) (struct-out static-call)
 (struct-out dynamic-var) (struct-out map-form) (struct-out set-form)
 (struct-out kw-access) (struct-out try-form) (struct-out catch-clause)
 (struct-out doseq-form) (struct-out case-form) (struct-out case-clause)
 (struct-out new-form) (struct-out protocol-form) (struct-out protocol-method)
 (struct-out defmulti-form) (struct-out defmethod-form)
 (struct-out with-form) (struct-out with-update)
 (struct-out defenum-form) (struct-out defunion-form) (struct-out deferror-form)
 (struct-out defscalar-form) (struct-out scalar-predicate)
 (struct-out match-form) (struct-out match-clause)
 (struct-out pat-wildcard) (struct-out pat-literal) (struct-out pat-record)
 (struct-out pat-map) (struct-out pat-var) (struct-out pat-or)
 (struct-out check-expr) (struct-out rescue-form) (struct-out target-case-form)
 (struct-out with-meta)
 (struct-out threading-marker)
 (struct-out when-let-form) (struct-out if-let-form)
 (struct-out when-some-form) (struct-out if-some-form)
 (struct-out with-open-form) (struct-out doto-form) (struct-out for-let)
 (struct-out dotimes-form) (struct-out condp-form) (struct-out defonce-form)
 (struct-out await-form) (struct-out set!-form)
 (struct-out letfn-form) (struct-out letfn-fn)
 (struct-out block-string)
 (struct-out defn-multi) (struct-out arity-clause)
 ;; Shared utility structs
 (struct-out param) (struct-out map-destructure) (struct-out seq-destructure)
 destructure-bound-names destructure-or-default-exprs
 (struct-out extend-type-form)
 (struct-out type-impl) (struct-out impl-method)
 (struct-out let-binding) (struct-out require-entry)
 ;; Program
 (struct-out program)
 ;; Nix AST
 (struct-out nix-inherit) (struct-out nix-inherit-from) (struct-out nix-with)
 (struct-out nix-rec-attrs) (struct-out nix-assert) (struct-out nix-get-or)
 (struct-out nix-has-attr) (struct-out nix-search-path)
 (struct-out nix-interpolated-string) (struct-out nix-multiline-string)
 (struct-out nix-path)
 (struct-out nix-fn-set) (struct-out nix-fn-set-formal)
 (struct-out nix-derivation) (struct-out nix-flake)
 (struct-out nix-with-cfg)
 (struct-out flake-input-form)
 ;; JS/quote AST
 (struct-out js-quote-form)
 (struct-out js-ast-block) (struct-out js-ast-const) (struct-out js-ast-let)
 (struct-out js-ast-assign) (struct-out js-ast-return) (struct-out js-ast-if)
 (struct-out js-ast-for-of) (struct-out js-ast-while) (struct-out js-ast-throw)
 (struct-out js-ast-try) (struct-out js-ast-expr-stmt)
 (struct-out js-ast-function) (struct-out js-ast-class) (struct-out js-ast-method)
 (struct-out js-ast-call) (struct-out js-ast-member) (struct-out js-ast-index)
 (struct-out js-ast-arrow) (struct-out js-ast-ternary)
 (struct-out js-ast-binary) (struct-out js-ast-unary) (struct-out js-ast-template)
 (struct-out js-ast-array) (struct-out js-ast-object) (struct-out js-ast-spread)
 (struct-out js-ast-await) (struct-out js-ast-new) (struct-out js-ast-typeof)
 (struct-out js-ast-ident) (struct-out js-ast-literal)
 (struct-out js-ast-splice-expr) (struct-out js-ast-splice-stmts) (struct-out js-ast-splice-json)
 ;; Typed JS AST (minimal set)
 (struct-out jst-return) (struct-out jst-class) (struct-out jst-method)
 (struct-out jst-dot) (struct-out jst-spread) (struct-out jst-typeof)
 (struct-out jst-template) (struct-out jst-binary) (struct-out jst-unary)
 (struct-out jst-export) (struct-out jst-export-default)
 (struct-out jst-import-meta))
