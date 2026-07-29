#lang racket/base

;; A checked module's public, cross-module contract.
;;
;; The parser historically re-read a required source file and scraped a subset
;; of its datums directly into the consumer's extern table.  That remains the
;; compatibility path for importing the full legacy surface, but coherent-world
;; checking needs a first-class boundary for facts that must never disappear:
;; the exact export set and typed-error effects.  This module owns that boundary
;; and its deterministic digest.

(require racket/list
         racket/match
         racket/port
         racket/set
         openssl/sha1
         "ast.rkt"
         "types.rkt")

(define INTERFACE-SCHEMA-VERSION 1)
(define ANY (type-prim 'Any))

(struct interface-binding (name kind type raises) #:transparent)
(struct interface-error (name members member-fields) #:transparent)
(struct interface-type-declaration (name kind details) #:transparent)
(struct module-interface
  (schema-version namespace target bindings macro-fingerprints
                  type-declarations errors requires digest source-digest source-id)
  #:transparent)

;; A resolver returns a module-source.  DATUMS are consumed by the compatibility
;; importer; INTERFACE is #f during the bootstrap parse and a module-interface
;; during the authoritative parse.
(struct module-source (namespace source-id stxs datums interface) #:transparent)

;; One consumer-side import of an interface.  PREFIX is the spelling accepted at
;; qualified use sites; REFER is #f or the explicitly referred symbol list.
(struct module-import (interface prefix refer) #:transparent)

(define (param-interface-type p)
  (cond
    [(param? p) (or (param-type p) ANY)]
    [(or (map-destructure? p) (seq-destructure? p)) ANY]
    [else ANY]))

(define (function-type params rest-param return-type)
  (type-fn (map param-interface-type params)
           (and rest-param (param-interface-type rest-param))
           (or return-type ANY)))

(define (record-bindings name fields kind)
  (define record-type (type-prim name))
  (define name-string (symbol->string name))
  (define lower-name (string-downcase name-string))
  (append
   (list
    (interface-binding
     (string->symbol (string-append "->" name-string))
     kind
     (type-fn (map param-interface-type fields) #f record-type)
     #f)
    ;; Clojure's defrecord also exposes map->Name.  It is not yet typed by the
    ;; legacy importer, but it is a real export and therefore must not be
    ;; rejected as missing.
    (interface-binding
     (string->symbol (string-append "map->" name-string))
     kind
     (type-fn (list ANY) #f record-type)
     #f))
   (for/list ([field (in-list fields)])
     (interface-binding
      (string->symbol
       (string-append lower-name "-" (symbol->string (param-name field))))
      'accessor
      (type-fn (list record-type) #f (param-interface-type field))
      #f))))

(define (unwrap-public-form form)
  (cond
    [(with-meta? form) (unwrap-public-form (with-meta-expr form))]
    [(jst-export? form) (unwrap-public-form (jst-export-form form))]
    [(jst-export-default? form)
     (unwrap-public-form (jst-export-default-form form))]
    [else form]))

(define (ast-interface-bindings forms)
  (define out (make-hasheq))
  (define (add! binding)
    (hash-set! out (interface-binding-name binding) binding))
  (define (add-record! name fields kind)
    (for ([binding (in-list (record-bindings name fields kind))])
      (add! binding)))
  (for ([raw-form (in-list forms)])
    (define form (unwrap-public-form raw-form))
    (match form
      [(def-form name type _ _ _)
       (add! (interface-binding name 'def (or type ANY) #f))]
      [(defonce-form name type _ _)
       (add! (interface-binding name 'defonce (or type ANY) #f))]
      [(defn-form name params rest-param return-type _ private? raises _)
       (unless private?
         (add!
          (interface-binding
           name 'defn (function-type params rest-param return-type) raises)))]
      [(defn-multi name arities private? _)
       (unless private?
         (define alternatives
           (for/list ([arity (in-list arities)])
             (function-type
              (arity-clause-params arity)
              (arity-clause-rest-param arity)
              (arity-clause-return-type arity))))
         (add!
          (interface-binding
           name
           'defn-multi
           (if (= (length alternatives) 1)
               (car alternatives)
               (type-union alternatives))
           #f)))]
      [(record-form name fields)
       (add-record! name fields 'record-constructor)]
      [(protocol-form _ methods)
       (for ([method (in-list methods)])
         (add!
          (interface-binding
           (protocol-method-name method)
           'protocol-method
           (function-type
            (protocol-method-params method)
            #f
            (protocol-method-return-type method))
           #f)))]
      [(defmulti-form name _)
       (add! (interface-binding name 'defmulti
                                (type-fn (list ANY) ANY ANY) #f))]
      [(defenum-form name _)
       (add!
        (interface-binding
         (string->symbol (string-append (symbol->string name) "-values"))
         'enum-values
         (type-app 'Set (list (type-prim name)))
         #f))]
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
        (interface-binding
         (string->symbol (string-append "->" name-string))
         'scalar-constructor
         (type-fn (list backing) #f scalar-type)
         #f))
       (add!
        (interface-binding
         (string->symbol
          (string-append (string-downcase name-string) "-value"))
         'scalar-accessor
         (type-fn (list scalar-type) #f backing)
         #f))]
      [_ (void)]))
  out)

(define (raw-interface-bindings datums)
  ;; Meta forms are absent from program-forms.  Keep their actual public names
  ;; in the exact export set so macro/extern use is not falsely rejected.
  (for/fold ([out (hasheq)]) ([datum (in-list datums)])
    (match datum
      [(list 'defmacro (? symbol? name) _ _)
       (hash-set out name
                 (interface-binding name 'macro ANY #f))]
      [(list 'define-macro _ (? symbol? name) _ ': _ _)
       (hash-set out name
                 (interface-binding name 'macro ANY #f))]
      [(list 'declare-extern (? symbol? name) type-expression)
       (hash-set out name
                 (interface-binding
                  name 'extern (parse-type type-expression) #f))]
      [(list 'declare-extern names-form type-expression)
       #:when (bracketed? names-form)
       (for/fold ([next out]) ([name (in-list (bracket-body names-form))])
         (hash-set next name
                   (interface-binding
                    name 'extern (parse-type type-expression) #f)))]
      [_ out])))

(define (raw-macro-fingerprints datums)
  (for/fold ([fingerprints (hasheq)])
            ([datum (in-list datums)])
    (match datum
      [(list 'defmacro (? symbol? name) _ _)
       (hash-set fingerprints name (sha256-datum datum))]
      [(list 'define-macro _ (? symbol? name) _ ': _ _)
       (hash-set fingerprints name (sha256-datum datum))]
      [_ fingerprints])))

(define (program-errors forms)
  (for/hasheq ([raw-form (in-list forms)]
               #:do [(define form (unwrap-public-form raw-form))]
               #:when (deferror-form? form))
    (values
     (deferror-form-name form)
     (interface-error
      (deferror-form-name form)
      (deferror-form-members form)
      (for/hasheq ([member (in-list (deferror-form-members form))])
        (values member
                (hash-ref (deferror-form-member-fields form) member '())))))))

(define (program-type-declarations forms)
  (for/fold ([declarations (hasheq)])
            ([raw-form (in-list forms)])
    (define form (unwrap-public-form raw-form))
    (define declaration
      (match form
        [(record-form name fields)
         (interface-type-declaration
          name 'record
          `(fields ,@(map field->canonical-datum fields)))]
        [(protocol-form name methods)
         (interface-type-declaration
          name 'protocol
          `(methods
            ,@(for/list ([method (in-list methods)])
                (list
                 (protocol-method-name method)
                 (type->canonical-datum
                  (function-type
                   (protocol-method-params method)
                   #f
                   (protocol-method-return-type method)))))))]
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
                     (if member-fields
                         (hash-ref member-fields member '())
                         '()))))))]
        [(deferror-form name members member-fields)
         (interface-type-declaration
          name 'throwable-union
          `(members
            ,(for/list ([member (in-list members)])
               (list
                member
                (map field->canonical-datum
                     (hash-ref member-fields member '()))))))]
        [(defscalar-form name backing-type predicates)
         (interface-type-declaration
          name 'scalar
          `(backing ,backing-type
            predicates
            ,(for/list ([predicate (in-list predicates)])
               (list
                (scalar-predicate-op predicate)
                (scalar-predicate-value predicate)))))]
        [_ #f]))
    (if declaration
        (hash-set
         declarations
         (interface-type-declaration-name declaration)
         declaration)
        declarations)))

(define (raw-type-declarations datums)
  ;; Type aliases erase during parsing, so retain their public expansion in the
  ;; interface directly from the canonical reader datum.
  (for/fold ([declarations (hasheq)])
            ([datum (in-list datums)])
    (match datum
      [(list 'defalias (? symbol? name) type-expression)
       (hash-set
        declarations
        name
        (interface-type-declaration
         name 'alias `(expansion ,type-expression)))]
      [_ declarations])))

(define (type->canonical-datum type)
  (cond
    [(not type) '(unknown)]
    [(type-prim? type) `(prim ,(type-prim-name type))]
    [(type-var? type) `(var ,(type-var-name type))]
    [(type-app? type)
     `(app ,(type-app-ctor type)
           ,@(map type->canonical-datum (type-app-args type)))]
    [(type-union? type)
     `(union ,@(map type->canonical-datum (type-union-alts type)))]
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

(define (field->canonical-datum field)
  (list (param-name field)
        (type->canonical-datum (param-interface-type field))))

(define (interface-canonical-datum
         namespace mode target gen-class? bindings macro-fingerprints
         type-declarations errors requires)
  `(module-interface
    (schema ,INTERFACE-SCHEMA-VERSION)
    (namespace ,namespace)
    (mode ,mode)
    (target ,target)
    (gen-class ,gen-class?)
    (requires
     ,@(for/list ([entry (in-list
                          (sort requires symbol<?
                                #:key require-entry-ns))])
         (list (require-entry-ns entry)
               (require-entry-alias entry)
               (require-entry-refer entry))))
    (bindings
     ,@(for/list ([name (in-list (sort (hash-keys bindings) symbol<?))])
         (define binding (hash-ref bindings name))
         (list name
               (interface-binding-kind binding)
               (type->canonical-datum (interface-binding-type binding))
               (type->canonical-datum (interface-binding-raises binding)))))
    (macros
     ,@(for/list ([name (in-list (sort (hash-keys macro-fingerprints)
                                      symbol<?))])
         (list name (hash-ref macro-fingerprints name))))
    (types
     ,@(for/list
        ([name (in-list (sort (hash-keys type-declarations) symbol<?))])
         (define declaration (hash-ref type-declarations name))
         (list
          name
          (interface-type-declaration-kind declaration)
          (interface-type-declaration-details declaration))))
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

(define (program->module-interface prog
                                   #:source-id [source-id #f]
                                   #:datums [datums '()])
  (define ast-bindings (ast-interface-bindings (program-forms prog)))
  (define bindings (hash-copy ast-bindings))
  (for ([(name binding) (in-hash (raw-interface-bindings datums))])
    (hash-set! bindings name binding))
  (define errors (program-errors (program-forms prog)))
  (define macro-fingerprints (raw-macro-fingerprints datums))
  (define type-declarations
    (for/fold
     ([declarations
       (program-type-declarations (program-forms prog))])
     ([(name declaration) (in-hash (raw-type-declarations datums))])
      (hash-set declarations name declaration)))
  (define canonical
    (interface-canonical-datum
     (program-namespace prog)
     (program-mode prog)
     (program-target prog)
     (program-gen-class? prog)
     bindings
     macro-fingerprints
     type-declarations
     errors
     (program-requires prog)))
  (module-interface
   INTERFACE-SCHEMA-VERSION
   (program-namespace prog)
   (program-target prog)
   bindings
   macro-fingerprints
   type-declarations
   errors
   (program-requires prog)
   (sha256-datum canonical)
   (sha256-datum `(module-source ,@datums))
   source-id))

(define (module-interface-export? interface name)
  (hash-has-key? (module-interface-bindings interface) name))

(define (module-interface-binding-ref interface name [failure #f])
  (hash-ref (module-interface-bindings interface) name failure))

(define (module-interfaces-world-digest interfaces)
  (sha256-datum
   `(module-world
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
 type->canonical-datum
 program->module-interface
 module-interface-export?
 module-interface-binding-ref
 module-interfaces-world-digest
 (struct-out interface-binding)
 (struct-out interface-error)
 (struct-out interface-type-declaration)
 (struct-out module-interface)
 (struct-out module-source)
 (struct-out module-import))
