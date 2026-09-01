#lang racket/base

;; A checked module's public, cross-module contract.
;;
;; Every Beagle-to-Beagle import crosses this boundary.  Source syntax is parsed
;; once into a program; consumers receive only the program's semantic interface
;; and its deterministic digest.

(require racket/list
         racket/match
         racket/port
         racket/set
         openssl/sha1
         "ast.rkt"
         "effect-normalization-v1.rkt"
         "macros.rkt"
         "types.rkt")

(define INTERFACE-SCHEMA-VERSION 15)
;; V15 adds parametric JavaScript declaration records and construct signatures.
;; V14 keeps a checked JavaScript declaration view beside each runtime binding
;; instead of replacing the runtime type imported by downstream Beagle modules.
;; V13 added declaration-only JavaScript wire types.
(define INTERFACE-DIGEST-CONSUMER-PRUNING-SAFE? #t)
(define ANY (type-prim 'Any))

(struct interface-constraint (expression synchronous? provider) #:transparent)
(struct interface-binding
  (name kind type raises constraints synchronous?
        returns-synchronous-callable? effects js-declaration-type)
  #:transparent)

(define (runtime-interface-binding
         name kind type raises constraints synchronous?
         returns-synchronous-callable? effects)
  (interface-binding
   name kind type raises constraints synchronous?
   returns-synchronous-callable? effects #f))
(struct interface-macro (name kind fixed-params rest-param template)
  #:transparent)
(struct interface-error (name members member-fields) #:transparent)
(struct interface-type-declaration (name kind details) #:transparent)
(struct interface-type-export (name kind arity expansion) #:transparent)
(struct interface-js-declaration-field (name type optional?) #:transparent)
(struct interface-js-declaration-record (type-params fields) #:transparent)
(struct interface-record-contract (name kind fields validator-symbol)
  #:transparent)
(struct interface-protocol-method-contract
  (name params rest-param return-type effects)
  #:transparent)
(struct interface-protocol-contract (name methods) #:transparent)
(struct module-interface
  (schema-version namespace target bindings public-esm-exports macros macro-fingerprints
                  type-declarations type-exports record-contracts errors requires
                  dynamic-vars digest source-digest source-id)
  #:transparent)

;; Conformance is evidence about publication, not a second interface value.
;; Keep it attached by interface identity so the existing module-interface
;; remains the sole object imported by consumers.
(define MODULE-INTERFACE->CONFORMANCE (make-weak-hasheq))
(define (module-interface-conformance interface)
  (hash-ref MODULE-INTERFACE->CONFORMANCE interface #f))

;; Foreign declaration graphs are runtime query context, not part of Beagle's
;; canonical interface datum.  Attach their explicit transitive closure to the
;; interface object that carries foreign types so a consumer of an intermediate
;; Beagle module never needs an ambient global registry.
(define MODULE-INTERFACE->FOREIGN-DEPENDENCIES (make-weak-hasheq))

(define (module-interface-foreign-dependencies interface)
  (hash-ref MODULE-INTERFACE->FOREIGN-DEPENDENCIES interface (hash)))

(define (register-module-interface-foreign-dependencies! interface dependencies)
  (unless (and (module-interface? interface) (hash? dependencies))
    (raise-arguments-error
     'register-module-interface-foreign-dependencies!
     "expected a module interface and dependency hash"
     "interface" interface
     "dependencies" dependencies))
  (hash-set! MODULE-INTERFACE->FOREIGN-DEPENDENCIES
             interface dependencies)
  interface)

(define (inherited-foreign-dependencies prog)
  (for/fold ([dependencies (hash)])
            ([import (in-list (program-imported-module-interfaces prog))])
    (for/fold ([merged dependencies])
              ([(identity graph)
                (in-hash
                 (module-interface-foreign-dependencies
                  (module-import-interface import)))])
      (define prior (hash-ref merged identity #f))
      ;; Identity is the canonical semantic graph digest. The same declaration
      ;; may arrive through multiple package paths with distinct provenance and
      ;; therefore distinct graph objects; retain the first exact semantic
      ;; identity instead of comparing non-semantic attachment data.
      (if prior merged (hash-set merged identity graph)))))

;; A resolver returns a module-source. INTERFACE is #f during the bootstrap
;; parse and a module-interface during authoritative parsing.
(struct module-source (namespace source-id stxs interface) #:transparent)

;; One ordered import binding. SOURCE is the provider-owned export name;
;; LOCAL is the unqualified consumer binding selected by `:rename`.
(struct import-binding (source local) #:transparent)

;; One consumer-side import of an interface. IDENTITY is the exact canonical
;; requirement; PREFIX is the spelling accepted at qualified use sites;
;; BINDINGS is the authored `:refer` order after applying `:rename` once.
(struct module-import (identity interface prefix bindings) #:transparent)

;; The parser owns surface syntax, but it must pass one normalized import
;; contract to every module consumer.  In particular, the string `"react"`
;; and the namespace `react` are different identities: the former is an exact
;; native ESM specifier while the latter is a Beagle module-provider key.
(struct module-identity (kind value) #:transparent)
(struct canonical-libspec (identity alias bindings) #:transparent)
(struct canonical-global-refer (bindings) #:transparent)

(define (libspec-error format-string . arguments)
  (apply error 'normalize-require-libspec format-string arguments))

(define (plain-symbol? value)
  (and (symbol? value) (not (keyword? value))))

(define (distinct-symbols? values)
  (= (length values) (length (remove-duplicates values eq?))))

(define (validated-symbol-list value description)
  (unless (and (list? value)
               (andmap plain-symbol? value)
               (distinct-symbols? value))
    (libspec-error "~a must be a duplicate-free list of symbols, got: ~v"
                   description value))
  value)

(define (validate-import-binding-name! name description role)
  (define context (format "~a ~a" description role))
  (validate-identifier! name context)
  (when (regexp-match? #rx"/" (symbol->string name))
    (libspec-error
     "~a must be an unqualified bindable identifier, got: ~v"
     context name)))

(define (validated-import-bindings refer value description)
  (unless (hash? value)
    (libspec-error "~a must be a symbol-to-symbol map, got: ~v"
                   description value))
  (define entries (hash->list value))
  (unless (andmap (lambda (entry)
                    (and (plain-symbol? (car entry))
                         (plain-symbol? (cdr entry))))
                  entries)
    (libspec-error "~a must be a symbol-to-symbol map, got: ~v"
                   description value))
  (define sources (map car entries))
  (unless (andmap (lambda (source) (memq source refer)) sources)
    (libspec-error
     "~a may rename each explicitly referred symbol once, got: ~v"
     description value))
  (when (for/or ([entry (in-list entries)])
          (eq? (car entry) (cdr entry)))
    (libspec-error "~a cannot rename a symbol to itself, got: ~v"
                   description value))
  (define bindings
    (for/list ([source (in-list refer)])
      (import-binding source (hash-ref value source source))))
  (for ([binding (in-list bindings)])
    (validate-import-binding-name!
     (import-binding-source binding) description "source")
    (validate-import-binding-name!
     (import-binding-local binding) description "final local"))
  (define locals (map import-binding-local bindings))
  (unless (distinct-symbols? locals)
    (libspec-error
     "~a final local names must be unique across renamed and unrenamed refers, got: ~v"
     description locals))
  bindings)

(define (import-bindings->refer bindings)
  (map import-binding-source bindings))

(define (import-bindings->rename bindings)
  (for/hasheq ([binding (in-list bindings)]
               #:unless (eq? (import-binding-source binding)
                             (import-binding-local binding)))
    (values (import-binding-source binding)
            (import-binding-local binding))))

(define (libspec-identity source kind)
  (case kind
    [(require)
     (cond
       [(string? source) (module-identity 'native-esm source)]
       [(plain-symbol? source) (module-identity 'beagle-namespace source)]
       [else
        (libspec-error
         "require libspec must start with a namespace symbol or native ESM string, got: ~v"
         source)])]
    [(require-global)
     (cond
       [(plain-symbol? source) (module-identity 'global source)]
       [(string? source) (module-identity 'typescript-ambient source)]
       [else
        (libspec-error
         "require-global libspec must start with a global symbol or TypeScript ambient-provider string, got: ~v"
         source)])]
    [else
     (libspec-error "unknown libspec kind ~a" kind)]))

;; ITEMS are already-delimited source data: `(source :as alias :refer (name ...)
;; :rename #hasheq((name . local)))`.  This deliberately has no quoted, bare,
;; or alternate-option compatibility grammar.  The parser strips reader tags
;; and calls this one boundary for `require` and `require-global` alike.
(define (normalize-require-libspec items #:kind [kind 'require])
  (unless (and (list? items) (pair? items))
    (libspec-error "libspec must be a non-empty canonical item list, got: ~v"
                   items))
  (define identity (libspec-identity (car items) kind))
  (define seen (make-hasheq))
  (define alias #f)
  (define refer '())
  (define rename (hasheq))
  (let loop ([rest (cdr items)])
    (cond
      [(null? rest)
       (define bindings
         (validated-import-bindings refer rename ":rename"))
       (when (and (eq? (module-identity-kind identity) 'typescript-ambient)
                  (null? bindings))
         (libspec-error
          "require-global TypeScript ambient provider ~v requires an explicit non-empty :refer"
          (module-identity-value identity)))
       (canonical-libspec identity alias bindings)]
      [(or (not (plain-symbol? (car rest)))
           (not (memq (car rest) '(:as :refer :rename))))
       (libspec-error
        "unsupported libspec option ~v; supported: :as, :refer, :rename"
        (car rest))]
      [(hash-ref seen (car rest) #f)
       (libspec-error "libspec option ~a appears more than once" (car rest))]
      [(null? (cdr rest))
       (libspec-error "libspec option ~a requires a value" (car rest))]
      [else
       (hash-set! seen (car rest) #t)
       (case (car rest)
         [(:as)
          (unless (plain-symbol? (cadr rest))
            (libspec-error ":as expects a symbol, got: ~v" (cadr rest)))
          (set! alias (cadr rest))]
         [(:refer)
          (set! refer (validated-symbol-list (cadr rest) ":refer"))]
         [(:rename)
          ;; Validate after the complete option sequence, so option order has
          ;; no meaning while `:rename` still requires an explicit `:refer`.
          (set! rename (cadr rest))])
       (loop (cddr rest))])))

(define (normalize-canonical-libspec items #:kind [kind 'require])
  (normalize-require-libspec items #:kind kind))

;; `refer-global` is a separate namespace clause, not a module import.  It is
;; nevertheless normalized here because its renamed globals must retain a
;; global identity and must never be confused with a native ESM dependency.
(define (normalize-refer-global options)
  (unless (list? options)
    (libspec-error "refer-global options must be a canonical item list, got: ~v"
                   options))
  (define seen (make-hasheq))
  (define refer #f)
  (define rename (hasheq))
  (let loop ([rest options])
    (cond
      [(null? rest)
       (unless refer
         (libspec-error "refer-global requires :only [global ...]"))
       (canonical-global-refer
        (validated-import-bindings refer rename "refer-global :rename"))]
      [(or (not (plain-symbol? (car rest)))
           (not (memq (car rest) '(:only :rename))))
       (libspec-error
        "unsupported refer-global option ~v; supported: :only, :rename"
        (car rest))]
      [(hash-ref seen (car rest) #f)
       (libspec-error "refer-global option ~a appears more than once" (car rest))]
      [(null? (cdr rest))
       (libspec-error "refer-global option ~a requires a value" (car rest))]
      [else
       (hash-set! seen (car rest) #t)
       (case (car rest)
         [(:only)
          (set! refer (validated-symbol-list (cadr rest) "refer-global :only"))]
         [(:rename) (set! rename (cadr rest))])
       (loop (cddr rest))])))

(define (param-interface-type p)
  (cond
    [(param? p) (or (param-type p) ANY)]
    [(or (map-destructure? p) (seq-destructure? p)) ANY]
    [else ANY]))

(define (function-type params rest-param return-type)
  (type-fn (map param-interface-type params)
           (and rest-param (param-interface-type rest-param))
           return-type))

(define (open-interface-effects prog)
  (normalized-obligations-v1-open
   (program-target prog)
   (profile-for-target (program-target prog))))

(define (interface-effects-for prog owner provisional?)
  (normalize-signature-obligations-v1
   prog
   owner
   #:semantic-profile (profile-for-target (program-target prog))
   #:provisional? provisional?))

(define (param-interface-constraint p)
  (and (param? p) (param-constraint p)))

(define (constraint-expression value)
  (if (interface-constraint? value)
      (interface-constraint-expression value)
      value))

(define (constraint-contract-for prog parameter [provisional? #f])
  (define expression (param-interface-constraint parameter))
  (cond
    [(not expression) #f]
    [provisional?
     (interface-constraint expression #f #f)]
    [else
     (define proof
       (semantic-contract-ref
        (program-semantic-contracts prog)
        parameter
        binding-constraint-contract?
        #f))
     (unless (and (binding-constraint-contract? proof)
                  (binding-constraint-contract-synchronous? proof))
       (error
        'program->module-interface
        "cannot publish binding constraint without a positive synchronization proof: ~a"
        (param-name parameter)))
     (interface-constraint
      expression
      #t
      (binding-constraint-contract-provider proof))]))

(define (callable-constraints prog params [rest-param #f]
                              #:provisional? [provisional? #f])
  (for/list
      ([parameter
        (in-list
         (if rest-param
             (append params (list rest-param))
             params))])
    (constraint-contract-for prog parameter provisional?)))

(define (interface-field prog field provisional?)
  (struct-copy
   param field
   [constraint (constraint-contract-for prog field provisional?)]))

(define (interface-fields prog fields provisional?)
  (for/list ([field (in-list fields)])
    (interface-field prog field provisional?)))

(define (record-validator-symbol name)
  (string->symbol
   (format "$beagle$record$~a$validate" name)))

(define (constrained-fields? fields)
  (for/or ([field (in-list fields)])
    (and (param? field)
         (constraint-expression (param-constraint field)))))

(define (make-interface-record-contract prog name kind fields provisional?)
  (interface-record-contract
   name
   kind
   (for/list ([field (in-list fields)])
     (interface-field prog field provisional?))
   (and (constrained-fields? fields)
        (record-validator-symbol name))))

(define (program-record-contracts prog [provisional? #f])
  (define contracts (make-hasheq))
  (define (add! name kind fields)
    (hash-set!
     contracts name
     (make-interface-record-contract
      prog name kind fields provisional?)))
  (for ([raw-form (in-list (program-forms prog))])
    (define form (unwrap-public-form raw-form))
    (match form
      [(record-form name fields)
       (add! name 'record fields)]
      [(defunion-form _ members _ member-fields)
       (when member-fields
         (for ([member (in-list members)]
               #:when (hash-has-key? member-fields member))
           (add! member 'union-member
                 (hash-ref member-fields member '()))))]
      [(deferror-form _ members member-fields)
       (for ([member (in-list members)])
         (add! member 'throwable-member
               (hash-ref member-fields member '())))]
      [(jst-declare-record name _type-params fields)
       (for ([field (in-list fields)])
         (when (type-has-any? (jst-declaration-field-type field))
           (error 'program->module-interface
                  "js/declare-record ~a field ~a contains Beagle Any"
                  name
                  (jst-declaration-field-name field))))
       (add!
        name
        'js-wire-record
        (for/list ([field (in-list fields)])
          (param
           (jst-declaration-field-name field)
           (if (jst-declaration-field-optional? field)
               (type-union
                (list (jst-declaration-field-type field) (type-prim 'Nil)))
               (jst-declaration-field-type field))
           #f)))]
      [_ (void)]))
  contracts)

(define (make-interface-protocol-contract prog name methods provisional?)
  (define contracts (make-hasheq))
  (for ([method (in-list methods)])
    (define method-name (protocol-method-name method))
    (when (hash-has-key? contracts method-name)
      (error 'beagle
             "protocol ~a declares method ~a more than once"
             name method-name))
    (hash-set!
     contracts
     method-name
     (interface-protocol-method-contract
      method-name
      (for/list ([parameter (in-list (protocol-method-params method))])
        (struct-copy
         param parameter
         [constraint
          (constraint-contract-for prog parameter provisional?)]))
      (and
       (protocol-method-rest-param method)
       (let ([parameter (protocol-method-rest-param method)])
         (struct-copy
          param parameter
          [constraint
           (constraint-contract-for prog parameter provisional?)])))
      (protocol-method-return-type method)
      (open-interface-effects prog))))
  (interface-protocol-contract name contracts))

(define (program-protocol-contracts prog [provisional? #f])
  (for/hasheq ([raw-form (in-list (program-forms prog))]
               #:do [(define form (unwrap-public-form raw-form))]
               #:when (protocol-form? form))
    (values
     (protocol-form-name form)
     (make-interface-protocol-contract
      prog
      (protocol-form-name form)
      (protocol-form-methods form)
      provisional?))))

(define (record-bindings prog name fields kind map-constructor? provisional?)
  (define record-type (type-prim name))
  (define name-string (symbol->string name))
  (define lower-name (string-downcase name-string))
  (append
   (if (eq? (program-target prog) 'js)
       (list
        (runtime-interface-binding
         name
         kind
         (type-fn (map param-interface-type fields) #f record-type)
         #f
         (callable-constraints prog fields #:provisional? provisional?)
         #t
         #f
         (open-interface-effects prog)))
       '())
   (list
    (runtime-interface-binding
     (string->symbol (string-append "->" name-string))
     kind
     (type-fn (map param-interface-type fields) #f record-type)
     #f
     (callable-constraints prog fields #:provisional? provisional?)
     #t
     #f
     (open-interface-effects prog)))
   (if map-constructor?
       (list
        (runtime-interface-binding
         (string->symbol (string-append "map->" name-string))
         'map-constructor
         (type-fn (list ANY) #f record-type)
         #f
         (list #f)
         #t
         #f
         (open-interface-effects prog)))
       '())
   (for/list ([field (in-list fields)])
     (runtime-interface-binding
      (string->symbol
       (string-append lower-name "-" (symbol->string (param-name field))))
      'accessor
      (type-fn (list record-type) #f (param-interface-type field))
      #f
      (list #f)
      #t
      #f
      (open-interface-effects prog)))))

(define unwrap-public-form unwrap-definition-form)

;; On the js target, `js/export` is the deliberate publication surface: the
;; emitter exports exactly the wrapped definitions, so the interface must not
;; publish anything else or a consumer's checked reference dies at runtime as
;; a missing namespace-object member. `js/export-default` publishes only the
;; module's `default` slot, never the definition's own name.
(define (js-published? raw-form)
  (let loop ([form raw-form])
    (cond
      [(jst-export? form) #t]
      [(with-meta? form) (loop (with-meta-expr form))]
      [else #f])))

(define (public-esm-exports-for prog ast-bindings bindings)
  (if (eq? (program-target prog) 'js)
      (for/hasheq ([name (in-list (sort (hash-keys ast-bindings) symbol<?))]
                   #:when (hash-has-key? bindings name))
        (values name (symbol->string name)))
      (hasheq)))

(define (publication-effective-definition-types prog provisional?)
  (cond
    ;; Candidate-overlay bootstrap parsing needs names before checking can run.
    ;; The caller must opt into that weaker, transient interface explicitly.
    [provisional? #f]
    [else
     (define effective (program-effective-definition-types prog))
     (unless (hash? effective)
       (error
        'program->module-interface
        "interface publication requires finalized effective definition signatures; type-check the program first or use #:provisional? #t only for bootstrap parsing"))
     effective]))

(define (publication-conformed-bindings prog bindings provisional?)
  (define declaration (program-declared-module-contract prog))
  (cond
    [(or provisional? (not declaration)) bindings]
    [else
     (define projection (program-conformed-contract-projection prog))
     (unless (hash? projection)
       (error
        'program->module-interface
        "declared module contract has no passing conformance projection; type-check the program before publication"))
     (for/hasheq ([(name declared-scheme) (in-hash projection)])
       (define candidate
         (hash-ref
          bindings
          name
          (lambda ()
            (error
             'program->module-interface
             "conformed contract projection names missing interface export ~a"
             name))))
       (when (pair? (free-type-metas declared-scheme))
         (error
          'program->module-interface
          "cannot publish unresolved inference metavariable in declared contract scheme for ~a"
          name))
       (values
        name
        (struct-copy interface-binding candidate [type declared-scheme])))]))

(define (published-definition-type effective name authored)
  (define published
    (if effective
        (hash-ref
         effective
         name
         (lambda ()
           (error
            'program->module-interface
            "finalized effective definition signature is missing for ~a"
            name)))
        authored))
  (when (pair? (free-type-metas published))
    (error
     'program->module-interface
     "cannot publish unresolved inference metavariable in signature for ~a"
     name))
  published)

(define (ast-interface-bindings prog effective provisional?)
  (define forms (program-forms prog))
  (define target (program-target prog))
  (define out (make-hasheq))
  (define (add! binding)
    (hash-set! out (interface-binding-name binding) binding))
  (define (add-record! name fields kind)
    (for ([binding
           (in-list
            (record-bindings
             prog name fields kind (eq? target 'clj) provisional?))])
      (add! binding)))
  (for ([raw-form (in-list forms)]
        #:unless (and (eq? target 'js) (not (js-published? raw-form))))
    (define form (unwrap-public-form raw-form))
    (match form
      [(def-form name type _ _ _ private?)
       (unless private?
         (add!
          (runtime-interface-binding
           name
           'def
           (published-definition-type effective name (or type ANY))
           #f
           '()
           #f
           #f
           (open-interface-effects prog))))]
      [(defonce-form name type _ _ private?)
       (unless private?
         (add!
          (runtime-interface-binding
           name
           'defonce
           (published-definition-type effective name (or type ANY))
           #f
           '()
           #f
           #f
           (open-interface-effects prog))))]
      [(defn-form name params rest-param return-type _ private? raises _)
       (unless private?
         (define authored
           (function-type params rest-param return-type))
         (add!
          (runtime-interface-binding
           name
           'defn
           (published-definition-type effective name authored)
           raises
           (callable-constraints
            prog params rest-param #:provisional? provisional?)
           (and
            (not provisional?)
            (program-callable-synchronous? prog name #f))
           (and
            (not provisional?)
            (program-returns-synchronous-callable? prog name #f))
           (interface-effects-for prog form provisional?))))]
      [(defn-multi name arities private? _)
       (unless private?
         (define alternatives
           (for/list ([arity (in-list arities)])
             (function-type
              (arity-clause-params arity)
              (arity-clause-rest-param arity)
              (arity-clause-return-type arity))))
         (add!
          (runtime-interface-binding
           name
           'defn-multi
           (published-definition-type
            effective
            name
            (if (= (length alternatives) 1)
                (car alternatives)
                (type-union alternatives)))
           #f
           (for/list ([arity (in-list arities)])
             (callable-constraints
              prog
              (arity-clause-params arity)
              (arity-clause-rest-param arity)
              #:provisional? provisional?))
           (and
            (not provisional?)
            (program-callable-synchronous? prog name #f))
           (and
            (not provisional?)
            (program-returns-synchronous-callable? prog name #f))
           (interface-effects-for prog form provisional?))))]
      [(record-form name fields)
       (add-record! name fields 'record-constructor)]
      [(protocol-form _ methods)
       (for ([method (in-list methods)])
         (add!
          (runtime-interface-binding
           (protocol-method-name method)
           'protocol-method
           (function-type
            (protocol-method-params method)
            (protocol-method-rest-param method)
            (protocol-method-return-type method))
           #f
           (callable-constraints
            prog
            (protocol-method-params method)
            (protocol-method-rest-param method)
            #:provisional? provisional?)
           #t
           #f
           (open-interface-effects prog))))]
      [(defmulti-form name _)
       (add! (runtime-interface-binding name 'defmulti
                                (type-fn (list ANY) ANY ANY) #f '() #f #f
                                (open-interface-effects prog)))]
      [(defenum-form name _)
       (add!
        (runtime-interface-binding
         (string->symbol (string-append (symbol->string name) "-values"))
         'enum-values
         (type-app 'Set (list (type-prim name)))
         #f
         '()
         #f
         #f
         (open-interface-effects prog)))]
      [(defunion-form _ members _ member-fields)
       (when member-fields
         (for ([member (in-list members)])
           (add-record! member
                        (hash-ref member-fields member '())
                        'union-constructor)))]
      [(deferror-form _ members member-fields)
       (for ([member (in-list members)])
         (add-record! member
                      (hash-ref member-fields member '())
                      'error-constructor))]
      [(defscalar-form name backing-type _)
       (define scalar-type (type-prim name))
       (define backing (type-prim backing-type))
       (define name-string (symbol->string name))
       (add!
        (runtime-interface-binding
         (string->symbol (string-append "->" name-string))
         'scalar-constructor
         (type-fn (list backing) #f scalar-type)
         #f
         (list #f)
         #t
         #f
         (open-interface-effects prog)))
       (add!
        (runtime-interface-binding
         (string->symbol
          (string-append (string-downcase name-string) "-value"))
         'scalar-accessor
         (type-fn (list scalar-type) #f backing)
         #f
         (list #f)
         #t
         #f
         (open-interface-effects prog)))]
      [_ (void)]))
  (define declaration-overrides (make-hasheq))
  (for ([raw-form (in-list forms)])
    (define form (unwrap-public-form raw-form))
    (when (jst-declare-export? form)
      (define name (jst-declare-export-name form))
      (when (hash-has-key? declaration-overrides name)
        (error 'program->module-interface
               "duplicate js/declare-export for ~a"
               name))
      (hash-set! declaration-overrides name (jst-declare-export-type form))))
  ;; The wire declaration graph is structural and declaration-only.  Resolve
  ;; both local and imported names so JsObject may be narrowed only to a shape
  ;; that is proven to remain an ordinary JavaScript object at runtime.
  (define wire-declarations (make-hasheq))
  (for ([raw-form (in-list forms)])
    (define form (unwrap-public-form raw-form))
    (cond
      [(jst-declare-record? form)
       (hash-set!
        wire-declarations
        (jst-declare-record-name form)
        (interface-type-declaration
         (jst-declare-record-name form)
         'js-wire-record
         #f))]
      [(jst-declare-type? form)
       (hash-set!
        wire-declarations
        (jst-declare-type-name form)
        (interface-type-declaration
         (jst-declare-type-name form)
         'js-wire-alias
         (jst-declare-type-type form)))]))
  (for ([import (in-list (program-imported-module-interfaces prog))])
    (define interface (module-import-interface import))
    (define namespace (module-interface-namespace interface))
    (for ([(name declaration)
           (in-hash (module-interface-type-declarations interface))]
          #:when
          (memq (interface-type-declaration-kind declaration)
                '(js-wire-record js-wire-alias)))
      (hash-set!
       wire-declarations
       (qualify-type-name namespace name)
       (interface-type-declaration
        name
        (interface-type-declaration-kind declaration)
        (interface-type-declaration-details declaration)))))
  (define (provisional-imported-wire-name? name)
    (and
     provisional?
     (for/or ([require (in-list (program-requires prog))])
       (define identity (require-entry-identity require))
       (and
        (eq? (module-identity-kind identity) 'beagle-namespace)
        (eq? name
             (qualify-type-name
              (module-identity-value identity)
              (unqualify-type-name name)))))))
  (define (function-alternatives type)
    (cond
      [(type-fn? type) (list type)]
      [(and (type-union? type)
            (andmap type-fn? (type-union-alts type)))
       (type-union-alts type)]
      [else #f]))
  (define (js-optional-base type)
    (and (type-refinement? type)
         (eq? (type-refinement-placement type) 'js-declaration)
         (eq? (type-refinement-predicate type) 'js/optional)
         (type-refinement-base type)))
  (define (js-constructor-base type)
    (and (type-refinement? type)
         (eq? (type-refinement-placement type) 'js-declaration)
         (eq? (type-refinement-predicate type) 'js/constructor)
         (type-refinement-base type)))
  (define (polymorphic-body type)
    (if (type-poly? type) (type-poly-body type) type))
  (define (nullable-base type)
    (and
     (type-union? type)
     (let ([nullable
            (filter
             (lambda (alternative)
               (and (type-prim? alternative)
                    (eq? (type-prim-name alternative) 'Nil)))
             (type-union-alts type))]
           [values
            (filter
             (lambda (alternative)
               (not (and (type-prim? alternative)
                         (eq? (type-prim-name alternative) 'Nil))))
             (type-union-alts type))])
       (and (= (length nullable) 1)
            (= (length values) 1)
            (car values)))))
  (define (wire-object? type [seen (seteq)])
    (cond
      [(type-union? type)
       (and (pair? (type-union-alts type))
            (andmap (lambda (alternative) (wire-object? alternative seen))
                    (type-union-alts type)))]
      [(type-prim? type)
       (define name (type-prim-name type))
       (and
        (not (set-member? seen name))
        (let ([declaration (hash-ref wire-declarations name #f)])
          (cond
            [declaration
             (case (interface-type-declaration-kind declaration)
               [(js-wire-record) #t]
               [(js-wire-alias)
                (wire-object?
                 (interface-type-declaration-details declaration)
                 (set-add seen name))]
               [else #f])]
            ;; The first parse-only overlay round knows a required candidate's
            ;; canonical namespace but cannot retain its interface yet.  Admit
            ;; that exact imported identity provisionally; the next interface
            ;; round resolves its kind and every checked publication repeats
            ;; this compatibility proof without the provisional escape hatch.
            [else (provisional-imported-wire-name? name)])))]
      [(type-app? type)
       (define name (type-app-ctor type))
       (define declaration (hash-ref wire-declarations name #f))
       (cond
         [declaration
          (eq? (interface-type-declaration-kind declaration)
               'js-wire-record)]
         [else (provisional-imported-wire-name? name)])]
      [else #f]))
  (define (js-string-literal? type)
    (and
     (type-refinement? type)
     (eq? (type-refinement-placement type) 'js-declaration)
     (equal? (type-refinement-base type) (type-prim 'String))
     (match (type-refinement-predicate type)
       [(list 'js/literal (? string?)) #t]
       [_ #f])))
  (define (wire-string-enum? type [seen (seteq)])
    (cond
      [(js-string-literal? type) #t]
      [(type-union? type)
       (and
        (pair? (type-union-alts type))
        (andmap
         (lambda (alternative) (wire-string-enum? alternative seen))
         (type-union-alts type)))]
      [(type-prim? type)
       (define name (type-prim-name type))
       (and
        (not (set-member? seen name))
        (let ([declaration (hash-ref wire-declarations name #f)])
          (cond
            [(and declaration
                  (eq? (interface-type-declaration-kind declaration)
                       'js-wire-alias))
             (wire-string-enum?
              (interface-type-declaration-details declaration)
              (set-add seen name))]
            [declaration #f]
            [else (provisional-imported-wire-name? name)])))]
      [else #f]))
  (define (vec-string-enum-refinement? runtime declaration)
    (and
     (type-app? runtime)
     (eq? (type-app-ctor runtime) 'Vec)
     (= (length (type-app-args runtime)) 1)
     (equal? (car (type-app-args runtime)) (type-prim 'String))
     (type-app? declaration)
     (eq? (type-app-ctor declaration) 'Vec)
     (= (length (type-app-args declaration)) 1)
     (wire-string-enum? (car (type-app-args declaration)))))
  (define (position-compatible? runtime declaration)
    (or
     (equal? runtime declaration)
     (and
      (equal? runtime (type-prim 'JsObject))
      (wire-object? declaration))
     (vec-string-enum-refinement? runtime declaration)
     (let ([runtime-base (nullable-base runtime)]
           [declaration-base (js-optional-base declaration)])
       (and runtime-base
            declaration-base
            (position-compatible? runtime-base declaration-base)))))
  (define (valid-optional-parameters? parameters)
    (let loop ([remaining parameters] [optional-seen? #f])
      (cond
        [(null? remaining) #t]
        [(js-optional-base (car remaining))
         (loop (cdr remaining) #t)]
        [optional-seen? #f]
        [else (loop (cdr remaining) #f)])))
  (define (compatible-declaration? runtime declaration)
    (define constructor-base (js-constructor-base declaration))
    (define runtime-functions (function-alternatives runtime))
    (define declaration-functions
      (function-alternatives
       (if constructor-base
           (polymorphic-body constructor-base)
           declaration)))
    (cond
      [(and constructor-base (type-poly? runtime))
       (compatible-declaration?
        (type-poly-body runtime)
        declaration)]
      [(and runtime-functions declaration-functions)
       (and
        (= (length runtime-functions) (length declaration-functions))
        (for/and ([runtime-function (in-list runtime-functions)]
                  [declaration-function (in-list declaration-functions)])
          (and (valid-optional-parameters?
                (type-fn-params declaration-function))
               (= (length (type-fn-params runtime-function))
                  (length (type-fn-params declaration-function)))
               (for/and
                   ([runtime-parameter
                     (in-list (type-fn-params runtime-function))]
                    [declaration-parameter
                     (in-list (type-fn-params declaration-function))])
                 (position-compatible?
                  runtime-parameter declaration-parameter))
               (equal? (type-fn-rest-type runtime-function)
                       (type-fn-rest-type declaration-function))
               (position-compatible?
                (type-fn-ret runtime-function)
                (type-fn-ret declaration-function)))))]
      [(or runtime-functions declaration-functions) #f]
      [else (position-compatible? runtime declaration)]))
  (for ([(name declaration) (in-hash declaration-overrides)])
    (when (type-has-any? declaration)
      (error 'program->module-interface
             "js/declare-export ~a contains Beagle Any"
             name))
    (define runtime (hash-ref out name #f))
    (unless runtime
      (error 'program->module-interface
             "js/declare-export ~a must name a js/export runtime binding"
             name))
    (unless (compatible-declaration? (interface-binding-type runtime)
                                     declaration)
      (error 'program->module-interface
             "js/declare-export ~a must preserve callable arity; js/constructor may project a runtime callable as a construct signature, and positions may narrow only JsObject to checked JavaScript wire declarations, Vec String to a checked JavaScript string enum, or nullable values to js/optional; runtime type ~a, declaration type ~a"
             name
             (type->string (interface-binding-type runtime))
             (type->string declaration)))
    (hash-set!
     out
     name
     (struct-copy
      interface-binding
      runtime
      [js-declaration-type declaration])))
  out)

(define (declared-interface-bindings prog)
  ;; Meta declarations are absent from program-forms, so the parser retains
  ;; their local semantic products explicitly on the program.
  (define extern-bindings
    (for/hasheq ([(name type) (in-hash (program-declared-externs prog))])
      (values name
              (runtime-interface-binding name 'extern type #f '() #f #f
                                 (open-interface-effects prog)))))
  (for/fold ([bindings extern-bindings])
            ([name (in-hash-keys (program-declared-macros prog))])
    (hash-set bindings name
              (runtime-interface-binding name 'macro ANY #f '() #f #f
                                 (open-interface-effects prog)))))

(define (program-interface-macros prog)
  (for/hasheq ([(name definition)
                (in-hash (program-declared-macros prog))])
    (values
     name
     (interface-macro
      name
      (macro-def-kind definition)
      (macro-def-fixed-params definition)
      (macro-def-rest-param definition)
      (macro-def-template definition)))))

(define (interface-macro->canonical-datum macro)
  `(macro
    ,(interface-macro-name macro)
    ,(interface-macro-kind macro)
    (params ,@(interface-macro-fixed-params macro))
    (rest ,(interface-macro-rest-param macro))
    (template
     ,(constraint->canonical-datum (interface-macro-template macro)))))

(define (interface-macro-fingerprints macros)
  (for/hasheq ([(name macro) (in-hash macros)])
    (values name (sha256-datum (interface-macro->canonical-datum macro)))))

(define (program-dynamic-vars prog)
  (for/seteq ([raw-form (in-list (program-forms prog))]
              #:do [(define form (unwrap-public-form raw-form))]
              #:when (and (def-form? form) (def-form-dynamic? form)))
    (def-form-name form)))

(define (program-errors prog provisional?)
  (for/hasheq ([raw-form (in-list (program-forms prog))]
               #:do [(define form (unwrap-public-form raw-form))]
               #:when (deferror-form? form))
    (values
     (deferror-form-name form)
     (interface-error
      (deferror-form-name form)
      (deferror-form-members form)
      (for/hasheq ([member (in-list (deferror-form-members form))])
        (values member
                (for/list
                    ([field
                      (in-list
                       (hash-ref
                        (deferror-form-member-fields form) member '()))])
                  (interface-field prog field provisional?))))))))

(define (program-type-declarations prog declared-type-aliases provisional?)
  (define alias-declarations
    (for/hasheq ([(name expansion) (in-hash declared-type-aliases)])
      (values
       name
       (interface-type-declaration
        name
        'alias
        `(expansion ,(type->canonical-datum expansion))))))
  (for/fold ([declarations alias-declarations])
            ([raw-form (in-list (program-forms prog))])
    (define form (unwrap-public-form raw-form))
    (define declaration
      (match form
        [(record-form name fields)
         (interface-type-declaration
          name 'record
          `(fields
            ,@(map field->canonical-datum
                   (interface-fields prog fields provisional?))))]
        [(protocol-form name methods)
         (interface-type-declaration
          name 'protocol
          (make-interface-protocol-contract
           prog name methods provisional?))]
        [(defenum-form name values)
         (interface-type-declaration name 'enum `(values ,@values))]
        [(defunion-form name members type-params member-fields)
         (interface-type-declaration
          name 'union
          `(type-params ,type-params
            members
            ,(for/list ([member (in-list members)])
               (list
                member
                (map field->canonical-datum
                     (interface-fields
                      prog
                      (if member-fields
                          (hash-ref member-fields member '())
                          '())
                      provisional?))))))]
        [(deferror-form name members member-fields)
         (interface-type-declaration
          name 'throwable-union
          `(members
            ,(for/list ([member (in-list members)])
               (list
                member
                (map field->canonical-datum
                     (interface-fields
                      prog
                      (hash-ref member-fields member '())
                      provisional?))))))]
        [(defscalar-form name backing-type predicates)
         (interface-type-declaration
          name 'scalar
          `(backing ,backing-type
            predicates
            ,(for/list ([predicate (in-list predicates)])
               (list
                (scalar-predicate-op predicate)
                (scalar-predicate-value predicate)))))]
        [(jst-declare-record name type-params fields)
         (interface-type-declaration
          name
          'js-wire-record
          (interface-js-declaration-record
           type-params
           (for/list ([field (in-list fields)])
             (interface-js-declaration-field
              (jst-declaration-field-name field)
              (jst-declaration-field-type field)
              (jst-declaration-field-optional? field)))))]
        [(jst-declare-type name type)
         (when (type-has-any? type)
           (error 'program->module-interface
                  "js/declare-type ~a contains Beagle Any"
                  name))
         (interface-type-declaration name 'js-wire-alias type)]
        [_ #f]))
    (if declaration
        (hash-set
         declarations
         (interface-type-declaration-name declaration)
         declaration)
        declarations)))

(define (program-type-exports forms declared-type-aliases)
  ;; This is the authoritative namespace for type-position resolution.  Keep it
  ;; separate from value bindings: a record/union/alias may be a valid type
  ;; export without being a value named by the same symbol.
  (define exports (make-hasheq))
  (define (add! name kind [arity 0] [expansion #f])
    (hash-set!
     exports
     name
     (interface-type-export name kind arity expansion)))
  (for ([raw-form (in-list forms)])
    (define form (unwrap-public-form raw-form))
    (match form
      [(record-form name _)
       (add! name 'record)]
      [(protocol-form name _)
       (add! name 'protocol)]
      [(defenum-form name _)
       (add! name 'enum)]
      [(defunion-form name members type-params _)
       (add!
        name
        (if (null? type-params) 'union 'parametric-union)
        (length type-params))
       (for ([member (in-list members)])
         (add! member 'union-member))]
      [(deferror-form name members _)
       (add! name 'throwable-union)
       (for ([member (in-list members)])
         (add! member 'throwable-member))]
      [(defscalar-form name _ _)
       (add! name 'scalar)]
      [(jst-declare-record name type-params _)
       (add! name 'js-wire-record (length type-params))]
      [(jst-declare-type name type)
       (add! name 'js-wire-alias 0 type)]
      [_ (void)]))
  (for ([(name expansion) (in-hash declared-type-aliases)])
    (add! name 'alias 0 expansion))
  exports)

(define (qualify-type-name namespace name)
  (string->symbol
   (string-append
    (symbol->string namespace)
    "/"
    (symbol->string name))))

(define (qualify-provider-local-type-references
         type namespace local-type-names)
  ;; Alias expansion is a public type boundary.  Bare provider-local names are
  ;; meaningful only while parsing the provider; once exported they must carry
  ;; the provider namespace so a consumer's own same-spelled type cannot capture
  ;; them.  Built-ins, type variables, and already-qualified/imported identities
  ;; remain unchanged.
  (define (qualify-local name)
    (if (set-member? local-type-names name)
        (qualify-type-name namespace name)
        name))
  (define (recur nested)
    (qualify-provider-local-type-references
     nested namespace local-type-names))
  (cond
    [(type-prim? type)
     (type-prim (qualify-local (type-prim-name type)))]
    [(type-var? type) type]
    [(type-foreign? type)
     (type-foreign/instantiated
      (type-foreign-interface-id type)
      (type-foreign-node-id type)
      (for/list
          ([substitution
            (in-list (type-foreign-substitutions type))])
        (cons (car substitution) (recur (cdr substitution)))))]
    [(type-app? type)
     (type-app
      (qualify-local (type-app-ctor type))
      (map recur (type-app-args type)))]
    [(type-union? type)
     (type-union (map recur (type-union-alts type)))]
    [(type-refinement? type)
     (type-refinement
      (recur (type-refinement-base type))
      (type-refinement-predicate type)
      (type-refinement-placement type))]
    [(type-fn? type)
     (type-fn
      (map recur (type-fn-params type))
      (and (type-fn-rest-type type)
           (recur (type-fn-rest-type type)))
      (recur (type-fn-ret type)))]
    [(type-poly? type)
     (define bounds (type-poly-bounds type))
     (define qualified
       (type-poly
        (type-poly-vars type)
        (recur (type-poly-body type))
        (and
         bounds
         (for/hasheq ([(name bound) (in-hash bounds)])
           (values name (recur bound))))))
     (set-type-poly-origin! qualified (type-poly-origin type))
     qualified]
    [else type]))

(define (qualify-interface-record-contract
         contract namespace local-type-names)
  (struct-copy
   interface-record-contract
   contract
   [fields
    (for/list ([field
                (in-list (interface-record-contract-fields contract))])
      (struct-copy
       param field
       [type
        (qualify-provider-local-type-references
         (param-interface-type field)
         namespace
         local-type-names)]))]))

(define (qualify-interface-param parameter namespace local-type-names)
  (if (param? parameter)
      (struct-copy
       param parameter
       [type
        (qualify-provider-local-type-references
         (param-interface-type parameter)
         namespace
         local-type-names)])
      parameter))

(define (qualify-interface-protocol-contract
         contract namespace local-type-names)
  (interface-protocol-contract
   (interface-protocol-contract-name contract)
   (for/hasheq
       ([(name method)
         (in-hash (interface-protocol-contract-methods contract))])
     (values
      name
      (interface-protocol-method-contract
       name
       (for/list
           ([param
             (in-list (interface-protocol-method-contract-params method))])
         (qualify-interface-param param namespace local-type-names))
       (and
        (interface-protocol-method-contract-rest-param method)
        (qualify-interface-param
         (interface-protocol-method-contract-rest-param method)
         namespace
         local-type-names))
       (qualify-provider-local-type-references
        (interface-protocol-method-contract-return-type method)
        namespace
        local-type-names)
       (interface-protocol-method-contract-effects method))))))

(define (qualify-interface-type-declaration
         declaration namespace local-type-names)
  (define details (interface-type-declaration-details declaration))
  (cond
    [(and (eq? (interface-type-declaration-kind declaration) 'js-wire-alias)
          (type? details))
     (struct-copy
      interface-type-declaration
      declaration
      [details
       (qualify-provider-local-type-references
        details namespace local-type-names)])]
    [(interface-protocol-contract? details)
     (struct-copy
      interface-type-declaration
      declaration
      [details
       (qualify-interface-protocol-contract
        details namespace local-type-names)])]
    [(interface-js-declaration-record? details)
     (struct-copy
      interface-type-declaration
      declaration
      [details
       (struct-copy
        interface-js-declaration-record
        details
        [fields
         (for/list
             ([field
               (in-list
                (interface-js-declaration-record-fields details))])
           (struct-copy
            interface-js-declaration-field
            field
            [type
             (qualify-provider-local-type-references
              (interface-js-declaration-field-type field)
              namespace
              local-type-names)]))])])]
    [else declaration]))

(define (qualify-interface-type-export export namespace local-type-names)
  (define expansion (interface-type-export-expansion export))
  (if (and (eq? (interface-type-export-kind export) 'js-wire-alias)
           (type? expansion))
      (struct-copy
       interface-type-export
       export
       [expansion
        (qualify-provider-local-type-references
         expansion namespace local-type-names)])
      export))

(define (canonical-exported-aliases
         namespace forms declared-type-aliases)
  (define local-type-names
    (and
     (symbol? namespace)
     (list->seteq
      (hash-keys
       (program-type-exports forms declared-type-aliases)))))
  (for/hasheq ([(name expansion) (in-hash declared-type-aliases)])
    (values
     name
     (if local-type-names
         (qualify-provider-local-type-references
          expansion namespace local-type-names)
         ;; Namespace-free graph modules cannot satisfy a namespace require, so
         ;; their aliases have no cross-module identity to qualify.
         expansion))))

(define (type->canonical-datum type)
  (cond
    [(not type) '(unknown)]
    [(type-prim? type) `(prim ,(type-prim-name type))]
    [(type-var? type) `(var ,(type-var-name type))]
    [(type-foreign? type)
     `(foreign
       ,(type-foreign-interface-id type)
       ,(type-foreign-node-id type)
       ,@(for/list
             ([substitution
               (in-list (type-foreign-substitutions type))])
           `(substitution
             ,(car substitution)
             ,(type->canonical-datum (cdr substitution)))))]
    [(type-meta? type)
     (error
      'program->module-interface
      "cannot publish unresolved inference metavariable in a module interface")]
    [(type-app? type)
     `(app ,(type-app-ctor type)
           ,@(map type->canonical-datum (type-app-args type)))]
    [(type-union? type)
     `(union ,@(map type->canonical-datum (type-union-alts type)))]
    [(type-refinement? type)
     `(refinement
       ,(type->canonical-datum (type-refinement-base type))
       ,(type-refinement-predicate type)
       ,(type-refinement-placement type))]
    [(type-fn? type)
     `(fn
       (params ,@(map type->canonical-datum (type-fn-params type)))
       (rest ,(type->canonical-datum (type-fn-rest-type type)))
       (return ,(type->canonical-datum (type-fn-ret type))))]
    [(type-poly? type)
     (define bounds (type-poly-bounds type))
     `(poly
       (vars
        ,@(for/list ([var (in-list (type-poly-vars type))])
            (list var
                  (and bounds
                       (hash-ref bounds var #f)
                       (type->canonical-datum (hash-ref bounds var))))))
       ,(type->canonical-datum (type-poly-body type)))]
    [else `(other ,(format "~s" type))]))

(define (canonical-sort-key datum)
  (call-with-output-string
   (lambda (out) (write datum out))))

;; Constraint expressions cross the module boundary as transparent AST, not as
;; formatted source.  The digest mirrors that structure recursively so a
;; predicate edit invalidates consumers without making whitespace significant.
(define (constraint->canonical-datum value)
  (cond
    [(type? value) `(type ,(type->canonical-datum value))]
    [(null? value) '(list)]
    [(char? value) `(char ,(char->integer value))]
    [(bytes? value) `(bytes ,@(bytes->list value))]
    [(or (symbol? value) (string? value) (number? value)
         (boolean? value) (keyword? value))
     value]
    [(pair? value)
     (if (list? value)
         `(list ,@(map constraint->canonical-datum value))
         `(pair ,(constraint->canonical-datum (car value))
                ,(constraint->canonical-datum (cdr value))))]
    [(vector? value)
     `(vector
       ,@(for/list ([item (in-vector value)])
           (constraint->canonical-datum item)))]
    [(hash? value)
     (define entries
       (for/list ([(key item) (in-hash value)])
         (list (constraint->canonical-datum key)
               (constraint->canonical-datum item))))
     `(hash
       ,@(sort entries string<?
               #:key (lambda (entry)
                       (canonical-sort-key (car entry)))))]
    [(struct? value)
     (define parts (vector->list (struct->vector value)))
     `(struct ,(car parts)
              ,@(map constraint->canonical-datum (cdr parts)))]
    [(void? value) '(void)]
    [else
     (error
      'program->module-interface
      "cannot publish unsupported value in binding constraint AST: ~v"
      value)]))

(define (interface-constraint->canonical-datum value)
  (cond
    [(not value) '(none)]
    [(interface-constraint? value)
     `(constraint
       (expression
        ,(constraint->canonical-datum
          (interface-constraint-expression value)))
       (synchronous ,(interface-constraint-synchronous? value))
       (provider ,(interface-constraint-provider value)))]
    ;; Fail closed in the digest for malformed hand-built schema-v5 values.
    [else
     `(invalid-constraint ,(constraint->canonical-datum value))]))

(define (field->canonical-datum field)
  (list (param-name field)
        (type->canonical-datum (param-interface-type field))
        (interface-constraint->canonical-datum
         (param-interface-constraint field))))

(define (protocol-method-contract->canonical-datum method)
  `(method
    ,(interface-protocol-method-contract-name method)
    (params
     ,@(map field->canonical-datum
            (interface-protocol-method-contract-params method)))
    (rest
     ,(and
       (interface-protocol-method-contract-rest-param method)
       (field->canonical-datum
        (interface-protocol-method-contract-rest-param method))))
    (return
     ,(type->canonical-datum
       (interface-protocol-method-contract-return-type method)))
    (effects
     ,(interface-protocol-method-contract-effects method))))

(define (type-declaration-details->canonical-datum declaration)
  (define details (interface-type-declaration-details declaration))
  (cond
    [(and (eq? (interface-type-declaration-kind declaration) 'js-wire-alias)
          (type? details))
     `(js-wire-alias ,(type->canonical-datum details))]
    [(interface-protocol-contract? details)
     `(protocol
       (name ,(interface-protocol-contract-name details))
       (methods
        ,@(for/list
              ([name
                (in-list
                 (sort
                  (hash-keys (interface-protocol-contract-methods details))
                  symbol<?))])
            (protocol-method-contract->canonical-datum
             (hash-ref
              (interface-protocol-contract-methods details)
             name)))))]
    [(interface-js-declaration-record? details)
     `(js-wire-record
       (type-params
        ,@(interface-js-declaration-record-type-params details))
       (fields
        ,@(for/list
              ([field
                (in-list
                 (interface-js-declaration-record-fields details))])
           (list
            (interface-js-declaration-field-name field)
            (type->canonical-datum
             (interface-js-declaration-field-type field))
            (interface-js-declaration-field-optional? field)))))]
    [else details]))

(define (require-entry->canonical-datum entry)
  (define bindings (require-entry-bindings entry))
  (define rename (import-bindings->rename bindings))
  `(require
    (identity
     ,(module-identity-kind (require-entry-identity entry))
     ,(module-identity-value (require-entry-identity entry)))
    (alias ,(require-entry-alias entry))
    (refer ,@(import-bindings->refer bindings))
    (rename
     ,@(for/list ([source (in-list (sort (hash-keys rename) symbol<?))])
         (list source (hash-ref rename source))))))

(define (interface-canonical-datum
         namespace target gen-class? bindings macro-fingerprints
         type-declarations type-exports record-contracts errors requires
         dynamic-vars public-esm-exports)
  `(module-interface
    (schema ,INTERFACE-SCHEMA-VERSION)
    (consumer-pruning-safe
     ,INTERFACE-DIGEST-CONSUMER-PRUNING-SAFE?)
    (namespace ,namespace)
    (target ,target)
    (gen-class ,gen-class?)
    (requires
     ,@(sort (map require-entry->canonical-datum requires)
             string<?
             #:key canonical-sort-key))
    (public-esm-exports
     ,@(for/list ([name (in-list (sort (hash-keys public-esm-exports)
                                        symbol<?))])
         (list name (hash-ref public-esm-exports name))))
    (bindings
     ,@(for/list ([name (in-list (sort (hash-keys bindings) symbol<?))])
         (define binding (hash-ref bindings name))
         (list name
               (interface-binding-kind binding)
               (type->canonical-datum (interface-binding-type binding))
               (type->canonical-datum (interface-binding-raises binding))
               (map interface-constraint->canonical-datum
                    (interface-binding-constraints binding))
               (interface-binding-synchronous? binding)
               (interface-binding-returns-synchronous-callable? binding)
               (interface-binding-effects binding)
               (and
                (interface-binding-js-declaration-type binding)
                (type->canonical-datum
                 (interface-binding-js-declaration-type binding))))))
    (macros
     ,@(for/list ([name (in-list (sort (hash-keys macro-fingerprints)
                                      symbol<?))])
         (list name (hash-ref macro-fingerprints name))))
    (dynamic-vars ,@(sort (set->list dynamic-vars) symbol<?))
    (types
     ,@(for/list
        ([name (in-list (sort (hash-keys type-declarations) symbol<?))])
         (define declaration (hash-ref type-declarations name))
         (list
          name
          (interface-type-declaration-kind declaration)
          (type-declaration-details->canonical-datum declaration))))
    (type-exports
     ,@(for/list
        ([name (in-list (sort (hash-keys type-exports) symbol<?))])
         (define export (hash-ref type-exports name))
         (list
          name
          (interface-type-export-kind export)
          (interface-type-export-arity export)
          (and
           (interface-type-export-expansion export)
           (type->canonical-datum
            (interface-type-export-expansion export))))))
    (record-contracts
     ,@(for/list
        ([name (in-list (sort (hash-keys record-contracts) symbol<?))])
         (define contract (hash-ref record-contracts name))
         (list
          name
          (interface-record-contract-kind contract)
          (interface-record-contract-validator-symbol contract)
          (map field->canonical-datum
               (interface-record-contract-fields contract)))))
    (errors
     ,@(for/list ([name (in-list (sort (hash-keys errors) symbol<?))])
         (define error (hash-ref errors name))
         (list
          name
          (for/list ([member (in-list (interface-error-members error))])
            (list
             member
             (map field->canonical-datum
                  (hash-ref
                   (interface-error-member-fields error)
                   member
                   '())))))))))

(define (sha256-datum datum)
  (define bytes
    (call-with-output-bytes
     (lambda (out)
       (parameterize ([current-output-port out])
         (write datum)))))
  (string-append "sha256:"
                 (bytes->hex-string (sha256-bytes bytes))))

;; Module-interface owns its consumer-visible semantic identity.  Front ends
;; supply public facts; this constructor binds those facts to the current
;; schema and canonical encoding.  Exact source/content identity stays in
;; source-digest and source-id; the overlay digest binds both layers.
(define (make-module-interface
         #:namespace namespace
         #:target target
         #:gen-class? gen-class?
         #:bindings bindings
         #:public-esm-exports public-esm-exports
         #:macros macros
         #:macro-fingerprints macro-fingerprints
         #:type-declarations type-declarations
         #:type-exports type-exports
         #:record-contracts record-contracts
         #:errors errors
         #:requires requires
         #:dynamic-vars dynamic-vars
         #:source-digest source-digest
         #:source-id source-id)
  (module-interface
   INTERFACE-SCHEMA-VERSION
   namespace
   target
   bindings
   public-esm-exports
   macros
   macro-fingerprints
   type-declarations
   type-exports
   record-contracts
   errors
   requires
   dynamic-vars
   (sha256-datum
    (interface-canonical-datum
     namespace
     target
     gen-class?
     bindings
     macro-fingerprints
     type-declarations
     type-exports
     record-contracts
     errors
     requires
     dynamic-vars
     public-esm-exports))
   source-digest
   source-id))

(define (type-facts-v1-export name)
  ;; type-facts-v1 also exposes source-facet parsing, which depends on this
  ;; module through parse.rkt. Load it only after interface publication is
  ;; executing so the existing parse/module-interface boundary stays acyclic.
  (dynamic-require 'beagle/private/type-facts-v1 name))

(define (emit-interface-evidence-v1!
         prog interface [implementation-interface-digest #f])
  (define make-interface-fact
    (type-facts-v1-export 'interface-publication-fact-v1))
  (define make-interface-revision-fact
    (type-facts-v1-export 'interface-revision-fact-v1))
  (define make-checker-fact
    (type-facts-v1-export 'checker-identity-fact-v1))
  (define make-conformance
    (type-facts-v1-export 'make-interface-conformance-v1))
  (define conformance-fact
    (type-facts-v1-export 'interface-conformance-v1-fact))
  (define conformance-derivation
    (type-facts-v1-export 'interface-conformance-v1-derivation))
  (define make-attestation
    (type-facts-v1-export 'make-attestation-v1))
  (define make-edge
    (type-facts-v1-export 'make-derivation-edge-v1))
  (define semantic-fact-id
    (type-facts-v1-export 'semantic-fact-v1-id))
  (define epoch
    (type-facts-v1-export 'current-type-facts-checker-epoch-v1))
  (define profile-for-target
    (type-facts-v1-export 'semantic-profile-v1-for-target))
  (define profile (profile-for-target (program-target prog)))
  (define subject (format "~a" (program-namespace prog)))
  (define claim-fact
    (make-interface-fact
     profile
     subject
     (module-interface-schema-version interface)
     (module-interface-target interface)
     (module-interface-digest interface)))
  (define local-definition-ids
    (hash-values (program-shadow-definition-fact-ids prog)))
  (define imported-interface-ids
    (for/list ([import (in-list (program-imported-module-interfaces prog))])
      (define imported (module-import-interface import))
      (semantic-fact-id
       (make-interface-revision-fact
        profile
        (format "~a" (module-interface-namespace imported))
        (module-interface-schema-version imported)
        (module-interface-target imported)
        (module-interface-digest imported)))))
  (define base-using
    (sort (append local-definition-ids imported-interface-ids) string<?))
  (define checker
    (semantic-fact-id
     (make-checker-fact profile "beagle/type-checker" "interface-publication")))
  (define conformance
    (and
     implementation-interface-digest
     (let* ([declared-revision
             (make-interface-revision-fact
              profile
              subject
              (module-interface-schema-version interface)
              (module-interface-target interface)
              (module-interface-digest interface))]
            [implementation-revision
             (make-interface-revision-fact
              profile
              subject
              (module-interface-schema-version interface)
              (module-interface-target interface)
              implementation-interface-digest)]
            [proof
             (make-conformance
              profile
              (vector "InterfaceConformanceSubjectV1"
                      subject
                      (module-interface-digest interface))
              (semantic-fact-id declared-revision)
              (semantic-fact-id implementation-revision)
              (make-checker-fact
               profile "beagle/type-checker" "interface-conformance")
              (vector))])
       (append-program-shadow-evidence-edge!
        prog (conformance-derivation proof))
       (hash-set! MODULE-INTERFACE->CONFORMANCE interface proof)
       proof)))
  (define using
    (if conformance
        (sort
         (cons (semantic-fact-id (conformance-fact conformance)) base-using)
         string<?)
        base-using))
  (define attestation
    (make-attestation
     (epoch)
     claim-fact
     "PASS"
     (hash 'seam "interface-publication"
           'using (list->vector using)
           'interface-digest (module-interface-digest interface))))
  (append-program-shadow-evidence-edge!
   prog
   (make-edge (semantic-fact-id claim-fact) checker using attestation))
  interface)

(define (program->module-interface prog
                                   #:source-id [source-id #f]
                                   #:provisional? [provisional? #f]
                                   #:capture-types? [capture-types? #f])
  (when capture-types?
    (ensure-program-read-receipt-table! prog))
  (define effective
    (publication-effective-definition-types prog provisional?))
  (define ast-bindings
    (ast-interface-bindings prog effective provisional?))
  (define bindings (hash-copy ast-bindings))
  (for ([(name binding)
         (in-hash (declared-interface-bindings prog))])
    (hash-set! bindings name binding))
  (define conformed-bindings
    (publication-conformed-bindings prog bindings provisional?))
  (define errors (program-errors prog provisional?))
  (define macros (program-interface-macros prog))
  (define macro-fingerprints (interface-macro-fingerprints macros))
  (define dynamic-vars (program-dynamic-vars prog))
  (define exported-aliases
    (canonical-exported-aliases
     (program-namespace prog)
     (program-forms prog)
     (program-declared-type-aliases prog)))
  (define type-declarations
    (program-type-declarations
     prog
     exported-aliases
     provisional?))
  (define raw-type-exports
    (program-type-exports
     (program-forms prog)
     exported-aliases))
  (define local-type-names (list->seteq (hash-keys raw-type-exports)))
  (define type-exports
    (for/hasheq ([(name export) (in-hash raw-type-exports)])
      (values
       name
       (qualify-interface-type-export
        export
        (program-namespace prog)
        local-type-names))))
  (define qualified-type-declarations
    (for/hasheq
        ([(name declaration) (in-hash type-declarations)])
      (values
       name
       (qualify-interface-type-declaration
        declaration
        (program-namespace prog)
        local-type-names))))
  (define record-contracts
    (for/hasheq
        ([(name contract)
          (in-hash (program-record-contracts prog provisional?))])
      (values
       name
       (qualify-interface-record-contract
        contract
        (program-namespace prog)
        local-type-names))))
  (define (qualify-bindings input)
    (for/hasheq ([(name binding) (in-hash input)])
      (values
       name
       (struct-copy
        interface-binding
        binding
        [type
         (qualify-provider-local-type-references
          (interface-binding-type binding)
          (program-namespace prog)
          local-type-names)]
        [js-declaration-type
         (and
          (interface-binding-js-declaration-type binding)
          (qualify-provider-local-type-references
           (interface-binding-js-declaration-type binding)
           (program-namespace prog)
           local-type-names))]))))
  (define qualified-candidate-bindings (qualify-bindings bindings))
  (define qualified-bindings (qualify-bindings conformed-bindings))
  (define public-esm-exports
    (public-esm-exports-for prog ast-bindings qualified-bindings))
  (define candidate-public-esm-exports
    (public-esm-exports-for prog ast-bindings qualified-candidate-bindings))
  (define canonical
    (interface-canonical-datum
     (program-namespace prog)
     (program-target prog)
     (program-gen-class? prog)
     qualified-bindings
     macro-fingerprints
     qualified-type-declarations
     type-exports
     record-contracts
     errors
     (program-requires prog)
     dynamic-vars
     public-esm-exports))
  (define implementation-canonical
    (and
     (not provisional?)
     (program-declared-module-contract prog)
     (interface-canonical-datum
      (program-namespace prog)
      (program-target prog)
      (program-gen-class? prog)
      qualified-candidate-bindings
      macro-fingerprints
      qualified-type-declarations
      type-exports
      record-contracts
      errors
      (program-requires prog)
      dynamic-vars
      candidate-public-esm-exports)))
  (define source-canonical
    `(module-program
      (interface ,canonical)
      (forms
       ,@(for/list ([stx (in-list (program-form-stxs prog))])
           (syntax->datum stx)))
      (imports ,@(program-imports prog))))
  (define interface
    (make-module-interface
     #:namespace (program-namespace prog)
     #:target (program-target prog)
     #:gen-class? (program-gen-class? prog)
     #:bindings qualified-bindings
     #:public-esm-exports public-esm-exports
     #:macros macros
     #:macro-fingerprints macro-fingerprints
     #:type-declarations qualified-type-declarations
     #:type-exports type-exports
     #:record-contracts record-contracts
     #:errors errors
     #:requires (program-requires prog)
     #:dynamic-vars dynamic-vars
     #:source-digest (sha256-datum source-canonical)
     #:source-id source-id))
  (register-module-interface-foreign-dependencies!
   interface
   (inherited-foreign-dependencies prog))
  (unless provisional?
    (emit-interface-evidence-v1!
     prog
     interface
     (and implementation-canonical
          (sha256-datum implementation-canonical))))
  (when capture-types?
    (define profile (semantic-profile-for-target (program-target prog)))
    (define members (sort (hash-keys qualified-bindings) symbol<?))
    (define semantic-id (module-interface-digest interface))
    (define compiler-inputs
      (hash 'source-id source-id
            'namespace (program-namespace prog)
            'target (program-target prog)
            'profile profile
            'interface source-canonical))
    (record-program-read-receipt!
     prog
     (make-read-receipt-v1
      'interface-publication
      (or source-id (symbol->string (program-namespace prog)))
      members
      'published
      profile
      (program-target prog)
      compiler-inputs
      #:semantic-fact-ids (list semantic-id)))
    (record-program-read-receipt!
     prog
     (make-read-receipt-v1
      'module-member-enumeration
      (list 'interface (program-namespace prog))
      members
      (list->vector members)
      profile
      (program-target prog)
      compiler-inputs
      #:semantic-fact-ids (list semantic-id))))
  interface)

(define (module-interface-export? interface name)
  (hash-has-key? (module-interface-bindings interface) name))

(define (module-interface-binding-ref interface name [failure #f])
  (hash-ref (module-interface-bindings interface) name failure))

(define (module-interface-public-esm-name interface name [failure #f])
  (hash-ref (module-interface-public-esm-exports interface) name failure))

(define (module-interface-type-export? interface name)
  (hash-has-key? (module-interface-type-exports interface) name))

(define (module-interface-type-export-ref interface name [failure #f])
  (hash-ref (module-interface-type-exports interface) name failure))

(define (module-interface-record-contract-ref interface name [failure #f])
  (hash-ref (module-interface-record-contracts interface) name failure))

(define (module-interface-record-validator-ref interface name [failure #f])
  (define contract
    (module-interface-record-contract-ref interface name #f))
  (if contract
      (interface-record-contract-validator-symbol contract)
      (if (procedure? failure) (failure) failure)))

(define (module-interface-protocol-contract-ref interface name [failure #f])
  (define declaration
    (hash-ref (module-interface-type-declarations interface) name #f))
  (define details
    (and declaration
         (eq? (interface-type-declaration-kind declaration) 'protocol)
         (interface-type-declaration-details declaration)))
  (if (interface-protocol-contract? details)
      details
      (if (procedure? failure) (failure) failure)))

(define (module-interface-protocol-method-contract-ref
         interface protocol-name method-name [failure #f])
  (define protocol
    (module-interface-protocol-contract-ref interface protocol-name #f))
  (if protocol
      (hash-ref
       (interface-protocol-contract-methods protocol)
       method-name
       failure)
      (if (procedure? failure) (failure) failure)))

(define (record-constructor-symbol name)
  (string->symbol (format "->~a" name)))

(define (import-local-for-source bindings source)
  (for/first ([binding (in-list bindings)]
              #:when (eq? source (import-binding-source binding)))
    (import-binding-local binding)))

(define (record-import-local bindings name)
  (or
   (import-local-for-source bindings name)
   ;; Preserve the pre-rename contract where an unrenamed constructor refer
   ;; also admits the provider's record name. A renamed constructor has no
   ;; principled record spelling; only an explicit record binding can name it.
   (let ([constructor (record-constructor-symbol name)])
     (and (eq? constructor
               (import-local-for-source bindings constructor))
          name))))

(define (record-contract-entry-for-import-source interface source)
  (define contracts (module-interface-record-contracts interface))
  (define direct (hash-ref contracts source #f))
  (if direct
      (cons source direct)
      (for/first ([(name contract) (in-hash contracts)]
                  #:when (eq? source (record-constructor-symbol name)))
        (cons name contract))))

;; Return the additional runtime imports needed by referred constrained-record
;; updates. Each binding maps the provider's private validator export to the
;; consumer-local validator spelling derived from that exact module import.
(define (program-record-validator-import-bindings prog import)
  (unless (and (module-import? import)
               (memq import (program-imported-module-interfaces prog)))
    (raise-arguments-error
     'program-record-validator-import-bindings
     "expected an exact module import owned by the program"
     "import" import))
  (define used-consumer-validators
    (for/seteq ([contract
                 (in-list
                  (semantic-contract-table-values
                   (program-semantic-contracts prog)))]
                #:when
                (and (record-update-contract? contract)
                     (symbol?
                      (record-update-contract-validator-symbol contract))))
      (record-update-contract-validator-symbol contract)))
  (define interface (module-import-interface import))
  (define bindings (module-import-bindings import))
  (define-values (_seen reversed)
    (for/fold ([seen (seteq)] [result '()])
              ([binding (in-list bindings)])
      (define entry
        (record-contract-entry-for-import-source
         interface (import-binding-source binding)))
      (cond
        [(not entry) (values seen result)]
        [(set-member? seen (car entry)) (values seen result)]
        [else
         (define name (car entry))
         (define contract (cdr entry))
         (define provider-validator
           (interface-record-contract-validator-symbol contract))
         (define local (record-import-local bindings name))
         (define consumer-validator
           (and local provider-validator (record-validator-symbol local)))
         (values
          (set-add seen name)
          (if (and consumer-validator
                   (set-member? used-consumer-validators consumer-validator))
              (cons
               (import-binding provider-validator consumer-validator)
               result)
              result))])))
  (reverse reversed))

(struct imported-record-resolution (contract qualifier local) #:transparent)

(define (program-protocol-contract-ref prog protocol-name [failure #f])
  (define local-contracts
    (program-protocol-contracts prog))
  (define local-namespace (program-namespace prog))
  (define found
    (or
     (for/first ([(name contract) (in-hash local-contracts)]
                 #:when
                 (or (eq? protocol-name name)
                     (eq? protocol-name
                          (qualify-type-name local-namespace name))))
       contract)
     (for*/first
         ([import (in-list (program-imported-module-interfaces prog))]
          [entry
           (in-value
            (let* ([interface (module-import-interface import)]
                   [prefix (module-import-prefix import)]
                   [namespace (module-interface-namespace interface)]
                   [bindings (module-import-bindings import)])
              (for/first
                  ([name
                    (in-list
                     (sort
                      (hash-keys
                       (module-interface-type-declarations interface))
                      symbol<?))]
                   #:when
                   (or
                    (eq? protocol-name (qualify-type-name prefix name))
                    (eq? protocol-name (qualify-type-name namespace name))
                    (eq? protocol-name
                         (import-local-for-source bindings name))))
                (module-interface-protocol-contract-ref
                 interface name #f))))]
          #:when entry)
       entry)))
  (if found
      found
      (if (procedure? failure) (failure) failure)))

(define (program-protocol-method-contract-ref
         prog protocol-name method-name [failure #f])
  (define protocol
    (program-protocol-contract-ref prog protocol-name #f))
  (if protocol
      (hash-ref
       (interface-protocol-contract-methods protocol)
       method-name
       failure)
      (if (procedure? failure) (failure) failure)))

;; Resolve the record-like declaration whose nominal spelling appears in a
;; checked consumer.  Interfaces remain the authority for imported records;
;; the returned constraint AST is contract metadata and must never be emitted
;; in the consumer's lexical scope.
(define (program-record-contract-resolution prog type-name)
  (define local-contracts (program-record-contracts prog))
  (define local-namespace (program-namespace prog))
  (or
   (for/first ([(name contract) (in-hash local-contracts)]
               #:when
               (or (eq? type-name name)
                   (eq? type-name (qualify-type-name local-namespace name))))
     (imported-record-resolution contract #f name))
   (for*/first
       ([import (in-list (program-imported-module-interfaces prog))]
        [entry
         (in-value
          (let* ([interface (module-import-interface import)]
                 [prefix (module-import-prefix import)]
                 [namespace (module-interface-namespace interface)]
                 [bindings (module-import-bindings import)])
            (for/first
                ([(name contract)
                  (in-hash (module-interface-record-contracts interface))]
                 #:when
                 (or (eq? type-name (qualify-type-name prefix name))
                     (eq? type-name (qualify-type-name namespace name))
                     (eq? type-name (record-import-local bindings name))))
              (define local (record-import-local bindings name))
              (imported-record-resolution
               contract
               ;; A referred record has a real final local even when its
               ;; canonical type is provider-qualified. Runtime contracts use
               ;; that local, and emitters synthesize the private validator as
               ;; one additional source-identical refer. Qualified-only uses
               ;; retain the authored/default require prefix.
               (and (not local) prefix)
               local))))]
        #:when entry)
     entry)))

(define (program-record-contract-ref prog type-name [failure #f])
  (define resolution (program-record-contract-resolution prog type-name))
  (if resolution
      (imported-record-resolution-contract resolution)
      (if (procedure? failure) (failure) failure)))

;; Returns the executable validator reference. Qualified imports retain their
;; use-site qualifier; referred imports derive a private consumer-local helper
;; name from the final record local so provider spellings never select imports.
(define (program-record-validator-ref prog type-name [failure #f])
  (define resolution (program-record-contract-resolution prog type-name))
  (cond
    [resolution
     (define validator
       (interface-record-contract-validator-symbol
        (imported-record-resolution-contract resolution)))
     (define qualifier (imported-record-resolution-qualifier resolution))
     (define local (imported-record-resolution-local resolution))
     (and validator
          (cond
            [qualifier (qualify-type-name qualifier validator)]
            [local (record-validator-symbol local)]
            [else validator]))]
    [else (if (procedure? failure) (failure) failure)]))

(define (program-record-runtime-name-ref prog type-name [failure #f])
  (define resolution (program-record-contract-resolution prog type-name))
  (cond
    [resolution
     (define name
       (interface-record-contract-name
        (imported-record-resolution-contract resolution)))
     (define qualifier (imported-record-resolution-qualifier resolution))
     (if qualifier
         (qualify-type-name qualifier name)
         (or (imported-record-resolution-local resolution) name))]
    [else (if (procedure? failure) (failure) failure)]))

(define (module-interfaces-overlay-digest interfaces)
  (sha256-datum
   `(module-overlay
     (interface-schema ,INTERFACE-SCHEMA-VERSION)
     ,@(for/list ([interface
                   (in-list
                    (sort interfaces
                          string<?
                          #:key
                          (lambda (candidate)
                            (format
                             "~s|~s"
                             (module-interface-namespace candidate)
                             (module-interface-source-id candidate)))))])
         (list
          (module-interface-source-id interface)
          (module-interface-source-digest interface)
          (module-interface-namespace interface)
          (module-interface-target interface)
          (module-interface-digest interface))))))

(provide
 INTERFACE-SCHEMA-VERSION
 INTERFACE-DIGEST-CONSUMER-PRUNING-SAFE?
 qualify-provider-local-type-references
 type->canonical-datum
 constraint->canonical-datum
 interface-constraint->canonical-datum
 record-validator-symbol
 make-module-interface
 program->module-interface
 module-interface-conformance
 module-interface-foreign-dependencies
 register-module-interface-foreign-dependencies!
 module-interface-export?
 module-interface-binding-ref
 module-interface-public-esm-name
 module-interface-type-export?
 module-interface-type-export-ref
 module-interface-record-contract-ref
 module-interface-record-validator-ref
 module-interface-protocol-contract-ref
 module-interface-protocol-method-contract-ref
 program-record-contract-ref
 program-record-validator-ref
 program-record-validator-import-bindings
 program-record-runtime-name-ref
 program-protocol-contract-ref
 program-protocol-method-contract-ref
 module-interfaces-overlay-digest
 normalize-canonical-libspec
 normalize-refer-global
 import-bindings->refer
 import-bindings->rename
 (struct-out interface-binding)
 (struct-out interface-macro)
 (struct-out interface-constraint)
 (struct-out interface-error)
 (struct-out interface-type-declaration)
 (struct-out interface-type-export)
 (struct-out interface-js-declaration-field)
 (struct-out interface-js-declaration-record)
 (struct-out interface-record-contract)
 (struct-out interface-protocol-method-contract)
 (struct-out interface-protocol-contract)
 (struct-out module-interface)
 (struct-out module-source)
 (struct-out import-binding)
 (struct-out module-import)
 (struct-out module-identity)
 (struct-out canonical-libspec)
 (struct-out canonical-global-refer))
