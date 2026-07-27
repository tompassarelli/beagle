#lang racket/base

(require rackunit
         rackunit/text-ui
         racket/string
         racket/file
         racket/runtime-path
         (file "../../beagle-lib/private/parse.rkt")
         (file "../../beagle-lib/private/check.rkt")
         (file "../../beagle-lib/private/emit.rkt"))

(define-runtime-path self-host-readme "../../self-host/README.md")

(define (target-emit target forms)
  (define prog
    (parse-program
     (map (lambda (form) (datum->syntax #f form))
          (append
           (list '(ns smoke.main) '(define-mode strict)
                 `(define-target ,target))
           forms))
                   #:source-path "smoke.bsc"))
  (type-check! prog)
  (emit-program prog))

(define (scriptc-emit forms)
  (target-emit 'scriptc forms))

(run-tests
 (test-suite "scriptc emitter"
   (test-case "typed arithmetic and console log retain TypeScript boundaries"
     (define output
       (scriptc-emit
        (list '(defn add [(x :- Int) (y :- Int)] :- Int (+ x y))
              '(println (add 20 22)))))
     (check-true (string-contains? output "function add(x: number, y: number): number {"))
     (check-true (string-contains? output "return (x + y);"))
     (check-true (string-contains? output "console.log(add(20, 22));")))
   (test-case "unsupported top-level forms reject pointedly"
     (check-exn #rx"experimental scriptc supports defn and calls only"
                (lambda ()
                  (scriptc-emit
                   (list '(def answer :- Int 42))))))
   (test-case "F64-backed boundaries reject fixed-width types and preserve null"
     (for ([type-name (in-list '(I8 I16 I32 U8 U16 U32 U64 F32))])
       (check-exn
        (regexp
         (format "unsupported fixed-width boundary type ~a.*F64-backed"
                 type-name))
        (lambda ()
          (scriptc-emit
           (list
            `(defn identity-fixed [(x :- ,type-name)]
               :- ,type-name
               x))))))
     (define output
       (scriptc-emit
        (list '(defn nil-value [(x :- Nil)] :- Nil nil))))
     (check-true (string-contains? output
                                   "function nil_value(x: null): null {"))
     (check-true (string-contains? output "return null;")))
   (test-case "JS-family target-case selects the actual target"
     (define forms
       (list '(defn target-name [] :- String
                (target-case :js "js" :scriptc "scriptc"))))
     (define scriptc-output (scriptc-emit forms))
     (define js-output (target-emit 'js forms))
     (check-true (string-contains? scriptc-output "return \"scriptc\";"))
     (check-false (string-contains? scriptc-output "return \"js\";"))
     (check-true (string-contains? js-output "return \"js\";"))
     (check-false (string-contains? js-output "return \"scriptc\";")))
   (test-case "destructuring rejects with the scriptc diagnostic"
     (define map-param
       (list '#%map ':keys (cons '#%brackets '(x))))
     (check-exn #rx"unsupported destructuring parameter in take-x"
                (lambda ()
                  (scriptc-emit
                   (list
                    (list 'defn 'take-x
                          (cons '#%brackets (list map-param))
                          ':- 'Any
                          'x))))))
   (test-case "self-host Known gaps records scriptc as oracle-only"
     (define readme (file->string self-host-readme))
     (check-true
      (regexp-match?
       #rx"experimental `scriptc` target is therefore oracle-only"
       readme))
     (check-true
      (regexp-match?
       #rx"self-host has no `scriptc` parser, checker, or emitter route"
       readme)))))
