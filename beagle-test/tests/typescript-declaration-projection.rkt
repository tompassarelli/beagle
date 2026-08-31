#lang racket/base

(require rackunit
         racket/list
         racket/runtime-path
         racket/string
         beagle/private/emit
         beagle/private/emit-typescript-declarations
         beagle/private/module-interface
         beagle/private/module-overlay-check
         beagle/private/module-source-root
         beagle/private/types)

(define-runtime-path fixtures-dir "fixtures/typescript-declaration-projection")

(define provider-path (build-path fixtures-dir "provider.bjs"))
(define consumer-path (build-path fixtures-dir "consumer.bjs"))
(define invalid-scalar-path
  (build-path fixtures-dir "invalid-scalar-narrowing.bjs"))

(define closure
  (resolve-module-source-closure
   (list
    (module-source-input "declarations/provider.bjs" provider-path)
    (module-source-input "declarations/consumer.bjs" consumer-path))
   '()))

(define checked
  (check-module-source-closure
   closure
   #:emit? #f
   #:capture-types? #t))

(unless (overlay-check-result-ok? checked)
  (error 'typescript-declaration-projection
         "~a"
         (string-join
          (map overlay-diagnostic-message
               (overlay-check-result-diagnostics checked))
          "\n")))

(define (checked-module namespace)
   (findf (lambda (module)
            (eq? (checked-overlay-module-namespace module) namespace))
          (overlay-check-result-modules checked)))

(define (module-program namespace)
  (checked-overlay-module-program (checked-module namespace)))

(define provider-interface
  (checked-overlay-module-interface
   (checked-module 'declarations.provider)))

(define provider-declarations
  (emit-typescript-declarations
   (module-program 'declarations.provider)
   #:source-id "declarations/provider.bjs"))

(define provider-javascript
  (emit-program (module-program 'declarations.provider)))

(define consumer-declarations
  (emit-typescript-declarations
   (module-program 'declarations.consumer)
   #:source-id "declarations/consumer.bjs"))

(test-case "checked JS interface projects deterministic declarations"
  (check-equal?
   provider-declarations
   (emit-typescript-declarations
    (module-program 'declarations.provider)
    #:source-id "declarations/provider.bjs"))
  (check-true (string-contains? provider-declarations
                                "export interface Draft {\n  id: string;\n  tags: Array<string>;\n}"))
  (check-true (string-contains? provider-declarations
                                "export type Result = Accepted | Rejected;"))
  (check-true (string-contains? provider-declarations
                                "export interface PublicAccepted {\n  status: \"accepted\";\n  note?: string;\n}"))
  (check-true (string-contains? provider-declarations
                                "export interface PublicRejected {\n  status: \"rejected\";\n  reason: string;\n}"))
  (check-true (string-contains? provider-declarations
                                "export type PublicLabel = \"one\" | \"two\";"))
  (check-true (string-contains? provider-declarations
                                "export interface PublicDraft {\n  id: string;\n  label: PublicLabel;\n}"))
  (check-true (string-contains? provider-declarations
                                "export type PublicResult = PublicAccepted | PublicRejected;"))
  (check-true (string-contains? provider-declarations
                                "export declare const LABELS: Array<string>;"))
  (check-true (string-contains? provider-declarations
                                "export declare function choose(arg0: PublicDraft): PublicResult;"))
  (check-true (string-contains? provider-declarations
                                "export declare function choose(arg0: PublicDraft, arg1: boolean): PublicResult;"))
  (check-true (string-contains? provider-declarations
                                "export declare function maybeLabel(arg0?: string): string | undefined;"))
  (for ([name (in-list '(PublicAccepted PublicRejected PublicDraft
                         PublicLabel PublicResult))])
    (check-false
     (string-contains? provider-javascript (symbol->string name))))
  (check-false (regexp-match? #px"\\bany\\b" provider-declarations)))

(test-case "declaration-only wire refinement preserves provider runtime semantics"
  (define choose
    (module-interface-binding-ref provider-interface 'choose))
  (define runtime-type (interface-binding-type choose))
  (define declaration-type
    (interface-binding-js-declaration-type choose))
  (check-true (type-union? runtime-type))
  (check-true (type-union? declaration-type))
  (for ([function (in-list (type-union-alts runtime-type))])
    (check-equal? (car (type-fn-params function)) (type-prim 'JsObject))
    (check-equal? (type-fn-ret function) (type-prim 'JsObject)))
  (check-true
   (string-contains?
    consumer-declarations
    "export declare function forward(arg0: import(\"./provider.js\").PublicDraft): import(\"./provider.js\").PublicResult;"))
  (check-true
   (string-contains?
    consumer-declarations
    "export interface ForwardedLabel {\n  label: import(\"./provider.js\").PublicLabel;\n}")))

(test-case "imported Beagle type identity becomes a relative type import"
  (check-true
   (string-contains?
    consumer-declarations
    "export type ImportedResult = import(\"./provider.js\").Result;"))
  (check-true
   (string-contains?
    consumer-declarations
    "export declare function echo(arg0: import(\"./provider.js\").Result): import(\"./provider.js\").Result;"))
  (check-false (regexp-match? #px"\\bany\\b" consumer-declarations)))

(test-case "JsObject declaration refinement rejects non-wire scalar aliases"
  (check-exn
   #rx"may narrow only JsObject positions to checked JavaScript wire declarations"
   (lambda ()
     (check-module-source-closure
      (resolve-module-source-closure
       (list
        (module-source-input
         "declarations/invalid-scalar-narrowing.bjs"
         invalid-scalar-path))
       '())
      #:emit? #f
      #:capture-types? #t))))
