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

(define (br . xs) (cons '#%brackets xs))
(define (mt . xs) (cons '#%map xs))

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
        (list '(defn add [(x #%: Int) (y #%: Int)] -> Int (+ x y))
              '(println (add 20 22)))))
     (check-true (string-contains? output "function add(x: number, y: number): number {"))
     (check-true (string-contains? output "return (x + y);"))
     (check-true (string-contains? output "console.log(add(20, 22));")))
   (test-case "unsupported top-level forms reject pointedly"
     (check-exn #rx"experimental scriptc supports defn and calls only"
                (lambda ()
                  (scriptc-emit
                   (list '(def answer #%: Int 42))))))
   (test-case "F64-backed boundaries reject fixed-width types and preserve null"
     (for ([type-name (in-list '(I8 I16 I32 U8 U16 U32 U64 F32))])
       (check-exn
        (regexp
         (format "unsupported fixed-width boundary type ~a.*F64-backed"
                 type-name))
        (lambda ()
          (scriptc-emit
           (list
            `(defn identity-fixed [(x #%: ,type-name)]
               -> ,type-name
               x))))))
     (define output
       (scriptc-emit
        (list '(defn nil-value [(x #%: Nil)] -> Nil nil))))
     (check-true (string-contains? output
                                   "function nil_value(x: null): null {"))
     (check-true (string-contains? output "return null;")))
   (test-case "JS-family target-case selects the actual target"
     (define forms
       (list '(defn target-name [] -> String
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
                          '-> 'Any
                          'x))))))
   ;; Regression: annotation used to be a whole-output regexp, so a string
   ;; literal that merely LOOKED like a declaration was rewritten instead of the
   ;; declaration itself — leaving the real function untyped (TS7006 under
   ;; strict TypeScript). Annotation is now structural, at the defn node.
   (test-case "function-like strings stay byte-stable and the real declaration is typed"
     (define output
       (scriptc-emit
        (list '(println "function add(x) {")
              '(defn add [(x #%: Int)] -> Int x))))
     (check-true (string-contains? output "console.log(\"function add(x) {\");")
                 (format "string literal must be emitted verbatim in:\n~a" output))
     (check-true (string-contains? output "function add(x: number): number {")
                 (format "the actual declaration must be typed in:\n~a" output))
     (check-false (string-contains? output "console.log(\"function add(x: number)")
                  (format "string literal must NOT be annotated in:\n~a" output))
     (check-false (regexp-match? #rx"\nfunction add\\(x\\) \\{" output)
                  (format "no untyped declaration may survive in:\n~a" output)))

   ;; A declaration-shaped string AFTER the defn pins the other regexp ordering.
   (test-case "function-like strings after the declaration are also byte-stable"
     (define output
       (scriptc-emit
        (list '(defn add [(x #%: Int)] -> Int x)
              '(println "function add(x) {"))))
     (check-true (string-contains? output "console.log(\"function add(x) {\");"))
     (check-true (string-contains? output "function add(x: number): number {")))

   (test-case "ordinary JS emission is unchanged by the scriptc signature seam"
     (define output
       (target-emit 'js
                    (list '(println "function add(x) {")
                          '(defn add [(x #%: Int)] -> Int x))))
     (check-true (string-contains? output "console.log(\"function add(x) {\");"))
     (check-true (string-contains? output "function add(x) {\n  return x;\n}")
                 (format "JS defn must stay untyped and byte-stable in:\n~a" output))
     (check-false (string-contains? output ": number")
                  (format "JS output must carry no TypeScript annotation in:\n~a" output)))

   (test-case "nested/rest/default/destructured/catch boundaries are fully annotated"
     (define map-param
       (mt ':keys (br 'x) ':or (mt 'x 1)))
     (define seq-param (br 'head '& 'tail))
     (define output
       (scriptc-emit
        (list
         (list 'defn 'exercise (br) '-> 'Int
               (list
                'let
                (br
                 'variadic
                 (list 'fn (br 'n ANN-MARKER 'Int '& 'more ANN-MARKER 'Int)
                       '-> 'Int 'n)
                 'defaulted
                 (list 'fn (br map-param) '-> 'Int 'x)
                 'sequenced
                 (list 'fn (br seq-param) '-> 'Any 'head))
                (list 'try
                      (list 'variadic 1)
                      (list 'catch 'Exception 'err
                            (list 'defaulted (mt ':x 3)))))))))
     (for ([expected
            (in-list
             '("(n: number, ...more: (number)[]): number =>"
               "({x = 1}: { x?: number }): number =>"
               "([head, ...tail]: unknown[]): unknown =>"
               "catch (_caught) {"
               "const err: Error = _caught as Error;"))])
       (check-true (string-contains? output expected)
                   (format "expected ~v in:\n~a" expected output)))
     (for ([forbidden (in-list '("(n) =>" "...more) =>" "catch (err)"))])
       (check-false (string-contains? output forbidden)
                    (format "unannotated boundary ~v survived in:\n~a"
                            forbidden output))))

   (test-case "declare-extern renders one module-local ambient declaration"
     (define output
       (scriptc-emit
        (list `(declare-extern host-parse ,(br 'String '-> 'Int))
              '(defn parse-or-zero [(s #%: String)] -> Int (host-parse s))
              '(println (parse-or-zero "17")))))
     (check-true
      (string-prefix? output
                      "export {};\ndeclare function host_parse(_arg0: string): number;\n")
      (format "ambient declarations must precede executable statements:\n~a" output))
     (check-equal? (length (regexp-match* #rx"declare function host_parse" output)) 1))

   (test-case "ScriptC str avoids String.prototype.concat while JS stays byte-stable"
     (define forms
       (list '(println (str "beagle" "-" "scriptc"))))
     (define scriptc-output (scriptc-emit forms))
     (define js-output (target-emit 'js forms))
     (check-true
      (string-contains? scriptc-output
                        "console.log((\"\" + \"beagle\" + \"-\" + \"scriptc\"));"))
     (check-false (string-contains? scriptc-output ".concat("))
     (check-true
      (string-contains? js-output
                        "console.log((\"\".concat(\"beagle\", \"-\", \"scriptc\")));")))

   (test-case "defn-only ScriptC modules export their public bindings"
     (define output
       (scriptc-emit
        (list '(defn triple [(n #%: Int)] -> Int (* n 3)))))
     (check-true
      (string-contains? output
                        "export function triple(n: number): number {")))

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
