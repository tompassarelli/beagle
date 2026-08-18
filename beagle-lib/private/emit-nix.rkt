#lang racket/base

;; Nix emitter backend.
;; Maps Beagle AST → Nix source code.

(require racket/match
         racket/string
         racket/format
         racket/list
         racket/set
         "parse.rkt"
         "types.rkt"
         "emit-dispatch.rkt"
         "emit-nix-strings.rkt")

;; --- indentation -----------------------------------------------------------

(define (indent n)
  (make-string (* 2 n) #\space))

;; --- recur context (parameterized during loop emission) -------------------

(define current-recur-name (make-parameter #f))
(define current-nix-record-types (make-parameter (seteq)))
(define current-nix-program (make-parameter #f))
(define current-nix-require-prefixes (make-parameter (hash)))
(define current-nix-semantic-contracts (make-parameter #f))
(define current-nix-constraint-owners (make-parameter (hasheq)))
(define current-nix-module-omit-attrs (make-parameter '()))

;; --- identifier mangling ---------------------------------------------------

(define (mangle-name sym)
  (define s (symbol->string sym))
  ;; Compiler ABI symbols occupy the source-reserved `bgl____` host prefix and
  ;; encode every UTF-8 byte. Merely replacing `$` with `_` is not injective:
  ;; legal source names containing `$` and `_` can collapse to the same Nix
  ;; binding. Hex makes the conceptual `$beagle$...` ABI round-trippable and
  ;; incapable of colliding with either authored names or another helper.
  (define compiler-owned? (string-prefix? s "$beagle$"))
  (define (hex-encode text)
    (apply
     string-append
     (for/list ([byte (in-bytes (string->bytes/utf-8 text))])
       (define hex (number->string byte 16))
       (if (= (string-length hex) 1) (string-append "0" hex) hex))))
  (define ordinary
    (string-replace
     (string-replace
      (string-replace
       (string-replace s "$" "_")
       "->" "mk")
      "?" "_p")
     "!" "_bang"))
  (define out
    (if compiler-owned?
        (string-append "bgl____" (hex-encode s))
        ordinary))
  (if (nix-reserved? out) (string-append out "'") out))

;; A Beagle namespace separator becomes Nix attr selection, but each selected
;; binding still needs ordinary host mangling.  Applying only `/` -> `.` left
;; qualified predicate names containing `?`, and the provider validator ABI's
;; `$` names, as invalid Nix identifiers.
(define (mangle-qualified-parts qualifier name)
  (define prefix (symbol->string qualifier))
  (define runtime-prefix
    (hash-ref (current-nix-require-prefixes) prefix #f))
  (string-join
   (cons (or runtime-prefix (mangle-name (string->symbol prefix)))
         (for/list ([part (in-list (string-split (symbol->string name) "/"))])
           (mangle-name (string->symbol part))))
   "."))

(define (mangle-qualified-name ref)
  (mangle-qualified-parts
   (qualified-ref-qualifier ref)
   (qualified-ref-name ref)))

;; Record-update contracts name compiler-owned validators as symbols rather
;; than expression references.
(define (mangle-record-validator-name validator)
  (define parts (string-split (symbol->string validator) "/"))
  (if (null? (cdr parts))
      (mangle-name validator)
      (mangle-qualified-parts
       (string->symbol (car parts))
       (string->symbol (string-join (cdr parts) "/")))))

;; Generated Nix modules live at the namespace path. Resolve one provider from
;; the importing module's directory, rather than repeating the common namespace
;; prefix underneath that directory (`a/consumer.nix` imports `./provider.nix`,
;; not `./a/provider.nix`).
(define (relative-nix-module-path importer-ns imported-ns)
  (define importer-parts (string-split (symbol->string importer-ns) "."))
  (define importer-dir
    (if (null? importer-parts)
        '()
        (drop-right importer-parts 1)))
  (define target-parts (string-split (symbol->string imported-ns) "."))
  (define-values (remaining-dir remaining-target)
    (let loop ([dir importer-dir] [target target-parts])
      (if (and (pair? dir)
               (pair? target)
               (string=? (car dir) (car target)))
          (loop (cdr dir) (cdr target))
          (values dir target))))
  (define path
    (string-append
     (string-join
      (append (make-list (length remaining-dir) "..") remaining-target)
      "/")
     ".nix"))
  (if (string-prefix? path "..") path (string-append "./" path)))

(define (require-module-import prog entry)
  (for/first ([import (in-list (program-imported-module-interfaces prog))]
              #:when
              (eq? (module-interface-namespace
                    (module-import-interface import))
                   (require-entry-ns entry)))
    import))

(define NON-RUNTIME-INTERFACE-KINDS
  '(extern macro protocol-method defmulti))

(define (runtime-interface-binding? interface name)
  (define binding (module-interface-binding-ref interface name #f))
  (and binding
       (not (memq (interface-binding-kind binding)
                  NON-RUNTIME-INTERFACE-KINDS))))

(define (used-unqualified-record-validators prog)
  (for/seteq ([(node contract)
               (in-hash (program-semantic-contracts prog))]
              #:when
              (and (record-update-contract? contract)
                   (record-update-contract-validator-symbol contract)
                   (not
                    (string-contains?
                     (symbol->string
                      (record-update-contract-validator-symbol contract))
                     "/"))))
    (record-update-contract-validator-symbol contract)))

(define (referred-record-validator-symbols prog entry interface)
  (define used (used-unqualified-record-validators prog))
  (define referred (or (require-entry-refer entry) '()))
  (for/list ([(record-name contract)
              (in-hash (module-interface-record-contracts interface))]
             #:do
             [(define validator
                (interface-record-contract-validator-symbol contract))
              (define constructor
                (string->symbol (format "->~a" record-name)))]
             #:when
             (and validator
                  (set-member? used validator)
                  (or (memq record-name referred)
                      (memq constructor referred))))
    validator))

;; Nix syntactic keywords. `import` is a function (builtins.import), not a
;; keyword, so it's intentionally excluded.
(define nix-reserved-words
  '("if" "then" "else" "let" "in" "with" "rec" "inherit"
    "assert" "or" "true" "false" "null"))

(define (nix-reserved? s)
  (member s nix-reserved-words))

;; Attribute labels are data, not binders. Preserve authored Map keyword text
;; and quote any segment that cannot be written as a bare Nix attribute. Record
;; fields are different: their checked representation uses the same mangled
;; host spelling as generated constructors/accessors.
(define nix-bare-attr-rx #px"^[a-zA-Z_][a-zA-Z0-9_'-]*$")

(define (nix-static-attr-segment text)
  (if (and (regexp-match? nix-bare-attr-rx text)
           (not (nix-reserved? text)))
      text
      (format "\"~a\"" (escape-nix text))))

(define (nix-static-attr-path text)
  (string-join
   (for/list ([segment (in-list (string-split text "." #:trim? #f))])
     (nix-static-attr-segment segment))
   "."))

(define (record-valued-expr? e)
  (define table (current-type-table))
  (define inferred (and table (hash-ref table e #f)))
  (define name
    (cond
      [(type-prim? inferred) (type-prim-name inferred)]
      [(type-app? inferred) (type-app-ctor inferred)]
      [else #f]))
  (or (and name (set-member? (current-nix-record-types) name))
      ;; Parser-only emission has no inferred-type table. A direct checked
      ;; record constructor still carries an unambiguous nominal spelling.
      (and (call-form? e)
           (symbol? (call-form-fn e))
           (let ([fn-text (symbol->string (call-form-fn e))])
             (and (string-prefix? fn-text "->")
                  (set-member?
                   (current-nix-record-types)
                   (string->symbol (substring fn-text 2))))))))

(define (record-field-access? access-node target-expr)
  (define prog (current-nix-program))
  (define contracts (and prog (program-semantic-contracts prog)))
  (define contract
    (and access-node contracts (hash-ref contracts access-node #f)))
  (when (and contract (not (record-field-access-contract? contract)))
    (error 'emit-nix
           "keyword access has invalid checked representation contract: ~v"
           contract))
  (or (record-field-access-contract? contract)
      ;; Parser-only emission has no checked contract. Preserve the direct
      ;; constructor case without treating general Map keywords as binders.
      (and (not (and prog (program-type-table prog)))
           (record-valued-expr? target-expr))))

(define (keyword-selection-field target-expr keyword [access-node #f])
  (define raw (symbol->string keyword))
  (define field (if (string-prefix? raw ":") (substring raw 1) raw))
  (if (record-field-access? access-node target-expr)
      (mangle-name (string->symbol field))
      (nix-static-attr-path field)))

;; --- params ------------------------------------------------------------------

;; Param → nix pattern. Plain params curry as `name:`. Map destructuring
;; renders as the IDIOMATIC nix attrset pattern — Clojure's
;; {:keys [a b] :or {a 1} :as m} IS nix's { a ? 1, b, ... } @ m: — the
;; same meaning native on both surfaces. Sequential destructuring has no
;; nix analog: pointed error naming the let-binding replacement.
(define (nix-param-pattern p depth [emit-default #f])
  (define target (param-binding-target p))
  (define annotation (and (param? p) (param-type p)))
  (cond
    [(symbol? target)
     (format "~a:" (mangle-name (binder-output-symbol p target)))]
    [(map-destructure? target)
     (define ors (map-destructure-or-defaults target))
     (define as-name (map-destructure-as-name target))
     (when (null? (map-destructure-keys target))
       (error 'emit-nix
              "empty map destructuring parameters are not supported by the nix backend — bind the aggregate to a name"))
     (define nominal-record?
       (and (type-prim? annotation)
            (set-member? (current-nix-record-types)
                         (type-prim-name annotation))))
     (unless (or nominal-record?
                 (= (length ors) (length (map-destructure-keys target))))
       (error 'emit-nix
              "map destructuring parameters require :or defaults for every key on the nix backend — Nix attrset patterns otherwise reject missing keys instead of binding nil"))
     (define entries
       (for/list ([k (in-list (map-destructure-keys target))])
         (unless (symbol? k)
           (error 'beagle
                  "nested map destructuring in params is not supported by the nix backend — destructure the outer level and bind the rest with let"))
         (define dflt (and ors (assq k ors)))
         (if dflt
             (format "~a ? ~a"
                     (mangle-name k)
                     (if emit-default
                         (emit-default (car dflt) (cdr dflt))
                         (emit-expr (cdr dflt) depth)))
             (mangle-name k))))
     (format "{ ~a... }~a:"
             (if (null? entries)
                 ""
                 (string-append (string-join entries ", ") ", "))
             (if as-name (format " @ ~a" (mangle-name as-name)) ""))]
    [else
     (error 'beagle
            "sequential destructuring in params is not supported by the nix backend — nix functions destructure attrsets only; bind positionally: (let [x (first xs) y (second xs)] ...)")]))

;; Constraints are executable predicates on the complete incoming value.  A
;; constrained binder therefore needs two lexical phases in Nix: capture the
;; predicate before the target is in scope, then apply it to the raw argument
;; before any destructuring pattern runs.  Nix's laziness shares both thunks,
;; so neither the raw value nor the predicate application is duplicated.
(define (binding-target-label target)
  (define b (param-binding-target target))
  (cond
    [(symbol? b) (symbol->string b)]
    [(map-destructure? b)
     (define keys
       (string-join
        (for/list ([key (in-list (map-destructure-keys b))])
          (binding-target-label key))
        " "))
     (format "{:keys [~a]~a}"
             keys
             (if (map-destructure-as-name b)
                 (format " :as ~a" (map-destructure-as-name b))
                 ""))]
    [(seq-destructure? b)
     (define names
       (for/list ([name (in-list (seq-destructure-names b))])
         (binding-target-label name)))
     (define all-names
       (if (seq-destructure-rest-name b)
           (append names
                   (list "&"
                         (symbol->string (seq-destructure-rest-name b))))
           names))
     (format "[~a]" (string-join all-names " "))]
    [else "<binding>"]))

(define (binding-constraint-failure target)
  (format "builtins.throw \"Binding constraint failed: ~a\""
          (escape-nix (binding-target-label target))))

(define (binding-constraint binding)
  (cond
    [(param? binding) (param-constraint binding)]
    [(let-binding? binding) (let-binding-constraint binding)]
    [(for-binding? binding) (for-binding-constraint binding)]
    [else #f]))

(define (binding-constraint-proof binding)
  (define owner
    (hash-ref (current-nix-constraint-owners) binding binding))
  (and (current-nix-semantic-contracts)
       (hash-ref (current-nix-semantic-contracts) owner #f)))

;; A constraint is executable compiler output, so syntax alone is not enough
;; authority to emit it. The checker owns the positive proof that the predicate
;; is synchronous; every Nix binding path calls this accessor before touching
;; the constraint expression. This also makes parser-only emission fail closed.
(define (checked-binding-constraint binding)
  (define constraint (binding-constraint binding))
  (when constraint
    (define proof (binding-constraint-proof binding))
    (unless (and (binding-constraint-contract? proof)
                 (binding-constraint-contract-synchronous? proof))
      (error
       'beagle-nix
       (string-append
        "binding constraint for ~a lacks the compiler's positive "
        "synchronization proof; checked emission refuses to call it")
       (binding-target-label binding))))
  constraint)

(define (record-validator-symbol name)
  (string->symbol (format "$beagle$record$~a$validate" name)))

(define (record-validator-name name)
  (mangle-name (record-validator-symbol name)))

;; Record fields use target-mangled attribute names; general Map keys preserve
;; their authored keyword text. The distinction belongs to the aggregate type,
;; never to the punctuation of an individual key.
(define (nominal-record-param? p)
  (define annotation (and (param? p) (param-type p)))
  (define name
    (cond
      [(type-prim? annotation) (type-prim-name annotation)]
      [(type-app? annotation) (type-app-ctor annotation)]
      [else #f]))
  (and name (set-member? (current-nix-record-types) name)))

;; Emit curried lambdas while keeping ordinary and unconstrained map parameters
;; native and lazy. A constrained map alone needs a raw aggregate so its
;; predicate runs before destructuring. Predicate/default thunks are defined
;; outside every authored binder (the checker's incoming callable scope) and
;; invoked inside the corresponding parameter event.
(define (emit-param-chain params body depth)
  (define indexed
    (for/list ([p (in-list params)] [i (in-naturals)]) (cons i p)))
  (define (raw-name index) (format "bgl____binding__~a" index))
  (define (constraint-name index) (format "bgl____constraint__~a" index))
  (define (constraint-thunk-name index)
    (format "bgl____constraint__thunk__~a" index))
  (define (default-thunk-name param-index default-index)
    (format "bgl____default__thunk__~a__~a"
            param-index default-index))
  (define (indexed-defaults p)
    (define target (param-binding-target p))
    (if (map-destructure? target)
        (for/list ([entry (in-list (map-destructure-or-defaults target))]
                   [default-index (in-naturals)])
          (cons default-index entry))
        '()))
  (define (default-index-for p key)
    (for/first ([indexed-default (in-list (indexed-defaults p))]
                #:when (eq? key (car (cdr indexed-default))))
      key))
  (define (emit-projected-binding name value rest)
    (define emitted (mangle-name name))
    (format "((~a: ~a) (~a))" emitted rest value))
  (define (emit-map-projections index p raw rest)
    (define target (param-binding-target p))
    (define keys (map-destructure-keys target))
    (define defaults (map-destructure-or-defaults target))
    (define nominal? (nominal-record-param? p))
    (unless (or nominal? (= (length defaults) (length keys)))
      (error 'emit-nix
             "map destructuring parameters require :or defaults for every key on the nix backend — Nix Maps may omit a key, which binds nil in Beagle"))
    (define with-as
      (if (map-destructure-as-name target)
          (emit-projected-binding (map-destructure-as-name target) raw rest)
          rest))
    (for/fold ([result with-as])
              ([key (in-list (reverse keys))])
      (define authored (symbol->string key))
      (define attr-name
        (if nominal? (mangle-name key) authored))
      (define attr-string (format "\"~a\"" (escape-nix attr-name)))
      (define default-index (default-index-for p key))
      (define projected
        (cond
          [default-index
           (format (string-append
                    "if builtins.hasAttr ~a ~a "
                    "then builtins.getAttr ~a ~a else ~a null")
                   attr-string raw attr-string raw
                   (default-thunk-name index default-index))]
          [else (format "builtins.getAttr ~a ~a" attr-string raw)]))
      (emit-projected-binding key projected result)))
  (define (emit-one index p rest)
    (define target (param-binding-target p))
    (define constraint (checked-binding-constraint p))
    (define native-map?
      (and (map-destructure? target) (not constraint)))
    (define raw
      (if (and (symbol? target) (not constraint))
          (mangle-name target)
          (raw-name index)))
    (define bound-rest
      (cond
        [(symbol? target)
         (if constraint
             (emit-projected-binding target raw rest)
             rest)]
        [(map-destructure? target)
         (emit-map-projections index p raw rest)]
        [else
         (error 'beagle
                "sequential destructuring in params is not supported by the nix backend — nix functions destructure attrsets only; bind positionally")]))
    (define guarded-rest
      (if constraint
          (format (string-append
                   "let ~a = ~a null; in "
                   "if ~a ~a then (~a) else ~a")
                  (constraint-name index)
                  (constraint-thunk-name index)
                  (constraint-name index)
                  raw
                  bound-rest
                  (binding-constraint-failure p))
          bound-rest))
    (cond
      [native-map?
       (format "~a ~a"
               (nix-param-pattern
                p depth
                (lambda (key _value)
                  (format "~a null" (default-thunk-name index key))))
               rest)]
      [constraint
       (format "~a: builtins.deepSeq ~a (~a)" raw raw guarded-rest)]
      [else (format "~a: ~a" raw guarded-rest)]))
  (define (emit-params remaining)
    (cond
      [(null? remaining) body]
      [else
       (define index (caar remaining))
       (define p (cdar remaining))
       (emit-one index p (emit-params (cdr remaining)))]))
  (define with-constraint-thunks
    (for/fold ([result (emit-params indexed)])
              ([entry (in-list (reverse indexed))]
               #:when (checked-binding-constraint (cdr entry)))
      (define index (car entry))
      (define p (cdr entry))
      (format "let ~a = _: ~a; in ~a"
              (constraint-thunk-name index)
              (emit-expr (checked-binding-constraint p) depth)
              result)))
  (define with-default-thunks
    (for*/fold ([result with-constraint-thunks])
               ([entry (in-list (reverse indexed))]
                [indexed-default
                 (in-list (reverse (indexed-defaults (cdr entry))))])
      (define default-entry (cdr indexed-default))
      (format "let ~a = _: ~a; in ~a"
              (default-thunk-name (car entry) (car default-entry))
              (emit-expr (cdr default-entry) depth)
              result)))
  ;; Nix has no nullary lambda. Lower the source unit call boundary to one
  ;; ignored `null` argument so every invocation remains a distinct event.
  (if (null? params) (format "_: ~a" body) with-default-thunks))

;; Loop bindings are sequential in the checker, unlike function parameters:
;; a later constraint may reference an earlier loop binder. Raw loop values are
;; still captured first, and each constraint is evaluated before only its own
;; authored target enters scope.
(define (emit-sequential-param-chain params body depth)
  (let/ec return
   (define constrained? (ormap checked-binding-constraint params))
  (unless constrained?
    (return (emit-param-chain params body depth)))
  (define indexed
    (for/list ([p (in-list params)] [i (in-naturals)]) (cons i p)))
  (define (raw-name index) (format "bgl____binding__~a" index))
  (define (emit-bindings remaining)
    (cond
      [(null? remaining) body]
      [else
       (define index (caar remaining))
       (define p (cdar remaining))
       (define constraint (checked-binding-constraint p))
       (define bind
         (format "((~a ~a) ~a)"
                 (nix-param-pattern p depth)
                 (emit-bindings (cdr remaining))
                 (raw-name index)))
       (if constraint
           (let ([predicate-name (format "bgl____constraint__~a" index)])
             (format (string-append
                     "let ~a = ~a; in builtins.deepSeq ~a "
                      "(if ~a ~a then (~a) else ~a)")
                     predicate-name
                     (emit-expr constraint depth)
                     (raw-name index)
                     predicate-name
                     (raw-name index)
                     bind
                     (binding-constraint-failure p)))
           bind)]))
  (if (null? indexed)
      (format "_: ~a" body)
      (for/fold ([result (emit-bindings indexed)])
                ([entry (in-list (reverse indexed))])
        (format "~a: ~a" (raw-name (car entry)) result)))))

;; --- special float values ---------------------------------------------------

(define (emit-nix-number n)
  (cond
    [(or (eqv? n +inf.0) (eqv? n -inf.0) (eqv? n +nan.0))
     (error 'emit-nix "Nix does not support Infinity or NaN literals")]
    [else (number->string n)]))

;; Nix string escaping + interp/multiline/indented helpers live in
;; emit-nix-strings.rkt and are imported above. They call back via
;; the `current-emit-expr` parameter.


;; --- Nix emission from Beagle AST -----------------------------------------

(define (nix-emit-program prog)
  (define record-types
    (for/fold ([names
                (for/fold ([imported (seteq)])
                          ([name (in-hash-keys
                                  (program-imported-record-fields prog))])
                  (set-add imported name))])
              ([form (in-list (program-forms prog))])
      (define definition (unwrap-definition-form form))
      (cond
        [(record-form? definition)
         (set-add names (record-form-name definition))]
        [(and (defunion-form? definition)
              (defunion-form-member-fields definition))
         (for/fold ([out names])
                   ([member
                     (in-list (defunion-form-members definition))]
                    #:when
                    (hash-has-key?
                     (defunion-form-member-fields definition)
                     member))
           (set-add out member))]
        [(deferror-form? definition)
         (for/fold ([out names])
                   ([member (in-list (deferror-form-members definition))])
           (set-add out member))]
        [else names])))
  (define require-prefixes
    (for/fold ([prefixes (hash)])
              ([entry (in-list (program-requires prog))]
               [index (in-naturals)])
      (define namespace (symbol->string (require-entry-ns entry)))
      (define default-prefix (last (string-split namespace ".")))
      (define alias (require-entry-alias entry))
      (define runtime-prefix
        (if alias
            (mangle-name alias)
            (if (require-entry-refer entry)
                (format "bgl____module__~a" index)
                (mangle-name (string->symbol default-prefix)))))
      (define with-namespace (hash-set prefixes namespace runtime-prefix))
      (define with-default (hash-set with-namespace default-prefix runtime-prefix))
      (if alias
          (hash-set with-default (symbol->string alias) runtime-prefix)
          with-default)))
  (parameterize ([current-emit-expr emit-expr]
                 [current-nix-record-types record-types]
                 [current-nix-program prog]
                 [current-nix-semantic-contracts
                  (program-semantic-contracts prog)]
                 [current-nix-require-prefixes require-prefixes]
                 [current-type-table (program-type-table prog)])
    (nix-emit-program-body prog)))

(define (nix-emit-program-body prog)
  (define depth 0)
  (define forms (program-forms prog))
  (define requires (program-requires prog))
  (define ns (program-namespace prog))
  (define defs '())
  (define body-exprs '())

  ;; Separate top-level defs from expressions
  (for ([raw-form (in-list forms)])
    (define f (unwrap-definition-form raw-form))
    (cond
      [(or (def-form? f) (defn-form? f) (defn-multi? f)
           (defonce-form? f) (record-form? f) (defenum-form? f)
           (defunion-form? f) (deferror-form? f) (defscalar-form? f)
           (protocol-form? f) (extend-type-form? f)
           (defmulti-form? f) (defmethod-form? f)
           (nix-inherit? f) (nix-inherit-from? f))
       (set! defs (cons f defs))]
      [else
       (set! body-exprs (cons f body-exprs))]))

  (set! defs (reverse defs))
  (set! body-exprs (reverse body-exprs))

  (define import-str
    (if (null? requires)
      ""
      (string-append
       (string-join
        (apply
         append
         (for/list ([r (in-list requires)] [index (in-naturals)])
           (define namespace (symbol->string (require-entry-ns r)))
           (define module-name (format "bgl____module__~a" index))
           (define module-import (require-module-import prog r))
           (define interface
             (and module-import (module-import-interface module-import)))
           (define alias
             (or (require-entry-alias r)
                 (and (not (require-entry-refer r))
                      (string->symbol (last (string-split namespace "."))))))
           (append
            (list
             (format "  ~a = import ~a;"
                     module-name
                     (relative-nix-module-path
                      ns (require-entry-ns r))))
            (if alias
                (list (format "  ~a = ~a;" (mangle-name alias) module-name))
                '())
            (for/list ([name (in-list (or (require-entry-refer r) '()))]
                       #:when
                       (cond
                         [interface
                          (runtime-interface-binding? interface name)]
                         [else
                          (error
                           'beagle-nix
                           (string-append
                            "Nix :refer import from ~a lacks an authoritative "
                            "module interface; checked emission refuses to "
                            "guess its runtime export surface")
                           namespace)]))
              (format "  ~a = ~a.~a;"
                      (mangle-name name)
                      module-name
                      (mangle-name name)))
            (if interface
                (for/list
                    ([validator
                      (in-list
                       (referred-record-validator-symbols
                        prog r interface))])
                  (format "  ~a = ~a.~a;"
                          (mangle-name validator)
                          module-name
                          (mangle-name validator)))
                '()))))
        "\n")
       "\n")))

  (define def-strs
    (for/list ([d (in-list defs)])
      (emit-top-def d 1)))

  (define body-str
    (emit-body body-exprs 0))

  (define local-validator-exports
    (sort
     (apply
      append
      (for/list ([raw-form (in-list forms)])
        (define form (unwrap-definition-form raw-form))
        (define (validator-for name fields)
          (and (record-fields-constrained? fields)
               (cons (record-validator-symbol name)
                     (record-validator-name name))))
        (cond
          [(record-form? form)
           (filter values
                   (list
                    (validator-for
                     (record-form-name form) (record-form-fields form))))]
          [(and (defunion-form? form)
                (defunion-form-member-fields form))
           (filter-map
            (lambda (member)
              (validator-for
               member
               (hash-ref
                (defunion-form-member-fields form) member '())))
            (defunion-form-members form))]
          [(deferror-form? form)
           (filter-map
            (lambda (member)
              (validator-for
               member
               (hash-ref
                (deferror-form-member-fields form) member '())))
            (deferror-form-members form))]
          [else '()])))
     symbol<?
     #:key car))

  (define (local-runtime-export-bindings)
    (define interface
      (and (pair? defs)
           (program->module-interface
           prog
           #:provisional?
            (not (hash? (program-effective-definition-types prog)))
            #:capture-types?
            (and (program-type-table prog) #t))))
    (if (not interface)
        '()
        (sort
         (filter-map
          (lambda (name)
            (define binding (module-interface-binding-ref interface name #f))
            (define kind (and binding (interface-binding-kind binding)))
            ;; Declarations with no Nix runtime binding are rejected earlier by
            ;; emit-top-def. Externs and macros are provider dependencies or
            ;; compile-time values, never exports from this generated module.
            (and binding
                 (not (memq kind '(extern macro protocol-method defmulti)))
                 (cons name (mangle-name name))))
          (hash-keys (module-interface-bindings interface)))
         symbol<?
         #:key car)))

  (define runtime-exports
    (append (local-runtime-export-bindings) local-validator-exports))
  (define export-attrs
    (and
     (pair? runtime-exports)
     (format "{ ~a }"
             (string-join
              (for/list ([entry (in-list runtime-exports)])
                (format "~a = ~a;"
                        (mangle-name (car entry))
                        (cdr entry)))
              " "))))
  (define module-result
    (cond
      [(not export-attrs) body-str]
      [(null? body-exprs) export-attrs]
      ;; An authored attrset is explicitly a module product. Add the generated
      ;; public/ABI surface after it so reserved compiler-owned keys win.
      [(and (pair? body-exprs) (map-form? (last body-exprs)))
       (format "(~a // ~a)" body-str export-attrs)]
      ;; Any other authored result IS the module's product — a Nix module may
      ;; evaluate to a string, list, or derivation. There is no attrset to
      ;; merge into, and an importer could not reach an export surface through
      ;; a non-attrset value anyway, so the defs stay module-internal.
      [else body-str]))

  (cond
    ;; No defs — just emit the body expression
    [(and (null? defs) (null? requires))
     (string-append module-result "\n")]
    ;; Wrap in let ... in
    [else
     (string-append
      "let\n"
      import-str
      (string-join def-strs "\n")
      "\n"
      "in\n"
      module-result "\n")]))

;; --- top-level def emission ------------------------------------------------

(define (emit-top-def f depth)
  (define ind (indent depth))
  (cond
    [(def-form? f)
     (format "~a~a = ~a;" ind
             (mangle-name (def-form-name f))
             (emit-expr (def-form-value f) depth))]

    [(defonce-form? f)
     (format "~a~a = ~a;" ind
             (mangle-name (defonce-form-name f))
             (emit-expr (defonce-form-value f) depth))]

    [(defn-form? f)
     (define name (mangle-name (defn-form-name f)))
     (define params (defn-form-params f))
     (define rest-p (defn-form-rest-param f))
     (define body (defn-form-body f))
     (define body-str (emit-body body depth))
     (define fn-str
       (emit-param-chain
        (if rest-p (append params (list rest-p)) params)
        body-str
        depth))
     (format "~a~a = ~a;" ind name fn-str)]

    [(defn-multi? f)
     (error 'emit-nix "multi-arity defn not supported for Nix target: ~a"
            (defn-multi-name f))]

    [(record-form? f)
     (emit-record-defs f depth)]

    [(protocol-form? f)
     (error 'emit-nix
            "protocol declarations are not supported by the nix backend: ~a"
            (protocol-form-name f))]

    [(extend-type-form? f)
     (error 'emit-nix
            "protocol implementations are not supported by the nix backend: ~a"
            (extend-type-form-type-name f))]

    [(or (defmulti-form? f) (defmethod-form? f))
     (error 'emit-nix
            "multimethod declarations are not supported by the nix backend")]

    [(defunion-form? f)
     (define name (mangle-name (defunion-form-name f)))
     (define members (defunion-form-members f))
     (define member-fields (defunion-form-member-fields f))
     (if (not member-fields)
         (format "~a# union ~a = ~a" ind name
                 (string-join (map symbol->string members) " | "))
         (string-append
          (format "~a# union ~a = ~a" ind name
                  (string-join (map symbol->string members) " | "))
          "\n"
          (string-join
           (for/list ([member (in-list members)]
                      #:when (hash-has-key? member-fields member))
             (emit-tagged-type-defs
              member (hash-ref member-fields member) depth))
           "\n")))]

    [(defenum-form? f)
     (define name (defenum-form-name f))
     (define vals (defenum-form-values f))
     (define entries
       (string-join
        (for/list ([v (in-list vals)])
          (format "\"~a\"" (escape-nix (string-replace (symbol->string v) ":" ""))))
        " "))
     (format "~a~a = [ ~a ];"
             ind
             (mangle-name
              (string->symbol (format "~a-values" name)))
             entries)]

    [(deferror-form? f)
     (define name (mangle-name (deferror-form-name f)))
     (define members (deferror-form-members f))
     (define mf (deferror-form-member-fields f))
     (string-append (format "~a# error ~a" ind name) "\n"
                    (string-join
                     (for/list ([member (in-list members)])
                       (emit-tagged-type-defs
                        member (hash-ref mf member '()) depth))
                     "\n"))]

    [(defscalar-form? f)
     (emit-defscalar-nix f depth)]

    [(nix-inherit? f)
     (format "~ainherit ~a;"
             ind
             (string-join (map (lambda (n) (mangle-name n))
                               (nix-inherit-names f))
                          " "))]

    [(nix-inherit-from? f)
     (format "~ainherit (~a) ~a;"
             ind
             (emit-expr (nix-inherit-from-ns-expr f) depth)
             (string-join (map (lambda (n) (mangle-name n))
                               (nix-inherit-from-names f))
                          " "))]

    [else (format "~a# unsupported form: ~v" ind f)]))

;; --- defscalar → branded constructor with runtime predicates ---------------

(define (scalar-pred->nix backing-sym v p)
  (define op (scalar-predicate-op p))
  (define val (scalar-predicate-value p))
  (case op
    [(>) (format "~a > ~v" v val)]
    [(>=) (format "~a >= ~v" v val)]
    [(<) (format "~a < ~v" v val)]
    [(<=) (format "~a <= ~v" v val)]
    [(=) (format "~a == ~v" v val)]
    [(==) (format "~a == ~v" v val)]
    [(!=) (format "~a != ~v" v val)]
    [(not=) (format "~a != ~v" v val)]
    [else (error 'emit-nix "defscalar: unsupported predicate operator: ~a" op)]))

(define (backing-type-check backing-sym v)
  (case backing-sym
    [(Int) (format "builtins.isInt ~a" v)]
    [(Float) (format "builtins.isFloat ~a" v)]
    [(String) (format "builtins.isString ~a" v)]
    [(Bool) (format "builtins.isBool ~a" v)]
    [else #f]))

(define (emit-defscalar-nix f depth)
  (define ind (indent depth))
  (define name (defscalar-form-name f))
  (define backing (defscalar-form-backing-type f))
  (define preds (defscalar-form-predicates f))
  (define ctor-name (mangle-name (string->symbol (format "->~a" name))))
  (define accessor-name
    (mangle-name
     (string->symbol
      (format "~a-value" (string-downcase (symbol->string name))))))
  (define v "v")
  (define backing-assert (backing-type-check backing v))
  (define pred-asserts
    (map (lambda (p) (scalar-pred->nix backing v p)) preds))
  (define all-asserts
    (if backing-assert (cons backing-assert pred-asserts) pred-asserts))
  (cond
    [(null? all-asserts)
     ;; No checks — identity function as a brand
     (format "~a~a = v: v;\n~a~a = v: v;"
             ind ctor-name ind accessor-name)]
    [else
     (define assert-block
       (string-join
        (for/list ([a (in-list all-asserts)])
          (format "assert ~a;" a))
        " "))
     (format "~a~a = v: ~a v;\n~a~a = v: v;"
             ind ctor-name assert-block ind accessor-name)]))

;; --- record → attrset constructor + accessors ------------------------------

(define (record-fields-constrained? fields)
  (ormap checked-binding-constraint fields))

(define (emit-record-validator-def name fields depth)
  (and
   (record-fields-constrained? fields)
   (let* ([ind (indent depth)]
          [value-name "bgl____record__value"]
          [constrained
           (for/list ([field (in-list fields)] [index (in-naturals)]
                      #:when (checked-binding-constraint field))
             (cons index field))]
          [guarded
           (for/fold ([result value-name])
                     ([entry (in-list (reverse constrained))])
             (define index (car entry))
             (define field (cdr entry))
             (define predicate-name (format "bgl____constraint__~a" index))
             (define field-name (mangle-name (param-name field)))
             (format (string-append
                      "builtins.deepSeq ~a.~a "
                      "(if ~a ~a.~a then (~a) else ~a)")
                     value-name
                     field-name
                     predicate-name
                     value-name
                     field-name
                     result
                     (binding-constraint-failure field)))]
          [with-predicates
           (for/fold ([result guarded])
                     ([entry (in-list (reverse constrained))])
             (define index (car entry))
             (define field (cdr entry))
             (format "let bgl____constraint__~a = ~a; in ~a"
                     index
                     (emit-expr (checked-binding-constraint field) depth)
                     result))])
     (format "~a~a = ~a: ~a;"
             ind
             (record-validator-name name)
             value-name
             with-predicates))))

(define (emit-tagged-type-defs name fields depth)
  (define ind (indent depth))
  (define tag (string-downcase (symbol->string name)))
  (define ctor-name (mangle-name (string->symbol (format "->~a" name))))
  (define field-names (map param-name fields))
  (define entries
    (string-append
     (format " _tag = \"~a\";" (escape-nix tag))
     (if (null? field-names)
         " "
         (string-append
          " "
          (string-join
           (for/list ([field-name (in-list field-names)])
             (define emitted (mangle-name field-name))
             (format "~a = ~a;" emitted emitted))
           " ")
          " "))))
  ;; A local constructor owns the original field declarations. Guard each raw
  ;; argument before the field is installed in the result object; the aggregate
  ;; validator remains a provider ABI for `with` and imported consumers, not a
  ;; second constructor pass over already-installed properties.
  (define value-str (format "{~a}" entries))
  (define ctor
    (format "~a~a = ~a;"
            ind
            ctor-name
            (emit-param-chain fields value-str depth)))
  (define accessors
    (for/list ([field-name (in-list field-names)])
      (define emitted (mangle-name field-name))
      (define accessor
        (mangle-name
         (string->symbol
          (format "~a-~a" tag (symbol->string field-name)))))
      (format "~a~a = r: r.~a;" ind accessor emitted)))
  (string-join
   (filter values
           (append
            (list (emit-record-validator-def name fields depth) ctor)
            accessors))
   "\n"))

(define (emit-record-defs rf depth)
  (emit-tagged-type-defs
   (record-form-name rf) (record-form-fields rf) depth))

;; --- expression emission ---------------------------------------------------

(define (emit-expr e depth)
  (cond
    [(resolved-ref? e) (mangle-name (resolved-ref-output-symbol e))]
    [(qualified-ref? e) (mangle-qualified-name e)]
    [(number? e) (emit-nix-number e)]
    [(string? e) (format "\"~a\"" (escape-nix e))]
    [(boolean? e) (if e "true" "false")]
    ;; Char literals lower to single-character strings in Nix (no char type).
    [(char? e) (format "\"~a\"" (escape-nix (string e)))]
    [(eq? e 'nil) "null"]

    [(symbol? e)
     (define sym-str (symbol->string e))
     (cond
       [(eq? e 'nil) "null"]
       [(eq? e 'true) "true"]
       [(eq? e 'false) "false"]
       [(char=? (string-ref sym-str 0) #\:)
        (format "\"~a\"" (escape-nix (substring sym-str 1)))]
       [(string-contains? sym-str ".")
        sym-str]
       [else (mangle-name e)])]

    [(def-form? e)
     (format "let ~a = ~a; in ~a"
             (mangle-name (def-form-name e))
             (emit-expr (def-form-value e) depth)
             (mangle-name (def-form-name e)))]

    [(fn-form? e)
     (define params (fn-form-params e))
     (define rest-p (fn-form-rest-param e))
     (define body (fn-form-body e))
     (emit-param-chain
      (if rest-p (append params (list rest-p)) params)
      (emit-body body depth)
      depth)]

    [(let-form? e)
     (emit-let e depth)]

    [(if-form? e)
     (format "if ~a then ~a else ~a"
             (emit-expr (if-form-cond-expr e) depth)
             (emit-expr (if-form-then-expr e) depth)
             (emit-expr (if-form-else-expr e) depth))]

    [(cond-form? e)
     (emit-cond e depth)]

    [(when-form? e)
     (format "if ~a then ~a else null"
             (emit-expr (when-form-cond-expr e) depth)
             (emit-body (when-form-body e) depth))]

    [(do-form? e)
     (emit-body (do-form-body e) depth)]

    [(call-form? e)
     (emit-call e depth)]

    [(vec-form? e)
     (emit-nix-list (vec-form-items e) depth)]

    [(map-form? e)
     (emit-nix-attrs (map-form-pairs e) depth)]

    [(set-form? e)
     (error 'emit-nix
            "Nix has no set literal. Use a list (#{...} → [...]) or an attrset {:k true} for set-of-keywords semantics.")]

    [(kw-access? e)
     (define target-expr (kw-access-target e))
     (define target
       (paren-wrap (emit-expr target-expr depth) target-expr))
     (define field
       (keyword-selection-field target-expr (kw-access-kw e) e))
     (cond
       [(kw-access-default e)
        ;; (get m :k default) → `target.field or default` — same emit as
        ;; the pre-canonicalization call-form path's literal-key 3-arity.
        ;; Nix's `or` suffix is greedy on the right, so paren-wrap is the
        ;; caller's job (see paren-wrap rules for nix-get-or).
        (format "~a.~a or ~a"
                target
                field
                (emit-expr (kw-access-default e) depth))]
       [else
        (format "~a.~a" target field)])]

    [(quoted? e)
     (define d (quoted-datum e))
     (cond
       [(symbol? d) (format "\"~a\"" (escape-nix (symbol->string d)))]
       [(string? d) (format "\"~a\"" (escape-nix d))]
       [(number? d) (emit-nix-number d)]
       [(boolean? d) (if d "true" "false")]
       [else (format "\"~v\"" d)])]

    [(flake-input-form? e)
     ;; (flake-input :NAME :NAMESPACE :seg ...) →
     ;;   inputs.NAME.NAMESPACE.${pkgs.stdenv.hostPlatform.system}.seg1.seg2...
     ;; System axis collapsed; path segments emitted verbatim.
     (define (seg->str s)
       (define str (symbol->string s))
       (if (string-prefix? str ":") (substring str 1) str))
     (define input-str (seg->str (flake-input-form-input-name e)))
     (define ns-str (seg->str (flake-input-form-namespace e)))
     (define path-segs (flake-input-form-path-segments e))
     (define path-str (string-join (map seg->str path-segs) "."))
     (if (string=? path-str "")
         (format "inputs.~a.~a.${pkgs.stdenv.hostPlatform.system}"
                 input-str ns-str)
         (format "inputs.~a.~a.${pkgs.stdenv.hostPlatform.system}.~a"
                 input-str ns-str path-str))]

    [(match-form? e)
     (emit-match e depth)]

    [(with-form? e)
     (emit-with-form e depth)]

    [(for-form? e)
     (emit-for e depth)]

    [(loop-form? e)
     ;; Nix doesn't have loops — emit as recursive let
     (emit-loop e depth)]

    [(recur-form? e)
     (define name (current-recur-name))
     (unless name
       (error 'emit-nix "(recur ...) outside of (loop ...)"))
     (define arg-strs
       (map (lambda (a) (paren-wrap (emit-expr a depth) a))
            (recur-form-args e)))
     (if (null? arg-strs)
       (string-append name " null")
       (string-append name " " (string-join arg-strs " ")))]

    [(ascription? e) (emit-expr (ascription-expr e))]
    [(check-expr? e)
     (define inner (emit-expr (check-expr-expr e) depth))
     (format "(let r = ~a; in if r ? _tag && r._tag == \"Ok\" then r.value else abort \"check failed\")"
             inner)]
    [(rescue-form? e)
     (define inner (emit-expr (rescue-form-expr e) depth))
     (define fallback (emit-expr (rescue-form-fallback e) depth))
     (format "(let r = ~a; in if r ? _tag && r._tag == \"Ok\" then r.value else ~a)"
             inner fallback)]
    [(target-case-form? e)
     (define cases (target-case-form-cases e))
     (define branch (or (hash-ref cases 'nix #f)))
     (unless branch
       (error 'beagle "target-case: no branch for target nix"))
     (emit-expr branch depth)]
    [(try-form? e)
     ;; Nix's builtins.tryEval returns { success; value; } — unwrap to value-or-null
     ;; so the rest of beagle sees the same semantics as other targets.
     (format "(let bgl____try = builtins.tryEval (~a); in if bgl____try.success then bgl____try.value else null)"
             (emit-body (try-form-body e) depth))]


    [(with-meta? e)
     (emit-expr (with-meta-expr e) depth)]

    ;; threading-marker is transparent to the Nix emitter — walk the
    ;; desugared AST. emit-clj recognizes the marker to reconstruct the
    ;; surface form, but Nix has no idiomatic threading equivalent.
    [(threading-marker? e)
     (emit-expr (threading-marker-desugared e) depth)]

    [(method-call? e)
     ;; (.attr target args ...) → (target.attr args ...) in Nix.
     ;; Used for attr-access on a parenthesized expression: in Nix
     ;; you write `(expr).attr arg` for `(get expr "attr")` applied
     ;; to arg. Beagle's dotted-access syntax requires a leading
     ;; identifier, so this is the canonical way to express "attr
     ;; access on a complex expression" in beagle/nix.
     (define method-str (substring (symbol->string (method-call-method-name e)) 1))
     (define target-str (paren-wrap (emit-expr (method-call-target e) depth)
                                    (method-call-target e)))
     (define arg-strs
       (map (lambda (a) (paren-wrap (emit-expr a depth) a))
            (method-call-args e)))
     (cond
       [(null? arg-strs) (format "~a.~a" target-str method-str)]
       [else
        (format "~a.~a ~a"
                target-str method-str
                (string-join arg-strs " "))])]

    [(await-form? e)
     (error 'emit-nix "await is only supported in beagle/js")]

    [(when-let-form? e)
     (format "let bgl____value = ~a; in if bgl____value != null then ~a else null"
             (emit-expr (when-let-form-expr e) depth)
             (format "let ~a = bgl____value; in ~a"
                     (mangle-name (when-let-form-name e))
                     (emit-body (when-let-form-body e) depth)))]

    [(if-let-form? e)
     (format "let bgl____value = ~a; in if bgl____value != null then ~a else ~a"
             (emit-expr (if-let-form-expr e) depth)
             (format "let ~a = bgl____value; in ~a"
                     (mangle-name (if-let-form-name e))
                     (emit-body (if-let-form-then-body e) depth))
             (emit-body (if-let-form-else-body e) depth))]

    ;; --- Nix-specific forms --------------------------------------------------

    [(nix-inherit? e)
     (format "inherit ~a;"
             (string-join (map (lambda (n) (mangle-name n))
                               (nix-inherit-names e))
                          " "))]

    [(nix-inherit-from? e)
     (format "inherit (~a) ~a;"
             (emit-expr (nix-inherit-from-ns-expr e) depth)
             (string-join (map (lambda (n) (mangle-name n))
                               (nix-inherit-from-names e))
                          " "))]

    [(nix-with? e)
     (define ns-str (emit-expr (nix-with-ns-expr e) depth))
     (define body-expr (nix-with-body e))
     (define body-str (emit-expr body-expr depth))
     (define ns-prefix (string-append ns-str "."))
     (if (and (vec-form? body-expr)
              (andmap (lambda (item)
                        (and (symbol? item)
                             (string-prefix? (symbol->string item) ns-prefix)))
                      (vec-form-items body-expr)))
       body-str
       (format "with ~a; ~a" ns-str body-str))]

    [(nix-rec-attrs? e)
     (emit-nix-rec-attrs (nix-rec-attrs-pairs e) depth)]

    [(nix-assert? e)
     (format "assert ~a; ~a"
             (emit-expr (nix-assert-cond-expr e) depth)
             (emit-expr (nix-assert-body e) depth))]

    [(nix-get-or? e)
     (format "~a.~a or ~a"
             (emit-expr (nix-get-or-base-expr e) depth)
             (nix-get-or-path e)
             (emit-expr (nix-get-or-default e) depth))]

    [(nix-has-attr? e)
     ;; Nix's `?` operator RHS accepts a bare identifier, a dotted path
     ;; of identifiers, or a quoted string. If the path contains
     ;; non-identifier characters (e.g. `/`), it MUST be quoted —
     ;; otherwise `target ? /persist` parses as a path literal in
     ;; expression position and fails.
     (define raw-path (nix-has-attr-path e))
     (define formatted-path
       (cond
         [(regexp-match? #rx"^[a-zA-Z_][a-zA-Z0-9_'-]*(\\.[a-zA-Z_][a-zA-Z0-9_'-]*)*$"
                         raw-path)
          raw-path]
         [else (format "~v" raw-path)]))
     (format "~a ? ~a"
             (emit-expr (nix-has-attr-base-expr e) depth)
             formatted-path)]

    [(nix-search-path? e)
     (format "<~a>" (nix-search-path-name e))]

    [(nix-interpolated-string? e)
     (emit-nix-interp-string (nix-interpolated-string-parts e) depth)]

    [(nix-multiline-string? e)
     (emit-nix-multiline-string (nix-multiline-string-lines e) depth)]

    [(block-string? e)
     (emit-nix-indented-string (block-string-text e) depth)]

    [(nix-path? e)
     (nix-path-path-string e)]

    [(nix-fn-set? e)
     (emit-nix-fn-set e depth)]

    ;; nix-pipe / nix-impl emit-arms removed — pipe family is gone.

    [(nix-derivation? e)
     (emit-nix-derivation e depth)]

    [(nix-flake? e)
     (emit-nix-flake e depth)]

    [(nix-with-cfg? e)
     (emit-nix-with-cfg e depth)]

    ;; --- end Nix-specific forms ----------------------------------------------

    [else (error 'emit-nix "no Nix emission defined for AST node: ~v" e)]))

;; --- derivation / flake / with-cfg emission --------------------------------

;; --- derivation: typed attrset shape validation ---------------------------
;; Required: (:pname OR :name)
;; Optional with known types:
;;   :version (String), :src (Any/Path), :builder (Any — overrides pkgs.stdenv.mkDerivation),
;;   :buildInputs (Vec/List), :nativeBuildInputs (Vec/List), :propagatedBuildInputs (Vec/List),
;;   :buildPhase (String), :installPhase (String), :configurePhase (String),
;;   :checkPhase (String), :patchPhase (String), :unpackPhase (String),
;;   :preBuild (String), :postBuild (String), :preInstall (String), :postInstall (String),
;;   :patches (Vec/List), :meta (Map), :outputs (Vec/List String),
;;   :doCheck (Bool), :enableParallelBuilding (Bool),
;;   :CARGO_BUILD_TARGET / :MAKE / arbitrary build-env vars (String — caught by allow-env-pattern)
;; Unknown keys that don't match an env-var pattern are rejected with did-you-mean.

(define DERIVATION-REQUIRED-ONE-OF
  '(":pname" ":name"))

(define DERIVATION-KNOWN-KEYS
  '(":pname" ":name" ":version" ":src" ":builder"
    ":buildInputs" ":nativeBuildInputs" ":propagatedBuildInputs"
    ":propagatedNativeBuildInputs" ":checkInputs" ":nativeCheckInputs"
    ":buildPhase" ":installPhase" ":configurePhase" ":checkPhase"
    ":patchPhase" ":unpackPhase" ":fixupPhase" ":distPhase"
    ":preBuild" ":postBuild" ":preInstall" ":postInstall"
    ":preConfigure" ":postConfigure" ":preCheck" ":postCheck"
    ":preFixup" ":postFixup" ":preUnpack" ":postUnpack"
    ":patches" ":meta" ":outputs" ":doCheck" ":doInstallCheck"
    ":enableParallelBuilding" ":enableParallelChecking"
    ":dontUnpack" ":dontConfigure" ":dontBuild" ":dontInstall" ":dontFixup"
    ":dontStrip" ":dontPatchELF" ":separateDebugInfo"
    ":system" ":hardeningDisable" ":hardeningEnable"
    ":NIX_CFLAGS_COMPILE" ":NIX_LDFLAGS"
    ":cargoBuildFlags" ":cargoSha256" ":cargoHash" ":vendorHash" ":cargoLock"
    ":pyproject" ":pythonImportsCheck" ":format"
    ":makeFlags" ":installFlags" ":checkFlags"
    ":passthru" ":__structuredAttrs"))

(define (env-var-key? key-str)
  ;; All-caps key with optional underscores — treat as a build-env variable.
  (regexp-match? #px"^:[A-Z][A-Z0-9_]*$" key-str))

(define (kw-key-string p)
  (and (symbol? (car p)) (symbol->string (car p))))

(define (key-similarity-suggest key known-keys)
  (define candidates
    (sort
     (filter (lambda (k) (<= (key-levenshtein key k) 2))
             known-keys)
     < #:key (lambda (k) (key-levenshtein key k))))
  (cond
    [(null? candidates) #f]
    [else (string-join (take candidates (min 3 (length candidates))) " or ")]))

(define (key-levenshtein a b)
  (define la (string-length a))
  (define lb (string-length b))
  (cond [(zero? la) lb] [(zero? lb) la]
        [else
         (define prev (make-vector (add1 lb)))
         (define curr (make-vector (add1 lb)))
         (for ([j (in-range (add1 lb))]) (vector-set! prev j j))
         (for ([i (in-range 1 (add1 la))])
           (vector-set! curr 0 i)
           (for ([j (in-range 1 (add1 lb))])
             (define cost (if (char=? (string-ref a (sub1 i)) (string-ref b (sub1 j))) 0 1))
             (vector-set! curr j (min (add1 (vector-ref curr (sub1 j)))
                                      (add1 (vector-ref prev j))
                                      (+ cost (vector-ref prev (sub1 j))))))
           (vector-copy! prev 0 curr))
         (vector-ref prev lb)]))

(define (emit-nix-derivation e depth)
  (define attrs (nix-derivation-attrs e))
  (unless (map-form? attrs)
    (error 'emit-nix "(derivation ...) requires an attrset literal, got ~v" attrs))
  (define pairs (map-form-pairs attrs))
  ;; Validate keys
  (define has-name?
    (ormap (lambda (p) (and (kw-key-string p)
                            (member (kw-key-string p) DERIVATION-REQUIRED-ONE-OF)))
           pairs))
  (unless has-name?
    (error 'emit-nix "(derivation ...) requires either :pname or :name"))
  ;; Reject unknown keys (unless they're env-var-shaped)
  (for ([p (in-list pairs)])
    (define k (kw-key-string p))
    (when k
      (unless (or (member k DERIVATION-KNOWN-KEYS) (env-var-key? k))
        (define suggest (key-similarity-suggest k DERIVATION-KNOWN-KEYS))
        (error 'emit-nix
               "(derivation ...): unknown key ~a~a"
               k
               (if suggest (format " — did you mean ~a?" suggest) "")))))
  ;; Extract :builder for redirection
  (define builder
    (let loop ([ps pairs])
      (cond [(null? ps) #f]
            [(equal? (kw-key-string (car ps)) ":builder") (cdr (car ps))]
            [else (loop (cdr ps))])))
  (define filtered
    (filter (lambda (p) (not (equal? (kw-key-string p) ":builder"))) pairs))
  (define builder-str
    (if builder (emit-expr builder depth) "pkgs.stdenv.mkDerivation"))
  (define attrs-str (emit-nix-attrs filtered depth))
  (format "(~a ~a)" builder-str attrs-str))

;; --- flake: typed attrset shape validation --------------------------------
;; A flake.nix has exactly: :description, :inputs, :outputs (required),
;; optional :nixConfig. Unknown top-level keys are rejected.
;; :outputs must be a function (nix/module or nix/fn-set). :inputs is a map.

(define FLAKE-REQUIRED '(":outputs"))
(define FLAKE-KNOWN-KEYS
  '(":description" ":inputs" ":outputs" ":nixConfig"))

(define (emit-nix-flake e depth)
  (define attrs (nix-flake-attrs e))
  (unless (map-form? attrs)
    (error 'emit-nix "(flake ...) requires an attrset literal, got ~v" attrs))
  (define pairs (map-form-pairs attrs))
  ;; Required keys present?
  (for ([req (in-list FLAKE-REQUIRED)])
    (unless (ormap (lambda (p) (equal? (kw-key-string p) req)) pairs)
      (error 'emit-nix "(flake ...): missing required key ~a" req)))
  ;; All keys known?
  (for ([p (in-list pairs)])
    (define k (kw-key-string p))
    (when k
      (unless (member k FLAKE-KNOWN-KEYS)
        (define suggest (key-similarity-suggest k FLAKE-KNOWN-KEYS))
        (error 'emit-nix
               "(flake ...): unknown top-level key ~a~a"
               k
               (if suggest (format " — did you mean ~a?" suggest) "")))))
  ;; :outputs must be a function (nix-fn-set or fn-form)
  (for ([p (in-list pairs)])
    (when (equal? (kw-key-string p) ":outputs")
      (unless (or (nix-fn-set? (cdr p)) (fn-form? (cdr p)))
        (error 'emit-nix
               "(flake ...): :outputs must be a function of inputs — use (nix/module [self ...] BODY) or (nix/fn-set [...] BODY)"))))
  (emit-expr attrs depth))

(define (emit-nix-with-cfg e depth)
  ;; (with-cfg config.path body) — introduces `cfg = config.path;` over body
  ;; and (if body is a map literal) rewrites occurrences of config.path. into cfg.
  ;; AST-level replacement for the legacy regex-based extract-cfg-root in emit-nix-fn-set.
  (define path-expr (nix-with-cfg-path e))
  (define body (nix-with-cfg-body e))
  (define path-str (emit-expr path-expr depth))
  (define rewritten-body
    (rewrite-cfg-ref body path-str))
  (define body-str (emit-expr rewritten-body depth))
  (format "let\n~acfg = ~a;\nin\n~a"
          (indent (+ depth 1)) path-str body-str))

;; Walk AST, replace occurrences of `path-str` qualified-access with `cfg`.
;; This is an AST-level substitution: any symbol whose name starts with
;; `path-str.` becomes `cfg.<rest>`; any kw-access on `path-str` becomes
;; kw-access on `cfg`.
(define (rewrite-cfg-ref e path-str)
  (define cfg-prefix (string-append path-str "."))
  (define prog (current-nix-program))
  (define semantic-contracts (and prog (program-semantic-contracts prog)))
  (define type-table (and prog (program-type-table prog)))
  (define src-table (and prog (program-src-table prog)))
  ;; This emitter-local rewrite creates fresh AST identities. Preserve every
  ;; eq?-keyed checked side-table entry so lowering cannot erase contracts,
  ;; inferred types, or source blame (notably a record-update validator nested
  ;; beneath nix/with-cfg).
  (define (preserve-metadata old new)
    (for ([table (in-list (list semantic-contracts type-table src-table))]
          #:when (and table (hash-has-key? table old)))
      (hash-set! table new (hash-ref table old)))
    new)
  (define (walk-binding-target target)
    (cond
      [(map-destructure? target)
       (map-destructure
        (map-destructure-keys target)
        (map-destructure-as-name target)
        (for/list ([entry (in-list (map-destructure-or-defaults target))])
          (cons (car entry) (walk (cdr entry)))))]
      [(seq-destructure? target)
       (seq-destructure
        (for/list ([name (in-list (seq-destructure-names target))])
          (if (symbol? name) name (walk-binding-target name)))
        (seq-destructure-rest-name target))]
      [else target]))
  (define (walk-param p)
    (param (walk-binding-target (param-name p))
           (param-type p)
           (and (param-constraint p) (walk (param-constraint p)))))
  (define (walk-let-binding b)
    (let-binding
     (and (let-binding-name b)
          (walk-binding-target (let-binding-name b)))
     (let-binding-type b)
     (and (let-binding-constraint b) (walk (let-binding-constraint b)))
     (walk (let-binding-value b))))
  (define (walk-for-clause clause)
    (cond
      [(for-binding? clause)
       (for-binding
        (walk-binding-target (for-binding-name clause))
        (walk (for-binding-expr clause))
        (for-binding-type clause)
        (and (for-binding-constraint clause)
             (walk (for-binding-constraint clause))))]
      [(for-when? clause) (for-when (walk (for-when-test clause)))]
      [(for-let? clause)
       (for-let (map walk-let-binding (for-let-bindings clause)))]
      [else clause]))
  (define (walk e)
    (define rewritten
      (cond
      [(symbol? e)
       (define s (symbol->string e))
       (cond
         [(string=? s path-str) 'cfg]
         [(string-prefix? s cfg-prefix)
          (string->symbol (string-append "cfg." (substring s (string-length cfg-prefix))))]
         [else e])]
      [(map-form? e)
       (map-form
        (for/list ([p (in-list (map-form-pairs e))])
          (cons (walk (car p)) (walk (cdr p)))))]
      [(vec-form? e)
       (vec-form (map walk (vec-form-items e)))]
      [(call-form? e)
       (call-form (walk (call-form-fn e)) (map walk (call-form-args e)))]
      [(fn-form? e)
       (fn-form (map walk-param (fn-form-params e))
                (and (fn-form-rest-param e)
                     (walk-param (fn-form-rest-param e)))
                (fn-form-return-type e)
                (map walk (fn-form-body e)))]
      [(let-form? e)
       (let-form
        (map walk-let-binding (let-form-bindings e))
        (map walk (let-form-body e)))]
      [(loop-form? e)
       (loop-form (map walk-let-binding (loop-form-bindings e))
                  (map walk (loop-form-body e)))]
      [(for-form? e)
       (for-form (map walk-for-clause (for-form-clauses e))
                 (map walk (for-form-body e)))]
      [(doseq-form? e)
       (doseq-form (map walk-for-clause (doseq-form-clauses e))
                   (map walk (doseq-form-body e)))]
      [(binding-form? e)
       (binding-form (map walk-let-binding (binding-form-bindings e))
                     (map walk (binding-form-body e)))]
      [(with-open-form? e)
       (with-open-form (map walk-let-binding (with-open-form-bindings e))
                       (map walk (with-open-form-body e)))]
      [(if-form? e)
       (if-form (walk (if-form-cond-expr e))
                (walk (if-form-then-expr e))
                (and (if-form-else-expr e) (walk (if-form-else-expr e))))]
      [(when-form? e)
       (when-form (walk (when-form-cond-expr e)) (map walk (when-form-body e)))]
      [(when-let-form? e)
       (when-let-form (when-let-form-name e)
                      (walk (when-let-form-expr e))
                      (map walk (when-let-form-body e)))]
      [(if-let-form? e)
       (if-let-form (if-let-form-name e)
                    (walk (if-let-form-expr e))
                    (map walk (if-let-form-then-body e))
                    (map walk (if-let-form-else-body e)))]
      [(do-form? e)
       (do-form (map walk (do-form-body e)))]
      [(kw-access? e)
       (kw-access (kw-access-kw e) (walk (kw-access-target e))
                  (and (kw-access-default e) (walk (kw-access-default e))))]
      [(nix-with? e)
       (nix-with (walk (nix-with-ns-expr e)) (walk (nix-with-body e)))]
      [(nix-assert? e)
       (nix-assert (walk (nix-assert-cond-expr e)) (walk (nix-assert-body e)))]
      [(with-form? e)
       (with-form
        (walk (with-form-target e))
        (for/list ([update (in-list (with-form-updates e))])
          (with-update (with-update-field-kw update)
                       (walk (with-update-value update)))))]
      [(nix-get-or? e)
       (nix-get-or (walk (nix-get-or-base-expr e)) (nix-get-or-path e) (walk (nix-get-or-default e)))]
      [(nix-interpolated-string? e)
       (nix-interpolated-string (map walk (nix-interpolated-string-parts e)))]
      [(nix-multiline-string? e)
       (nix-multiline-string (map walk (nix-multiline-string-lines e)))]
      [else e]))
    (if (eq? rewritten e)
        rewritten
        (preserve-metadata e rewritten)))
  (walk e))

;; --- let -------------------------------------------------------------------

(define (emit-let e depth)
  (emit-let-binding-chain
   (let-form-bindings e)
   (emit-body (let-form-body e) depth)
   depth))

;; Bindings nest so each predicate is emitted in the scope that exists just
;; before its own target.  The guarded case uses function application instead
;; of a recursive Nix let: the constraint expression cannot accidentally see
;; the target it is declaring, and the RHS remains one shared argument thunk.
(define (emit-let-binding-chain bindings body-str depth [index 0])
  (cond
    [(null? bindings) body-str]
    [else
     (define b (car bindings))
     (define n (let-binding-name b))
     (define v (let-binding-value b))
     (define rest-str
       (emit-let-binding-chain (cdr bindings) body-str depth (add1 index)))
     (define ind (indent (+ depth 1)))
     (cond
       ;; Singleton inherit/inherit-from bindings: name=#f sentinel, value is
       ;; the parsed nix-inherit/nix-inherit-from form.
       [(and (not n) (nix-inherit? v))
        (string-append
         "let\n"
         (format "~ainherit ~a;" ind
                 (string-join (map symbol->string (nix-inherit-names v)) " "))
         "\n" (indent depth) "in\n"
         (indent depth) rest-str)]
       [(and (not n) (nix-inherit-from? v))
        (string-append
         "let\n"
         (format "~ainherit (~a) ~a;" ind
                 (emit-expr (nix-inherit-from-ns-expr v) (+ depth 1))
                 (string-join (map symbol->string (nix-inherit-from-names v)) " "))
         "\n" (indent depth) "in\n"
         (indent depth) rest-str)]
       [else
        (define target-name (emit-binding-target b))
        (define value-str (emit-expr v (+ depth 1)))
        (define constraint (checked-binding-constraint b))
        (cond
          [constraint
           (define predicate-name (format "bgl____constraint__~a" index))
           (define raw-name (format "bgl____binding__~a" index))
           (format
            (string-append
             "((let ~a = ~a; in ~a: builtins.deepSeq ~a "
             "(if ~a ~a then (((~a: builtins.deepSeq ~a (~a)) ~a)) "
             "else ~a)) ~a)")
            predicate-name
            (emit-expr constraint (+ depth 1))
            raw-name
            raw-name
            predicate-name
            raw-name
            target-name
            target-name
            rest-str
            raw-name
            (binding-constraint-failure n)
            (paren-wrap value-str v))]
          [else
           ;; Function application keeps the RHS outside its own binder while
           ;; preserving Nix laziness. Only the constrained branch above owns
           ;; an evaluation event.
           (format "((~a: ~a) ~a)"
                   target-name rest-str (paren-wrap value-str v))])])]))

(define (emit-binding-target b)
  (define target
    (cond
      [(param? b) (param-name b)]
      [(let-binding? b) (let-binding-name b)]
      [(for-binding? b) (for-binding-name b)]
      [else (param-binding-target b)]))
  (cond
    [(symbol? target) (mangle-name (binder-output-symbol b target))]
    [else
     (error 'emit-nix
            "destructuring in let bindings is not supported by the nix backend — bind the aggregate to a name, then project its fields explicitly")]))

;; --- call ------------------------------------------------------------------

(define (emit-call e depth)
  (define fn-expr (call-form-fn e))
  (define args (call-form-args e))
  (define fn-name (and (symbol? fn-expr) fn-expr))
  (define promote-ref?
    (and (qualified-ref? fn-expr)
         (eq? (qualified-ref-qualifier fn-expr) 'bgl)
         (eq? (qualified-ref-name fn-expr) 'promote)))

  ;; Core stdlib translations
  (cond
    ;; `bgl/promote` copies a value into an older epoch's arena. Nix has one
    ;; GC-owned heap and no epochs, so the value already outlives every scope
    ;; that could name it: the form erases.
    [(and promote-ref? (= (length args) 1))
     (emit-expr (car args) depth)]

    ;; Unary not → !
    [(and fn-name (eq? fn-name 'not) (= (length args) 1))
     (format "!~a" (paren-wrap (emit-expr (car args) depth) (car args)))]

    ;; mod — Nix has no native modulo; emit inline arithmetic
    [(and fn-name (eq? fn-name 'mod) (= (length args) 2))
     (define a-str (emit-expr (car args) depth))
     (define b-str (emit-expr (cadr args) depth))
     (format "(~a - (~a / ~a) * ~a)" a-str a-str b-str b-str)]

    ;; Arithmetic/comparison — infix
    [(and fn-name (nix-infix-op fn-name))
     => (lambda (op)
          (define (emit-operand a)
            ;; paren-wrap operands that would otherwise be parsed
            ;; greedily by Nix (if/let/fn/etc absorb everything to
            ;; the right unless wrapped).
            (paren-wrap (emit-expr a depth) a))
          (cond
            [(= (length args) 2)
             (format "(~a ~a ~a)"
                     (emit-operand (car args))
                     op
                     (emit-operand (cadr args)))]
            [(and (= (length args) 1) (member fn-name '(- not)))
             (format "(~a~a)"
                     (if (eq? fn-name 'not) "!" "-")
                     (emit-operand (car args)))]
            [else
             ;; N-ary infix → left-fold: join rendered args with " op ".
             ;; (The earlier pair-wise iteration duplicated every middle
             ;; arg — `(+ a b c d)` became `a + b + b + c + c + d`.)
             (format "(~a)"
                     (string-join
                       (map emit-operand args)
                       (format " ~a " op)))]))]

    ;; Collection ops
    [(and fn-name (eq? fn-name 'str))
     (define parts (map (lambda (a) (emit-expr a depth)) args))
     (format "(~a)" (string-join parts " + "))]

    [(and fn-name (eq? fn-name 'count))
     (format "builtins.length ~a" (paren-wrap (emit-expr (car args) depth) (car args)))]

    [(and fn-name (eq? fn-name 'map))
     (format "builtins.map ~a ~a"
             (paren-wrap (emit-expr (car args) depth) (car args))
             (paren-wrap (emit-expr (cadr args) depth) (cadr args)))]

    [(and fn-name (eq? fn-name 'filter))
     (format "builtins.filter ~a ~a"
             (paren-wrap (emit-expr (car args) depth) (car args))
             (paren-wrap (emit-expr (cadr args) depth) (cadr args)))]

    [(and fn-name (eq? fn-name 'concat))
     (cond
       [(= (length args) 2)
        (format "(~a ++ ~a)"
                (emit-expr (car args) depth)
                (emit-expr (cadr args) depth))]
       [else
        (format "(~a)"
                (string-join (map (lambda (a) (emit-expr a depth)) args) " ++ "))])]

    [(and fn-name (eq? fn-name 'merge))
     (cond
       [(= (length args) 2)
        (format "(~a // ~a)"
                (emit-expr (car args) depth)
                (emit-expr (cadr args) depth))]
       [else
        (format "(~a)"
                (string-join (map (lambda (a) (emit-expr a depth)) args) " // "))])]

    [(and fn-name (eq? fn-name 'get))
     (cond
       [(< (length args) 2)
        (format "builtins.getAttr ~a"
                (string-join (map (lambda (a) (emit-expr a depth)) args) " "))]
       [else
        ;; Literal keyword key → unquoted attrset access (`m.name`), the
        ;; idiomatic Nix form. Non-literal keys (bare variable references,
        ;; complex expressions) must use Nix's dynamic-attr interpolation
        ;; `target.${expr}` — emitting `target.<sym-name>` would treat the
        ;; variable's NAME as the attribute key instead of its VALUE.
        (define key-arg (cadr args))
        (define is-keyword?
          (and (symbol? key-arg)
               (let ([s (symbol->string key-arg)])
                 (and (positive? (string-length s))
                      (char=? (string-ref s 0) #\:)))))
        ;; paren-wrap the target — `(get-or X k d).y` would otherwise
        ;; parse as `X.k or d.y` because Nix's `or` operator consumes
        ;; the trailing `.y` as part of its default expression.
        (define target-str
          (paren-wrap (emit-expr (car args) depth) (car args)))
        (cond
          [is-keyword?
           (format "~a.~a"
                   target-str
                   (keyword-selection-field (car args) key-arg))]
          [else
           (format "~a.\"${~a}\""
                   target-str
                   (emit-expr key-arg depth))])])]

    [(and fn-name (eq? fn-name 'assoc))
     (if (>= (length args) 3)
       (format "(~a // { ~a = ~a; })"
               (emit-expr (car args) depth)
               (emit-expr (cadr args) depth)
               (emit-expr (caddr args) depth))
       (format "/* assoc needs 3 args */ null"))]

    [(and fn-name (eq? fn-name 'nil?))
     (format "(~a == null)" (emit-expr (car args) depth))]

    [(and fn-name (eq? fn-name 'some?))
     (format "(~a != null)" (emit-expr (car args) depth))]

    [(and fn-name (eq? fn-name 'string?))
     (format "(builtins.isString ~a)" (paren-wrap (emit-expr (car args) depth) (car args)))]

    [(and fn-name (eq? fn-name 'int?))
     (format "(builtins.isInt ~a)" (paren-wrap (emit-expr (car args) depth) (car args)))]

    [(and fn-name (eq? fn-name 'list?))
     (format "(builtins.isList ~a)" (paren-wrap (emit-expr (car args) depth) (car args)))]

    [(and fn-name (eq? fn-name 'map?))
     (format "(builtins.isAttrs ~a)" (paren-wrap (emit-expr (car args) depth) (car args)))]

    [(and fn-name (eq? fn-name 'inc))
     (format "(~a + 1)" (emit-expr (car args) depth))]

    [(and fn-name (eq? fn-name 'dec))
     (format "(~a - 1)" (emit-expr (car args) depth))]

    [(and fn-name (eq? fn-name 'first))
     (format "builtins.head ~a" (paren-wrap (emit-expr (car args) depth) (car args)))]

    [(and fn-name (eq? fn-name 'rest))
     (format "builtins.tail ~a" (paren-wrap (emit-expr (car args) depth) (car args)))]

    [(and fn-name (eq? fn-name 'keys))
     (format "builtins.attrNames ~a" (paren-wrap (emit-expr (car args) depth) (car args)))]

    [(and fn-name (eq? fn-name 'vals))
     (format "builtins.attrValues ~a" (paren-wrap (emit-expr (car args) depth) (car args)))]

    [(and fn-name (eq? fn-name 'contains?))
     (if (>= (length args) 2)
       (format "(builtins.hasAttr ~a ~a)"
               (emit-expr (cadr args) depth)
               (paren-wrap (emit-expr (car args) depth) (car args)))
       "null")]

    [(and fn-name (eq? fn-name 'range))
     (cond
       [(= (length args) 1)
        (format "builtins.genList (x: x) ~a" (emit-expr (car args) depth))]
       [(= (length args) 2)
        (format "builtins.genList (x: x + ~a) (~a - ~a)"
                (emit-expr (car args) depth)
                (emit-expr (cadr args) depth)
                (emit-expr (car args) depth))]
       [else "null"])]

    [(and fn-name (eq? fn-name 'println))
     (format "builtins.trace ~a null" (paren-wrap (emit-expr (car args) depth) (car args)))]

    ;; Nix-specific: qualified calls (lib/mkIf → lib.mkIf, pkgs/foo → pkgs.foo)
    [(qualified-ref? fn-expr)
     (define nix-name (mangle-qualified-name fn-expr))
     (format "~a~a" nix-name
             (if (null? args) " null"
                 (string-append " " (string-join
                                     (map (lambda (a) (paren-wrap (emit-expr a depth) a)) args)
                                     " "))))]

    ;; nix-ident handling removed — the parser now rejects (nix-ident ...) calls
    ;; at parse time. Use (flake-input :NAME :NAMESPACE :path ...) instead.

    ;; Generic function call
    [else
     (define fn-str (emit-expr fn-expr depth))
     (define arg-strs
       (map (lambda (a) (paren-wrap (emit-expr a depth) a)) args))
     (if (null? arg-strs)
       (string-append fn-str " null")
       (string-append fn-str " " (string-join arg-strs " ")))]))

(define (nix-infix-op sym)
  (case sym
    [(+) "+"] [(-) "-"] [(*) "*"] [(/) "/"]
    [(<) "<"] [(>) ">"] [(<=) "<="] [(>=) ">="]
    [(=) "=="] [(==) "=="] [(not=) "!="] [(!=) "!="]
    [(and) "&&"] [(or) "||"]
    [(++) "++"]         ;; Nix list concatenation
    [(//) "//"]         ;; Nix attrset update/merge
    [(->) "->"]         ;; Nix logical implication
    [else #f]))

(define (paren-wrap text expr)
  (cond
    [(flake-input-form? expr) text]
    ;; In application position Nix parses `f -1` as subtraction, not as a
    ;; call with a negative numeric literal.
    [(and (number? expr) (negative? expr)) (format "(~a)" text)]
    [(and (call-form? expr)
          (symbol? (call-form-fn expr))
          (nix-infix-op (call-form-fn expr)))
     text]
    [(or (call-form? expr) (fn-form? expr) (let-form? expr)
         (if-form? expr) (when-form? expr) (cond-form? expr)
         (match-form? expr) (for-form? expr)
         ;; nix-get-or emits as `target.attr or default` — Nix's `or`
         ;; suffix-operator absorbs anything to the right (e.g. a
         ;; trailing `.X`), so wherever this appears as a target of
         ;; further select/has/etc, it MUST be parenthesized.
         (nix-get-or? expr)
         ;; kw-access with a default emits the same `target.attr or
         ;; default` shape — same greedy-`or` hazard.
         (and (kw-access? expr) (kw-access-default expr))
         ;; nix-with / nix-assert similarly emit expressions with
         ;; greedy trailing-token semantics (`with X; body` consumes
         ;; everything as body); wrap to keep them as values.
         (nix-with? expr)
         (nix-assert? expr))
     (format "(~a)" text)]
    [else text]))

;; --- nix list --------------------------------------------------------------

(define (emit-nix-list items depth)
  (cond
    [(null? items) "[ ]"]
    [else
     (define item-strs
       (map (lambda (i) (paren-wrap (emit-expr i depth) i)) items))
     (define single-line (format "[ ~a ]" (string-join item-strs " ")))
     (define base-indent (* depth 2))
     (if (and (<= (length items) 6)
              (not (ormap map-form? items))
              (<= (+ base-indent (string-length single-line)) 80))
       single-line
       (let ([ind (indent (+ depth 1))])
         (string-append
          "[\n"
          (string-join
           (map (lambda (i) (string-append ind (paren-wrap (emit-expr i (+ depth 1)) i)))
                items)
           "\n")
          "\n" (indent depth) "]")))]))

;; --- nix attrs (map literal) -----------------------------------------------

(define (emit-key key depth)
  (cond
    [(symbol? key)
     (define s (symbol->string key))
     (if (string-prefix? s ":")
       (nix-static-attr-path (substring s 1))
       (format "${~a}" (mangle-name key)))]
    [(string? key)
     ;; If the key contains ${...} interpolation, preserve it so Nix
     ;; evaluates it (computed key). Otherwise full-escape as literal.
     (if (regexp-match? #rx"\\$\\{" key)
       (format "\"~a\"" (escape-nix #:keep-interp? #t key))
       (format "\"~a\"" (escape-nix key)))]
    [(quoted? key)
     (define d (quoted-datum key))
     (if (symbol? d)
       (let ([s (symbol->string d)])
         (if (string-prefix? s ":")
           (nix-static-attr-path (substring s 1))
           s))
       (emit-expr key (+ depth 1)))]
    [(nix-interpolated-string? key)
     (emit-expr key (+ depth 1))]
    [else (format "${~a}" (emit-expr key (+ depth 1)))]))

(define (flattenable-map? val)
  (and (map-form? val)
       (= (length (map-form-pairs val)) 1)
       (not (map-form? (cdr (car (map-form-pairs val)))))))

(define (flatten-dot-path prefix pairs depth)
  (define ind (indent (+ depth 1)))
  (apply append
    (for/list ([pair (in-list pairs)])
      (define key (car pair))
      (define val (cdr pair))
      (define key-str (emit-key key depth))
      (define full-key (string-append prefix "." key-str))
      (cond
        [(flattenable-map? val)
         (flatten-dot-path full-key (map-form-pairs val) depth)]
        [else
         (list (format "~a~a = ~a;" ind full-key (emit-expr val (+ depth 1))))]))))

(define (emit-nix-attrs pairs depth)
  (cond
    [(null? pairs) "{ }"]
    [else
     (define ind (indent (+ depth 1)))
     (define entries
       (for/list ([pair (in-list pairs)])
         (define key (car pair))
         (define val (cdr pair))
         (cond
           ;; Singleton inherit / inherit-from binding (parsed by
           ;; parse-map-literal with val = #f). Emit Nix's inherit
           ;; syntax directly: `inherit a b c;` or `inherit (src) a b c;`.
           [(and (not val) (nix-inherit? key))
            (list (format "~ainherit ~a;" ind
                          (string-join (map symbol->string (nix-inherit-names key)) " ")))]
           [(and (not val) (nix-inherit-from? key))
            (list (format "~ainherit (~a) ~a;" ind
                          (emit-expr (nix-inherit-from-ns-expr key) (+ depth 1))
                          (string-join (map symbol->string (nix-inherit-from-names key)) " ")))]
           [else
            (define key-str (emit-key key depth))
            (cond
              [(and (map-form? val)
                    (string-contains? key-str ".")
                    (= (length (map-form-pairs val)) 1))
               (flatten-dot-path key-str (map-form-pairs val) depth)]
              [else
               (list (format "~a~a = ~a;" ind key-str (emit-expr val (+ depth 1))))])])))
     (string-append
      "{\n"
      (string-join (apply append entries) "\n")
      "\n" (indent depth) "}")]))

;; --- cond → nested if/then/else -------------------------------------------

(define (emit-cond e depth)
  (define clauses (cond-form-clauses e))
  (define (emit-clauses cs)
    (cond
      [(null? cs) "null"]
      [(and (= (length cs) 1)
            (eq? (cond-clause-test (car cs)) 'else))
       (emit-body (cond-clause-body (car cs)) depth)]
      [else
       (define c (car cs))
       (format "if ~a then ~a else ~a"
               (emit-expr (cond-clause-test c) depth)
               (emit-body (cond-clause-body c) depth)
               (emit-clauses (cdr cs)))]))
  (emit-clauses clauses))

;; --- match → nested if/then/else on _tag -----------------------------------

(define (emit-match e depth)
  (define target (emit-expr (match-form-target e) depth))
  (define clauses (match-form-clauses e))
  (define (emit-match-clauses cs)
    (cond
      [(null? cs) "null"]
      [else
       (define c (car cs))
       (define pat (match-clause-pattern c))
       (define body-str (emit-body (match-clause-body c) depth))
       (cond
         [(pat-wildcard? pat)
          body-str]
         [(pat-literal? pat)
          (format "if ~a == ~a then ~a else ~a"
                  target
                  (emit-expr (pat-literal-value pat) depth)
                  body-str
                  (emit-match-clauses (cdr cs)))]
         [(pat-record? pat)
          (define type-name (pat-record-type-name pat))
          (define tag
            (string-downcase
             (symbol->string
              (if (qualified-ref? type-name)
                  (qualified-ref-name type-name)
                  type-name))))
          (define bindings (pat-record-bindings pat))
          (define bind-str
            (if (null? bindings)
              body-str
              (format "let ~a in ~a"
                      (string-join
                       (for/list ([b (in-list bindings)])
                         (define name (if (pat-var? b) (pat-var-name b) b))
                         (format "~a = ~a.~a;"
                                 (mangle-name (binder-output-symbol pat name))
                                 target
                                 (mangle-name name)))
                       " ")
                      body-str)))
          (format "if ~a._tag == \"~a\" then ~a else ~a"
                  target (escape-nix tag) bind-str
                  (emit-match-clauses (cdr cs)))]
         [(pat-var? pat)
          (format "let ~a = ~a; in ~a"
                  (mangle-name (binder-output-symbol pat (pat-var-name pat)))
                  target body-str)]
         ;; or-pattern (v1: literal-only alternatives). Combines tests
         ;; with `||` in a Nix `if`. Future operators slot in as sibling
         ;; cases here.
         [(pat-or? pat)
          (define tests
            (for/list ([alt (in-list (pat-or-alternatives pat))])
              (cond
                [(pat-literal? alt)
                 (format "~a == ~a" target (emit-expr (pat-literal-value alt) depth))]
                [(pat-wildcard? alt) "true"]
                [else (error 'emit-nix
                             "or-pattern (v1) supports literal alternatives only; got: ~v"
                             alt)])))
          (format "if ~a then ~a else ~a"
                  (string-join tests " || ")
                  body-str
                  (emit-match-clauses (cdr cs)))]
         [else (emit-match-clauses (cdr cs))])]))
  (emit-match-clauses clauses))

;; --- with form (record update) → attrset merge ----------------------------

(define (emit-with-form e depth)
  (define target-expr (with-form-target e))
  (define target (emit-expr target-expr depth))
  (define prog (current-nix-program))
  (define semantic-contracts (and prog (program-semantic-contracts prog)))
  (define contract
    (and semantic-contracts (hash-ref semantic-contracts e #f)))
  (when (and contract (not (record-update-contract? contract)))
    (error 'emit-nix "with-form has invalid record-update contract: ~v" contract))
  (define record-update?
    (or (record-update-contract? contract)
        ;; Parser-only direct-record updates have no checked metadata.
        (and (not (and prog (program-type-table prog)))
             (record-valued-expr? target-expr))))
  (define updates (with-form-updates e))
  (define target-name "bgl____update__target")
  (define update-name
    (lambda (index) (format "bgl____update__value__~a" index)))
  (define update-entries
    (for/list ([u (in-list updates)] [index (in-naturals)])
      (define kw (symbol->string (with-update-field-kw u)))
      (define field (if (string-prefix? kw ":") (substring kw 1) kw))
      (format "~a = ~a;"
              (if record-update?
                  (mangle-name (string->symbol field))
                  (nix-static-attr-path field))
              (update-name index))))
  (define updated
    (format "(~a // { ~a })" target-name (string-join update-entries " ")))
  ;; Checked typed updates always carry this contract. If a caller supplies a
  ;; captured type table but drops the contract, fail closed rather than
  ;; silently skipping a declared record invariant. Parser-only/dynamic emit
  ;; paths have neither and preserve the ordinary attrset merge.
  (unless contract
    (define type-table (and prog (program-type-table prog)))
    (define inferred-type
      (and type-table
           (or (hash-ref type-table e #f)
               (hash-ref type-table (with-form-target e) #f))))
    (define record-name
      (cond
        [(type-prim? inferred-type) (type-prim-name inferred-type)]
        [(type-app? inferred-type) (type-app-ctor inferred-type)]
        [else #f]))
    (when (and record-name
               (program-record-contract-ref prog record-name #f))
      (error 'emit-nix
             "typed with-form lacks its checked record-update contract")))
  (define validator
    (and contract (record-update-contract-validator-symbol contract)))
  (define candidate-name "bgl____update__candidate")
  (define result
    (if validator
        ;; Keep one private candidate between merge and provider validation.
        ;; No user-visible selection or use occurs before the validator returns.
        (format "(~a ~a)"
                (mangle-record-validator-name validator)
                candidate-name)
        candidate-name))
  (define with-candidate
    (format "let ~a = ~a; in ~a" candidate-name updated result))
  (define with-update-values
    (for/fold ([body with-candidate])
              ([update (in-list (reverse updates))]
               [index (in-list (reverse (range (length updates))))])
      (format "let ~a = ~a; in builtins.deepSeq ~a (~a)"
              (update-name index)
              (emit-expr (with-update-value update) depth)
              (update-name index)
              body)))
  ;; Target and every update RHS are evaluated once in source order before the
  ;; candidate can be observed. This models Beagle's eager `with` event despite
  ;; Nix's recursive, lazy lets.
  (format "let ~a = ~a; in builtins.deepSeq ~a (~a)"
          target-name target target-name with-update-values))

;; --- for comprehension ----------------------------------------------------
;; (for [x xs :when (pred x) y ys] body) →
;;   concatMap (x: optionals (pred x) (concatMap (y: [body]) ys)) xs
;; Bindings nest left-to-right; :when filters the *next* binding's iteration
;; (matches Clojure semantics); :let extends scope; :while truncates.
;;
;; emit-nix supports multiple bindings + :when; :let lowers to a wrapping let;
;; :while is not expressible without imperative state — emit an explicit error.

(define (emit-for e depth)
  (define clauses (for-form-clauses e))
  (define body (for-form-body e))

  (when (null? clauses)
    (error 'emit-nix "(for [] ...) has no bindings"))
  (unless (for-binding? (car clauses))
    (error 'emit-nix "(for ...) must start with a binding clause"))

  ;; Recurse left-to-right so each collection, modifier, and constraint is
  ;; emitted inside the scope established by every preceding clause.
  (define (emit-clauses cs)
    (cond
      [(null? cs) (format "[ ~a ]" (emit-body body depth))]
      [else
       (define c (car cs))
       (cond
         [(for-binding? c)
          (define target (for-binding-name c))
          (unless (symbol? target)
            (error 'emit-nix
                   "destructuring in for bindings is not supported by the nix backend — bind each element to a name, then project it in :let"))
          (define coll (emit-expr (for-binding-expr c) depth))
          (define parameter
            (register-binder-identities!
             (param target (for-binding-type c) (for-binding-constraint c))
             (binder-identities c)))
          (define lambda-str
            (parameterize
                ([current-nix-constraint-owners
                  (hash-set (current-nix-constraint-owners) parameter c)])
              (emit-param-chain
               (list parameter) (emit-clauses (cdr cs)) depth)))
          (format "builtins.concatMap (~a) ~a"
                  lambda-str
                  (paren-wrap coll (for-binding-expr c)))]
         [(for-when? c)
          (define test-str (emit-expr (for-when-test c) depth))
          (format "(if ~a then ~a else [ ])"
                  test-str
                  (emit-clauses (cdr cs)))]
         [(for-let? c)
          (for ([b (in-list (for-let-bindings c))])
            (unless (symbol? (let-binding-name b))
              (error 'emit-nix
                     "destructuring in for :let is not supported by the nix backend — bind the aggregate to a name, then project it explicitly")))
          (emit-let-binding-chain
           (for-let-bindings c)
           (emit-clauses (cdr cs))
           depth)]
         [else
          (error 'emit-nix ":while is not expressible in Nix without imperative state — use :when with a guard instead")])]))
  (emit-clauses clauses))

;; --- loop/recur → recursive Nix function -----------------------------------

(define (emit-loop e depth)
  (define bindings (loop-form-bindings e))
  (define body (loop-form-body e))

  (unless (andmap (lambda (b) (symbol? (let-binding-name b))) bindings)
    (error 'emit-nix
           "destructuring in loop bindings is not supported by the nix backend — bind the aggregate to one loop name, then project inside the body"))

  (define body-str
    (parameterize ([current-recur-name "bgl____loop"])
      (emit-body body depth)))
  (define loop-params
    (for/list ([b (in-list bindings)])
      (register-binder-identities!
       (param (let-binding-name b)
              (let-binding-type b)
              (let-binding-constraint b))
       (binder-identities b))))
  (define loop-constraint-owners
    (for/fold ([owners (current-nix-constraint-owners)])
              ([parameter (in-list loop-params)]
               [binding (in-list bindings)])
      (hash-set owners parameter binding)))
  (define raw-loop-params
    (for/list ([p (in-list loop-params)])
      (register-binder-identities!
       (param (param-name p) (param-type p) #f)
       (binder-identities p))))
  (define loop-args
    (string-join
     (for/list ([p (in-list loop-params)])
       (mangle-name (binder-output-symbol p (param-name p))))
     " "))
  (define loop-body-fn
    (emit-param-chain raw-loop-params body-str depth))
  (define recursive-body
    (if (null? loop-params)
        "bgl____loop__body null"
        (format "bgl____loop__body ~a" loop-args)))
  (define loop-fn
    (parameterize
        ([current-nix-constraint-owners loop-constraint-owners])
      (emit-sequential-param-chain loop-params recursive-body depth)))
  ;; Initializers are let-like and therefore sequential: a later initializer
  ;; and constraint can reference every earlier loop binder.  Keep that path
  ;; separate from the recursive guard function so the initial constraints run
  ;; once, while every `(recur ...)` still enters through the guarded loop and is
  ;; checked once before the next body evaluation.
  (define initial-body
    (emit-let-binding-chain bindings recursive-body depth))

  (format "(let bgl____loop__body = ~a; bgl____loop = ~a; in ~a)"
          loop-body-fn
          loop-fn
          initial-body))

;; --- body (sequence of exprs → last one) -----------------------------------

(define (emit-body exprs depth)
  (cond
    [(null? exprs) "null"]
    [(= (length exprs) 1) (emit-expr (car exprs) depth)]
    ;; Nix let-bindings are lazy, so an unused temporary does not sequence
    ;; anything. A nested `builtins.deepSeq` chain forces each non-final form
    ;; in source order before returning the final value. Deep forcing matters
    ;; when an otherwise-unused aggregate contains a constrained call: plain
    ;; `seq` would stop at the list/attrset shell and erase the validation.
    [else
     (define last-expr (car (reverse exprs)))
     (define stmts (reverse (cdr (reverse exprs))))
     (for/fold ([result (emit-expr last-expr depth)])
               ([statement (in-list (reverse stmts))])
       (format "builtins.deepSeq (~a) (~a)"
               (emit-expr statement depth)
               result))]))

;; --- Nix-specific form helpers ----------------------------------------------

(define (emit-nix-rec-attrs pairs depth)
  (define ind (indent (+ depth 1)))
  (define entries
    (for/list ([pair (in-list pairs)])
      (define key (car pair))
      (define val (cdr pair))
      (format "~a~a = ~a;" ind (mangle-name key) (emit-expr val (+ depth 1)))))
  (string-append
   "rec {\n"
   (string-join entries "\n")
   "\n" (indent depth) "}"))

(define (qualified-reference=? ref qualifier name)
  (and (qualified-ref? ref)
       (eq? (qualified-ref-qualifier ref) qualifier)
       (eq? (qualified-ref-name ref) name)))

;; Only the outer NixOS module map owns project authoring metadata. Preserve a
;; nested key with the same spelling: it is ordinary user configuration.
(define (omit-module-attrs expr attrs)
  (cond
    [(map-form? expr)
     (struct-copy
      map-form expr
      [pairs
       (filter (lambda (pair) (not (memq (car pair) attrs)))
               (map-form-pairs expr))])]
    [(let-form? expr)
     (define body (let-form-body expr))
     (if (null? body)
         expr
         (struct-copy
          let-form expr
          [body (append (drop-right body 1)
                        (list (omit-module-attrs (last body) attrs)))]))]
    [(and (call-form? expr)
          (or (qualified-reference=? (call-form-fn expr) 'lib 'mkIf)
              (eq? (call-form-fn expr) 'lib.mkIf))
          (pair? (call-form-args expr)))
     (define args (call-form-args expr))
     (struct-copy
      call-form expr
      [args (append (drop-right args 1)
                    (list (omit-module-attrs (last args) attrs)))])]
    [else expr]))

(define (emit-nix-fn-set e depth)
  (define formals (nix-fn-set-formals e))
  (define rest? (nix-fn-set-rest? e))
  (define at-name (nix-fn-set-at-name e))
  (define body (nix-fn-set-body e))
  (define formal-strs
    (for/list ([f (in-list formals)])
      (define name (symbol->string (nix-fn-set-formal-name f)))
      (define default (nix-fn-set-formal-default f))
      (if default
        (format "~a ? ~a" name (emit-expr default depth))
        name)))
  (define all-formals
    (if rest?
      (append formal-strs (list "..."))
      formal-strs))
  (define set-str (string-join all-formals ", "))
  (define pattern
    (if at-name
      (format "{ ~a } @ ~a" set-str (mangle-name at-name))
      (format "{ ~a }" set-str)))
  (define attrs
    (if (and (= depth 0) rest?)
        (current-nix-module-omit-attrs)
        '()))
  (define body-str
    (emit-expr (if (null? attrs) body (omit-module-attrs body attrs)) depth))
  (cond
    [(= depth 0)
     (format "~a:\n\n~a" pattern body-str)]
    [else
     ;; Wrap in parens when emitted inside another expression: Nix's lambda
     ;; `{a}: body` has very low precedence and breaks list/attrset parsing.
     (format "(~a: ~a)" pattern body-str)]))

;; --- registration ----------------------------------------------------------

(define nix-backend
  (emitter-backend 'nix nix-emit-program))

(register-backend! 'nix nix-backend)

(provide current-nix-module-omit-attrs)
