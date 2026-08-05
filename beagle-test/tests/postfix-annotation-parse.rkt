#lang racket/base

;; Parser half of the postfix type-annotation surface: every annotatable
;; position parses AND type-checks, plus the four new diagnostics.
;;
;; Dual-accept cut: legacy `:-` still parses (bindings AND returns) so the
;; corpus can migrate in parallel. Return position is the one structural
;; difference — canonical `->`, legacy `:-`, and `:` REJECTED there.

(require rackunit
         racket/string
         beagle/lang/reader-impl
         beagle/private/parse
         beagle/private/check
         beagle/private/types
         beagle/private/ast)

(define PRELUDE "(ns t)\n(define-mode strict)\n(define-target clj)\n")

(define (read-forms str)
  (parameterize ([current-readtable beagle-readtable])
    (define in (open-input-string str))
    (let loop ()
      (define stx (read-syntax 'postfix-test in))
      (if (eof-object? stx) '() (cons stx (loop))))))

(define (parse-src str) (parse-program (read-forms (string-append PRELUDE str))))
(define (check-src str)
  (parameterize ([current-check-profile 2])
    (type-check! (parse-src str))))

(define-syntax-rule (ok name src)
  (test-case name (check-not-exn (lambda () (check-src src)))))

(define-syntax-rule (err/rx name rx src)
  (test-case name (check-exn rx (lambda () (parse-src src)))))

;; --- every annotatable position ---------------------------------------------

(ok "def"                      "(def answer: Int 42)")
(ok "def + docstring"          "(def answer: Int \"doc\" 42)")
(ok "defonce"                  "(defonce once: Int 1)")
(ok "^:dynamic def"            "(def ^:dynamic *cfg*: Int 1)")
(ok "defn params + return"     "(defn add [x: Int y: Int] -> Int (+ x y))")
(ok "defn mixed typed/untyped" "(defn mix [a: Int b c: String] -> String c)")
(ok "defn wrapped param"       "(defn w [(a: Int)] -> Int a)")
(ok "defn rest param"          "(defn r [a: Int & more: Int] -> Int a)")
(ok "defn :raises"             "(defunion :throwable Boom (Boom [msg: String]))\n(defn f [] -> Int :raises Boom 1)")
(ok "defn- private"            "(defn- p [a: Int] -> Int a)")
(ok "^:private defn"           "(defn ^:private q [a: Int] -> Int a)")
(ok "defn fn-type param"       "(defn hof [cb: [Int -> String]] -> String (cb 1))")
(ok "multi-arity clause returns"
    "(defn m ([a: Int] -> Int a) ([a: Int b: Int] -> Int (+ a b)))")
(ok "anonymous fn return"      "(defn u [a: Int] -> Int ((fn [b: Int] -> Int b) a))")
(ok "letfn return"             "(defn v [a: Int] -> Int (letfn [(h [b: Int] -> Int b)] (h a)))")
(ok "let binding"              "(defn l [a: Int] -> Int (let [n: Int a] n))")
(ok "let wrapped binding"      "(defn lw [a: Int] -> Int (let [(n: Int) a] n))")
(ok "loop binding"             "(defn lp [a: Int] -> Int (loop [i: Int a] i))")
(ok "if-let / when-let binder" "(defn il [a: Int] -> Int (if-let [v: Int a] v 0))")
(ok "for clause + :let"        "(defn fr [xs: (Vec Int)] -> (Vec Int) (for [x: Int xs :let [y: Int x]] y))")
(ok "doseq clause"             "(defn ds [xs: (Vec Int)] -> Nil (doseq [x: Int xs] (println x)))")
(ok "defrecord fields"         "(defrecord P [x: Int y: Int])")
(ok "defrecord wrapped fields" "(defrecord Q [(x: Int) (y: Int)])")
(ok "defunion member fields"   "(defrecord C [r: Int])\n(defrecord S [side: Int])\n(defunion Shape C S)")
(ok "throwable union fields"   "(defunion :throwable Bad (Bad [msg: String]))")
(ok "defprotocol method return"
    "(defprotocol Area (area [self] -> Int))")
(ok "extend-type method return"
    "(defrecord Sq [side: Int])\n(defprotocol Area (area [self] -> Int))\n(extend-type Sq Area (area [self] -> Int (:side self)))")

;; --- dual-accept: legacy `:-` still parses ----------------------------------

(ok "legacy `:-` bindings + return" "(defn old [x :- Int] :- Int x)")
(ok "legacy `:-` def"               "(def oldv :- Int 42)")
(ok "mixed legacy binding + new return" "(defn mixm [x :- Int] -> Int x)")
(ok "mixed new binding + legacy return" "(defn mixn [x: Int] :- Int x)")

;; --- annotations actually populate the type slots ---------------------------

(test-case "postfix annotation populates param/return/def/let type slots"
  (define p (parse-src "(def answer: Int 42)\n(defn add [x: Int] -> String (let [n: Int x] \"s\"))"))
  (define forms (program-forms p))
  (define d (car forms))
  (check-eq? (type-prim-name (def-form-type d)) 'Int)
  (define f (cadr forms))
  (check-eq? (type-prim-name (param-type (car (defn-form-params f)))) 'Int)
  (check-eq? (type-prim-name (defn-form-return-type f)) 'String)
  (define lb (car (let-form-bindings (car (defn-form-body f)))))
  (check-eq? (type-prim-name (let-binding-type lb)) 'Int))

(test-case "type errors still fire through the postfix annotation"
  (check-exn exn:fail? (lambda () (check-src "(def answer: Int \"nope\")"))))

;; --- diagnostics ------------------------------------------------------------

(err/rx "keyword confusion in a param vector"
  #rx"unexpected keyword :Int after binding a; did you mean a: Int\\?"
  "(defn f [a :Int] -> Int a)")

(err/rx "keyword confusion in a defrecord field vector"
  #rx"unexpected keyword :Int after binding x; did you mean x: Int\\?"
  "(defrecord P [x :Int])")

(err/rx "keyword confusion in a let binding"
  #rx"unexpected keyword :Int after binding v; did you mean v: Int\\?"
  "(defn f [a: Int] -> Int (let [v :Int a] v))")

(test-case "a keyword IS a legal let VALUE — the confusion check must not misfire"
  (check-not-exn (lambda () (parse-src "(defn f [] -> Keyword (let [v :Some] v))"))))

(err/rx "dangling marker in a param vector"
  #rx"dangling `:` in parameter list"
  "(defn f [: Int] -> Int 1)")

(err/rx "dangling marker in def"
  #rx"dangling `:` in def"
  "(def : Int 42)")

(err/rx "dangling marker with no type after it"
  #rx"dangling `:` in parameter list"
  "(defn f [a:] -> Int 1)")

(err/rx "marker in return position names `->` (defn)"
  #rx"`:` is not the return-type marker in defn f — write `-> RET`"
  "(defn f [a: Int] : Int a)")

(err/rx "marker in return position names `->` (defn-)"
  #rx"`:` is not the return-type marker in defn- f"
  "(defn- f [a: Int] : Int a)")

(err/rx "marker in return position names `->` (fn)"
  #rx"`:` is not the return-type marker in fn"
  "(defn g [a: Int] -> Int ((fn [b: Int] : Int b) a))")

(err/rx "marker in return position names `->` (multi-arity clause)"
  #rx"`:` is not the return-type marker in multi-arity clause"
  "(defn m ([a: Int] : Int a) ([a: Int b: Int] : Int b))")

(err/rx "marker in return position names `->` (letfn)"
  #rx"`:` is not the return-type marker in letfn h"
  "(defn v [a: Int] -> Int (letfn [(h [b: Int] : Int b)] (h a)))")

(err/rx "schema-style prefix return annotation is still pointed"
  #rx"the return annotation goes after the param vector"
  "(defn f -> Int [a: Int] a)")

;; --- bracketed annotation collides with sequential destructuring ------------

(err/rx "bracketed annotation in a param slot names the paren form"
  #rx"`\\[x : Int\\]` is not a typed binding.*Write the parenthesized form: `\\(x : Int\\)`"
  "(defn f [[x : Int]] -> Int x)")

(err/rx "bracketed annotation in a let binding names the paren form"
  #rx"`\\[n : Int\\]` is not a typed binding.*Write the parenthesized form: `\\(n : Int\\)`"
  "(defn f [a: Int] -> Int (let [[n : Int] a] n))")

(err/rx "bracketed legacy annotation is caught too"
  #rx"`\\[x :- Int\\]` is not a typed binding.*Write the parenthesized form: `\\(x : Int\\)`"
  "(defn f [[x :- Int]] -> Int x)")

(ok "genuine sequential destructuring still parses"
    "(defn f [[a b]] -> Int a)")
(ok "nested + rest destructuring still parses"
    "(defn f [[a [b c]] & more] -> Int a)")

;; --- (PATTERN : Type) — the parenthesized form carries a pattern -------------

(define REC "(defrecord Point [x: Int y: Int])\n")

(ok "seq pattern with a type"
    "(defn sq [([a b] : (Vec Int))] -> Int (+ a b))")
(ok "map pattern with a type"
    (string-append REC "(defn m [({:keys [x y]} : Point)] -> Int 0)"))
(ok "a typed pattern accepts a matching argument"
    (string-append REC
                   "(defn m [({:keys [x y]} : Point)] -> Int 0)\n"
                   "(defn use [p: Point] -> Int (m p))"))

(test-case "a typed seq pattern enforces its declared type at the call site"
  (check-exn #rx"call to sq: arg 1 expected \\(Vec Int\\), got String"
             (lambda ()
               (check-src (string-append
                           "(defn sq [([a b] : (Vec Int))] -> Int (+ a b))\n"
                           "(defn use [] -> Int (sq \"nope\"))")))))

(test-case "a typed map pattern enforces its declared type at the call site"
  (check-exn #rx"call to m: arg 1 expected Point, got String"
             (lambda ()
               (check-src (string-append
                           REC
                           "(defn m [({:keys [x y]} : Point)] -> Int 0)\n"
                           "(defn use [] -> Int (m \"nope\"))")))))

;; --- the `:-` migration diagnostic ------------------------------------------

(test-case "legacy `:-` warns once per source in the default 'warn mode"
  (define out (open-output-string))
  (parameterize ([current-error-port out])
    (parse-program (read-forms (string-append PRELUDE "(defn a [x :- Int] :- Int x)\n(defn b [y :- Int] :- Int y)"))
                   #:source-path "legacy-probe.bclj"))
  (define s (get-output-string out))
  (check-regexp-match #rx"legacy-annotation-marker" s)
  (check-regexp-match #rx"`:-` is the legacy type-annotation marker" s)
  (check-equal? (length (regexp-match* #rx"legacy-annotation-marker" s)) 1
                "the notice is one-per-source, not one-per-occurrence"))

(test-case "'error mode makes legacy `:-` a hard parse error (the removal flip)"
  (define e
    (parameterize ([legacy-annotation-marker-mode 'error])
      (with-handlers ([beagle-parse-error? values])
        (parse-src "(defn a [x :- Int] :- Int x)")
        'no-error-raised)))
  (check-pred beagle-parse-error? e)
  (check-eq? (beagle-parse-error-kind e) 'legacy-annotation-marker)
  (check-equal? (hash-ref (beagle-parse-error-details e) 'cause) "surface-divergence"))

(test-case "'quiet mode emits nothing"
  (define out (open-output-string))
  (parameterize ([current-error-port out]
                 [legacy-annotation-marker-mode 'quiet])
    (parse-src "(defn a [x :- Int] :- Int x)"))
  (check-equal? (get-output-string out) ""))

;; --- bare-multi-arity must bail on a top-level `->` -------------------------

(test-case "a top-level `->` return is single-arity, never a clause boundary"
  (define p (parse-src "(defn f [a: Int] -> [Int -> String] (fn [x: Int] -> String \"s\"))"))
  (define f (car (program-forms p)))
  (check-true (defn-form? f))
  (check-false (defn-multi? f)))

(test-case "a threading `->` CALL in the body is not mistaken for a return marker"
  (check-not-exn
   (lambda () (check-src "(defn f [a: Int] -> Int (-> a (+ 1)))"))))
