#lang racket/base

(require rackunit
         racket/file
         racket/string
         beagle/private/module-source-root
         beagle/private/parse
         beagle/private/emit)

(require beagle/private/types)

(define (compile . forms)
  (emit-program
   (parse-program (map (lambda (f) (datum->syntax #f f)) forms))))

(define (write-rooted-source! path source)
  (make-parent-directory* path)
  (call-with-output-file path
    (lambda (out) (display source out))
    #:exists 'truncate/replace))

(define (compile-rooted-require namespace relative-provider-path require-form)
  (define root (make-temporary-file "beagle-emit-module-root-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define provider-root (build-path root "providers"))
      (define provider-path (build-path provider-root relative-provider-path))
      (define consumer-path (build-path root "consumer.bclj"))
      (write-rooted-source!
       provider-path
       (format "#lang beagle/clj\n(ns ~a)\n" namespace))
      (write-rooted-source!
       consumer-path
       (string-append
        "#lang beagle/clj\n"
        "(ns rooted.consumer)\n"
        (format "~s\n" require-form)
        "(def x 1)\n"))
      (define closure
        (resolve-module-source-closure
         (list (module-source-input "cases/consumer.bclj" consumer-path))
         (list (make-module-source-root-v0 "providers" provider-root))))
      (define sources (module-source-closure-sources closure))
      (define consumer
        (for/first ([source (in-list sources)]
                    #:when (equal? (module-source-source-id source)
                                   "cases/consumer.bclj"))
          source))
      (emit-program
       (module-source-closure-parse-source
        closure
        consumer
        (lambda (required-namespace _importer)
          (for/first ([source (in-list sources)]
                      #:when (eq? (module-source-namespace source)
                                  required-namespace))
            source)))))
    (lambda () (delete-directory/files root))))

(define (matches? rx out) (regexp-match? rx out))

(define (br . xs) (cons BRACKET-TAG xs))
;; Canonical function-type datum: (Fn [P ...] R).
;; `params` may carry a `&` tail for a variadic extern.
(define (fn-ty params ret) (list 'Fn (apply br params) ret))

(test-case "ns declaration"
  (define out (compile '(def x 1)))
  (check-true (matches? #rx"\\(ns beagle\\.user\\)" out)))

(test-case "namespace override"
  (define out (compile '(ns foo.bar) '(def x 1)))
  (check-true (matches? #rx"\\(ns foo\\.bar\\)" out)))

(test-case "typed def emits ^Type tag"
  ;; Previously paired `(claim greeting String) (def greeting "hello")`;
  ;; claim was removed under the Zero-users rule. The positional type carries
  ;; the same information to the Clojure emitter, producing ^Type metadata.
  (define out (compile '(def greeting String "hello")))
  (check-true (matches? #rx"\\(def \\^String greeting \"hello\"\\)" out)))

(test-case "defn lowers param types to ^Tag metadata in arg vector"
  ;; Structural `(x T)` typed params lower to Clojure `^Tag` metadata — EXCEPT
  ;; Int/Float, whose primitive hints (^long/
  ;; ^double) are dropped: babashka ignores them and GraalVM AOT rejects
  ;; them, so Int/Float params emit bare like untyped ones.
  (define out (compile '(defn add [(x Int) (y Int)] Int (+ x y))))
  (check-true (matches? #rx"\\(defn add \\[x y\\]" out))
  (check-true (matches? #rx"\\(\\+ x y\\)"            out)))

(test-case "primitive array params emit array tags without enabling ^long"
  (define out
    (compile '(defn arrays [(bytes (Arr I8)) (entries (Arr Int)) (index Int)] Int
                (aget entries index))))
  (check-true (matches? #rx"\\[\\^bytes bytes \\^longs entries index\\]" out))
  (check-false (matches? #rx"\\^long([ ^])" out)))

(test-case "authored Java imports make class hints safe on params and lets"
  (define out
    (compile '(import java.io.RandomAccessFile)
             '(import java.nio.channels.FileChannel)
             '(defn size [(file RandomAccessFile)] Int
                (let [channel FileChannel (.getChannel file)]
                  (.size channel)))))
  (check-true (matches? #rx"\\[\\^RandomAccessFile file\\]" out))
  (check-true (matches? #rx"\\[\\^FileChannel channel \\(\\.getChannel file\\)\\]" out)))

;; Omitted binding types are gone, so a vector mixing a bare binder with a
;; grouped declaration is rejected — naming the binder left without a type.
(test-case "mixed inferred and typed parameters are rejected"
  (check-exn
   #rx"parameter a has no following type"
   (lambda () (compile '(defn select [a (b String)] Any b)))))

(test-case "unchecked constraint emission fails closed without a sync proof"
  (check-exn
   (lambda (failure)
     (and (exn:fail? failure)
          (regexp-match?
           #rx"binding constraint for value lacks.*positive synchronization proof"
           (exn-message failure))))
   (lambda ()
     (compile '(defn accept [(value Int positive?)] Int value)))))

(test-case "let emits with brackets"
  (define out (compile `(def y (let ,(br 'x 'Int 1 'y 'Int 2) (+ x y)))))
  (check-true (matches? #rx"\\(let \\[" out)))

(test-case "if with and without else"
  (define a (compile '(def y (if true 1 2))))
  (define b (compile '(def y (if true 1))))
  (check-true (matches? #rx"\\(if true 1 2\\)" a))
  (check-true (matches? #rx"\\(if true 1\\)"  b)))

(test-case "cond emits as Clojure cond"
  (define out (compile `(def y (cond ,(br 'true 1) ,(br 'false 2)))))
  (check-true (matches? #rx"\\(cond" out))
  (check-true (matches? #rx"true 1"  out))
  (check-true (matches? #rx"false 2" out)))

;; when removed — interim (if c body) / (if c (do b1 b2 …)) pattern; covered
;; by general if + do emit tests.

(test-case "do emits"
  (define out (compile '(def y (do 1 2 3))))
  (check-true (matches? #rx"\\(do" out)))

(test-case "fn emits"
  (define out (compile '(def f (fn [x] Int (+ x 1)))))
  (check-true (matches? #rx"\\(fn \\[x\\]" out)))

(test-case "vector literal emits with brackets"
  (define out (compile `(def xs ,(br 1 2 3))))
  (check-true (matches? #rx"\\[1 2 3\\]" out)))

(test-case "function call emits"
  (define out (compile '(def y (add 1 2))))
  (check-true (matches? #rx"\\(add 1 2\\)" out)))

(test-case "qualified value reference prints from structural qualification"
  (define out (compile '(def upper str/upper-case)))
  (check-true (matches? #rx"\\(def upper str/upper-case\\)" out)))

(test-case "imported bare call becomes structural before printing"
  (define parsed
    (parse-program
     (list (datum->syntax #f '(def y (upper-case "hi"))))))
  (define prog
    (struct-copy program parsed
                 [imported-symbol-ns (hasheq 'upper-case 'str)]))
  (define out (emit-program prog))
  (check-true (matches? #rx"\\(str/upper-case \"hi\"\\)" out)))

(test-case "monotonic clock primitive emits the JVM monotonic clock"
  (define out (compile '(defn now [] Int (monotonic-nanoseconds))))
  (check-true (matches? #rx"\\(System/nanoTime\\)" out)))

(test-case "keyword access in call position emits as an expression-valued head"
  (define out (compile '(defn call-keyword [m] Any ((:k m)))))
  (check-true (matches? #rx"\\(\\(:k m\\)\\)" out)))

(test-case "^:dynamic def metadata survives Clojure emission"
  (define out (compile '(def (#%meta :dynamic *arity-check?*) Bool true)))
  (check-true (matches? #rx"\\(def \\^:dynamic \\^Boolean \\*arity-check\\?\\* true\\)" out)))

(test-case "boolean literals render Clojure-style"
  (define a (compile '(def y true)))
  (define b (compile '(def y false)))
  (check-true (matches? #rx"\\(def y true\\)"  a))
  (check-true (matches? #rx"\\(def y false\\)" b)))

;; Racket-style #t/#f map to Clojure true/false too
(test-case "Racket #t / #f render as Clojure true / false"
  (define a (compile '(def y #t)))
  (define b (compile '(def y #f)))
  (check-true (matches? #rx"\\(def y true\\)"  a))
  (check-true (matches? #rx"\\(def y false\\)" b)))

(test-case "unsafe-clj is rejected at parse time"
  (check-exn (lambda (e) (and (exn:fail? e)
                              (regexp-match? #rx"escape hatches are not available"
                                             (exn-message e))))
             (lambda () (compile '(unsafe-clj "(defn h [] :ok)")))))

;; --- macro expansion shows up in emitted code ------------------------------

(test-case "procedural macro expansion emits as direct Clojure"
  (define out (compile
               `(defmacro inc1 ,(br 'x)
                  (quasiquote (+ (unquote x) 1)))
               '(defn use [n] Any (inc1 n))))
  (check-true (matches? #rx"\\(\\+ n 1\\)" out)))

;; --- require emits in ns form ---------------------------------------------

(test-case "require with alias emits in ns :require"
  (define out
    (compile-rooted-require
     'beagle.example.helpers
     "beagle/example/helpers.bclj"
     (list 'require (br 'beagle.example.helpers ':as 'h))))
  (check-true (matches? #rx":require" out))
  (check-true (matches? #rx"\\[beagle\\.example\\.helpers :as h\\]" out)))

(test-case "require without alias emits :as with module name"
  (define out
    (compile-rooted-require
     'beagle.helpers
     "beagle/helpers.bclj"
     (list 'require (br 'beagle.helpers))))
  (check-true (matches? #rx"\\[beagle\\.helpers :as helpers\\]" out)))

(test-case "clojure namespace require emits in ns :require"
  (define out (compile `(require ,(br 'clojure.string ':as 'str))
                       '(def x (str/upper-case "hi"))))
  (check-true (matches? #rx"\\[clojure\\.string :as str\\]" out))
  (check-true (matches? #rx"str/upper-case" out)))

(test-case "multiple clojure requires emit correctly"
  (define out (compile `(require ,(br 'clojure.string ':as 'str))
                       `(require ,(br 'clojure.set ':as 'cset))
                       '(def x 1)))
  (check-true (matches? #rx"\\[clojure\\.string :as str\\]" out))
  (check-true (matches? #rx"\\[clojure\\.set :as cset\\]" out)))

;; --- regex literal ---------------------------------------------------------

;; Regex literals must emit as native #"..." (2026-06-12: the previous
;; (re-pattern "...") lowering produced invalid string escapes for any
;; pattern containing backslashes — #"\d" emitted (re-pattern "\d")).
(test-case "regex literal emits as native Clojure regex literal"
  (define out (compile '(def x (#%regex "\\s+"))))
  (check-true (matches? #rx"#\"\\\\s\\+\"" out))
  (check-false (matches? #rx"re-pattern" out)))

(test-case "regex in function call emits correctly"
  (define out (compile `(require ,(br 'clojure.string ':as 'str))
                       '(def x (str/split "a b" (#%regex "\\s+")))))
  (check-true (matches? #rx"str/split" out))
  (check-true (matches? #rx"#\"\\\\s\\+\"" out)))

(test-case "regex literal gets no ^{:line} metadata (Pattern is not IObj)"
  ;; Attaching metadata to a regex literal crashes the Clojure reader.
  (define out (compile '(def x (#%regex "\\d{4}"))))
  (check-false (matches? #rx"\\^\\{[^}]*\\} *#\"" out)))

;; --- declare-extern does not emit code ------------------------------------

(test-case "declare-extern is a type-only declaration; emits nothing"
  (define out (compile `(declare-extern foo ,(fn-ty '(Int) 'Int))
                       '(def x 1)))
  (check-false (matches? #rx"foo" out)))

;; --- macro &rest with splice emits correctly -------------------------------

(test-case "macro &rest with splice emits as expected Clojure call"
  (define out (compile
               `(defmacro call-it ,(br 'f '& 'args) (apply list f args))
               '(defn use [] Any (call-it + 1 2 3))))
  (check-true (matches? #rx"\\(\\+ 1 2 3\\)" out)))

;; --- loop/recur emits as Clojure loop/recur --------------------------------

(test-case "loop/recur emits"
  (define out (compile
               `(def x (loop ,(br 'acc 'Int 0 'n 'Int 10)
                  (if (= n 0) acc (recur (+ acc n) (- n 1)))))))
  (check-true (matches? #rx"\\(loop \\[acc 0" out))
  (check-true (matches? #rx"\\(recur \\(\\+ acc n\\)" out)))

;; --- for emits as Clojure for -----------------------------------------------

(test-case "for comprehension emits"
  (define out (compile
               '(def xs (for [x (range 10) y (range x)]
                  (+ x y)))))
  (check-true (matches? #rx"\\(for \\[x \\(range 10\\)" out))
  (check-true (matches? #rx"y \\(range x\\)" out))
  (check-true (matches? #rx"\\(\\+ x y\\)" out)))

(test-case "for with :when emits"
  (define out (compile
               '(def xs (for [x (range 10) :when (> x 5)] x))))
  (check-true (matches? #rx"\\(for" out))
  (check-true (matches? #rx":when" out)))

;; --- macro hygiene in emitted code ----------------------------------------

(test-case "procedural macro hygiene: emitted let doesn't shadow outer binding"
  (define out (compile
               `(defmacro with-temp ,(br 'val 'body)
                  ,(list 'quasiquote
                         (list 'let
                               (br 'x 'Int (list 'unquote 'val))
                               (list 'unquote 'body))))
               `(def y (let ,(br 'x 'Int 42) (with-temp 1 x)))))
  (check-true (matches? #rx"\\(let \\[x 42\\]" out))
  (check-false (matches? #rx"\\(let \\[x 1\\]" out)))

;; --- defrecord ---------------------------------------------------------------

(test-case "defrecord emits Clojure defrecord plus accessors"
  (define out (compile `(defrecord Employee ,(br (list 'name 'String) (list 'rate 'Int)))))
  (check-true (matches? #rx"\\(defrecord Employee \\[name rate\\]\\)" out))
  (check-true (matches? #rx"\\(defn employee-name \\[r\\] \\(:name r\\)\\)" out))
  (check-true (matches? #rx"\\(defn employee-rate \\[r\\] \\(:rate r\\)\\)" out)))

;; --- Java interop ------------------------------------------------------------

(test-case "dot-method emits as (.method target args)"
  (define out (compile '(def x (.trim s))))
  (check-true (matches? #rx"\\(\\.trim s\\)" out)))

(test-case "dot-method with args emits correctly"
  (define out (compile '(def x (.startsWith s "http"))))
  (check-true (matches? #rx"\\(\\.startsWith s \"http\"\\)" out)))

(test-case "static method emits as (Class/method args)"
  (define out (compile '(def x (System/getProperty "user.home"))))
  (check-true (matches? #rx"\\(System/getProperty \"user\\.home\"\\)" out)))

(test-case "dynamic var emits as *name*"
  (define out (compile '(def x (first *command-line-args*))))
  (check-true (matches? #rx"\\*command-line-args\\*" out)))

;; --- map literals ------------------------------------------------------------

(define MT MAP-TAG)
(define (mt . xs) (cons MT xs))

(test-case "map literal emits as Clojure map"
  (define out (compile `(def m ,(mt ':a 1 ':b 2))))
  (check-true (matches? #rx"\\{:a 1 :b 2\\}" out)))

(test-case "empty map literal emits"
  (define out (compile `(def m ,(mt))))
  (check-true (matches? #rx"\\{\\}" out)))

(test-case "nested map in vector emits"
  (define out (compile `(def xs ,(br (mt ':a 1)))))
  (check-true (matches? #rx"\\[\\{:a 1\\}\\]" out)))

;; --- set literals ------------------------------------------------------------

(define ST SET-TAG)
(define (st . xs) (cons ST xs))

(test-case "set literal emits as Clojure set"
  (define out (compile `(def s ,(st 1 2 3))))
  (check-true (matches? #rx"#\\{1 2 3\\}" out)))

(test-case "empty set literal emits"
  (define out (compile `(def s ,(st))))
  (check-true (matches? #rx"#\\{\\}" out)))

;; --- import ------------------------------------------------------------------

(test-case "import emits :import in ns form"
  (define out (compile '(import java.io.File)
                       '(def x 1)))
  (check-true (matches? #rx":import" out))
  (check-true (matches? #rx"\\[java\\.io File\\]" out)))

(test-case "multiple imports emit correctly"
  (define out (compile '(import java.io.File)
                       '(import java.util.ArrayList)
                       '(def x 1)))
  (check-true (matches? #rx"\\[java\\.io File\\]" out))
  (check-true (matches? #rx"\\[java\\.util ArrayList\\]" out)))

(test-case "import with require emits both"
  (define out (compile `(require ,(br 'clojure.string ':as 'str))
                       '(import java.io.File)
                       '(def x 1)))
  (check-true (matches? #rx":require" out))
  (check-true (matches? #rx":import" out))
  (check-true (matches? #rx"\\[clojure\\.string :as str\\]" out))
  (check-true (matches? #rx"\\[java\\.io File\\]" out)))

;; --- try/catch/finally -------------------------------------------------------

(test-case "try/catch emits as Clojure try/catch"
  (define out (compile '(def x (try (/ 1 0) (catch Exception e (str e))))))
  (check-true (matches? #rx"\\(try" out))
  (check-true (matches? #rx"\\(catch Exception e" out))
  (check-true (matches? #rx"\\(str e\\)" out)))

(test-case "try/catch/finally emits all parts"
  (define out
    (compile
     '(def x
        (try (risky) (catch Exception e "err") (finally (cleanup))))))
  (check-true (matches? #rx"\\(try" out))
  (check-true (matches? #rx"\\(catch Exception e" out))
  (check-true (matches? #rx"\\(finally" out))
  (check-true (matches? #rx"\\(cleanup\\)" out)))

(test-case "try with multiple catches emits both"
  (define out (compile '(def x (try (risky)
    (catch ArithmeticException e "math")
    (catch Exception e "other")))))
  (check-true (matches? #rx"ArithmeticException" out))
  (check-true (matches? #rx"Exception e" out)))

;; --- doseq -------------------------------------------------------------------

(test-case "doseq emits as Clojure doseq"
  (define out (compile '(doseq [x (range 10)] (println x))))
  (check-true (matches? #rx"\\(doseq \\[x \\(range 10\\)\\]" out))
  (check-true (matches? #rx"\\(println x\\)" out)))

(test-case "doseq with :when emits"
  (define out (compile '(doseq [x (range 10) :when (even? x)] (println x))))
  (check-true (matches? #rx"\\(doseq" out))
  (check-true (matches? #rx":when" out)))

;; case removed — use (match x [v1 body1] [v2 body2] [_ default]) or
;; (match x [(or v1 v2) shared-body] [_ default]). Case-fold optimization
;; in the Clojure emitter lowers literal-only match -> native (case ...).
;; See "match: or-pattern + case-fold optimization" tests below.

;; --- constructor calls -------------------------------------------------------

(test-case "constructor call emits as Clojure constructor"
  (define out (compile '(def f (File. "/tmp"))))
  (check-true (matches? #rx"\\(File\\. \"/tmp\"\\)" out)))

(test-case "constructor with no args emits"
  (define out (compile '(def x (ArrayList.))))
  (check-true (matches? #rx"\\(ArrayList\\.\\)" out)))

(test-case "constructor with multiple args emits"
  (define out (compile '(def p (Point. 10 20))))
  (check-true (matches? #rx"\\(Point\\. 10 20\\)" out)))

;; (:keyword target) call-form removed — use (get m :key) for maps,
;; (field-name r) for record field access.

;; --- defprotocol -----------------------------------------------------------

(test-case "defprotocol emits"
  (define out (compile `(defprotocol Greetable
                          (greet ,(br (list 'self 'Any)) String))))
  (check-true (matches? #rx"defprotocol Greetable" out))
  (check-true
   (matches? #rx"\\(\\$beagle\\$protocol\\$Greetable\\$greet \\[" out))
  (check-true (matches? #rx"\\(defn greet \\[" out)))

;; defmulti / defmethod removed (zero corpus usage).

;; --- destructuring ----------------------------------------------------------

(define (mp . xs) (cons MAP-TAG xs))

(test-case "map destructure in params emits"
  (define out (compile `(defn process
                          ,(br (list (mp ':keys (br 'name 'age)) '(Map Keyword Any)))
                          Any
                          (println name))))
  (check-true (matches? #rx"\\{:keys \\[name age\\]\\}" out)))

(test-case "map destructure with :as emits"
  (define out (compile `(defn process
                          ,(br (list (mp ':keys (br 'x 'y) ':as 'm) '(Map Keyword Any)))
                          Any
                          (println x))))
  (check-true (matches? #rx"\\{:keys \\[x y\\] :as m\\}" out)))

(test-case "map destructure in let emits"
  (define out (compile `(let ,(br (mp ':keys (br 'x 'y)) 'point) (+ x y))))
  (check-true (matches? #rx"\\{:keys \\[x y\\]\\} point" out)))

;; --- sequential destructuring ------------------------------------------------

(test-case "sequential destructure in params emits"
  (define out (compile `(defn process
                          ,(br (list (br 'a 'b 'c) '(HVec Any Any Any)))
                          Any
                          (println a))))
  (check-true (matches? #rx"\\[a b c\\]" out)))

(test-case "sequential destructure with & rest emits"
  (define out (compile `(defn process
                          ,(br (list (br 'a 'b '& 'rest) '(Vec Any)))
                          Any
                          (println a))))
  (check-true (matches? #rx"\\[a b & rest\\]" out)))

(test-case "sequential destructure in let emits"
  (define out (compile `(let ,(br (br 'a 'b) 'coll) (+ a b))))
  (check-true (matches? #rx"\\[a b\\] coll" out)))

;; --- extend-type -------------------------------------------------------------
;;
;; deftype removed (2026-05 surface drop). Use (defrecord Name [...]) for the
;; data shape and (extend-type Name Protocol (method ...)) for the protocol
;; impls. The decomposition is the canonical idiom — bundling them into deftype
;; conflates data shape and protocol attachment.

(test-case "extend-type emits"
  (define out (compile `(extend-type String
                          Showable
                          (show ,(br (list 'self 'String)) String (str self)))))
  (check-true (matches? #rx"\\(extend-type String" out))
  (check-true (matches? #rx"Showable" out))
  (check-true
   (matches? #rx"\\(\\$beagle\\$protocol\\$Showable\\$show \\[\\^String self\\]" out)))

;; --- threading macros: surface reconstruction at emit ------------------------
;;
;; The threading family (-> / ->> / as-> / cond-> / cond->> / some-> / some->>)
;; desugars at parse-time for the type checker and the Nix emitter, but the
;; clj emitter recognises the threading-marker wrapper and reconstructs
;; the surface form so the emitted Clojure is idiomatic (not a flattened call
;; chain). orig-args carries the parsed surface args; emit walks them with
;; emit-expr so any inner forms also emit normally.

(test-case "-> emits surface thread-first form"
  (define out (compile '(def x (-> 1 (foo) (bar)))))
  (check-true (matches? #rx"\\(-> 1 \\(foo\\) \\(bar\\)\\)" out)))

(test-case "-> with bare-symbol step keeps the symbol bare"
  ;; (-> x f g) is valid Clojure; the macro auto-wraps bare symbols.
  ;; The surface form must round-trip, not expand to (g (f x)).
  (define out (compile '(def y (-> x f g))))
  (check-true (matches? #rx"\\(-> x f g\\)" out)))

(test-case "->> emits surface thread-last form"
  (define out (compile '(def x (->> coll (map inc) (filter even?)))))
  (check-true (matches? #rx"\\(->> coll \\(map inc\\) \\(filter even\\?\\)\\)" out)))

(test-case "as-> emits surface form with placeholder symbol"
  (define out (compile '(def x (as-> 0 v (+ v 1) (* v 2)))))
  (check-true (matches? #rx"\\(as-> 0 v \\(\\+ v 1\\) \\(\\* v 2\\)\\)" out)))

(test-case "cond-> emits surface form with flat test/step pairs"
  (define out (compile '(def x (cond-> 0 true (+ 1) false (+ 2)))))
  (check-true (matches? #rx"\\(cond-> 0 true \\(\\+ 1\\) false \\(\\+ 2\\)\\)" out)))

(test-case "cond->> emits surface form"
  (define out (compile '(def x (cond->> coll true (map inc) false (filter odd?)))))
  (check-true (matches? #rx"\\(cond->> coll true \\(map inc\\) false \\(filter odd\\?\\)\\)" out)))

(test-case "some-> emits surface form"
  (define out (compile '(def x (some-> m (get :k) inc))))
  (check-true (matches? #rx"\\(some-> m \\(get :k\\) inc\\)" out)))

(test-case "some->> emits surface form"
  (define out (compile '(def x (some->> coll (map inc) (filter odd?)))))
  (check-true (matches? #rx"\\(some->> coll \\(map inc\\) \\(filter odd\\?\\)\\)" out)))

;; --- expression-level source mapping ----------------------------------------

(define BT BRACKET-TAG)
(define (located d src line)
  (datum->syntax #f d (vector src line 0 #f #f)))

(test-case "expression-level: inner call gets per-expression metadata"
  (define src "test.bclj")
  (define body-stx (located '(+ x 1) src 2))
  (define params-stx (located (list BT 'x) src 1))
  (define form-stx (located (list 'defn 'f params-stx 'Int body-stx) src 1))
  (define prog (parse-program (list form-stx)))
  (define out (emit-program prog))
  (check-true (matches? #rx"\\^\\{:line 1 :file \"test\\.bclj\"\\} \\(defn" out))
  (check-true (matches? #rx"\\^\\{:line 2 :file \"test\\.bclj\"\\} \\(\\+ x 1\\)" out)))

(test-case "expression-level: atoms don't get metadata"
  (define src "test.bclj")
  (define form-stx (located '(def x 42) src 1))
  (define prog (parse-program (list form-stx)))
  (define out (emit-program prog))
  (check-false (matches? #rx"\\^\\{.*\\} 42" out)))

(test-case "expression-level: let value expressions get metadata"
  (define src "test.bclj")
  (define value-stx (located '(+ 1 2) src 3))
  (define bindings-stx (located (list BT 'x value-stx) src 2))
  (define body-stx (located '(+ x 1) src 4))
  (define form-stx (located (list 'def 'y (list 'let bindings-stx body-stx)) src 1))
  (define prog (parse-program (list form-stx)))
  (define out (emit-program prog))
  (check-true (matches? #rx"\\^\\{:line 3 :file \"test\\.bclj\"\\} \\(\\+ 1 2\\)" out))
  (check-true (matches? #rx"\\^\\{:line 4 :file \"test\\.bclj\"\\} \\(\\+ x 1\\)" out)))

(test-case "expression-level: src-table is populated"
  (define src "test.bclj")
  (define body-stx (located '(+ x 1) src 2))
  (define params-stx (located (list BT 'x) src 1))
  (define form-stx (located (list 'defn 'f params-stx 'Int body-stx) src 1))
  (define prog (parse-program (list form-stx)))
  (check-true (> (hash-count (program-src-table prog)) 0)))

(test-case "expression-level: no metadata when syntax has no source location"
  (define out (compile '(defn f [x] Int (+ x 1))))
  (check-false (matches? #rx"\\^\\{" out)))

;; --- with form emission ------------------------------------------------------

(test-case "with emits assoc"
  (define out (compile `(defrecord P ,(br (list 'x 'Int)))
                       `(def p (->P 1))
                       `(def q (with p ,(br ':x 2)))))
  (check-true (matches? #rx"\\(assoc p :x 2\\)" out)))

(test-case "with multi-field emits multi-arg assoc"
  (define out (compile `(defrecord P ,(br (list 'x 'Int) (list 'y 'Int)))
                       `(def p (->P 1 2))
                       `(def q (with p ,(br ':x 10) ,(br ':y 20)))))
  (check-true (matches? #rx"\\(assoc p :x 10 :y 20\\)" out)))

;; --- defenum emission --------------------------------------------------------

(test-case "defenum emits set def"
  (define out (compile '(defenum Color :red :green :blue)))
  (check-true (matches? #rx"\\(def Color-values #\\{" out))
  (check-true (matches? #rx":red" out))
  (check-true (matches? #rx":green" out))
  (check-true (matches? #rx":blue" out)))

;; --- defscalar emission -------------------------------------------------------

(test-case "defscalar without :where emits comment (erased)"
  (define out (compile '(defscalar Amount Int)
                       '(def x Amount (->Amount 42))))
  (check-true (matches? #rx";; Amount : Int \\(scalar\\)" out))
  (check-false (matches? #rx"defn ->Amount" out)))

(test-case "defscalar with :where emits constructor with :pre"
  (define out (compile '(defscalar Percentage Int :where (>= 0) (<= 100))
                       '(def x Percentage (->Percentage 50))))
  (check-true (matches? #rx"defn ->Percentage" out))
  (check-true (matches? #rx":pre" out))
  (check-true (matches? #rx"\\(>= v 0\\)" out))
  (check-true (matches? #rx"\\(<= v 100\\)" out)))

(test-case "defscalar with :where constructor is not erased at call site"
  (define out (compile '(defscalar Percentage Int :where (>= 0) (<= 100))
                       '(def x Percentage (->Percentage 50))))
  (check-true (matches? #rx"\\(->Percentage 50\\)" out)))

;; --- varargs emission --------------------------------------------------------

(test-case "defn with & rest emits Clojure varargs"
  ;; Int/Float params emit bare (their ^long/^double primitive hints are
  ;; dropped — babashka ignores them, GraalVM AOT rejects them). The host rest
  ;; seq stays compiler-owned and is normalized to Beagle's aggregate Vec.
  (define out (compile '(defn my-sum [(x Int) & (rest (Vec Int))] Int
                          (+ x (reduce + 0 rest)))))
  (check-true
   (matches? #rx"\\(defn my-sum \\[x & \\$beagle\\$rest\\$host\\]" out))
  (check-true
   (matches? #rx"\\(let \\[rest \\(vec \\$beagle\\$rest\\$host\\)\\]" out)))

(test-case "fn with & rest emits varargs"
  (define out (compile '(def f (fn [(a Int) & (b (Vec Int))] Int (+ a 1)))))
  (check-true (matches? #rx"\\(fn \\[a & \\$beagle\\$rest\\$host\\]" out))
  (check-true
   (matches? #rx"\\(let \\[b \\(vec \\$beagle\\$rest\\$host\\)\\]" out)))

(test-case "defn with only & rest and no fixed params"
  (define out (compile '(defn log-it [& (msgs (Vec String))] String
                          (clojure.string/join ", " msgs))))
  (check-true
   (matches? #rx"log-it \\[& \\$beagle\\$rest\\$host\\]" out))
  (check-true
   (matches? #rx"\\(let \\[msgs \\(vec \\$beagle\\$rest\\$host\\)\\]" out)))

;; --- metadata emission -------------------------------------------------------

(test-case "metadata emits ^{...} prefix"
  (define out (compile `(def x (#%meta (,MT :stretch 1) ,(br 1 2 3)))))
  (check-true (matches? #rx"\\^\\{:stretch 1\\}" out))
  (check-true (matches? #rx"\\[1 2 3\\]" out)))

(test-case "metadata keyword shorthand emits correctly"
  (define out (compile `(def x (#%meta (,MT :dynamic true) ,(br 4 5)))))
  (check-true (matches? #rx"\\^\\{:dynamic true\\}" out)))

(test-case "nested metadata in vector"
  (define out (compile `(def z ,(br `(#%meta (,MT :stretch 1) ,(br 'a))
                                     `(#%meta (,MT :stretch 2) ,(br 'b))))))
  (check-true (matches? #rx"\\^\\{:stretch 1\\}" out))
  (check-true (matches? #rx"\\^\\{:stretch 2\\}" out)))

;; when-let / if-let removed — interim (let [x Any v] (if x …)) pattern emits
;; standard let + if Clojure forms (already covered by let/if emit tests).

(test-case "with-open emits"
  (define out (compile '(defn f [(p String)] Any (with-open [r (slurp p)] r))))
  (check-true (matches? #rx"\\(with-open \\[r" out)))

(test-case "doto emits"
  (define out (compile '(def x (doto (atom 1) (reset! 2)))))
  (check-true (matches? #rx"\\(doto" out)))

(test-case "for with :let emits"
  (define out (compile `(def x (for ,(br 'i '(range 3) ':let (br 's '(str i))) s))))
  (check-true (matches? #rx":let \\[s" out)))

;; when-not / if-not removed — use (when (not ...)) / (if (not ...) ...).

;; --- comment ---

(test-case "comment emits nil"
  (define out (compile '(def x (comment (+ 1 2)))))
  (check-true (matches? #rx"nil" out)))

;; dotimes removed — use (doseq [i (range n)] body).

;; --- condp ---

(test-case "condp emits with default"
  (define out (compile '(defn f [(x Keyword)] String (condp = x :a "alpha" :b "beta" "other"))))
  (check-true (matches? #rx"\\(condp = x" out))
  (check-true (matches? #rx":a \"alpha\"" out))
  (check-true (matches? #rx"\"other\"" out)))

;; --- defonce ---

(test-case "defonce emits"
  (define out (compile '(defonce db (atom nil))))
  (check-true (matches? #rx"\\(defonce db" out)))

;; --- letfn ---

(test-case "letfn emits"
  (define out (compile '(defn outer [] Int
                          (letfn [(f [(x Int)] Int (+ x 1))
                                  (g [(x Int)] Int (f x))]
                            (g 10)))))
  (check-true (matches? #rx"\\(letfn \\[" out))
  (check-true (matches? #rx"\\(f \\[x\\]" out))
  (check-true (matches? #rx"\\(g \\[x\\]" out))
  (check-true (matches? #rx"\\(g 10\\)" out)))

(test-case "letfn emits rest param"
  (define out (compile '(defn outer [] Int
                          (letfn [(f [(x Int) & (rest (Vec Int))] Int x)]
                            (f 1 2 3)))))
  (check-true (matches? #rx"\\(letfn \\[" out))
  (check-true
   (matches? #rx"\\(f \\[x & \\$beagle\\$rest\\$host\\]" out))
  (check-true
   (matches? #rx"\\(let \\[rest \\(vec \\$beagle\\$rest\\$host\\)\\]" out)))

;; --- check/rescue ------------------------------------------------------------

(test-case "check emits let+if pattern"
  (define out (compile '(def x (check (fetch-user 1)))))
  (check-true (matches? #rx"let \\[r__check" out))
  (check-true (matches? #rx"Ok" out)))

(test-case "rescue emits let+if pattern"
  (define out (compile '(def x (rescue (fetch-user 1) default-user))))
  (check-true (matches? #rx"let \\[r__rescue" out))
  (check-true (matches? #rx"Ok" out)))

(test-case "rescue with error binding emits binding name"
  (define out (compile '(def x (rescue (fetch-user 1) err (handle-error err)))))
  (check-true (matches? #rx"let \\[r__rescue" out))
  (check-true (matches? #rx"err" out)))

;; --- defunion :throwable -----------------------------------------------------

(test-case "defunion :throwable emits defrecord per variant"
  (define out (compile `(defunion :throwable ApiError
                          (NotFound ,(br (list 'id 'Int)))
                          (RateLimit ,(br (list 'retry-after 'Int))))))
  (check-true (matches? #rx"error ApiError" out))
  (check-true (matches? #rx"\\(defrecord NotFound" out))
  (check-true (matches? #rx"\\(defrecord RateLimit" out)))

;; --- target-case -------------------------------------------------------------

(test-case "target-case selects clj branch"
  (define out (compile '(def x (target-case :clj "clojure" :js "javascript"))))
  (check-true (matches? #rx"\"clojure\"" out))
  (check-false (matches? #rx"\"javascript\"" out)))

;; --- set! ------------------------------------------------------------------

(test-case "set! on a symbol emits Clojure set!"
  (define out (compile '(defn f [] Any (set! *warn-on-reflection* true))))
  (check-true (matches? #rx"\\(set! \\*warn-on-reflection\\* true\\)" out)))

(test-case "set! on a method-call target wraps in (set! (.field obj) val)"
  (define out (compile '(defn f [(o Any)] Any (set! (.-name o) "x"))))
  (check-true (matches? #rx"\\(set! \\(\\.-name o\\) \"x\"\\)" out)))

;; (:keyword target) call-form removed — use (get m :key) for maps.

;; --- condp without default --------------------------------------------------

(test-case "condp without default omits trailing default clause"
  (define out (compile '(defn f [(k Keyword)] String (condp = k :a "alpha" :b "beta"))))
  (check-true (matches? #rx"\\(condp = k" out))
  (check-true (matches? #rx":a \"alpha\"" out))
  (check-true (matches? #rx":b \"beta\"" out))
  ;; default would be a 3-element format; without one, the output should
  ;; not end with a stray "other" branch
  (check-false (matches? #rx"\"other\"" out)))

;; --- match: record pattern with no bindings ---------------------------------

(test-case "match record pattern with empty bindings emits bare instance? test"
  (define out (compile `(defrecord Tag ,(br (list 'n 'Int)))
                       `(defn f [(t Any)] Int
                          (match t
                            ,(br '(Tag) 0)
                            ,(br '_ 1)))))
  (check-true (matches? #rx"\\(instance\\? Tag" out)))

(test-case "match map pattern with single key emits unwrapped test"
  (define out
    (compile `(defn f [(m Any)] Int
                (match m
                  ,(br (mt ':k 1) 10)
                  ,(br '_ 20)))))
  (check-true (matches? #rx"\\(= \\(:k " out))
  (check-false (matches? #rx"\\(and \\(=" out)))

;; --- match: or-pattern + case-fold optimization (Clojure target) ---
;;
;; All-literal-dispatch match (with optional wildcard/var default) gets
;; lowered to Clojure's `case` form for O(1) dispatch — preserves the
;; perf characteristic of the dropped `case` form after it's folded into
;; match+or. Mixed-pattern matches (records + literals, etc.) fall
;; through to the general (let ... (cond ...)) emission, where or-pattern
;; emits as combined (or test1 test2 ...).

(test-case "or-pattern of integer literals — case-fold to (case x ...)"
  (define out
    (compile `(defn f [(x Int)] String
                (match x
                  ,(br '(or 1 2 3) "low")
                  ,(br '_ "other")))))
  (check-true (matches? #rx"\\(case x" out))
  (check-true (matches? #rx"\\(1 2 3\\) \"low\"" out))
  (check-true (matches? #rx"\"other\"" out)))

(test-case "or-pattern of keyword literals — case-fold to (case k ...)"
  (define out
    (compile `(defn f [(k Keyword)] String
                (match k
                  ,(br '(or :a :b) "first")
                  ,(br '_ "other")))))
  (check-true (matches? #rx"\\(case k" out))
  (check-true (matches? #rx"\\(:a :b\\) \"first\"" out)))

(test-case "or-pattern mixed with non-literal — falls through to cond chain"
  (define out
    (compile `(defrecord Tag ,(br (list 'n 'Int)))
             `(defn f [(x Any)] Int
                (match x
                  ,(br '(or 1 2) 10)
                  ,(br '(Tag n) 'n)
                  ,(br '_ 0)))))
  ;; Not case-foldable because (Tag n) is not a literal; emits the
  ;; general cond chain with (or test1 test2) for the literal alternatives.
  (check-true (matches? #rx"\\(cond" out))
  (check-true (matches? #rx"\\(or \\(= " out)))

;; --- new-form (single-arg constructor) -------------------------------------

(test-case "new-form with one arg emits as call"
  (define out (compile `(defrecord Box ,(br (list 'v 'Int)))
                       '(def b (Box 42))))
  (check-true (matches? #rx"\\(Box 42\\)" out)))

;; --- with-form (record update) -----------------------------------------------

(test-case "with-form emits assoc"
  (define out
    (compile `(defrecord P ,(br (list 'x 'Int) (list 'y 'Int)))
             `(defn shift [(p P)] P
                (with p ,(br ':x '(+ (p-x p) 1)) ,(br ':y '(+ (p-y p) 1))))))
  (check-true (matches? #rx"\\(assoc p :x" out))
  (check-true (matches? #rx":y \\(\\+ \\(p-y p\\)" out)))

(test-case "qualified record validator prints from structural qualification"
  (define parsed
    (parse-program
     (list
      (datum->syntax #f `(def updated (with score ,(br ':value 2)))))))
  (define update
    (def-form-value (car (program-forms parsed))))
  (define validator
    (qualified-ref 'records '$beagle$record$Score$validate
                   'constraints.records))
  (define prog
    (struct-copy
     program
     parsed
     [semantic-contracts
      (hasheq
       update
       (record-update-contract
        (qualified-ref 'records 'Score 'constraints.records)
        validator
        '(:value)))]))
  (define out (emit-program prog))
  (check-true
   (matches?
    #rx"\\(records/\\$beagle\\$record\\$Score\\$validate \\$beagle\\$record\\$update\\$candidate\\)"
    out)))

;; --- defenum ---------------------------------------------------------------

(test-case "defenum emits set of keywords with -values suffix"
  (define out (compile '(defenum Color red green blue)))
  (check-true (matches? #rx"\\(def Color-values #\\{" out))
  (check-true (matches? #rx":red" out))
  (check-true (matches? #rx":blue" out)))

;; --- defunion (closed, with member fields) ----------------------------------

(test-case "defunion with member fields emits comment + per-variant defrecord"
  (define out (compile `(defunion Shape
                          (Circle ,(br (list 'radius 'Int)))
                          (Square ,(br (list 'side 'Int))))))
  (check-true (matches? #rx";; Shape = Circle \\| Square" out))
  (check-true (matches? #rx"\\(defrecord Circle \\[radius\\]\\)" out))
  (check-true (matches? #rx"\\(defrecord Square \\[side\\]\\)" out)))

;; --- ns emits combined :require + :import correctly ------------------------

(test-case "ns with both :require and :import emits both clauses"
  (define out (compile `(require ,(br 'clojure.string ':as 'str))
                       '(import java.io.File)
                       '(def x 1)))
  (check-true (matches? #rx":require" out))
  (check-true (matches? #rx":import" out))
  (check-true (matches? #rx"\\[clojure\\.string :as str\\]" out))
  (check-true (matches? #rx"\\[java\\.io File\\]" out)))

;; --- ns with bare-class import (no dot) -------------------------------------

(test-case "ns import for bare class emits plain symbol"
  (define out (compile '(import Exception)
                       '(def x 1)))
  (check-true (matches? #rx":import" out))
  (check-true (matches? #rx"Exception" out)))
