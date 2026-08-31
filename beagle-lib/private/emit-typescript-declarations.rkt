#lang racket/base

;; Deterministic TypeScript declarations projected from a checked JS module
;; interface. The module interface remains the sole public type authority.

(require racket/list
         racket/match
         racket/string
         "ast.rkt"
         "js-emit-utils.rkt"
         "module-interface.rkt"
         "types.rkt")

(define numeric-primitives
  '(Int Float U8 U16 U32 U64 I8 I16 I32 F32))

(define (typescript-identifier? value)
  (regexp-match? #px"^[A-Za-z_$][A-Za-z0-9_$]*$" value))

(define (require-typescript-identifier who value)
  (define text (if (symbol? value) (symbol->string value) value))
  (unless (and (string? text) (typescript-identifier? text))
    (error who "unsupported TypeScript declaration identifier: ~v" value))
  text)

(define (relative-js-module-path importer-ns imported-ns)
  (define importer-parts (string-split importer-ns "."))
  (define importer-directory
    (if (null? importer-parts)
        '()
        (drop-right importer-parts 1)))
  (define imported-parts (string-split imported-ns "."))
  (let loop ([directory importer-directory] [target imported-parts])
    (if (and (pair? directory)
             (pair? target)
             (string=? (car directory) (car target)))
        (loop (cdr directory) (cdr target))
        (let* ([parents (map (lambda (_) "..") directory)]
               [parts (append parents target)]
               [path (string-append (string-join parts "/") ".js")])
          (if (string-prefix? path "..")
              path
              (string-append "./" path))))))

(define (qualified-type-name value)
  (and
   (symbol? value)
   (match (regexp-match #px"^(.+)/([^/]+)$" (symbol->string value))
     [(list _ namespace name) (cons namespace name)]
     [_ #f])))

(define (js-string-literal-value type)
  (and
   (type-refinement? type)
   (eq? (type-refinement-placement type) 'js-declaration)
   (match (type-refinement-predicate type)
     [(list 'js/literal (? string? value)) value]
     [_ #f])))

(define (js-optional-base type)
  (and (type-refinement? type)
       (eq? (type-refinement-placement type) 'js-declaration)
       (eq? (type-refinement-predicate type) 'js/optional)
       (type-refinement-base type)))

(define (make-type-renderer interface)
  (define current-namespace
    (symbol->string (module-interface-namespace interface)))

  (define (render-primitive name)
    (define qualified (qualified-type-name name))
    (cond
      [qualified
       (define namespace (car qualified))
       (define local-name
         (require-typescript-identifier
          'beagle-dts
          (cdr qualified)))
       (if (string=? namespace current-namespace)
           local-name
           (format "import(~s).~a"
                   (relative-js-module-path current-namespace namespace)
                   local-name))]
      [(eq? name 'Any)
       (error 'beagle-dts
              "refusing to emit TypeScript declarations containing Beagle Any")]
      [(eq? name 'String) "string"]
      [(memq name numeric-primitives) "number"]
      [(eq? name 'Bool) "boolean"]
      [(eq? name 'Nil) "null"]
      [(memq name '(Keyword Symbol)) "string"]
      [(memq name '(Regex RegExp)) "RegExp"]
      [(eq? name 'JsObject) "Record<string, unknown>"]
      [(eq? name 'JsArray) "Array<unknown>"]
      [else (require-typescript-identifier 'beagle-dts name)]))

  (define (render-function type)
    (format
     "(~a) => ~a"
     (string-join
      (for/list ([parameter (in-list (type-fn-params type))]
                 [index (in-naturals)])
        (define optional-base (js-optional-base parameter))
        (format "arg~a~a: ~a"
                index
                (if optional-base "?" "")
                (render-type (or optional-base parameter))))
      ", ")
     (render-type (type-fn-ret type))))

  (define (render-type type)
    (cond
      [(type-prim? type) (render-primitive (type-prim-name type))]
      [(type-var? type)
       (require-typescript-identifier 'beagle-dts (type-var-name type))]
      [(type-refinement? type)
       (cond
         [(js-string-literal-value type) => js-string-lit]
         [(js-optional-base type)
          => (lambda (base)
               (format "~a | undefined" (render-type base)))]
         [else (render-type (type-refinement-base type))])]
      [(type-fn? type) (render-function type)]
      [(type-app? type)
       (define constructor (type-app-ctor type))
       (define arguments (type-app-args type))
       (case constructor
         [(Vec List Arr TransientVec)
          (unless (= (length arguments) 1)
            (error 'beagle-dts "~a expects one type argument" constructor))
          (format "Array<~a>" (render-type (car arguments)))]
         [(HVec)
          (format "[~a]" (string-join (map render-type arguments) ", "))]
         [(Set Promise)
          (unless (= (length arguments) 1)
            (error 'beagle-dts "~a expects one type argument" constructor))
          (format "~a<~a>" constructor (render-type (car arguments)))]
         [(Map JsMap)
          (unless (= (length arguments) 2)
            (error 'beagle-dts "~a expects two type arguments" constructor))
          (format "Map<~a, ~a>"
                  (render-type (car arguments))
                  (render-type (cadr arguments)))]
         [else
          (format "~a<~a>"
                  (render-primitive constructor)
                  (string-join (map render-type arguments) ", "))])]
      [(type-union? type)
       (define rendered
         (remove-duplicates
          (for/list ([alternative (in-list (type-union-alts type))])
            (define value (render-type alternative))
            (if (type-fn? alternative) (format "(~a)" value) value))
          string=?))
       (string-join rendered " | ")]
      [(type-poly? type)
       (error 'beagle-dts
              "polymorphic TypeScript declaration projection is not yet supported")]
      [(type-foreign? type)
       (error 'beagle-dts
              "foreign declaration graph types are outside the native .bjs projection")]
      [(type-meta? type)
       (error 'beagle-dts
              "refusing to emit an unresolved inference metavariable")]
      [else (error 'beagle-dts "unsupported Beagle type: ~v" type)]))

  render-type)

(define (function-alternatives type)
  (cond
    [(type-fn? type) (list type)]
    [(and (type-union? type)
          (andmap type-fn? (type-union-alts type)))
     (type-union-alts type)]
    [else #f]))

(define (declaration-fields interface name)
  (define contract
    (module-interface-record-contract-ref interface name #f))
  (unless contract
    (error 'beagle-dts "record ~a has no checked interface contract" name))
  (interface-record-contract-fields contract))

(define (emit-record-declaration interface render-type name)
  (define rendered-name
    (require-typescript-identifier 'beagle-dts name))
  (define fields
    (for/list ([field (in-list (declaration-fields interface name))])
      (define field-name (symbol->string (param-name field)))
      (format "  ~a: ~a;"
              (if (typescript-identifier? field-name)
                  field-name
                  (format "~s" field-name))
              (render-type (param-type field)))))
  (string-append
   "export interface " rendered-name " {"
   (if (null? fields) "" (string-append "\n" (string-join fields "\n")))
   (if (null? fields) "}" "\n}")))

(define (emit-wire-record-declaration render-type name fields)
  (define rendered-name
    (require-typescript-identifier 'beagle-dts name))
  (define rendered-fields
    (for/list ([field (in-list fields)])
      (define field-name
        (symbol->string (interface-js-declaration-field-name field)))
      (format "  ~a~a: ~a;"
              (if (typescript-identifier? field-name)
                  field-name
                  (format "~s" field-name))
              (if (interface-js-declaration-field-optional? field) "?" "")
              (render-type
               (interface-js-declaration-field-type field)))))
  (string-append
   "export interface " rendered-name " {"
   (if (null? rendered-fields)
       ""
       (string-append "\n" (string-join rendered-fields "\n")))
   (if (null? rendered-fields) "}" "\n}")))

(define (union-details declaration)
  (match (interface-type-declaration-details declaration)
    [(list 'type-params type-params 'members members)
     (values type-params members)]
    [details
     (error 'beagle-dts "unsupported union interface details: ~v" details)]))

(define (emit-type-declaration interface render-type declaration)
  (define name (interface-type-declaration-name declaration))
  (define rendered-name
    (require-typescript-identifier 'beagle-dts name))
  (case (interface-type-declaration-kind declaration)
    [(alias)
     (define exported
       (module-interface-type-export-ref interface name #f))
     (unless (and exported (interface-type-export-expansion exported))
       (error 'beagle-dts "alias ~a has no checked expansion" name))
     (format "export type ~a = ~a;"
             rendered-name
             (render-type (interface-type-export-expansion exported)))]
    [(js-wire-alias)
     (format "export type ~a = ~a;"
             rendered-name
             (render-type
              (interface-type-declaration-details declaration)))]
    [(record)
     (emit-record-declaration interface render-type name)]
    [(js-wire-record)
     (emit-wire-record-declaration
      render-type
      name
      (interface-type-declaration-details declaration))]
    [(union)
     (define-values (type-params members) (union-details declaration))
     (unless (null? type-params)
       (error 'beagle-dts
              "parametric union projection is not yet supported: ~a"
              name))
     (for ([member (in-list members)])
       (unless (and (list? member) (= (length member) 2) (null? (cadr member)))
         (error 'beagle-dts
                "inline union member projection is not yet supported: ~v"
                member)))
     (format "export type ~a = ~a;"
             rendered-name
             (string-join
              (for/list ([member (in-list members)])
                (require-typescript-identifier 'beagle-dts (car member)))
              " | "))]
    [else
     (error 'beagle-dts
            "unsupported checked type declaration kind ~a for ~a"
            (interface-type-declaration-kind declaration)
            name)]))

(define (emit-value-declaration render-type public-name binding)
  (define name
    (require-typescript-identifier 'beagle-dts public-name))
  (define type
    (or (interface-binding-js-declaration-type binding)
        (interface-binding-type binding)))
  (define functions (function-alternatives type))
  (if functions
      (string-join
       (for/list ([function (in-list functions)])
         (format
          "export declare function ~a(~a): ~a;"
          name
          (string-join
           (for/list ([parameter (in-list (type-fn-params function))]
                      [index (in-naturals)])
             (define optional-base (js-optional-base parameter))
             (format "arg~a~a: ~a"
                     index
                     (if optional-base "?" "")
                     (render-type (or optional-base parameter))))
           ", ")
          (render-type (type-fn-ret function))))
       "\n")
      (format "export declare const ~a: ~a;" name (render-type type))))

(define (emit-typescript-declarations/interface interface)
  (unless (eq? (module-interface-target interface) 'js)
    (error 'beagle-dts
           "TypeScript declarations require a checked beagle/js module, got ~a"
           (module-interface-target interface)))
  (define render-type (make-type-renderer interface))
  (define type-declarations
    (for/list ([name (in-list
                      (sort
                       (hash-keys (module-interface-type-declarations interface))
                       symbol<?))])
      (emit-type-declaration
       interface
       render-type
       (hash-ref (module-interface-type-declarations interface) name))))
  (define value-declarations
    (for/list ([local-name
                (in-list
                 (sort
                  (hash-keys (module-interface-public-esm-exports interface))
                  symbol<?))])
      (define binding
        (module-interface-binding-ref interface local-name #f))
      (unless binding
        (error 'beagle-dts
               "public ESM export ~a has no checked interface binding"
               local-name))
      (emit-value-declaration
       render-type
       (hash-ref (module-interface-public-esm-exports interface) local-name)
       binding)))
  (define sections
    (filter (lambda (section) (not (null? section)))
            (list type-declarations value-declarations)))
  (string-append
   (string-join
    (for/list ([section (in-list sections)])
      (string-join section "\n\n"))
    "\n\n")
   "\n"))

(define (emit-typescript-declarations program #:source-id [source-id #f])
  (emit-typescript-declarations/interface
   (program->module-interface program #:source-id source-id)))

(provide emit-typescript-declarations
         emit-typescript-declarations/interface)
