#lang racket/base

(require rackunit
         rackunit/text-ui
         racket/string
         racket/system
         racket/port
         racket/format
         racket/file
         racket/list
         setup/collects
         (file "../../beagle-lib/private/parse.rkt")
         (file "../../beagle-lib/private/check.rkt")
         (file "../../beagle-lib/private/emit.rkt")
         (file "../../beagle-lib/private/types.rkt"))

(define (br . xs) (cons BRACKET-TAG xs))
;; Canonical function-type datum: (Fn [P ...] R).
;; `params` may carry a `&` tail for a variadic extern.
(define (fn-ty params ret) (list 'Fn (apply br params) ret))
(define (mt . xs) (cons MAP-TAG xs))
(define (st . xs) (cons SET-TAG xs))

(define (find-bun-in-store store)
  (and (directory-exists? store)
       (for/or ([p (in-list (directory-list store))])
         (define candidate (build-path store p "bin" "bun"))
         (and (file-exists? candidate) candidate))))

(define BUN-PATH
  (or (find-executable-path "bun")
      (find-bun-in-store (string->path "/nix/store"))
      (begin
        (displayln "SKIP: bun not found, skipping behavioral JS tests")
        #f)))

(module+ test
  (define sandbox (make-temporary-file "beagle-missing-store-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (check-false (find-bun-in-store (build-path sandbox "store"))))
    (lambda ()
      (delete-directory/files sandbox))))

(define (js-emit src-forms)
  (define prog
    (parse-program
     (map (lambda (f) (datum->syntax #f f)) src-forms)
     #:source-path "test.bjs"))
  (type-check! prog)
  (emit-program prog))

;; Compile beagle forms to JS, append assertion code, run with bun.
;; assertions-js is raw JS appended after the emitted program.
(define BEAGLE-CORE-JS-PATH
  (collection-file-path "lib/beagle/core.js" "beagle"))
(define BEAGLE-CORE-JS (path->string BEAGLE-CORE-JS-PATH))
(define BEAGLE-HOST-JS
  (path->string
   (collection-file-path "lib/beagle/host.js" "beagle")))
(define BEAGLE-EXCEPTION-DISPATCH-JS
  (path->string
   (collection-file-path "lib/beagle/exception-dispatch.js" "beagle")))
(define BEAGLE-EXCEPTION-INFO-JS
  (path->string
   (collection-file-path "lib/beagle/exception-info.js" "beagle")))

(define (resolve-beagle-runtime-imports raw-js)
  (for/fold ([js raw-js])
            ([replacement
              (in-list
               (list (cons "beagle/core.js" BEAGLE-CORE-JS)
                     (cons "beagle/host.js" BEAGLE-HOST-JS)
                     (cons "beagle/exception-dispatch.js"
                           BEAGLE-EXCEPTION-DISPATCH-JS)
                     (cons "beagle/exception-info.js"
                           BEAGLE-EXCEPTION-INFO-JS)))])
    (string-replace js
                    (format "from '~a'" (car replacement))
                    (format "from '~a'" (cdr replacement)))))

(define (run-js-test beagle-forms assertions-js)
  (define raw-js
    (js-emit (append (list '(ns test.app) '(define-target js))
                     beagle-forms)))
  (define js-code
    (string-append
     (resolve-beagle-runtime-imports raw-js)
     "\n\n// --- assertions ---\n"
     assertions-js
     "\n"))
  (define tmp (make-temporary-file "beagle-test-~a.js"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file tmp #:exists 'truncate
        (lambda (out) (display js-code out)))
      (define-values (proc stdout stdin stderr)
        (subprocess #f #f #f BUN-PATH (path->string tmp)))
      (close-output-port stdin)
      (define out-str (port->string stdout))
      (define err-str (port->string stderr))
      (subprocess-wait proc)
      (define code (subprocess-status proc))
      (close-input-port stdout)
      (close-input-port stderr)
      (values code out-str err-str js-code))
    (lambda ()
      (when (file-exists? tmp) (delete-file tmp)))))

(define-syntax-rule (check-js-behavior name forms assertions-js)
  (test-case name
    (define-values (code out err js) (run-js-test forms assertions-js))
    (check-equal? code 0
                  (format "exit ~a\n--- stderr ---\n~a\n--- js ---\n~a" code err js))))

(define-syntax-rule (check-js-output name forms assertions-js expected-out)
  (test-case name
    (define-values (code out err js) (run-js-test forms assertions-js))
    (check-equal? code 0
                  (format "exit ~a\n--- stderr ---\n~a\n--- js ---\n~a" code err js))
    (check-equal? (string-trim out) expected-out
                  (format "wrong output\n--- js ---\n~a" js))))

(when BUN-PATH
(run-tests
 (test-suite "JS behavioral"

   ;; --- basic arithmetic & values -------------------------------------------

   (check-js-output "def + defn round-trip"
     (list '(def x Int 42)
           '(defn double [(n Int)] Int (* n 2))
           '(defn main [] Nil (println (double x))))
     "main();"
     "84")

   (check-js-output "string concatenation"
     (list '(defn greet [(name String)] String (str "Hello, " name "!"))
           '(defn main [] Nil (println (greet "world"))))
     "main();"
     "Hello, world!")

   (check-js-behavior "keyword, symbol, nil, and declared scalar identity"
     (list
      `(def literal-keyword Keyword :alpha/item)
      `(def literal-symbol Symbol (quote alpha/item))
      `(defn make-keyword ,(br 'text 'String) Keyword (keyword text))
      `(defn make-symbol ,(br 'text 'String) Symbol (symbol text))
      `(defn keyword-value? ,(br 'value 'Any) Bool (keyword? value))
      `(defn symbol-value? ,(br 'value 'Any) Bool (symbol? value))
      `(defn scalar-equal? ,(br 'left 'Any 'right 'Any) Bool (= left right))
      `(defn value-hash ,(br 'value 'Any) Int (hash value))
      `(defn value-name ,(br 'value 'Any) String (name value))
      `(defn render ,(br 'value 'Any) String (str value))
      `(defn print-value ,(br 'value 'Any) String (pr-str value))
      `(defn scalar-map ,(br) Any ,(mt ':x 1 "x" 2))
      `(defn map-get ,(br 'm 'Any 'key 'Any) Any (get m key))
      `(defn scalar-keys ,(br 'm 'Any) Any (keys m))
      `(defn as-int ,(br 'value 'Any) Int (int value))
      `(defn as-double ,(br 'value 'Any) Float (double value))
      `(defn as-char ,(br 'value 'Any) Any (char value)))
     (string-append
      "const k1 = make_keyword('alpha/item'), k2 = make_keyword('alpha/item');\n"
      "const s1 = make_symbol('alpha/item'), s2 = make_symbol('alpha/item');\n"
      "if (!keyword_value_p(literal_keyword) || keyword_value_p('alpha/item')) throw new Error('keyword predicate');\n"
      "if (!symbol_value_p(literal_symbol) || symbol_value_p(Symbol('foreign'))) throw new Error('symbol predicate');\n"
      "if (!scalar_equal_p(k1, k2) || scalar_equal_p(k1, 'alpha/item')) throw new Error('keyword equality');\n"
      "if (!scalar_equal_p(s1, s2) || scalar_equal_p(s1, k1)) throw new Error('symbol equality');\n"
      "if (value_hash(k1) !== value_hash(k2) || value_hash(s1) !== value_hash(s2)) throw new Error('value hash');\n"
      "if (value_hash(k1) === value_hash('alpha/item') || value_hash(s1) === value_hash('alpha/item')) throw new Error('tagged hash');\n"
      "if (value_name(k1) !== 'item' || value_name(s1) !== 'item') throw new Error('name');\n"
      "if (render(null) !== '' || render(undefined) !== '' || render(k1) !== ':alpha/item' || render(s1) !== 'alpha/item') throw new Error('str');\n"
      "if (print_value(k1) !== ':alpha/item' || print_value(s1) !== 'alpha/item' || print_value('alpha/item') !== '\"alpha/item\"') throw new Error('pr-str');\n"
      "const m = scalar_map();\n"
      "if (map_get(m, k1.text === 'alpha/item' ? make_keyword('x') : null) !== 1 || map_get(m, 'x') !== 2) throw new Error('property codec');\n"
      "const ks = scalar_keys(m);\n"
      "if (ks.length !== 2 || !ks.some(keyword_value_p) || !ks.some(x => typeof x === 'string')) throw new Error('property decode');\n"
      "if (as_int(3.9) !== 3 || as_int(-3.9) !== -3 || as_int(undefined) !== 0) throw new Error('int');\n"
      "if (as_double('3.5') !== 3.5 || !Number.isNaN(as_double(undefined))) throw new Error('double');\n"
      "if (as_char(65) !== 'A' || as_char('Z') !== 'Z') throw new Error('char');\n"
      "let charFailed = false; try { as_char('too long'); } catch (_) { charFailed = true; }\n"
      "if (!charFailed) throw new Error('char rejection');"))

   (check-js-output "keyword and symbol print as scalar values"
     (list
      `(defn print-scalars ,(br) Nil
         (do (print :alpha/item)
             (print (symbol "alpha/item"))
             (pr :alpha/item)
             (pr (symbol "alpha/item"))
             nil)))
     "print_scalars();"
     ":alpha/itemalpha/item:alpha/itemalpha/item")

   (check-js-output "boolean logic"
     (list '(defn both [(a Bool) (b Bool)] Bool (and a b))
           '(defn main [] Nil
              (do (println (both true true))
                  (println (both true false)))))
     "main();"
     "true\nfalse")

   (check-js-output "logical loop tails preserve recur and Clojure truthiness"
     (list
      `(def ordered-events Any ,(br))
      `(def and-events Any ,(br))
      `(def or-events Any ,(br))
      '(defn note! [(value Any)] Any
         (do (.push ordered-events value) true))
      '(defn observe-and! [(value Any)] Any
         (do (.push and-events value) value))
      '(defn observe-or! [(value Any)] Any
         (do (.push or-events value) value))
      '(defn ordered! [(limit Int)] Any
         (loop [at Int 0 prior Int -1]
           (or (and (= at limit) prior)
               (and (note! at)
                    (< at limit)
                    (recur (+ at 1) at)))))
      '(defn and-gate! [(gate Any)] Any
         (loop [at Int 0]
           (and gate
                (observe-and! at)
                (< at 1)
                (recur (+ at 1)))))
      '(defn or-gate! [(gate Any)] Any
         (loop [at Int 0]
           (or gate
               (observe-or! (= at 1))
               (recur (+ at 1))))))
     (string-append
      "console.log(JSON.stringify(["
      "ordered_bang(3), ordered_events, "
      "and_gate_bang(0), and_gate_bang(\"\"), and_gate_bang(false), and_gate_bang(null), and_events, "
      "or_gate_bang(0), or_gate_bang(\"\"), or_gate_bang(false), or_gate_bang(null), or_events"
      "]));")
     (string-append
      "[2,[0,1,2],false,false,false,null,[0,1,0,1],"
      "0,\"\",true,true,[false,true,false,true]]"))

   ;; --- records -------------------------------------------------------------

   (check-js-output "record construction and field access"
     (list '(defrecord Point [(x Int) (y Int)])
           '(defn main [] Nil
              (let [p (->Point 3 4)]
                (do (println (point-x p))
                    (println (point-y p))))))
     "main();"
     "3\n4")

   (check-js-output "record with -> Object.freeze is immutable"
     (list '(defrecord Point [(x Int) (y Int)])
           `(defn main [] Nil
              (let [p (->Point 1 2)
                    q (with p ,(br ':x 10))]
                (do (println (point-x p))
                    (println (point-x q))))))
     "main();"
     "1\n10")

   (check-js-behavior "record is frozen (mutation throws in strict mode)"
     (list '(defrecord Point [(x Int) (y Int)]))
     "
'use strict';
const p = Point(1, 2);
let threw = false;
try { p.x = 99; } catch(e) { threw = true; }
console.assert(threw, 'frozen record should reject mutation');
")

   (check-js-output "defscalar equality and inequality predicates guard at runtime"
     (list '(defscalar Zero Int :where (= 0))
           '(defscalar Nonzero Int :where (not= 0)))
     (string-append
      "console.log(__gtZero(0));\n"
      "console.log(__gtNonzero(1));\n"
      "for (const [ctor, value] of [[__gtZero, 1], [__gtNonzero, 0]]) {\n"
      "  try { ctor(value); console.log('missed'); }\n"
      "  catch (_error) { console.log('rejected'); }\n"
      "}")
     "0\n1\nrejected\nrejected")

   (check-js-output "record _tag for pattern dispatch"
     (list '(defrecord Circle [(radius Int)])
           '(defrecord Rect [(w Int) (h Int)])
           `(defn area [(shape Any)] Int
              (match shape
                ,(br '(Circle r) '(* (int r) (int r)))
                ,(br '(Rect w h) '(* (int w) (int h))))))
     "console.log(area(Circle(5))); console.log(area(Rect(3, 4)));"
     "25\n12")

   (check-js-output "defunion variant accessors are defined"
     (list `(defunion Shape
              (Circle ,(br '(radius Int)))
              (Square ,(br '(side Int)))))
     "console.log(circle_radius(Circle(5))); console.log(square_side(Square(3)));"
     "5\n3")

   (check-js-output "defunion single-binding patterns bind fields"
     (list `(defunion Shape
              (Circle ,(br '(radius Int)))
              (Square ,(br '(side Int))))
           `(defn shape-size [(shape Shape)] Int
              (match shape
                ,(br '(Circle radius) 'radius)
                ,(br '(Square side) 'side))))
     "console.log(shape_size(Circle(5))); console.log(shape_size(Square(3)));"
     "5\n3")

   ;; --- seam 1: reserved-word field/property positions ----------------------
   ;; A record field named for a JS reserved word must round-trip through its
   ;; generated accessor. Pre-fix the accessor is emitted as `cfg_delete$` but
   ;; the call site emits `cfg_delete` (the whole `cfg-delete` symbol is not
   ;; reserved) -> ReferenceError. Property positions never get the `$` suffix.
   (check-js-output "record reserved-word field accessors round-trip"
     (list '(defrecord Cfg [(delete Bool) (default Int)])
           '(defn main [] Nil
              (let [c (->Cfg true 5)]
                (do (println (cfg-delete c))
                    (println (cfg-default c))))))
     "main();"
     "true\n5")

   (check-js-output "record reserved-word field match-destructure"
     (list '(defrecord Cfg [(delete Bool) (default Int)])
           `(defn describe [(c Cfg)] Int
              (match c
                ,(br '(Cfg d df) 'df)))
           '(defn main [] Nil
              (println (describe (->Cfg true 7)))))
     "main();"
     "7")

   (check-js-output "selector punctuation is byte-exact"
     (list '(defn invoke-ready [(gate Any)] Bool
              (.ready? gate)))
     "console.log(invoke_ready({ 'ready?'() { return true; } }));"
     "true")

   (check-js-output "authored underscore selectors and map keys round-trip"
     (list '(defn exercise! [(obj Any)] String
              (do (set! (.-total_str obj)
                    (str (.-wall_s obj) ":" (.ctx_str obj)))
                  (.-total_str obj)))
           `(defn snapshot [] Any ,(mt ':wall_s 8 ':ctx_str "ctx" ':total_str "total")))
     "console.log(exercise_bang({wall_s: 'wall', ctx_str() { return 'ctx'; }, total_str: ''}));
console.log(JSON.stringify(snapshot()));"
     "wall:ctx\n{\"wall_s\":8,\"ctx_str\":\"ctx\",\"total_str\":\"total\"}")

   (check-js-output "underscored record fields keep literal properties and binding-safe accessors"
     (list '(defrecord Snapshot [(wall_s Int) (ctx_str String) (total_str String)])
           '(defn main [] Nil
              (let [s (->Snapshot 8 "ctx" "total")]
                (do (println (snapshot-wall_s s))
                    (println (snapshot-ctx_str s))
                    (println (snapshot-total_str s))))))
     "main();"
     "8\nctx\ntotal")

   ;; --- seam 2: effect-position control flow executes correctly -------------
   ;; Semantics must be preserved through the idiomatic-statement lowering.
   (check-js-output "seam2: effect-position if-else runs then-branch"
     (list '(defn main [] Nil
              (do (if true (println "a") (println "b"))
                  (println "z"))))
     "main();"
     "a\nz")

   (check-js-output "seam2: effect-position cond selects else branch"
     (list '(defn main [(n Int)] Nil
              (do (cond (> n 10) (println "big")
                        :else (println "small"))
                  (println "done"))))
     "main(3);"
     "small\ndone")

   (check-js-output "seam2: nested if inside when body executes"
     (list '(defn main [(d Bool)] Nil
              (when true
                (if d (println "yes") (println "no")))))
     "main(false);"
     "no")

   ;; --- nil / null ----------------------------------------------------------

   (check-js-output "nil maps to null"
     (list '(def x Nil nil)
           '(defn main [] Nil (println (nil? x))))
     "main();"
     "true")

   (check-js-output "nil? on non-nil returns false"
     (list '(defn main [] Nil (println (nil? "hello"))))
     "main();"
     "false")

   ;; --- Beagle truthiness: only false and nil are falsey --------------------

   (check-js-output "if with 0 — Beagle truthy"
     (list '(defn f [(x Int)] String (if x "truthy" "falsy")))
     "console.log(f(0));"
     "truthy")

   (check-js-output "if with empty string — Beagle truthy"
     (list '(defn f [(x String)] String (if x "truthy" "falsy")))
     "console.log(f(\"\"));"
     "truthy")

   (check-js-output "if with null — falsy"
     (list '(defn f [(x Any)] String (if x "truthy" "falsy")))
     "console.log(f(null));"
     "falsy")

   (check-js-output "if with false — falsy"
     (list '(defn f [(x Bool)] String (if x "truthy" "falsy")))
     "console.log(f(false));"
     "falsy")

   (check-js-output "if with non-zero — truthy"
     (list '(defn f [(x Int)] String (if x "truthy" "falsy")))
     "console.log(f(1));"
     "truthy")

   ;; --- let / IIFE ----------------------------------------------------------

   (check-js-output "let binds correctly"
     (list '(defn f [] Int (let [x Int 10 y Int 20] (+ x y))))
     "console.log(f());"
     "30")

   (check-js-output "nested let scoping"
     (list '(defn f [] Int
              (let [x Int 1]
                (let [x Int 2]
                  x))))
     "console.log(f());"
     "2")

   (check-js-output "let does not leak into outer scope"
     (list '(defn f [] Int
              (let [x Int 1]
                (+ (let [y Int 10] y) x))))
     "console.log(f());"
     "11")

   ;; Regression: a `let` that rebinds the same name twice (ordinary Clojure
   ;; shadowing, e.g. an ignored `_` result used twice) type-checked clean but
   ;; emitted two `const x = …;` in one JS block -> SyntaxError at runtime.
   ;; See emit-js.rkt's `current-rename-env` / `emit-let-bindings`.
   (check-js-output "let with repeated binding name (return position)"
     (list '(defn f [] Int
              (let [x Int 1
                    x Int (+ x 1)]
                x)))
     "console.log(f());"
     "2")

   (check-js-output "let with repeated binding name (non-return position)"
     (list '(defn f [] Int
              (let [x Int 1
                    x Int (+ x 1)]
                x))
           '(defn main [] Nil
              (do (println (f))
                  (println (f)))))
     "main();"
     "2\n2")

   (check-js-output "let with three-times-repeated binding name"
     (list '(defn f [] Int
              (let [x Int 1
                    x Int (+ x 1)
                    x Int (* x 10)]
                x)))
     "console.log(f());"
     "20")

   (check-js-behavior "let with repeated binding name emits distinct JS identifiers"
     (list '(defn f [] Int
              (let [x Int 1
                    x Int (+ x 1)]
                x)))
     "if (f() !== 2) throw new Error('expected 2');")

   ;; --- structural binding constraints --------------------------------------

   (check-js-output "binding constraints guard params, rest, let, and fn"
     (list '(defn positive? [(value Int)] Bool (> value 0))
           '(defn all-positive? [(values (List Int))] Bool
              (every? positive? values))
           '(defn constrained-rest
              [(head Int positive?) & (tail (List Int) all-positive?)]
              Int
              (+ head (count tail)))
           '(defn local [(input Int)] Int
              (let [(checked Int positive?) input]
                checked))
           '(defn call-constrained [(input Int)] Int
              ((fn [(value Int positive?)] Int value) input)))
     (string-append
      "console.log(constrained_rest(3, 4, 5));\n"
      "console.log(local(6)); console.log(call_constrained(7));\n"
      "for (const [call, binding] of ["
      "[() => constrained_rest(-1), 'head'],"
      "[() => constrained_rest(1, -2), 'tail'],"
      "[() => local(-3), 'checked'],"
      "[() => call_constrained(-4), 'value']]) {"
      "try { call(); throw new Error('missing failure'); } "
      "catch (error) { console.log(error.message === "
      "'Binding constraint failed: ' + binding); }}")
     "5\n6\n7\ntrue\ntrue\ntrue\ntrue")

   (check-js-output "destructuring constraints see aggregate before projection"
     (list '(defn positive-point? [(point (HVec Int Int))] Bool
              (and (> (first point) 0) (> (second point) 0)))
           `(defn point-x
              ,(br (list (br 'x 'y) '(HVec Int Int) 'positive-point?))
              Int
              x)
           `(defn local-point [(point (HVec Int Int))] Int
              (let ,(br (list (br 'x 'y)
                              '(HVec Int Int)
                              'positive-point?)
                         'point)
                y)))
     (string-append
      "console.log(point_x([2, 3])); console.log(local_point([4, 5]));\n"
      "for (const call of [() => point_x([-1, 3]), "
      "() => local_point([4, -5])]) { try { call(); } "
      "catch (error) { console.log(error.message); }}")
     (string-append
      "2\n5\nBinding constraint failed: [x y]\n"
      "Binding constraint failed: [x y]"))

   (check-js-output "binding constraints guard multi arity, letfn, for, and loop recur"
     (list '(defn positive? [(value Int)] Bool (> value 0))
           `(defn choose
              ,(list (br '(value Int positive?)) 'Int 'value)
              ,(list (br '(value Int positive?) '(extra Int))
                     'Int '(+ value extra)))
           '(defn nested [(value Int)] Int
              (letfn [(accept [(item Int positive?)] Int item)]
                (accept value)))
           '(defn projected [(values (Vec Int))] (Vec Int)
              (for [(value Int positive?) values] value))
           '(defn countdown [(start Int)] Int
              (loop [(value Int positive?) start]
                (if (= value 1) value (recur (- value 1))))))
     (string-append
      "console.log(choose(2)); console.log(choose(2, 3)); "
      "console.log(nested(4)); console.log(JSON.stringify(projected([5,6]))); "
      "console.log(countdown(3));\n"
      "for (const call of [() => choose(0), () => nested(-1), "
      "() => projected([1,0]), () => countdown(0)]) { try { call(); } "
      "catch (error) { console.log(error.message); }}")
     (string-append
      "2\n5\n4\n[5,6]\n1\n"
      "Binding constraint failed: value\n"
      "Binding constraint failed: item\n"
      "Binding constraint failed: value\n"
      "Binding constraint failed: value"))

   (check-js-output "multi-arity constraints resolve predicates before parameter installs"
     (list
      '(defn value [(candidate Int)] Bool (> candidate 0))
      `(defn choose
         ,(list (br '(value Int value)) 'Int 'value)
         ,(list (br '(value Int value) '(extra Int))
                'Int '(+ value extra))))
     (string-append
      "console.log(choose(2)); console.log(choose(2, 3));\n"
      "try { choose(0); } catch (error) { console.log(error.message); }")
     "2\n5\nBinding constraint failed: value")

   (check-js-output "record constraints guard constructor and with update"
     (list '(defn positive? [(value Int)] Bool (> value 0))
           '(defrecord Score [(value Int positive?) (label String)])
           `(defn change [(score Score) (value Int)] Score
              (with score ,(br ':value 'value))))
     (string-append
      "const score = Score(7, 'ok'); console.log(score.value); "
      "console.log(change(score, 8).value);\n"
      "for (const call of [() => Score(0, 'bad'), "
      "() => change(score, -1)]) { try { call(); } "
      "catch (error) { console.log(error.message); }}")
     (string-append
      "7\n8\nBinding constraint failed: value\n"
      "Binding constraint failed: value"))

   (check-js-output "record field predicates are resolved before hidden installs"
     (list '(defn value [(candidate Int)] Bool (> candidate 0))
           '(defrecord Meter [(value Int value)]))
     (string-append
      "console.log(Meter(4).value);\n"
      "try { Meter(0); } catch (error) { console.log(error.message); }")
     "4\nBinding constraint failed: value")

   (check-js-output "constraint scopes, sequential loops, and mutation stay structural"
     (list
      '(defn checked [(candidate Int)] Bool (> candidate 0))
      '(defn parameter-collision! [(checked Int checked)] Int
         (do (set! checked (+ checked 1)) checked))
      '(defn let-collision! [(input Int)] Int
         (let [(checked Int checked) input]
           (do (set! checked (+ checked 1)) checked)))
      `(def outer Int 11)
      `(defn destructure-default
         ,(br (list (mt ':keys (br 'outer)
                        ':or (mt 'outer 'outer))
                    '(Map Keyword Int))
              '(guard Int checked))
         Int
         outer)
      `(def observations (Atom (Vec Int)) (atom ,(br)))
      '(defn observe-positive! [(candidate Int)] Bool
         (do (reset! observations (conj (deref observations) candidate))
             (> candidate 0)))
      '(defn observation-values [] (Vec Int) (deref observations))
      '(defn sequential-loop! [(start Int)] Int
         (loop [(left Int observe-positive!) start
                (right Int checked)
                (+ left 1)]
           (if (= left 1)
               right
               (recur (- left 1) left)))))
     (string-append
      "console.log(parameter_collision_bang(2)); console.log(let_collision_bang(3));\n"
      "console.log(destructure_default({}, 1)); console.log(sequential_loop_bang(2));\n"
      "console.log(JSON.stringify(observation_values()));\n"
      "for (const call of [() => parameter_collision_bang(0), "
      "() => let_collision_bang(0), () => sequential_loop_bang(0)]) { try { call(); } "
      "catch (error) { console.log(error.message); }}")
     (string-append
      "3\n4\n11\n2\n[2,1]\n"
      "Binding constraint failed: checked\n"
      "Binding constraint failed: checked\n"
      "Binding constraint failed: left"))

   (check-js-output "sibling constrained lets use distinct compiler slots"
     (list
      '(defn positive? [(candidate Int)] Bool (> candidate 0))
      `(defn sibling-lets [(first-input Int) (second-input Int)] Int
         (do
           (let ,(br '(first-value Int positive?) 'first-input) first-value)
           (let ,(br '(second-value Int positive?) 'second-input) second-value)
           3)))
     "console.log(sibling_lets(1, 2));"
     "3")

   (check-js-output "for modifiers and doseq enforce constraints exactly once"
     (list
      '(def row-checks Any (atom 0))
      '(def default-builds Any (atom 0))
      `(def observed Any (atom ,(br)))
      '(defn positive? [(candidate Int)] Bool (> candidate 0))
      '(defn row-valid! [(row (Map Keyword Int))] Bool
         (do (swap! row-checks inc) true))
      '(defn build-default! [] Int
         (do (swap! default-builds inc) 7))
      `(defn project! [(rows (Vec (Map Keyword Int)))] (Vec Int)
         (for [(
                ,(mt ':keys (br 'value)
                     ':or (mt 'value '(build-default!)))
                (Map Keyword Int)
                row-valid!)
               rows
               :when (> value 1)
               :let [(twice Int positive?) (* value 2)]]
           twice))
      '(defn collect! [(values (Vec Int))] Nil
         (doseq [(value Int positive?) values]
           (.push (deref observed) value))))
     (string-append
      "console.log(JSON.stringify(project_bang([{}, {value: 2}, {value: -2}])));\n"
      "console.log(row_checks.value); console.log(default_builds.value);\n"
      "collect_bang([1, 2]);\n"
      "try { collect_bang([3, 0]); } catch (error) { console.log(error.message); }\n"
      "console.log(JSON.stringify(observed.value));")
     (string-append
      "[14,4]\n3\n1\nBinding constraint failed: value\n[1,2,3]"))

   (check-js-output "tagged union and throwable constructors use record validators"
     (list
      '(defn positive? [(candidate Int)] Bool (> candidate 0))
      `(defunion Result (Accepted ,(br '(value Int positive?))))
      `(defunion :throwable Failure (Rejected ,(br '(value Int positive?)))))
     (string-append
      "console.log(Accepted(4).value); console.log(Rejected(5).value);\n"
      "for (const call of [() => Accepted(0), () => Rejected(-1)]) {"
      "try { call(); } catch (error) { console.log(error.message); }}")
     (string-append
      "4\n5\nBinding constraint failed: value\n"
      "Binding constraint failed: value"))

   (test-case "let with repeated binding name never emits duplicate const/let in one block"
     (define js (js-emit (list '(ns test.app) '(define-target js)
                                '(defn f [] Int
                                   (let [x Int 1
                                         x Int (+ x 1)]
                                     x)))))
     (define decls (regexp-match* #rx"(const|let) x[a-zA-Z0-9_]* =" js))
     (check-equal? (length (remove-duplicates decls)) (length decls)
                   (format "duplicate JS declaration among ~v in:\n~a" decls js)))

   ;; --- loop/recur ----------------------------------------------------------

   (check-js-output "loop/recur basic countdown"
     (list '(defn countdown [(n Int)] Int
              (loop [i n]
                (if (= i 0) i (recur (- i 1))))))
     "console.log(countdown(10));"
     "0")

   (check-js-output "loop/recur accumulator"
     (list '(defn sum-to [(n Int)] Int
              (loop [i n acc 0]
                (if (= i 0) acc (recur (- i 1) (+ acc i))))))
     "console.log(sum_to(5));"
     "15")

   ;; --- for / map / filter --------------------------------------------------

   (check-js-output "for -> map"
     (list '(defn double-all [(xs (Vec Int))] (Vec Int)
              (for [x xs] (* x 2))))
     "console.log(JSON.stringify(double_all([1,2,3])));"
     "[2,4,6]")

   (check-js-output "for with :when -> filter + map"
     (list '(defn positives [(xs (Vec Int))] (Vec Int)
              (for [x xs :when (> x 0)] x)))
     "console.log(JSON.stringify(positives([-1, 0, 1, 2, -3])));"
     "[1,2]")

   ;; --- cond / case ---------------------------------------------------------

   (check-js-output "cond evaluates correct branch"
     (list '(defn classify [(n Int)] String
              (cond (< n 0) "neg" (= n 0) "zero" :else "pos")))
     "console.log(classify(-1)); console.log(classify(0)); console.log(classify(1));"
     "neg\nzero\npos")

   (check-js-output "match with or-pattern matches correct value (was: case)"
     (list '(defn day-type [(d Int)] String
              (match d [(or 0 6) "weekend"] [_ "weekday"])))
     "console.log(day_type(0)); console.log(day_type(3)); console.log(day_type(6));"
     "weekend\nweekday\nweekend")

   ;; --- try/catch -----------------------------------------------------------

   (check-js-output "try/catch returns catch value on error"
     (list '(defn safe-div [(a Int) (b Int)] Int
              (try (/ a b) (catch :default error -1))))
     "console.log(safe_div(10, 2));"
     "5")

   (check-js-output "try/catch as expression in let"
     (list '(defn f [] Int
              (let [x (try 42 (catch :default error 0))]
                (+ x 1))))
     "console.log(f());"
     "43")

   (test-case "exception imports are demand tracked"
     (define plain-js
       (js-emit
        (list '(ns test.plain)
              '(define-target js)
              '(defn value [] Int 1))))
     (check-false (string-contains? plain-js "exception-dispatch.js"))
     (check-false (string-contains? plain-js "exception-info.js"))

     (define typed-js
       (js-emit
        (list '(ns test.typed)
              '(define-target js)
              '(defn recover [] Int
                 (try 1 (catch js/Error error 0))))))
     (check-true (string-contains? typed-js "catch_dispatch as $$bd$catch_dispatch"))
     (check-false (string-contains? typed-js "default_catch"))
     (check-false (string-contains? typed-js "exception-info.js"))

     (define default-js
       (js-emit
        (list '(ns test.default)
              '(define-target js)
              '(defn recover [] Int
                 (try 1 (catch :default error 0))))))
     (check-true (string-contains? default-js "catch_dispatch as $$bd$catch_dispatch"))
     (check-true (string-contains? default-js "default_catch as $$bd$default_catch"))

     (define info-js
       (js-emit
        (list '(ns test.info)
              '(define-target js)
              `(defn make-error [] Any (ex-info "failed" ,(mt)))
              '(defn recover [] Int
                 (try 1 (catch ExceptionInfo error 0))))))
     (check-true
      (string-contains? info-js
                        "ExceptionInfo as $$be$ExceptionInfo")))

   (check-js-output "ordered typed/default catches bind only the selected name, rethrow identity, and preserve finally"
     (list
      '(def finalized Any (atom false))
      '(defn clear-finalized! [] Any (reset! finalized false))
      '(defn finalized? [] Bool (deref finalized))
      `(defn throw-info [] Any
         (throw (ex-info "failed" ,(mt ':phase "compile"))))
      `(defn recover! ,(br 'thunk (fn-ty '() 'Any)) Any
         (try
          (thunk)
          (catch ExceptionInfo info (ex-message info))
          (catch js/TypeError type-error (ex-message type-error))
          (catch :default fallback fallback)
          (finally (reset! finalized true))))
      `(defn ordered ,(br 'thunk (fn-ty '() 'Any)) String
         (try
          (thunk)
          (catch js/Error broad "broad")
          (catch ExceptionInfo narrow "narrow")))
      `(defn typed-only ,(br 'thunk (fn-ty '() 'Any)) Any
         (try
          (thunk)
          (catch js/TypeError type-error type-error))))
     #<<JS
console.log(recover_bang(throw_info));
console.log(finalized_p());
clear_finalized_bang();
console.log(recover_bang(() => { throw new TypeError("bad type"); }));
console.log(finalized_p());
clear_finalized_bang();
console.log(recover_bang(() => { throw 42; }));
console.log(finalized_p());
console.log(ordered(throw_info));
const marker = { marker: true };
try {
  typed_only(() => { throw marker; });
  console.log("not-rethrown");
} catch (caught) {
  console.log(caught === marker);
}
JS
     "failed\ntrue\nbad type\ntrue\n42\ntrue\nbroad\ntrue")

   ;; --- do ------------------------------------------------------------------

   (check-js-output "do executes side effects in order"
     (list '(defn f [] Nil
              (do (println "first")
                  (println "second")
                  (println "third"))))
     "f();"
     "first\nsecond\nthird")

   ;; --- when / when-let / if-let --------------------------------------------

   (check-js-output "when true runs body"
     (list '(defn f [(x Bool)] Nil (when x (println "yes"))))
     "f(true);"
     "yes")

   (check-js-behavior "when false produces no output"
     (list '(defn f [(x Bool)] Nil (when x (println "yes"))))
     "f(false);")

   (check-js-output "when-let non-null runs body"
     (list '(defn f [(x Any)] Nil (when-let [v x] (println v))))
     "f(42);"
     "42")

   (check-js-behavior "when-let null skips body"
     (list '(defn f [(x Any)] Nil (when-let [v x] (println v))))
     "f(null);")

   (check-js-output "if-let selects branch"
     (list '(defn f [(x Any)] String (if-let [v x] "found" "missing")))
     "console.log(f(1)); console.log(f(null));"
     "found\nmissing")

   ;; --- doseq ---------------------------------------------------------------
   ;; dotimes removed — use (doseq [i (range n)] body).

   (check-js-output "doseq iterates"
     (list '(defn f [(xs (Vec Int))] Nil (doseq [x xs] (println x))))
     "f([10, 20, 30]);"
     "10\n20\n30")

   ;; --- interop -------------------------------------------------------------

   (check-js-output "direct member call"
     (list '(defn f [(x Any)] String (.toString x)))
     "console.log(f(42));"
     "42")

   (check-js-output "Math/abs static call"
     (list '(defn f [(x Int)] Int (Math/abs x)))
     "console.log(f(-7));"
     "7")

   (check-js-output "direct constructor"
     (list '(def d Any (new Date 2024)))
     "console.log(typeof d);"
     "object")

   (check-js-behavior "typed host collection access admits only its saved root"
     (list
      '(defn native-array [] JsArray (new Array 1 2))
      '(defn native-object [] JsObject (new Object))
      '(defn read-array [(value JsArray) (key Any)] Any (aget value key))
      '(defn write-array! [(value JsArray) (key Any) (next Any)] Any
         (aset value key next))
      '(defn read-object [(value JsObject) (key Any)] Any (aget value key))
      '(defn write-object! [(value JsObject) (key Any) (next Any)] Any
         (aset value key next))
      '(defn read-either [(value (U JsArray JsObject)) (key Any)] Any
         (aget value key))
      '(defn read-dynamic [(value Any) (key Any)] Any (aget value key))
      '(defn read-nested [(value JsArray)] Any (aget value 0 "leaf"))
      '(defn read-trusted-array [(value Any) (key Any)] Any
         (aget (: value JsArray) key)))
     (string-append
      "const rejectsType = action => { let rejected = false; try { action(); } catch (error) { rejected = error instanceof TypeError; } if (!rejected) throw new Error('expected TypeError'); };\n"
      "const nativeArray = native_array(), nativeObject = native_object();\n"
      "if (read_array(nativeArray, 1) !== 2) throw new Error('native Array constructor');\n"
      "write_object_bang(nativeObject, 'answer', 42);\n"
      "if (nativeObject.answer !== 42) throw new Error('native Object constructor');\n"
      "const foreignArray = [3], foreignObject = {answer: 4};\n"
      "write_array_bang(foreignArray, 0, 5);\n"
      "write_object_bang(foreignObject, 'answer', 6);\n"
      "if (foreignArray[0] !== 5 || foreignObject.answer !== 6) throw new Error('identity-preserving mutation');\n"
      "if (read_either([7], 0) !== 7 || read_either({0: 8}, 0) !== 8) throw new Error('union admission');\n"
      "if (read_trusted_array([9], 0) !== 9) throw new Error('explicit capability ascription');\n"
      "rejectsType(() => read_array({0: 1}, 0));\n"
      "rejectsType(() => read_object([1], 0));\n"
      "rejectsType(() => read_either(null, 0));\n"
      "rejectsType(() => read_either(1, 0));\n"
      "rejectsType(() => read_dynamic([10], 0));\n"
      "rejectsType(() => read_dynamic({0: 10}, 0));\n"
      "const nested = [{leaf: 11}];\n"
      "rejectsType(() => read_nested(nested));\n"
      "if (read_object(nested[0], 'leaf') !== 11) throw new Error('separate nested admission');"))

   (check-js-behavior "typed host aset evaluates arguments once in source order"
     (list
      `(declare-extern root! ,(fn-ty '() 'Any))
      `(declare-extern key! ,(fn-ty '() 'Any))
      `(declare-extern value! ,(fn-ty '() 'Any))
      '(defn ordered-write! [] Any
         (aset (: (root!) JsArray) (key!) (value!))))
     (string-append
      "const target = [0], events = [];\n"
      "globalThis.root_bang = () => { events.push('root'); return target; };\n"
      "globalThis.key_bang = () => { events.push('key'); return 0; };\n"
      "globalThis.value_bang = () => { events.push('value'); return 12; };\n"
      "if (ordered_write_bang() !== 12 || target[0] !== 12) throw new Error('aset result');\n"
      "if (events.join(',') !== 'root,key,value') throw new Error(`order:${events.join(',')}`);"))

   (check-js-output "direct members preserve selectors and the receiver"
     (list
      '(defn read-static [(object Any)] Any (.-value object))
      '(defn call-static [(object Any) (n Int)] Any
         (.add object n))
      '(defn write! [(object Any) (value Any)] Any
         (set! (.-value object) value))
      '(defn remove! [(object Any)] Bool (js/delete! object .trash))
      '(defn owns-value? [(object Any)] Bool (js/in? object .value))
      '(defn value-kind [(value Any)] String (js/typeof value)))
     (string-append
      "const object = {value: 3, trash: true, add(n) { return this.value + n; }};\n"
      "console.log(read_static(object));\n"
      "console.log(call_static(object, 4));\n"
      "console.log(write_bang(object, 9));\n"
      "console.log(owns_value_p(object));\n"
      "console.log(remove_bang(object));\n"
      "console.log('trash' in object);\n"
      "console.log(value_kind(object.value));")
     "3\n7\n9\ntrue\ntrue\nfalse\nnumber")

   (check-js-output "receiver and dynamic key expressions evaluate once in source order"
     (list
      `(declare-extern receiver! ,(fn-ty '() 'Any))
      `(declare-extern key! ,(fn-ty '(String) 'String))
      '(defn delete-once! [] Bool
         (js/delete! (receiver!) (key! "trash")))
      '(defn in-once! [] Bool (js/in? (receiver!) (key! "value"))))
     (string-append
      "let events = [];\n"
      "let target = {value: 3, trash: true, add(n) { return this.value + n; }};\n"
      "globalThis.receiver_bang = () => { events.push('receiver'); return target; };\n"
      "globalThis.key_bang = (key) => { events.push('key'); return key; };\n"
      "const observe = (label, operation) => {\n"
      "  events = []; const value = operation();\n"
      "  console.log(`${label}:${value}:${events.join(',')}`);\n"
      "};\n"
      "observe('delete', delete_once_bang);\n"
      "observe('in', in_once_bang);")
     (string-append
      "delete:true:receiver,key\n"
      "in:true:receiver,key"))

   (check-js-output "threading retains the remaining JavaScript primitives"
     (list
      '(defn threaded-in? [(object Any)] Bool
         (-> object (js/in? .value)))
      '(defn threaded-typeof [(object Any)] String
         (-> object js/typeof)))
     (string-append
      "const object = {value: 3, add(n) { return this.value + n; }};\n"
      "console.log(threaded_in_p(object));\n"
      "console.log(threaded_typeof(object));")
     "true\nobject")

   ;; A set!-mutated let local must execute as mutable JS (`let`, not `const`).
   ;; Static emitter coverage alone misses "Assignment to constant variable".
   (check-js-output "set!-mutated let local executes"
     (list '(defn overwrite-local! [(n Int)] Int
              (let [acc Int 0]
                (set! acc n)
                acc)))
     "console.log(overwrite_local_bang(42));"
     "42")

   ;; --- multi-arity ---------------------------------------------------------

   (check-js-output "multi-arity dispatch"
     (list `(defn greet
              (,(br '(name String)) String (str "Hi " name))
              (,(br '(first String) '(last String)) String (str "Hi " first " " last))))
     "console.log(greet(\"Alice\")); console.log(greet(\"Bob\", \"Smith\"));"
     "Hi Alice\nHi Bob Smith")

   ;; --- async/await ---------------------------------------------------------

   (check-js-output "async/await basic"
     (list `(declare-extern fetch-data ,(fn-ty '(String) '(Promise String)))
           '(defn (#%meta :async f) [(x String)] (Promise String)
              (await (fetch-data x))))
     "
globalThis.fetch_data = async (x) => 'got:' + x;
f('hello').then(r => console.log(r));
"
     "got:hello")

   (check-js-output "await in nested let"
     (list `(declare-extern get-val ,(fn-ty '(Int) '(Promise Int)))
           '(defn (#%meta :async f) [(n Int)] (Promise Int)
              (let [a (await (get-val n))
                    b (await (get-val (+ n 1)))]
                (+ a b))))
     "
globalThis.get_val = async (n) => n * 10;
f(3).then(r => console.log(r));
"
     "70")

   (check-js-behavior "sync letfn declarations do not wrap a sync body"
     (list '(defn outer [] Int
              (letfn [(later [(value Int)] Int (+ value 1))]
                42)))
     "if (outer() !== 42) throw new Error('letfn body became wrapped');")

   ;; --- munge disambiguation ------------------------------------------------

   (check-js-behavior "hyphen and underscore names are distinct"
     (list '(def my-x Int 1)
           '(def my_x Int 2))
     "
console.assert(my_x === 1, 'my-x should be 1, got ' + my_x);
console.assert(my__x === 2, 'my_x should be 2, got ' + my__x);
")

   ;; --- edge cases ----------------------------------------------------------

   (check-js-output "inc and dec"
     (list '(defn f [(x Int)] Int (+ x 1))
           '(defn g [(x Int)] Int (- x 1)))
     "console.log(f(5)); console.log(g(5));"
     "6\n4")

   (check-js-output "count on vec"
     (list '(defn f [(xs (Vec Int))] Int (count xs)))
     "console.log(f([1,2,3]));"
     "3")

   (check-js-output "first on vec"
     (list '(defn f [(xs (Vec Int))] Int (first xs)))
     "console.log(f([10,20,30]));"
     "10")

   (check-js-output "nested record construction"
     (list '(defrecord Inner [(val Int)])
           '(defrecord Outer [(inner Inner)])
           '(defn get-val [(o Outer)] Int (inner-val (outer-inner o))))
     "console.log(get_val(Outer(Inner(42))));"
     "42")

   (check-js-output "defenum values"
     (list '(defenum Color :red :green :blue))
     "console.log(Color_values.has(':red')); console.log(Color_values.has(':purple'));"
     "true\nfalse")

   ;; --- atom operations -------------------------------------------------------

   (check-js-output "atom create and deref"
     (list '(defn f [] Int
              (let [a (atom 42)]
                (deref a))))
     "console.log(f());"
     "42")

   (check-js-output "atom reset!"
     (list '(defn f! [] Int
              (let [a (atom 0)]
                (do (reset! a 99)
                    (deref a)))))
     "console.log(f_bang());"
     "99")

   (check-js-output "atom swap!"
     (list '(defn f! [] Int
              (let [a (atom 10)]
                (do (swap! a (fn [(x Int)] Int (+ x 1)))
                    (deref a)))))
     "console.log(f_bang());"
     "11")

   (check-js-output "atom swap! with extra args"
     (list '(defn add [(x Int) (y Int)] Int (+ x y))
           '(defn f! [] Int
              (let [a (atom 10)]
                (do (swap! a add 5)
                    (deref a)))))
     "console.log(f_bang());"
     "15")

   ;; --- additional stdlib -----------------------------------------------------

   (check-js-output "some returns the first Clojure-truthy predicate value"
     (list '(def evaluation-order Any (atom ""))
           '(def predicate-builds Any (atom 0))
           '(def collection-builds Any (atom 0))
           '(def callback-count Any (atom 0))
           '(defn zero-element [] Any
              (some (fn [(x Int)] Any (if (= x 0) true false))
                    (range -1 1)))
           '(defn string-result [] Any
              (some (fn [(x Int)] Any
                      (cond (= x 0) false
                            (= x 1) nil
                            (= x 2) "matched"
                            :else "late"))
                    (range 0 4)))
           '(defn number-result [] Any
              (some (fn [(x Int)] Any (if (= x 2) 73 nil))
                    (range 0 4)))
           '(defn falsey-number-result [] Any
              (some (fn [(x Int)] Any (if (= x 2) 0 nil))
                    (range 0 4)))
           '(defn no-match [] Any
              (some (fn [(x Int)] Any (if (> x 9) x nil))
                    (range 0 4)))
           '(defn nil-collection [] Any
              (some identity nil))
           '(defn make-predicate! [] Any
              (do (swap! evaluation-order str "p")
                  (swap! predicate-builds inc)
                  (fn [(x Int)] Any
                    (do (swap! callback-count inc)
                        (cond (= x 1) false
                              (= x 2) nil
                              (= x 3) "hit"
                              :else "late")))))
           '(defn make-collection! [] Any
              (do (swap! evaluation-order str "c")
                  (swap! collection-builds inc)
                  (range 1 5)))
           '(defn effect-result! [] Any
              (some (make-predicate!) (make-collection!))))
     (string-append
      "console.log(JSON.stringify(["
      "zero_element(),string_result(),number_result(),falsey_number_result(),"
      "no_match(),nil_collection(),effect_result_bang(),evaluation_order.value,predicate_builds.value,"
      "collection_builds.value,callback_count.value]));")
     "[true,\"matched\",73,0,null,null,\"hit\",\"pc\",1,1,3]")

   (check-js-output "take-last"
     (list '(defn f [(xs (Vec Int))] Any (take-last 2 xs)))
     "console.log(JSON.stringify(f([1,2,3,4,5])));"
     "[4,5]")

   (check-js-output "not= returns boolean"
     (list '(defn f [(a Int) (b Int)] Bool (not (= a b))))
     "console.log(f(1,2)); console.log(f(1,1));"
     "true\nfalse")

   (check-js-output "seq on empty returns null"
     (list '(defn f [(xs (Vec Int))] Any (seq xs)))
     "console.log(f([])); console.log(f([1]) !== null);"
     "null\ntrue")

   (check-js-output "sequential? predicate"
     (list '(defn f [(x Any)] Bool (sequential? x)))
     "console.log(f([1,2])); console.log(f(42));"
     "true\nfalse")

   ;; --- runtime helpers (beagle/core.js) ------------------------------------

   (check-js-output "range generates array"
     (list '(defn f [] Any (range 5)))
     "console.log(JSON.stringify(f()));"
     "[0,1,2,3,4]")

   (check-js-output "range with start and end"
     (list '(defn f [] Any (range 2 7)))
     "console.log(JSON.stringify(f()));"
     "[2,3,4,5,6]")

   (check-js-output "range with step"
     (list '(defn f [] Any (range 0 10 3)))
     "console.log(JSON.stringify(f()));"
     "[0,3,6,9]")

   (check-js-output "remove filters out matching"
     (list '(defn z? [(x Int)] Bool (= x 0))
           '(defn f [(xs (Vec Int))] Any (remove z? xs)))
     "console.log(JSON.stringify(f([0,1,0,2,0,3])));"
     "[1,2,3]")

   (check-js-output "mapcat flattens"
     (list '(defn dup [(x Int)] (Vec Int)
              (let [v x] (conj (conj (conj (range 0) v) v) v)))
            '(defn f [(xs (Vec Int))] Any (mapcat dup xs)))
     "console.log(JSON.stringify(f([1,2])));"
     "[1,1,1,2,2,2]")

   (check-js-output "every? checks all"
     (list '(defn p? [(x Int)] Bool (> x 0))
           '(defn f [(xs (Vec Int))] Any (every? p? xs)))
     "console.log(f([1,2,3])); console.log(f([1,0,3]));"
     "true\nfalse")

   (check-js-output "keep filters nulls"
     (list '(defn maybe-inc [(x Int)] Any (if (> x 0) (+ x 1) nil))
           '(defn f [(xs (Vec Int))] Any (keep maybe-inc xs)))
     "console.log(JSON.stringify(f([0,1,0,2])));"
     "[2,3]")

   (check-js-output "take-while stops at first false"
     (list '(defn p? [(x Int)] Bool (> x 0))
           '(defn f [(xs (Vec Int))] Any (take-while p? xs)))
     "console.log(JSON.stringify(f([3,2,1,0,-1])));"
     "[3,2,1]")

   (check-js-output "drop-while drops prefix"
     (list '(defn n? [(x Int)] Bool (< x 0))
           '(defn f [(xs (Vec Int))] Any (drop-while n? xs)))
     "console.log(JSON.stringify(f([-3,-2,-1,0,1,2])));"
     "[0,1,2]")

   (check-js-output "select-keys picks keys"
     (list `(defn f [(m Any)] Any (select-keys m ,(br ':a ':c))))
     "console.log(JSON.stringify(f({a:1, b:2, c:3})));"
     "{\"a\":1,\"c\":3}")

   (check-js-output "assoc-in nested set"
     (list `(defn f [(m Any)] Any (assoc-in m ,(br ':a ':b) 42)))
     "console.log(JSON.stringify(f({a: {b: 0}})));"
     "{\"a\":{\"b\":42}}")

   (check-js-output "update-in nested update"
     (list '(defn add1 [(x Int)] Int (+ x 1))
           `(defn f [(m Any)] Any (update-in m ,(br ':a) add1)))
     "console.log(JSON.stringify(f({a: 5})));"
     "{\"a\":6}")

   ;; --- higher-order value wrappers -------------------------------------------

   (check-js-output "map inc as value"
     (list '(defn f [(xs (Vec Int))] Any (map inc xs)))
     "console.log(JSON.stringify(f([1,2,3])));"
     "[2,3,4]")

   (check-js-output "map dec as value"
     (list '(defn f [(xs (Vec Int))] Any (map dec xs)))
     "console.log(JSON.stringify(f([10,20,30])));"
     "[9,19,29]")

   (check-js-output "filter pos? as value"
     (list '(defn f [(xs (Vec Int))] Any (filter pos? xs)))
     "console.log(JSON.stringify(f([-1,0,1,2,-3])));"
     "[1,2]")

   (check-js-output "reduce + as value"
     (list '(defn f [(xs (Vec Int))] Any (reduce + 0 xs)))
     "console.log(f([1,2,3,4]));"
     "10")

   (check-js-output "filter some? as value"
     (list '(defn f [(xs (Vec Any))] Any (filter some? xs)))
     "console.log(JSON.stringify(f([1,null,2,null,3])));"
     "[1,2,3]")

   (check-js-output "filter nil? as value"
     (list '(defn f [(xs (Vec Any))] Any (filter nil? xs)))
     "console.log(f([1,null,2,null,3]).length);"
     "2")

   (check-js-output "kw-access on Any uses nil-safe polymorphic lookup"
     (list '(defrecord Payload [(wall_s-ready?! Int)])
           `(defunion Event (Hit ,(br '(delete String))))
           '(defn lookup [(value Any)] Any (get value :wall_s-ready?!))
           '(defn lookup-default [(value Any)] Any (get value :delete "missing")))
     (string-append
      "console.log(JSON.stringify(["
      "lookup({wall_s_ready_p_bang: 4}),"
      "lookup(Payload(5)),"
      "lookup_default(Hit('tagged')) ,"
      "lookup_default({}),"
      "lookup_default(42),"
      "lookup_default(null)]));")
     "[4,5,\"tagged\",\"missing\",\"missing\",\"missing\"]")

   (check-js-output "user-defined inc shadows stdlib in map"
     (list '(defn inc [(x Int)] Int (* x 10))
           '(defn f [(xs (Vec Int))] Any (map inc xs)))
     "console.log(JSON.stringify(f([1,2,3])));"
     "[10,20,30]")

   (check-js-output "loop with let containing recur"
     (list '(defn find-char [(s String) (target Int)] Int
              (loop [i Int 0]
                (let [c Int (.charCodeAt s i)]
                  (if (= c target) i (recur (+ i 1)))))))
     "console.log(find_char('hello', 108));"
     "2")

   (check-js-output "loop with nested let containing recur"
     (list '(defn sum-until [(xs (Vec Int)) (limit Int)] Int
              (loop [i Int 0 total Int 0]
                (if (>= i (count xs)) total
                  (let [v Int (nth xs i)]
                    (if (>= (+ total v) limit) total
                      (recur (+ i 1) (+ total v))))))))
     "console.log(sum_until([1,2,3,4,5], 7));"
     "6")

   (check-js-output "loop with cond containing recur"
     (list '(defn classify-first [(xs (Vec Int))] String
              (loop [i Int 0]
                (if (>= i (count xs)) "none"
                  (let [v Int (nth xs i)]
                    (cond
                      (> v 100) "big"
                      (> v 10) "medium"
                      :else (recur (+ i 1))))))))
     "console.log(classify_first([1,5,50,200]));"
     "medium")

   ;; --- special float values (Inf/NaN) ----------------------------------------

   (check-js-output "+inf.0 -> Infinity at runtime"
     (list '(def x Float +inf.0)
           '(defn main [] Nil (println x)))
     "main();"
     "Infinity")

   (check-js-output "-inf.0 -> -Infinity at runtime"
     (list '(def x Float -inf.0)
           '(defn main [] Nil (println x)))
     "main();"
     "-Infinity")

   (check-js-output "+nan.0 -> NaN at runtime"
     (list '(def x Float +nan.0)
           '(defn main [] Nil (println x)))
     "main();"
     "NaN")

   (check-js-behavior "Infinity arithmetic works"
     (list '(def x Float +inf.0)
           '(def y Float -inf.0)
           '(def z Float +nan.0))
     "if (x !== Infinity) throw new Error('expected Infinity');
      if (y !== -Infinity) throw new Error('expected -Infinity');
      if (!Number.isNaN(z)) throw new Error('expected NaN');")

   ;; --- host-object equality --------------------------------------------------
   ;; No DOM under bun; the runtime discriminates on prototype alone, so a class
   ;; instance stands in for a DOM node.

   (check-js-output "= is structural on plain objects, identity on host objects"
     (list '(defn host-eq [(a Any) (b Any)] Bool (= a b)))
     (string-append
      "class HostNode {}\n"
      "const n1 = new HostNode(), n2 = new HostNode();\n"
      "const h1 = Object.create({kind: 'host'}), h2 = Object.create({kind: 'host'});\n"
      "const d1 = new Date(0), d2 = new Date(0);\n"
      "console.log(JSON.stringify(["
      "host_eq({a: 1, b: [2, 3]}, {a: 1, b: [2, 3]}),"   ; distinct plain, equal contents
      "host_eq(n1, n2),"                                 ; distinct host objects
      "host_eq(h1, h2),"
      "host_eq(d1, d2),"
      "host_eq(n1, n1),"                                 ; same object
      "host_eq(h1, h1),"
      "host_eq({row: n1}, {row: n1}),"                   ; host at a nested leaf
      "host_eq({row: n1}, {row: n2}),"
      "host_eq([n1, {k: n2}], [n1, {k: n2}]),"
      "host_eq([n1], [n2])]));")
     "[true,false,false,false,true,true,true,false,true,false]")

 )))
