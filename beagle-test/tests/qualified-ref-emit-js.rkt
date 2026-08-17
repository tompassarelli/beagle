#lang racket/base

(require rackunit
         rackunit/text-ui
         racket/string
         beagle/private/check
         beagle/private/emit
         beagle/private/module-interface
         beagle/private/parse
         (only-in beagle/private/tags BRACKET-TAG))

(define (br . items) (cons BRACKET-TAG items))

(define (checked-program datums #:resolver [resolver #f])
  (define prog
    (parse-program
     (map (lambda (datum) (datum->syntax #f datum)) datums)
     #:source-path "qualified-ref-emit-test.bjs"
     #:module-resolver resolver))
  (type-check! prog)
  prog)

(define (emit-checked datums #:resolver [resolver #f])
  (emit-program (checked-program datums #:resolver resolver)))

(define provider-datums
  (list '(ns model.provider)
        '(define-target js)
        `(defrecord Widget ,(br '(item Int)))))

(define provider-stxs
  (map (lambda (datum) (datum->syntax #f datum)) provider-datums))
(define provider-program
  (checked-program provider-datums))
(define provider-source
  (module-source
   'model.provider
   "model/provider.bjs"
   provider-stxs
   (program->module-interface
    provider-program #:source-id "model/provider.bjs")))

(define (provider-resolver namespace _importer)
  (and (eq? namespace 'model.provider) provider-source))

(run-tests
 (test-suite
  "qualified-ref JavaScript emission"

  (test-case "qualified import call and reference use structural members"
    (define emitted
      (emit-checked
       '((ns test.app)
         (define-target js)
         (require datascript :as ds)
         (def connection Any (ds/create-conn))
         (def constructor Any ds/connection-from-datoms))))
    (check-true (string-contains? emitted "ds.create_conn()"))
    (check-true
     (string-contains? emitted "ds.connection_from_datoms"))
    (check-false (string-contains? emitted "ds/")))

  (test-case "qualified constructors strip the leaf marker"
    (define emitted
      (emit-checked
       '((ns test.app)
         (define-target js)
         (require ir :as ir)
         (def program Any (ir/->IrProgram "test"))
         (def scene Any (js/new ir/Scene)))))
    (check-true (string-contains? emitted "ir.IrProgram(\"test\")"))
    (check-true (string-contains? emitted "new ir.Scene()")))

  (test-case "static calls render qualifier and leaf at output"
    (define emitted
      (emit-checked
       (list
        '(ns test.app)
        '(define-target js)
        `(declare-extern System/getProperty (Fn ,(br 'String) String))
        '(def home String (System/getProperty "user.home")))))
    (check-true
     (string-contains? emitted "System.getProperty(\"user.home\")")))

  (test-case "qualified regex special calls inspect the structural leaf"
    (define emitted
      (emit-checked
       '((ns test.app)
         (define-target js)
         (require clojure.string :as str)
         (def changed String
           (str/replace "aba" (re-pattern "a") "x"))
         (def pieces (Vec String)
           (str/split "a,b" (re-pattern ","))))))
    (check-true (string-contains? emitted "_r.flags.replace"))
    (check-true (string-contains? emitted "for (const _m of _s.matchAll")))

  (test-case "qualified record patterns use the structural leaf tag and fields"
    (define emitted
      (emit-checked
       (list
        '(ns test.app)
        '(define-target js)
        '(require model.provider :as model)
        `(defn item-of ,(br '(value Any)) Any
           (match value ,(br '(model/Widget item) 'item))))
       #:resolver provider-resolver))
    (check-true (string-contains? emitted "._tag === \"Widget\""))
    (check-true (string-contains? emitted ".item;"))
    (check-false (string-contains? emitted "model/Widget")))))
