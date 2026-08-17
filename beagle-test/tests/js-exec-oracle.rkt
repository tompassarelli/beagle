#lang racket/base

;; Execution oracle for JS fixtures: compile each .bjs through a checked JS
;; path, then exercise the emitted JavaScript with a node driver. Catches
;; semantic bugs (ReferenceError, TypeError, wrong value) that
;; emit-structure assertions cannot.
;;
;; Per-fixture: emit to a temp dir, then run a small node driver that
;; imports the emitted module + calls functions + prints expected output.

(require rackunit
         racket/list
         racket/set
         racket/string
         racket/port
         racket/system
         racket/runtime-path
         racket/file
         (file "../../beagle-lib/private/parse.rkt")
         (only-in (file "../../beagle-lib/private/emit-js.rkt")
                  current-js-export-names)
         (file "../../beagle-lib/private/module-overlay-check.rkt"))

(define-runtime-path fixtures-dir "fixtures")
(define-runtime-path beagle-build "../../bin/beagle-build")

(define tmp-dir (make-temporary-file "beagle-js-oracle-~a" 'directory))

(define (write-source path source)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'truncate
    (lambda (out) (display source out))))

(define (module-output-path out-dir namespace)
  (define parts (string-split namespace "."))
  (apply build-path
         out-dir
         (append (drop-right parts 1)
                 (list (string-append (last parts) ".js")))))

(define (source-namespace source)
  (second (regexp-match #px"\\(ns\\s+([^\\s\\)]+)" source)))

(define (overlay-diagnostics->string result)
  (string-join
   (for/list ([diagnostic
               (in-list (overlay-check-result-diagnostics result))])
     (format "~a: ~a"
             (overlay-diagnostic-source diagnostic)
             (overlay-diagnostic-message diagnostic)))
   "\n"))

(define (emit-batch-and-run modules entry-namespace)
  (define scratch
    (make-temporary-file "beagle-js-batch-oracle-~a" 'directory))
  (define src-dir (build-path scratch "src"))
  (define out-dir (build-path scratch "out"))
  (dynamic-wind
   void
   (lambda ()
     (define sources
       (for/list ([module (in-list modules)])
         (define path
           (build-path src-dir (string-append (car module) ".bjs")))
         (write-source path (cdr module))
         path))
     (define checked
       ;; build-all derives the provider export set from the whole batch. The
       ;; overlay already supplies that whole-module context, so emit every
       ;; public binding while exercising its canonical interfaces.
       (parameterize ([current-js-export-names (set '*)])
         (check-module-overlay
          (for/list ([module (in-list modules)]
                     [path (in-list sources)])
            (define stxs (read-beagle-syntax path))
            (module-source
             (string->symbol (source-namespace (cdr module)))
             (path->string path)
             stxs
             #f))
          #:capture-types? #t
          #:closed? #t)))
     (define build-code (if (overlay-check-result-ok? checked) 0 1))
     (define emitted
       (if (zero? build-code)
           (for/hash ([module
                       (in-list (overlay-check-result-modules checked))])
             (define namespace
               (symbol->string (checked-overlay-module-namespace module)))
             (define source (checked-overlay-module-emitted module))
             (write-source (module-output-path out-dir namespace) source)
             (values namespace source))
           (hash)))
     (write-source (build-path out-dir "package.json")
                   "{\"type\":\"module\"}\n")
     (define run-out (open-output-string))
     (define run-err (open-output-string))
     (define node (find-executable-path "node"))
     (define run-code
       (if (and node (zero? build-code))
           (parameterize ([current-directory out-dir]
                          [current-output-port run-out]
                          [current-error-port run-err])
             (system*/exit-code
              node
              (module-output-path out-dir entry-namespace)))
           1))
     (values build-code run-code emitted
             (get-output-string run-out)
             (string-append (overlay-diagnostics->string checked)
                            (get-output-string run-err))))
   (lambda () (delete-directory/files scratch #:must-exist? #f))))

(define (emit-and-run name driver-code)
  (define src (build-path fixtures-dir (string-append name ".bjs")))
  ;; Emit as ESM-compatible .mjs so the driver can `import` it.
  (define out (build-path tmp-dir (string-append name ".mjs")))
  (parameterize ([current-output-port (open-output-string)]
                 [current-error-port  (open-output-string)])
    (system* (path->string beagle-build) (path->string src) (path->string out)))
  ;; Beagle emits `function foo() { ... }` without exports. Wrap by
  ;; appending `export { ... }` for the functions the driver uses, OR
  ;; concatenate the driver after the module body.
  (define module-src (if (file-exists? out) (file->string out) ""))
  (define full-script (string-append module-src "\n" driver-code))
  (define out-port (open-output-string))
  (define err-port (open-output-string))
  (define ok?
    (parameterize ([current-output-port out-port]
                   [current-error-port  err-port])
      (system* "/run/current-system/sw/bin/node" "--input-type=module"
               "-e" full-script)))
  (values ok? (get-output-string out-port) (get-output-string err-port)))

(test-case "js-stdlib-statics — Math/JSON/Number statics run"
  (define-values (ok? out err)
    (emit-and-run "js-stdlib-statics" #<<JS
console.log(parse_config('[1,2,3]').length);
console.log(to_config({a:1}));
console.log(floor_of(3.7));
console.log(sqrt_of(16));
console.log(pow_of(2, 10));
console.log(integer_p(5));
console.log(integer_p(5.5));
console.log(nan_p(NaN));
console.log(parse_int('42'));
JS
    ))
  (check-true ok? err)
  (check-equal? out "3\n{\"a\":1}\n3\n4\n1024\ntrue\nfalse\ntrue\n42\n"))

;; regression: unary (- x) must lower to -x, not the broken value-wrapper ref _(x).
;; binary (- a b) must remain a - b. (dogfood-codegen-findings #2)
(test-case "js-unary-minus — (- x) lowers to -x; binary (- a b) unaffected"
  (define-values (ok? out err)
    (emit-and-run "js-unary" #<<JS
console.log(neg);
console.log(negate(5));
console.log(sub(7, 2));
JS
    ))
  (check-true ok? err)
  (check-equal? out "-1\n-5\n5\n"))

(test-case "js-promises — async/await + Promise.all/race run"
  (define-values (ok? out err)
    (emit-and-run "js-promises" #<<JS
const r1 = await resolve_now(42);
console.log(r1);
const r2 = await all_of([Promise.resolve(1), Promise.resolve(2), Promise.resolve(3)]);
console.log(r2);
const r3 = await race_of([
  new Promise(res => setTimeout(() => res('slow'), 50)),
  Promise.resolve('fast')
]);
console.log(r3);
try {
  await reject_with('oops');
} catch (e) {
  console.log('caught: ' + e);
}
JS
    ))
  (check-true ok? err)
  (check-equal? out "42\n[ 1, 2, 3 ]\nfast\ncaught: oops\n"))

(test-case "js-object-statics — Object.* / Array.* / Number.* statics run"
  (define-values (ok? out err)
    (emit-and-run "js-object-statics" #<<JS
const o = {a: 1, b: 2, c: 3};
console.log(obj_keys(o));
console.log(obj_values(o));
console.log(obj_entries(o));
console.log(merge_objects({x: 1}, {y: 2}));
const f = freeze_it({z: 99});
console.log(is_frozen_p(f));
console.log(from_entries([['a', 1], ['b', 2]]));
console.log(parse_int_of('123'));
console.log(parse_float_of('3.14'));
console.log(array_from('hi'));
console.log(array_is_p([1, 2]));
console.log(array_is_p({}));
JS
    ))
  (check-true ok? err)
  (check-equal? out
                (string-join
                 '("[ 'a', 'b', 'c' ]"
                   "[ 1, 2, 3 ]"
                   "[ [ 'a', 1 ], [ 'b', 2 ], [ 'c', 3 ] ]"
                   "{ x: 1, y: 2 }"
                   "true"
                   "{ a: 1, b: 2 }"
                   "123"
                   "3.14"
                   "[ 'h', 'i' ]"
                   "true"
                   "false"
                   "")
                 "\n")))

(test-case "js-array-methods — js/call array methods run"
  (define-values (ok? out err)
    (emit-and-run "js-array-methods" #<<JS
const xs = [10, 20, 30];
push_one(xs, 40);
console.log(xs);
console.log(pop_last(xs));
console.log(first_idx([1, 2, 3, 2], 2));
console.log(includes_p([1, 2, 3], 2));
console.log(joined(['a', 'b', 'c']));
console.log(sliced([1, 2, 3, 4, 5], 1, 4));
console.log(reversed([1, 2, 3]));
console.log(concatenated([1, 2], [3, 4]));
JS
    ))
  (check-true ok? err)
  (check-equal? out
                (string-join
                 '("[ 10, 20, 30, 40 ]"
                   "40"
                   "1"
                   "true"
                   "a, b, c"
                   "[ 2, 3, 4 ]"
                   "[ 3, 2, 1 ]"
                   "[ 1, 2, 3, 4 ]"
                   "")
                 "\n")))

(test-case "hello-js — defrecord constructor + async classify chain runs"
  (define-values (ok? out err)
    (emit-and-run "hello-js" #<<JS
const p = make_product('Widget', 25);
console.log(product_name(p));
console.log(product_price(p));
console.log(classify(p));
console.log(cheap_p(make_product('Cheap', 5)));
console.log(cheap_p(make_product('Pricey', 50)));
console.log(process_order(p));
console.log(process_order(make_product('Out', 5)));
JS
    ))
  (check-true ok? err)
  ;; Don't pin exact prices (defrecord includes tax-rate math); just check
  ;; structural correctness.
  (check-true (string-contains? out "Widget\n"))
  (check-true (string-contains? out "25\n"))
  (check-true (string-contains? out "mid-range\n"))
  (check-true (string-contains? out "true\n"))
  (check-true (string-contains? out "false\n"))
  (check-true (string-contains? out "Shipping: Widget\n")))

(test-case "js-arrow-object — inline arrow with object-literal body returns the object (not a block)"
  (define-values (ok? out err)
    (emit-and-run "js-arrow-object" #<<JS
console.log(JSON.stringify(pairs([{name: 'a', v: 1}, {name: 'b', v: 2}])));
console.log(JSON.stringify(empties([0, 0])));
JS
    ))
  (check-true ok? err)
  (check-equal? out "[{\"k\":\"a\",\"v\":1},{\"k\":\"b\",\"v\":2}]\n[{},{}]\n"))

(test-case "JS batch imports typed runtime bindings without owner collisions"
  (define-values (build-code run-code emitted out err)
    (emit-batch-and-run
     (list
      (cons
       "types"
       #<<BJS
#lang beagle/js
(ns oracle.types)
(js/export (defrecord Person [(name String)]))
(js/export (defunion Choice (Chosen [(value Int)])))
(js/export (defunion :throwable Failure (Bad [(message String)])))
(js/export (defscalar Checked Int :where (>= 0)))
(js/export (def total Int 7))
(js/export (defonce once Int 8))
(js/export (defenum Color :red :blue))
BJS
       )
      (cons
       "scalar"
       #<<BJS
#lang beagle/js
(ns oracle.scalar)
(js/export (defscalar Amount Int))
BJS
       )
      (cons
       "functions"
       #<<BJS
#lang beagle/js
(ns oracle.functions)
(js/export (defn ->Amount [(value Int)] Int (+ value 100)))
(js/export (defn amount-value [(value Int)] Int (+ value 200)))
BJS
       )
      (cons
       "entry"
       #<<BJS
#lang beagle/js
(ns oracle.entry
  (:require [oracle.types :refer [->Person person-name ->Chosen chosen-value
                                  ->Bad bad-message ->Checked checked-value
                                  total once Color-values
                                  Person Choice Failure Bad Checked]]
            [oracle.scalar :as scalar]
            [oracle.functions :refer [->Amount amount-value]]))
(println (person-name (->Person "Ada")))
(println (chosen-value (->Chosen 9)))
(println (bad-message (->Bad "oops")))
(println (checked-value (->Checked 3)))
(println total)
(println once)
(println (js/get Color-values .size))
(println (->Amount 1))
(println (amount-value 1))
(println (scalar/amount-value (scalar/->Amount 5)))
BJS
       ))
     "oracle.entry"))
  (check-equal? build-code 0 err)
  (check-equal? run-code 0 err)
  (check-equal? out "Ada\n9\noops\n3\n7\n8\n2\n101\n201\n5\n")
  (define types-js (hash-ref emitted "oracle.types" ""))
  (check-true (string-contains? types-js "export function Person("))
  (check-true (string-contains? types-js "export function Chosen("))
  (check-true (string-contains? types-js "export function Bad("))
  (check-true (string-contains? types-js "export function __gtChecked("))
  (check-true (string-contains? types-js "export const total = 7;"))
  (check-true (string-contains? types-js "export const once = 8;"))
  (check-true (string-contains? types-js "export const Color_values")))
