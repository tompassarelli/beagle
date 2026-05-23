#lang racket/base

;; Execution oracle for JS fixtures: compile each .bjs via beagle-build,
;; then exercise the emitted JavaScript with a node driver. Catches
;; semantic bugs (ReferenceError, TypeError, wrong value) that
;; emit-structure assertions cannot.
;;
;; Per-fixture: emit to a temp dir, then run a small node driver that
;; imports the emitted module + calls functions + prints expected output.

(require rackunit
         racket/string
         racket/port
         racket/system
         racket/runtime-path
         racket/file)

(define-runtime-path fixtures-dir "fixtures")
(define-runtime-path beagle-build "../../bin/beagle-build")

(define tmp-dir (make-temporary-file "beagle-js-oracle-~a" 'directory))

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

(test-case "js-array-methods — .push/.pop/.indexOf/.includes/.slice run"
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
