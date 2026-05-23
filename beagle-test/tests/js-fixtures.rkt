#lang racket/base

;; .bjs fixture coverage. Each fixture exercises a different surface
;; corner of the JS target.

(require rackunit
         racket/string
         racket/port
         racket/file
         racket/runtime-path
         beagle/private/parse
         beagle/private/emit
         beagle/lang/reader-impl)

(define-runtime-path fixtures-dir "fixtures")

(define (compile-bjs-file path)
  (define src (file->string path))
  (define lines (string-split src "\n"))
  (define body-lines
    (filter (lambda (l) (not (string-prefix? l "#lang"))) lines))
  (define body (string-append "(define-target js)\n"
                              (string-join body-lines "\n")))
  (define stxs
    (with-input-from-string body
      (lambda ()
        (let loop ([acc '()])
          (define d (beagle-read-syntax (path->string path) (current-input-port)))
          (if (eof-object? d) (reverse acc) (loop (cons d acc)))))))
  (define prog (parse-program stxs))
  (string-trim (emit-program prog)))

(define (js-fixture name)
  (compile-bjs-file (build-path fixtures-dir name)))

;; --- stdlib statics (Math/JSON/Number) -------------------------------------

(test-case "js-stdlib-statics fixture — uppercase-prefix slashed → dotted"
  (define out (js-fixture "js-stdlib-statics.bjs"))
  (check-true (string-contains? out "JSON.parse(s)"))
  (check-true (string-contains? out "JSON.stringify(obj)"))
  (check-true (string-contains? out "Math.floor(x)"))
  (check-true (string-contains? out "Math.sqrt(x)"))
  (check-true (string-contains? out "Math.pow(x, y)"))
  (check-true (string-contains? out "Math.random()"))
  (check-true (string-contains? out "Math.PI"))
  (check-true (string-contains? out "Number.isInteger(x)"))
  (check-true (string-contains? out "Number.isNaN(x)"))
  (check-true (string-contains? out "Number.parseInt(s)")))

;; --- Promise / await -------------------------------------------------------

(test-case "js-promises fixture — Promise.resolve/reject/all/race + async/await"
  (define out (js-fixture "js-promises.bjs"))
  (check-true (string-contains? out "async function fetch_text"))
  (check-true (string-contains? out "await fetch(url)"))
  (check-true (string-contains? out "await resp.text()"))
  (check-true (string-contains? out "Promise.resolve(x)"))
  (check-true (string-contains? out "Promise.reject(msg)"))
  (check-true (string-contains? out "Promise.all(promises)"))
  (check-true (string-contains? out "Promise.race(promises)")))

;; --- Object/Array/Number statics -------------------------------------------

(test-case "js-object-statics fixture — Object.* / Array.* / Number.* statics"
  (define out (js-fixture "js-object-statics.bjs"))
  (check-true (string-contains? out "Object.keys(o)"))
  (check-true (string-contains? out "Object.values(o)"))
  (check-true (string-contains? out "Object.entries(o)"))
  (check-true (string-contains? out "Object.assign(a, b)"))
  (check-true (string-contains? out "Object.freeze(o)"))
  (check-true (string-contains? out "Object.isFrozen(o)"))
  (check-true (string-contains? out "Object.fromEntries(pairs)"))
  (check-true (string-contains? out "Number.parseInt(s, 10)"))
  (check-true (string-contains? out "Number.parseFloat(s)"))
  (check-true (string-contains? out "Array.from(iter)"))
  (check-true (string-contains? out "Array.isArray(x)")))

;; --- Array prototype methods (.push, .pop, etc.) ---------------------------

(test-case "js-array-methods fixture — .method dispatch on instance"
  (define out (js-fixture "js-array-methods.bjs"))
  (check-true (string-contains? out "xs.push(x)"))
  (check-true (string-contains? out "xs.pop()"))
  (check-true (string-contains? out "xs.indexOf(target)"))
  (check-true (string-contains? out "xs.includes(target)"))
  (check-true (string-contains? out "xs.join(\", \")"))
  (check-true (string-contains? out "xs.slice(start, end)"))
  (check-true (string-contains? out "xs.reverse()"))
  (check-true (string-contains? out "a.concat(b)")))

;; --- existing hello-js fixture (records, classify, await, defrecord) -------

(test-case "hello-js fixture — defrecord, await, classify still emit"
  (define out (js-fixture "hello-js.bjs"))
  ;; defrecord emits a constructor function + accessor functions
  (check-true (string-contains? out "function Product(name, price"))
  (check-true (string-contains? out "function product_name(r)"))
  (check-true (string-contains? out "async function load_and_classify"))
  (check-true (string-contains? out "await fetch_product(id)"))
  (check-true (string-contains? out "function classify(p)")))

;; --- existing jsquote-demo (js/quote class/async/throw) --------------------

(test-case "jsquote-demo fixture — js/quote emits structural JS"
  (define out (js-fixture "jsquote-demo.bjs"))
  (check-true (string-contains? out "const greeting = \"Hello, World!\""))
  (check-true (string-contains? out "function validateAge"))
  (check-true (string-contains? out "async function fetchData"))
  (check-true (string-contains? out "await fetch(url)")))
