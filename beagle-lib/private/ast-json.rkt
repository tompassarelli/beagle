#lang racket/base

;; AST → JSON serialization.
;;
;; Converts beagle AST structs to JSON-serializable hasheqs.
;; Used by the self-hosted emitter pipeline:
;;   Racket (parse + check) → JSON AST → beagle-written emitter (JS)

(require racket/match
         racket/list
         racket/set
         racket/string
         racket/format
         json
         openssl/sha1
         "ast.rkt"
         "module-interface.rkt"
         "types.rkt"
         "macros.rkt"
         (only-in "parse.rkt" program-source-bytes)
         (only-in "semantic-index.rkt" write-canonical-json)
         "js-emit-utils.rkt")

(define current-json-src-table (make-parameter #f))
(define current-json-type-table (make-parameter #f))
(define current-json-macro-table (make-parameter #f))
(define current-json-macro-context (make-parameter #f))
(define current-json-inherited-source (make-parameter #f))
(define current-json-source-id (make-parameter #f))
(define current-checked-projection? (make-parameter #f))
(define current-json-effective-definition-types (make-parameter #f))
(define current-json-semantic-contracts (make-parameter #f))

(define CHECKED-PROGRAM-SCHEMA-VERSION 4)

(define (require-entry->json r)
  (define identity (require-entry-identity r))
  (hasheq
   'ns (symbol->string (require-entry-ns r))
   'identity
   (hasheq 'kind (symbol->string (module-identity-kind identity))
           'value (let ([value (module-identity-value identity)])
                    (if (symbol? value) (symbol->string value) value)))
   'alias (and (require-entry-alias r)
               (symbol->string (require-entry-alias r)))
   'refer (and (require-entry-refer r)
               (map symbol->string (require-entry-refer r)))
   'rename
   (for/hasheq ([source (in-list (hash-keys (require-entry-rename r)))])
     (values (symbol->string source)
             (symbol->string (hash-ref (require-entry-rename r) source))))))

(define (float->json-value value)
  (cond
    [(eqv? value -0.0) "-0.0"]
    [(eqv? value +nan.0) "NaN"]
    [(eqv? value +inf.0) "Infinity"]
    [(eqv? value -inf.0) "-Infinity"]
    [else value]))

(define (sha256-prefixed bytes)
  (string-append "sha256:"
                 (bytes->hex-string (sha256-bytes bytes))))

(define (canonical-json-bytes value)
  (define out (open-output-bytes))
  (write-canonical-json value out)
  (get-output-bytes out))

(define (node-source->json node)
  (define tbl (current-json-src-table))
  (define loc (and tbl (hash-ref tbl node #f)))
  (and loc
       (hash-set
        (hasheq 'line (src-loc-line loc)
                'col (src-loc-col loc)
                'origin (symbol->string (src-loc-origin loc))
                'canonical (and (src-loc-canonical loc) #t)
                'pos (or (src-loc-pos loc) #f)
                'span (or (src-loc-span loc) #f))
        (if (current-checked-projection?) 'sourceId 'source)
        (or (current-json-source-id) (~a (src-loc-source loc))))))

(define (type->json t)
  (cond
    [(not t) 'null]
    [(type-meta? t)
     (error
      'beagle-ast-json
      "unresolved inference metavariable cannot appear in checked AST JSON")]
    [(type-prim? t) (hasheq 'kind "prim" 'name (symbol->string (type-prim-name t)))]
    [(type-app? t) (hasheq 'kind "app"
                           'name (symbol->string (type-app-ctor t))
                           'args (map type->json (type-app-args t)))]
    [(type-fn? t) (hasheq 'kind "fn"
                          'params (map type->json (type-fn-params t))
                          'rest (type->json (type-fn-rest-type t))
                          'ret (type->json (type-fn-ret t)))]
    [(type-union? t) (hasheq 'kind "union"
                             'members (map type->json (type-union-alts t)))]
    [(type-var? t) (hasheq 'kind "var" 'name (symbol->string (type-var-name t)))]
    [(type-poly? t)
     (define bounds (type-poly-bounds t))
     (hasheq 'kind "poly"
             'vars (map symbol->string (type-poly-vars t))
             'body (type->json (type-poly-body t))
             'bounds
             (if bounds
                 (for/list ([var (in-list (type-poly-vars t))]
                            #:when (hash-has-key? bounds var))
                   (hasheq 'var (symbol->string var)
                           'type (type->json (hash-ref bounds var))))
                 '()))]
    [else (error 'beagle-ast-json "unsupported checked type: ~v" t)]))

(define (effective-definition-type->json name)
  (define effective (current-json-effective-definition-types))
  (unless (hash? effective)
    (error
     'beagle-ast-json
     "checked-program projection requires finalized effective definition signatures"))
  (type->json
   (hash-ref
    effective
    name
    (lambda ()
      (error
       'beagle-ast-json
       "checked-program projection is missing the effective signature for ~a"
       name)))))

(define (destructure-defaults->json defaults)
  (for/list ([entry (in-list defaults)])
    (hasheq 'key (symbol->string (car entry))
            'value (expr->json (cdr entry)))))

(define (binding-contract->json owner constraint wire)
  (if (not (current-checked-projection?))
      wire
      (let ([contract
             (and (current-json-semantic-contracts)
                  (hash-ref (current-json-semantic-contracts) owner #f))])
        (when (and constraint
                   (not (and (binding-constraint-contract? contract)
                             (binding-constraint-contract-synchronous?
                              contract))))
          (error
           'beagle-ast-json
           "checked binding constraint lacks a positive synchronization contract: ~v"
           constraint))
        (hash-set wire 'constraintSynchronous (and constraint #t)))))

(define (param->json p)
  (cond
    [(param? p)
     (binder-identities->json
      p
      (param-name p)
      (binding-contract->json
       p
       (param-constraint p)
       (hasheq 'type "param"
               'name (binding-target->json (param-name p))
               'ann (type->json (param-type p))
               'constraint (constraint->json (param-constraint p)))))]
    [(map-destructure? p)
     (hasheq 'type "map-destructure"
             'keys (map symbol->string (map-destructure-keys p))
             'as (and (map-destructure-as-name p)
                      (symbol->string (map-destructure-as-name p)))
             'or (destructure-defaults->json
                  (map-destructure-or-defaults p)))]
    [(seq-destructure? p)
     (hasheq 'type "seq-destructure"
             'names (map binding-target->json (seq-destructure-names p))
             'rest (and (seq-destructure-rest-name p)
                        (symbol->string (seq-destructure-rest-name p))))]
    [else (error 'beagle-ast-json "unsupported parameter: ~v" p)]))

;; Serialize a let-binding target.  Simple bindings carry a symbol; destructure
;; positions carry a map-destructure or seq-destructure struct — dispatch rather
;; than blindly calling symbol->string.  seq-destructure names may themselves
;; contain nested destructure structs (Clojure nested binding), so we recurse.
(define (binding-target->json target)
  (cond
    [(symbol? target)
     (symbol->string target)]
    [(map-destructure? target)
     (hasheq 'type "map-destructure"
             'keys (map symbol->string (map-destructure-keys target))
             'as (and (map-destructure-as-name target)
                      (symbol->string (map-destructure-as-name target)))
             'or (destructure-defaults->json
                  (map-destructure-or-defaults target)))]
    [(seq-destructure? target)
     (hasheq 'type "seq-destructure"
             'names (map binding-target->json (seq-destructure-names target))
             'rest (and (seq-destructure-rest-name target)
                        (symbol->string (seq-destructure-rest-name target))))]
    [else (error 'beagle-ast-json "unsupported binding target: ~v" target)]))

(define (binding->json b)
  (binder-identities->json
   b
   (let-binding-name b)
   (binding-contract->json
    b
    (let-binding-constraint b)
    (hasheq 'name (binding-target->json (let-binding-name b))
            'ann (type->json (let-binding-type b))
            'constraint (constraint->json (let-binding-constraint b))
            'value (expr->json (let-binding-value b))))))

(define (field->json field)
  (binding-contract->json
   field
   (param-constraint field)
   (hasheq 'name (symbol->string (param-name field))
           'ann (type->json (param-type field))
           'constraint (constraint->json (param-constraint field)))))

(define (for-binding->json binding)
  (binder-identities->json
   binding
   (for-binding-name binding)
   (binding-contract->json
    binding
    (for-binding-constraint binding)
    (hasheq 'type "binding"
            'name (binding-target->json (for-binding-name binding))
            'ann (type->json (for-binding-type binding))
            'constraint (constraint->json (for-binding-constraint binding))
            'expr (expr->json (for-binding-expr binding))))))

(define (constraint->json constraint)
  (if constraint (expr->json constraint) 'null))

(define (sym->js s)
  (if s (symbol->string s) 'null))

(define (binding-id->json id)
  (binding-id-stable id))

(define (binder-identities->json owner target wire)
  (define identities (binder-identities owner))
  (cond
    [(zero? (hash-count identities)) wire]
    [(and (symbol? target) (hash-ref identities target #f))
     => (lambda (id) (hash-set wire 'bindingId (binding-id->json id)))]
    [else
     (hash-set
      wire
      'bindingIds
      (for/hasheq ([(name id) (in-hash identities)])
        (values name (binding-id->json id))))]))

(define (reference-fields ref)
  (cond
    [(resolved-ref? ref)
     (define name (resolved-ref-name ref))
     (define base
       (hasheq 'name (symbol->string (structural-name-leaf name))
               'providerId (sym->js (structural-name-provider-id name))
               'refersTo (binding-id->json (resolved-ref-binding-id ref))))
     (if (structural-name-qualifier name)
         (hash-set
          base 'qualifier (symbol->string (structural-name-qualifier name)))
         base)]
    [(qualified-ref? ref)
     (hasheq 'qualifier (symbol->string (qualified-ref-qualifier ref))
             'name (symbol->string (qualified-ref-name ref))
             'providerId (sym->js (qualified-ref-provider-id ref)))]
    [(symbol? ref) (hasheq 'name (symbol->string ref))]
    [else (raise-argument-error 'reference-fields
                                "(or/c resolved-ref? qualified-ref? symbol?)"
                                ref)]))

(define (datum->json d)
  (cond
    [(string? d) d]
    [(number? d) d]
    [(boolean? d) d]
    [(char? d)   (hasheq 'type "char" 'value (char->integer d))]
    [(symbol? d) (hasheq 'type "symbol" 'value (symbol->string d))]
    [(keyword? d) (hasheq 'type "keyword" 'value (keyword->string d))]
    [(list? d) (map datum->json d)]
    [(pair? d) (list (datum->json (car d)) (datum->json (cdr d)))]
    [(void? d) 'null]
    [else (error 'beagle-ast-json "unsupported quoted datum: ~v" d)]))


(define (expansion-context->json ctx)
  (hasheq
   'chain
   (let loop ([current ctx] [chain '()])
     (if current
         (loop (expansion-ctx-parent current)
               (cons (hasheq 'name
                             (symbol->string
                              (expansion-ctx-macro-name current))
                             'depth (expansion-ctx-depth current))
                     chain))
         chain))))

(define (synthetic-source source)
  (and source
       (hash-set* source 'origin "synthetic" 'canonical #t)))

;; Every checked-program AST node flows through one decorator. This keeps
;; source, inferred type, and macro provenance available at declaration and
;; nested-expression depth without duplicating metadata logic in each variant.
(define (expr->json e)
  (define macro-table (current-json-macro-table))
  (define direct-context
    (and macro-table (hash-ref macro-table e #f)))
  (define context (or direct-context (current-json-macro-context)))
  (define direct-source (node-source->json e))
  (define source
    (cond
      [context
       (synthetic-source
        (or direct-source (current-json-inherited-source)))]
      [else direct-source]))
  (define inferred-table (current-json-type-table))
  (define inferred
    (and inferred-table (hash-ref inferred-table e #f)))
  (parameterize ([current-json-macro-context context]
                 [current-json-inherited-source
                  (if context source #f)])
    (define wire (expr->json/raw e))
    (cond
      [(not (current-checked-projection?)) wire]
      [else
       (define with-type
         (if inferred
             (hash-set wire 'inferredType (type->json inferred))
             wire))
       (define provenance
         (cond
           [(and source context)
            (hasheq 'source source
                    'macroExpansion (expansion-context->json context))]
           [source (hasheq 'source source)]
           [context
            (hasheq 'macroExpansion (expansion-context->json context))]
           [else #f]))
       (if provenance
           (hash-set with-type 'provenance provenance)
           with-type)])))

(define (expr->json/raw e)
  (cond
    [(or (qualified-ref? e) (resolved-ref? e))
     (hash-set (reference-fields e) 'node "ref")]
    [(string? e)  (hasheq 'node "literal" 'kind "string" 'value e)]
    ;; value is the integer code point: JSON has no char type, and the
    ;; selfhost consumer re-emits canonically from the value (emit-clj-char
    ;; rules), never from surface text.
    [(char? e)    (hasheq 'node "literal" 'kind "char" 'value (char->integer e))]
    [(and (number? e) (inexact? e))
     (hasheq 'node "literal" 'kind "float" 'value (float->json-value e))]
    [(number? e)  (hasheq 'node "literal" 'kind "number" 'value e)]
    [(boolean? e) (hasheq 'node "literal" 'kind "bool" 'value e)]
    [(symbol? e)
     (define s (symbol->string e))
     (cond
       [(string=? s "nil") (hasheq 'node "literal" 'kind "nil")]
       [(keyword-sym? e)   (hasheq 'node "literal" 'kind "keyword" 'value (substring s 1))]
       [else               (hasheq 'node "ref" 'name s)])]
    [(eq? e (void)) (hasheq 'node "literal" 'kind "nil")]

    [(def-form? e)
     (define wire
       (hasheq 'node "def"
               'name (symbol->string (def-form-name e))
               'ann (type->json (def-form-type e))
               'value (expr->json (def-form-value e))
               ;; emit-relevant flags: emit-clj renders "doc" and ^:dynamic;
               ;; check consults dynamic? for the `binding` target registry
               'doc (or (def-form-doc e) #f)
               'dynamic (and (def-form-dynamic? e) #t)))
     (if (current-checked-projection?)
         (hash-set
          wire
          'effectiveType
          (effective-definition-type->json (def-form-name e)))
         wire)]

    [(defn-form? e)
     (define wire
       (hasheq 'node "defn"
               'name (symbol->string (defn-form-name e))
               'params (map param->json (defn-form-params e))
               'rest (and (defn-form-rest-param e) (param->json (defn-form-rest-param e)))
               'ret (type->json (defn-form-return-type e))
               'body (map expr->json (defn-form-body e))
               'private (defn-form-private? e)
               'raises (type->json (defn-form-raises e))
               'doc (or (defn-form-doc e) #f)))
     (if (current-checked-projection?)
         (hash-set
          wire
          'effectiveType
          (effective-definition-type->json (defn-form-name e)))
         wire)]

    [(defn-multi? e)
     (define wire
       (hasheq 'node "defn-multi"
               'name (symbol->string (defn-multi-name e))
               'arities (map (lambda (a)
                               (hasheq 'params (map param->json (arity-clause-params a))
                                       'rest (and (arity-clause-rest-param a)
                                                  (param->json (arity-clause-rest-param a)))
                                       'ret (type->json (arity-clause-return-type a))
                                       'body (map expr->json (arity-clause-body a))))
                             (defn-multi-arities e))
               'private (defn-multi-private? e)
               'doc (or (defn-multi-doc e) #f)))
     (if (current-checked-projection?)
         (hash-set
          wire
          'effectiveType
          (effective-definition-type->json (defn-multi-name e)))
         wire)]

    [(fn-form? e)
     (hasheq 'node "fn"
             'params (map param->json (fn-form-params e))
             'rest (and (fn-form-rest-param e) (param->json (fn-form-rest-param e)))
             'ret (type->json (fn-form-return-type e))
             'body (map expr->json (fn-form-body e)))]

    [(let-form? e)
     (hasheq 'node "let"
             'bindings (map binding->json (let-form-bindings e))
             'body (map expr->json (let-form-body e)))]

    [(if-form? e)
     (hasheq 'node "if"
             'cond (expr->json (if-form-cond-expr e))
             'then (expr->json (if-form-then-expr e))
             'else (and (if-form-else-expr e)
                        (expr->json (if-form-else-expr e))))]

    [(when-form? e)
     (hasheq 'node "when"
             'cond (expr->json (when-form-cond-expr e))
             'body (map expr->json (when-form-body e)))]

    [(do-form? e)
     (hasheq 'node "do" 'body (map expr->json (do-form-body e)))]

    [(cond-form? e)
     (hasheq 'node "cond"
             'clauses (map (lambda (c)
                             (hasheq 'test (expr->json (cond-clause-test c))
                                     'body (map expr->json (cond-clause-body c))))
                           (cond-form-clauses e)))]

    [(call-form? e)
     (hasheq 'node "call"
             'fn (expr->json (call-form-fn e))
             'args (map expr->json (call-form-args e)))]

    [(clj-var-ref? e)
     (hash-set
      (reference-fields (clj-var-ref-reference e))
      'node "clj-var-ref")]

    [(vec-form? e)
     (hasheq 'node "vec" 'items (map expr->json (vec-form-items e)))]

    [(map-form? e)
     (hasheq 'node "map"
             'pairs (map (lambda (p)
                           (hasheq 'key (expr->json (car p))
                                   'val (expr->json (cdr p))))
                         (map-form-pairs e)))]

    [(set-form? e)
     (hasheq 'node "set" 'items (map expr->json (set-form-items e)))]

    [(record-form? e)
     (hasheq 'node "record"
             'name (symbol->string (record-form-name e))
             'fields (map field->json (record-form-fields e)))]

    [(quoted? e)
     (hasheq 'node "quoted" 'datum (datum->json (quoted-datum e)))]

    [(loop-form? e)
     (hasheq 'node "loop"
             'bindings (map binding->json (loop-form-bindings e))
             'body (map expr->json (loop-form-body e)))]

    [(recur-form? e)
     (hasheq 'node "recur" 'args (map expr->json (recur-form-args e)))]

    [(method-call? e)
     (hasheq 'node "method-call"
             'method (symbol->string (method-call-method-name e))
             'target (expr->json (method-call-target e))
             'args (map expr->json (method-call-args e)))]

    [(static-call? e)
     (hash-set*
      (reference-fields (static-call-class+method e))
      'node "static-call"
      'args (map expr->json (static-call-args e)))]

    [(kw-access? e)
     (define wire
       (hasheq 'node "kw-access"
               'kw (symbol->string (kw-access-kw e))
               'target (expr->json (kw-access-target e))
               'default
               (and (kw-access-default e)
                    (expr->json (kw-access-default e)))))
     (if (not (current-checked-projection?))
         wire
         (let ([contract
                (and (current-json-semantic-contracts)
                     (hash-ref (current-json-semantic-contracts) e #f))])
           (when (and contract (not (record-field-access-contract? contract)))
             (error
              'beagle-ast-json
              "kw-access node has invalid checked record-field contract: ~v"
              contract))
           (hash-set
            wire
            'recordFieldAccess
            (if contract
                (hasheq
                 'recordName
                 (symbol->string
                  (record-field-access-contract-record-name contract)))
                'null))))]

    [(try-form? e)
     (hasheq 'node "try"
             'body (map expr->json (try-form-body e))
             'catches (map (lambda (c)
                             (binder-identities->json
                              c
                              (catch-clause-name c)
                              (hasheq 'type (sym->js (catch-clause-exception-type c))
                                      'name (sym->js (catch-clause-name c))
                                      'body (map expr->json (catch-clause-body c)))))
                           (try-form-catches e))
             'finally (and (try-form-finally-body e)
                           (map expr->json (try-form-finally-body e))))]

    [(case-form? e)
     (hasheq 'node "case"
             'test (expr->json (case-form-test e))
             'clauses (map (lambda (c)
                             (hasheq 'value (datum->json (case-clause-value c))
                                     'body (expr->json (case-clause-body c))))
                           (case-form-clauses e))
             'default (and (case-form-default e) (expr->json (case-form-default e))))]

    [(match-form? e)
     (hasheq 'node "match"
             'target (expr->json (match-form-target e))
             'clauses (map (lambda (c)
                             (hasheq 'pattern (pattern->json (match-clause-pattern c))
                                     'body (map expr->json (match-clause-body c))))
                           (match-form-clauses e)))]

    [(for-form? e)
     (hasheq 'node "for"
             'clauses (map (lambda (c)
                             (cond
                               [(for-binding? c)
                                (for-binding->json c)]
                               [(for-when? c)
                                (hasheq 'type "when" 'test (expr->json (for-when-test c)))]
                               [(for-let? c)
                                (hasheq 'type "let" 'bindings (map binding->json (for-let-bindings c)))]
                               [else
                                (error 'beagle-ast-json
                                       "unsupported for clause: ~v" c)]))
                           (for-form-clauses e))
             'body (map expr->json (for-form-body e)))]

    [(with-form? e)
     (define semantic-contracts (current-json-semantic-contracts))
     (define contract
       (and semantic-contracts (hash-ref semantic-contracts e #f)))
     (when (and contract (not (record-update-contract? contract)))
       (error 'beagle-ast-json
              "with node has invalid checked record-update contract: ~v"
              contract))
     (define wire
       (hasheq 'node "with"
               'target (expr->json (with-form-target e))
               'updates
               (map (lambda (u)
                      (hasheq
                       'field (symbol->string (with-update-field-kw u))
                       'value (expr->json (with-update-value u))))
                    (with-form-updates e))))
     (if (not (current-checked-projection?))
         wire
         (hash-set
          wire
          'recordUpdate
          (if contract
              (hasheq
               'recordName
               (symbol->string (record-update-contract-record-name contract))
               'fieldOrder
               (map symbol->string
                    (record-update-contract-field-order contract))
               'validator
               (if (record-update-contract-validator-symbol contract)
                   (symbol->string
                    (record-update-contract-validator-symbol contract))
                   'null))
              'null)))]

    [(defenum-form? e)
     (hasheq 'node "defenum"
             'name (symbol->string (defenum-form-name e))
             'values (map symbol->string (defenum-form-values e)))]

    [(defunion-form? e)
     (define mf (defunion-form-member-fields e))
     (define tp (defunion-form-type-params e))
     (define base
       (hasheq 'node "defunion"
               'name (symbol->string (defunion-form-name e))
               'members (map symbol->string (defunion-form-members e))
               'type-params (if tp (map symbol->string tp) 'null)))
     (if mf
         (hash-set base 'member-fields
                   (for/hasheq ([(k v) (in-hash mf)])
                     (values k (map field->json v))))
         base)]

    [(deferror-form? e)
     (define mf (deferror-form-member-fields e))
     (define base
       (hasheq 'node "deferror"
               'name (symbol->string (deferror-form-name e))
               'members (map symbol->string (deferror-form-members e))))
     (if mf
         (hash-set base 'member-fields
                   (for/hasheq ([(k v) (in-hash mf)])
                     (values k (map field->json v))))
         base)]

    [(defscalar-form? e)
     (hasheq 'node "defscalar"
             'name (symbol->string (defscalar-form-name e))
             'backing
             (type->json
              (let ([backing (defscalar-form-backing-type e)])
                (if (symbol? backing) (type-prim backing) backing)))
             'predicates
             (for/list ([pred (in-list (defscalar-form-predicates e))])
               (hasheq 'op (symbol->string (scalar-predicate-op pred))
                       'value (scalar-predicate-value pred))))]

    [(regex-lit? e)
     (hasheq 'node "regex" 'pattern (regex-lit-pattern e))]

    [(await-form? e)
     (hasheq 'node "await" 'expr (expr->json (await-form-expr e)))]

    [(set!-form? e)
     (hasheq 'node "set!"
             'target (expr->json (set!-form-target e))
             'value (expr->json (set!-form-value e)))]

    [(letfn-form? e)
     (hasheq 'node "letfn"
             'fns (map (lambda (f)
                         (binder-identities->json
                          f
                          (letfn-fn-name f)
                          (hasheq 'name (symbol->string (letfn-fn-name f))
                                  'params (map param->json (letfn-fn-params f))
                                  'rest (and (letfn-fn-rest-param f) (param->json (letfn-fn-rest-param f)))
                                  'ret (type->json (letfn-fn-return-type f))
                                  'body (map expr->json (letfn-fn-body f)))))
                       (letfn-form-fns e))
             'body (map expr->json (letfn-form-body e)))]

    [(binding-form? e)
     (hasheq 'node "binding"
             'bindings (map binding->json (binding-form-bindings e))
             'body (map expr->json (binding-form-body e)))]

    [(with-open-form? e)
     (hasheq 'node "with-open"
             'bindings (map binding->json (with-open-form-bindings e))
             'body (map expr->json (with-open-form-body e)))]

    [(doto-form? e)
     (hasheq 'node "doto"
             'target (expr->json (doto-form-target e))
             'forms (map expr->json (doto-form-forms e)))]

    [(when-let-form? e)
     (hasheq 'node "when-let"
             'name (symbol->string (when-let-form-name e))
             'expr (expr->json (when-let-form-expr e))
             'body (map expr->json (when-let-form-body e)))]

    [(if-let-form? e)
     (hasheq 'node "if-let"
             'name (symbol->string (if-let-form-name e))
             'expr (expr->json (if-let-form-expr e))
             'then (expr->json (if-let-form-then-body e))
             'else (and (if-let-form-else-body e) (expr->json (if-let-form-else-body e))))]

    [(when-some-form? e)
     (hasheq 'node "when-some"
             'name (symbol->string (when-some-form-name e))
             'expr (expr->json (when-some-form-expr e))
             'body (map expr->json (when-some-form-body e)))]

    [(if-some-form? e)
     (hasheq 'node "if-some"
             'name (symbol->string (if-some-form-name e))
             'expr (expr->json (if-some-form-expr e))
             'then (expr->json (if-some-form-then-body e))
             'else (expr->json (if-some-form-else-body e)))]

    [(condp-form? e)
     (hasheq 'node "condp"
             'pred (expr->json (condp-form-pred-fn e))
             'test (expr->json (condp-form-test-expr e))
             'clauses (map (lambda (c)
                             (hasheq 'test (expr->json (car c))
                                     'body (expr->json (cdr c))))
                           (condp-form-clauses e))
             'default (and (condp-form-default e) (expr->json (condp-form-default e))))]

    [(doseq-form? e)
     (hasheq 'node "doseq"
             'clauses (map (lambda (c)
                             (cond
                               [(for-binding? c)
                                (for-binding->json c)]
                               [(for-when? c)
                                (hasheq 'type "when" 'test (expr->json (for-when-test c)))]
                               [(for-let? c)
                                (hasheq 'type "let" 'bindings (map binding->json (for-let-bindings c)))]
                               [else
                                (error 'beagle-ast-json
                                       "unsupported doseq clause: ~v" c)]))
                           (doseq-form-clauses e))
             'body (map expr->json (doseq-form-body e)))]

    [(dotimes-form? e)
     (hasheq 'node "dotimes"
             'name (symbol->string (dotimes-form-name e))
             'count (expr->json (dotimes-form-count-expr e))
             'body (map expr->json (dotimes-form-body e)))]

    [(new-form? e)
     (hasheq 'node "new"
             'class (symbol->string (new-form-class-name e))
             'args (map expr->json (new-form-args e)))]

    [(dynamic-var? e)
     (hasheq 'node "dynamic-var" 'name (symbol->string (dynamic-var-name e)))]

    ;; Checker-only: Native lowering receives the checked inner expression.
    [(ascription? e) (expr->json (ascription-expr e))]

    [(check-expr? e)
     (hasheq 'node "check" 'expr (expr->json (check-expr-expr e)))]

    [(rescue-form? e)
     (hasheq 'node "rescue"
             'expr (expr->json (rescue-form-expr e))
             'fallback (expr->json (rescue-form-fallback e))
             'err (and (rescue-form-err-name e) (symbol->string (rescue-form-err-name e))))]

    ;; cases live in a hasheq (unordered) — serialize sorted by target name
    ;; so the JSON is deterministic and the selfhost AST can match it.
    [(target-case-form? e)
     (define cases (target-case-form-cases e))
     (hasheq 'node "target-case"
             'cases (for/list ([k (in-list (sort (hash-keys cases) symbol<?))])
                      (hasheq 'target (symbol->string k)
                              'body (expr->json (hash-ref cases k)))))]

    [(defonce-form? e)
     (define wire
       (hasheq 'node "defonce"
               'name (symbol->string (defonce-form-name e))
               'ann (type->json (defonce-form-type e))
               'value (expr->json (defonce-form-value e))
               'doc (or (defonce-form-doc e) #f)))
     (if (current-checked-projection?)
         (hash-set
          wire
          'effectiveType
          (effective-definition-type->json (defonce-form-name e)))
         wire)]

    [(block-string? e)
     (hasheq 'node "block-string"
             'text (block-string-text e)
             'tag (and (block-string-tag e) (symbol->string (block-string-tag e))))]

    [(with-meta? e)
     ;; Keep the underlying node discriminator for existing emitters while
     ;; retaining the metadata that the checked projection promises.
     (hash-set (expr->json (with-meta-expr e))
               'metadata (expr->json (with-meta-metadata e)))]

    [(async-callable? e)
     ;; Preserve the callable node for AST-JSON consumers while projecting its
     ;; authored asynchronous ownership onto the callable itself.
     (hash-set (expr->json (async-callable-form e)) 'async #t)]

    ;; threading-marker: KIND + surface ARGS drive the clj emitter's
    ;; surface reconstruction; DESUGARED is what check (and emit-nix) walk.
    ;; Serialized in full so an AST-JSON consumer can do either. args and
    ;; desugared share AST nodes in-memory; the JSON duplicates them.
    [(threading-marker? e)
     (hasheq 'node "threading"
             'kind (symbol->string (threading-marker-kind e))
             'args (map expr->json (threading-marker-orig-args e))
             'desugared (expr->json (threading-marker-desugared e)))]

    ;; --- typed JavaScript forms ---
    [(jst-selector? e)
     (hasheq 'node "js-selector" 'name (jst-selector-name e))]
    [(jst-get? e)
     (hasheq 'node "js-get"
             'receiver (expr->json (jst-get-receiver e))
             'key (expr->json (jst-get-key e)))]
    [(jst-call? e)
     (hasheq 'node "js-call"
             'receiver (expr->json (jst-call-receiver e))
             'key (expr->json (jst-call-key e))
             'args (map expr->json (jst-call-args e)))]
    [(jst-set? e)
     (hasheq 'node "js-set"
             'receiver (expr->json (jst-set-receiver e))
             'key (expr->json (jst-set-key e))
             'value (expr->json (jst-set-value e)))]
    [(jst-new? e)
     (hasheq 'node "js-new"
             'callee (expr->json (jst-new-callee e))
             'args (map expr->json (jst-new-args e)))]
    [(jst-delete? e)
     (hasheq 'node "js-delete"
             'receiver (expr->json (jst-delete-receiver e))
             'key (expr->json (jst-delete-key e)))]
    [(jst-in? e)
     (hasheq 'node "js-in"
             'receiver (expr->json (jst-in-receiver e))
             'key (expr->json (jst-in-key e)))]
    [(jst-typeof? e)
     (hasheq 'node "js-typeof" 'expr (expr->json (jst-typeof-expr e)))]
    [(jst-export? e)
     (hasheq 'node "js-export" 'form (expr->json (jst-export-form e)))]
    [(jst-export-default? e)
     (hasheq 'node "js-export-default"
             'form (expr->json (jst-export-default-form e)))]
    [(jst-import-meta? e)
     (hasheq 'node "js-import-meta")]

    ;; --- Nix-specific forms ---
    [(nix-inherit? e)
     (hasheq 'node "nix-inherit"
             'names (map symbol->string (nix-inherit-names e)))]

    [(nix-inherit-from? e)
     (hasheq 'node "nix-inherit-from"
             'ns-expr (expr->json (nix-inherit-from-ns-expr e))
             'names (map symbol->string (nix-inherit-from-names e)))]

    [(nix-with? e)
     (hasheq 'node "nix-with"
             'ns-expr (expr->json (nix-with-ns-expr e))
             'body (expr->json (nix-with-body e)))]

    [(nix-rec-attrs? e)
     (hasheq 'node "nix-rec-attrs"
             'pairs (map (lambda (p)
                           (hasheq 'key (symbol->string (car p))
                                   'val (expr->json (cdr p))))
                         (nix-rec-attrs-pairs e)))]

    [(nix-assert? e)
     (hasheq 'node "nix-assert"
             'cond (expr->json (nix-assert-cond-expr e))
             'body (expr->json (nix-assert-body e)))]

    [(nix-get-or? e)
     (hasheq 'node "nix-get-or"
             'base (expr->json (nix-get-or-base-expr e))
             'path (symbol->string (nix-get-or-path e))
             'default (expr->json (nix-get-or-default e)))]

    [(nix-has-attr? e)
     (hasheq 'node "nix-has-attr"
             'base (expr->json (nix-has-attr-base-expr e))
             'path (symbol->string (nix-has-attr-path e)))]

    [(nix-search-path? e)
     (hasheq 'node "nix-search-path"
             'name (symbol->string (nix-search-path-name e)))]

    [(nix-interpolated-string? e)
     (hasheq 'node "nix-interpolated-string"
             'parts (map (lambda (part)
                           (if (string? part)
                               (hasheq 'type "text" 'value part)
                               (hasheq 'type "expr" 'value (expr->json part))))
                         (nix-interpolated-string-parts e)))]

    [(nix-multiline-string? e)
     (hasheq 'node "nix-multiline-string"
             'lines (map (lambda (line)
                           (cond
                             [(string? line) (hasheq 'type "text" 'value line)]
                             [(nix-interpolated-string? line)
                              (hasheq 'type "interp"
                                      'parts (map (lambda (part)
                                                    (if (string? part)
                                                        (hasheq 'type "text" 'value part)
                                                        (hasheq 'type "expr" 'value (expr->json part))))
                                                  (nix-interpolated-string-parts line)))]
                             [else (hasheq 'type "expr" 'value (expr->json line))]))
                         (nix-multiline-string-lines e)))]

    [(nix-path? e)
     (hasheq 'node "nix-path" 'path (nix-path-path-string e))]

    [(nix-fn-set? e)
     (hasheq 'node "nix-fn-set"
             'formals (map (lambda (f)
                             (hasheq 'name (symbol->string (nix-fn-set-formal-name f))
                                     'default (and (nix-fn-set-formal-default f)
                                                   (expr->json (nix-fn-set-formal-default f)))))
                           (nix-fn-set-formals e))
             'rest (nix-fn-set-rest? e)
             'at-name (and (nix-fn-set-at-name e) (symbol->string (nix-fn-set-at-name e)))
             'body (expr->json (nix-fn-set-body e)))]

    ;; driftlab D1: nix-pipe / nix-impl AST structs removed upstream
    ;; (pipe family hard-removed) — serializer cases amputated.

    ;; nix sugar forms whose validation/rewrite happens in emit-nix. Serialized
    ;; so the selfhost chain (parse->emit-nix) can round-trip them. `attrs` is a
    ;; map-form expr; the emitter validates its shape (derivation/flake key sets).
    [(nix-derivation? e)
     (hasheq 'node "nix-derivation" 'attrs (expr->json (nix-derivation-attrs e)))]

    [(nix-flake? e)
     (hasheq 'node "nix-flake" 'attrs (expr->json (nix-flake-attrs e)))]

    [(nix-with-cfg? e)
     (hasheq 'node "nix-with-cfg"
             'path (expr->json (nix-with-cfg-path e))
             'body (expr->json (nix-with-cfg-body e)))]

    [(flake-input-form? e)
     (hasheq 'node "flake-input"
             'input-name (symbol->string (flake-input-form-input-name e))
             'namespace (symbol->string (flake-input-form-namespace e))
             'path-segments (map symbol->string (flake-input-form-path-segments e)))]

    [(protocol-form? e)
     (hasheq 'node "defprotocol"
             'name (symbol->string (protocol-form-name e))
             'methods
             (for/list ([method (in-list (protocol-form-methods e))])
               (hasheq 'name (symbol->string (protocol-method-name method))
                       'params (map param->json (protocol-method-params method))
                       'rest (if (protocol-method-rest-param method)
                                 (param->json
                                  (protocol-method-rest-param method))
                                 'null)
                       'ret (type->json (protocol-method-return-type method)))))]

    [(extend-type-form? e)
     (hasheq 'node "extend-type"
             'type-name (symbol->string (extend-type-form-type-name e))
             'impls
             (for/list ([impl (in-list (extend-type-form-impls e))])
               (hasheq
                'protocol (symbol->string (type-impl-protocol-name impl))
                'methods
                (for/list ([method (in-list (type-impl-methods impl))])
                  (hasheq 'name (symbol->string (impl-method-name method))
                          'params (map param->json (impl-method-params method))
                          'rest (if (impl-method-rest-param method)
                                    (param->json
                                     (impl-method-rest-param method))
                                    'null)
                          'ret (type->json (impl-method-return-type method))
                          'body (map expr->json (impl-method-body method)))))))]

    [else (error 'beagle-ast-json "unsupported checked AST node: ~v" e)]))

(define (pattern->json p)
  (cond
    [(pat-wildcard? p) (hasheq 'type "wildcard")]
    [(pat-literal? p)  (hasheq 'type "literal" 'value (datum->json (pat-literal-value p)))]
    [(pat-record? p)
     (binder-identities->json
      p
      (pat-record-bindings p)
      (hash-set*
       (reference-fields (pat-record-type-name p))
       'type "record"
       'bindings
       (map (lambda (b)
              (if (symbol? b)
                  (hasheq 'name (symbol->string b))
                  (hasheq 'field (symbol->string (car b))
                          'name (symbol->string (cdr b)))))
            (pat-record-bindings p))))]
    [(pat-map? p)
     (binder-identities->json
      p
      (pat-map-entries p)
      (hasheq 'type "map"
              'entries (map (lambda (e)
                              (hasheq 'key (datum->json (car e))
                                      'name (symbol->string (cdr e))))
                            (pat-map-entries p))))]
    [(pat-var? p)
     (binder-identities->json
      p
      (pat-var-name p)
      (hasheq 'type "var" 'name (symbol->string (pat-var-name p))))]
    [(pat-or? p)       (hasheq 'type "or"
                               'alternatives (map pattern->json (pat-or-alternatives p)))]
    [else (error 'beagle-ast-json "unsupported match pattern: ~v" p)]))

(define (program->json prog)
  (parameterize ([current-json-src-table (program-src-table prog)]
                 [current-json-semantic-contracts
                  (program-semantic-contracts prog)])
    (hasheq 'target (symbol->string (program-target prog))
            'namespace (symbol->string (program-namespace prog))
            'gen-class (program-gen-class? prog)
            'imports (map symbol->string (program-imports prog))
            'requires (map require-entry->json (program-requires prog))
            'externs
            (for/list ([name (in-list
                              (sort (hash-keys (program-externs prog))
                                    symbol<?))])
              (define entry
                (hasheq 'name (symbol->string name)
                        'type (type->json
                               (hash-ref (program-externs prog) name))))
              (if (set-member? (program-external-dynamic-vars prog) name)
                  (hash-set entry 'dynamic #t)
                  entry))
            'forms (map expr->json (program-forms prog)))))

(define (program->json-string prog)
  (jsexpr->string (program->json prog)))

(define (imported-record-field-order->json prog)
  (for/hasheq ([(name fields)
                (in-hash (program-imported-record-field-order prog))])
    (values name fields)))

(define (imported-record-namespaces->json prog)
  (for/hasheq ([(name namespace)
                (in-hash (program-imported-record-ns prog))])
    (values name (symbol->string namespace))))

(define (checked-program->json prog #:source-id [source-id #f])
  (define type-table (program-type-table prog))
  (unless type-table
    (error 'beagle-ast-json
           "checked-program projection requires type checking with #:capture-types? #t"))
  (define effective-definition-types
    (program-effective-definition-types prog))
  (unless (hash? effective-definition-types)
    (error
     'beagle-ast-json
     "checked-program projection requires finalized effective definition signatures"))
  (define source-bytes (program-source-bytes prog))
  (unless source-bytes
    (error 'beagle-ast-json
           "checked-program projection requires a program parsed from an exact source-byte snapshot"))
  (define base
    (parameterize ([current-json-src-table (program-src-table prog)]
                   [current-json-type-table type-table]
                   [current-json-macro-table
                    (program-macro-derived-table prog)]
                   [current-json-source-id source-id]
                   [current-checked-projection? #t]
                   [current-json-effective-definition-types
                    effective-definition-types]
                   [current-json-semantic-contracts
                    (program-semantic-contracts prog)])
      (hasheq
       'kind "beagle.checked-program"
       'schemaVersion CHECKED-PROGRAM-SCHEMA-VERSION
       'phase "checked"
       'target (symbol->string (program-target prog))
       'namespace (symbol->string (program-namespace prog))
       'sourceId (or source-id 'null)
       'sourceSha256 (sha256-prefixed source-bytes)
       'gen-class (program-gen-class? prog)
       'imports (map symbol->string (program-imports prog))
       'importedRecordFieldOrder (imported-record-field-order->json prog)
       'importedRecordNamespaces (imported-record-namespaces->json prog)
       'requires
       (map require-entry->json (program-requires prog))
       'externs
       (for/list ([name (in-list
                         (sort (hash-keys (program-externs prog)) symbol<?))])
         (hasheq 'name (symbol->string name)
                 'type (type->json (hash-ref (program-externs prog) name))))
       'forms (map expr->json (program-forms prog)))))
  ;; Self-digest excludes only itself. sourceSha256 stays in BASE, binding the
  ;; canonical checked projection to the exact input bytes without recursion.
  (hash-set base 'projectionSha256
            (sha256-prefixed (canonical-json-bytes base))))

(define (write-checked-program-json prog
                                    [out (current-output-port)]
                                    #:source-id [source-id #f])
  (write-canonical-json
   (checked-program->json prog #:source-id source-id)
   out)
  (newline out))

(provide CHECKED-PROGRAM-SCHEMA-VERSION
         program->json
         program->json-string
         checked-program->json
         write-checked-program-json
         expr->json
         type->json)
