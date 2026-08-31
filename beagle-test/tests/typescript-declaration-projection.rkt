#lang racket/base

(require rackunit
         racket/list
         racket/runtime-path
         racket/string
         beagle/private/emit
         beagle/private/emit-typescript-declarations
         beagle/private/module-overlay-check
         beagle/private/module-source-root)

(define-runtime-path fixtures-dir "fixtures/typescript-declaration-projection")

(define provider-path (build-path fixtures-dir "provider.bjs"))
(define consumer-path (build-path fixtures-dir "consumer.bjs"))

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

(define (module-program namespace)
  (checked-overlay-module-program
   (findf (lambda (module)
            (eq? (checked-overlay-module-namespace module) namespace))
          (overlay-check-result-modules checked))))

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
                                "export type Label = string;"))
  (check-true (string-contains? provider-declarations
                                "export type Result = Accepted | Rejected;"))
  (check-true (string-contains? provider-declarations
                                "export interface PublicAccepted {\n  status: string;\n  note?: string;\n}"))
  (check-true (string-contains? provider-declarations
                                "export interface PublicRejected {\n  reason: string;\n}"))
  (check-true (string-contains? provider-declarations
                                "export type PublicResult = PublicAccepted | PublicRejected;"))
  (check-true (string-contains? provider-declarations
                                "export declare const LABELS: Array<string>;"))
  (check-true (string-contains? provider-declarations
                                "export declare function choose(arg0: Record<string, unknown>): PublicResult;"))
  (check-true (string-contains? provider-declarations
                                "export declare function choose(arg0: Record<string, unknown>, arg1: boolean): PublicResult;"))
  (for ([name (in-list '(PublicAccepted PublicRejected PublicResult))])
    (check-false
     (string-contains? provider-javascript (symbol->string name))))
  (check-false (regexp-match? #px"\\bany\\b" provider-declarations)))

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
