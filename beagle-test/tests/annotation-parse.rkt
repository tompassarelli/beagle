#lang racket/base

;; Structural typed bindings and fixed positional return slots.

(require rackunit
         racket/string
         beagle/lang/reader-impl
         beagle/private/parse
         beagle/private/check
         beagle/private/types
         beagle/private/ast
         beagle/private/emit-dispatch
         beagle/private/emit-clj
         beagle/private/emit-js
         beagle/private/emit-nix)

(define PRELUDE "(ns t)\n(define-target clj)\n")

(define (read-forms str)
  (parameterize ([current-readtable beagle-readtable])
    (define in (open-input-string str))
    (let loop ()
      (define stx (read-syntax 'annotation-test in))
      (if (eof-object? stx) '() (cons stx (loop))))))

(define (parse-src str)
  (parse-program (read-forms (string-append PRELUDE str))))

(define (check-src str)
  (parameterize ([current-check-profile 2])
    (type-check! (parse-src str))))

(define-syntax-rule (ok name src)
  (test-case name (check-not-exn (lambda () (check-src src)))))

(define-syntax-rule (err/rx name rx src)
  (test-case name (check-exn rx (lambda () (parse-src src)))))

(define-syntax-rule (check-err/rx name rx src)
  (test-case name (check-exn rx (lambda () (check-src src)))))

(test-case "retired function type reports a stable structured kind"
  (with-handlers ([beagle-parse-error?
                   (lambda (error)
                     (check-eq? (beagle-parse-error-kind error)
                                'legacy-function-type)
                     (check-equal?
                      (hash-ref (beagle-parse-error-details error) 'cause)
                      "surface-divergence"))])
    (parse-src "(def value [Int -> Int] nil)")
    (fail "expected retired function type rejection")))

(test-case "malformed Fn reports a stable structured kind"
  (with-handlers ([beagle-parse-error?
                   (lambda (error)
                     (check-eq? (beagle-parse-error-kind error)
                                'malformed-function-type)
                     (check-equal?
                      (hash-ref (beagle-parse-error-details error) 'cause)
                      "surface-divergence"))])
    (parse-src "(def value (Fn Int Bool) nil)")
    (fail "expected malformed function type rejection")))

;; Legacy grouped declarations remain readable during the enabling seam.
(ok "def"                     "(def answer Int 42)")
(ok "def + docstring"         "(def answer Int \"doc\" 42)")
(ok "untyped def"             "(def answer 42)")
(ok "defonce"                 "(defonce once Int 1)")
(ok "dynamic def"             "(def ^:dynamic *cfg* Int 1)")
(ok "legacy grouped params"
    "(defn f [(x Int) (y Any) (z String)] Int x)")
(ok "flat strict params"
    "(defn f [x Int y Any z String] Int x)")
(ok "wholly inferred params remain readable"
    "(defn f [x y] Any x)")
(ok "wholly inferred rest remains readable"
    "(defn f [x & more] Any x)")
(ok "typed sequential destructuring parameter"
    "(defn f [([x y] (HVec Float Float)) (opts Any)] Float x)")
(ok "typed map destructuring parameter"
    "(defrecord Config [(host String) (port Int)])\n(defn f [({:keys [host port]} Config) (timeout Int)] String host)")
(ok "nested heterogeneous destructuring parameter"
    (string-append
     "(defrecord Config [(host String)])\n"
     "(defn f [([[x y] {:keys [host]}] (HVec (HVec Int Float) Config))] String host)"))
(ok "explicit destructuring Any is a dynamic boundary"
    "(defn f [([x {:keys [y]}] Any)] Any y)")
(ok "homogeneous map default closes missing-key nullability"
    "(defn f [({:keys [x] :or {x 0}} (Map Keyword Int))] Int x)")
(ok "typed rest param"        "(defn r [(x Int) & (more (Vec Int))] Int x)")
(ok "flat rest param"         "(defn r [x Int & more (Vec Int)] Int x)")
(ok "function type param"     "(defn hof [(cb (Fn [Int] String))] String (cb 1))")
(ok "zero-argument function type"
    "(declare-extern host/now (Fn [] Int))")
(ok "multi-argument function type"
    "(declare-extern host/compare (Fn [String String] Bool))")
(ok "variadic function type"
    "(declare-extern host/join (Fn [String & String] String))")
(ok "nested function type"
    "(defn compose [(outer (Fn [String] Bool)) (inner (Fn [Int] String))] (Fn [Int] Bool) (fn [(value Int)] Bool (outer (inner value))))")
(ok "let and loop bindings"
    "(defn f [(x Int)] Int (let [(y Int) x z y] (loop [(n Int) z] n)))")
(ok "flat let and loop binding triples"
    "(defn f [(x Int)] Int (let [y Int x] (loop [n Int y] n)))")
(ok "conditional binding"     "(defn f [(x Int)] Int (if-let [(y Int) x] y 0))")
(ok "for and nested :let"
    "(defn f [(xs (Vec Int))] (Vec Int) (for [(x Int) xs :let [(y Int) x]] y))")
(ok "doseq binding"
    "(defn f [(xs (Vec Int))] Nil (doseq [(x Int) xs] (println x)))")
(ok "record fields"           "(defrecord Point [(x Int) (y Int)])")
(ok "flat record fields"      "(defrecord Point [x Int y Int])")
(ok "union and error fields"
    "(defunion Shape (Circle [(radius Int)]))\n(defunion :throwable Boom (Boom [(message String)]))")
(ok "catch binding"
    "(defn f [] Int (try 1 (catch Exception e 0)))")

;; Every executable/declaration signature has a mandatory positional return.
(ok "defn return"             "(defn f [(x Int)] Int x)")
(ok "defn raises"
    "(defunion :throwable Boom (Boom [(message String)]))\n(defn f [] Int :raises Boom 1)")
(ok "private defn"            "(defn- f [(x Int)] Int x)")
(ok "anonymous fn"            "(defn f [(x Int)] Int ((fn [(y Int)] Int y) x))")
(ok "flat anonymous fn"       "(defn f [x Int] Int ((fn [y Int] Int y) x))")
(ok "letfn"                   "(defn f [(x Int)] Int (letfn [(g [(y Int)] Int y)] (g x)))")
(ok "multi-arity"
    "(defn f ([(x Int)] Int x) ([(x Int) (y Int)] Int (+ x y)))")
(ok "protocol and implementation"
    (string-append
     "(defrecord Box [(value Int)])\n"
     "(defprotocol Value (value-of [(self Value)] Int))\n"
     "(extend-type Box Value (value-of [(self Box)] Int (:value self)))"))

(test-case "types populate AST slots"
  (define program
    (parse-src
     "(def answer Int 42)\n(defn add [x Int y Any] String (let [(n Int) x] \"s\"))"))
  (define forms (program-forms program))
  (check-eq? (type-prim-name (def-form-type (car forms))) 'Int)
  (define function (cadr forms))
  (check-eq? (type-prim-name (param-type (car (defn-form-params function)))) 'Int)
  (check-true (type? (param-type (cadr (defn-form-params function)))))
  (check-eq? (type-prim-name (defn-form-return-type function)) 'String)
  (define binding (car (let-form-bindings (car (defn-form-body function)))))
  (check-eq? (type-prim-name (let-binding-type binding)) 'Int))

(test-case "typed destructuring keeps the pattern and incoming aggregate type"
  (define program
    (parse-src
     (string-append
      "(defrecord Config [(host String) (port Int)])\n"
      "(defn unpack [([x y] (HVec Float Float)) ({:keys [host port] :as cfg} Config)] Float x)")))
  (define function (cadr (program-forms program)))
  (define seq-param (car (defn-form-params function)))
  (check-true (seq-destructure? (param-name seq-param)))
  (check-eq? (type-app-ctor (param-type seq-param)) 'HVec)
  (define map-param (cadr (defn-form-params function)))
  (check-true (map-destructure? (param-name map-param)))
  (check-eq? (map-destructure-as-name (param-name map-param)) 'cfg)
  (check-eq? (type-prim-name (param-type map-param)) 'Config))

(err/rx "bare sequential destructuring parameter requires annotation"
        #rx"parameter .*x y.* has no following type"
        "(defn f [[x y]] Any x)")
(err/rx "bare map destructuring parameter requires annotation"
        #rx"parameter .*host.* has no following type"
        "(defn f [{:keys [host]}] Any host)")
(err/rx "record fields cannot destructure"
        #rx"field name must be a symbol"
        "(defrecord Bad [([x y] (HVec Int Int))])")
(err/rx "rest parameter cannot destructure"
        #rx"rest parameter must bind one name"
        "(defn f [x Int & [y z] (HVec Int Int)] Int x)")
(err/rx "catch cannot destructure"
        #rx"catch name must be a symbol"
        "(defn f [] Int (try 1 (catch Exception [e more] 0)))")
(err/rx "duplicate nested parameter name rejected"
        #rx"binds `x` more than once"
        "(defn f [([x x] (HVec Int Int))] Int x)")
(err/rx "duplicate pattern and scalar parameter rejected"
        #rx"binds `x` more than once"
        "(defn f [([x y] (HVec Int Int)) (x Int)] Int x)")
(err/rx "duplicate map key and as name rejected"
        #rx"binds `x` more than once"
        "(defn f [({:keys [x] :as x} (Map Keyword Int))] Any x)")
(err/rx "compiler identifier prefix is reserved"
        #rx"reserved compiler identifier prefix"
        "(defn f [($beagle$param$0 Int)] Int $beagle$param$0)")

(check-err/rx "nominal record rejects positional destructuring"
              #rx"nominal records require"
              "(defrecord Point [(x Int) (y Int)])\n(defn f [([x y] Point)] Int x)")
(check-err/rx "HVec arity mismatch is pointed"
              #rx"pattern requires 3 positional values, but the tuple has 2"
              "(defn f [([x y z] (HVec Int Int))] Int x)")
(check-err/rx "unknown record field is pointed"
              #rx"field :missing is not present"
              "(defrecord Config [(host String)])\n(defn f [({:keys [missing]} Config)] Any missing)")
(check-err/rx "Map destructuring requires keyword-compatible keys"
              #rx"requires Keyword-compatible map keys"
              "(defn f [({:keys [x]} (Map String Int))] Any x)")
(check-err/rx "Vec positional leaf is nullable"
              #rx"expected return Int, got Int[?]"
              "(defn f [([x] (Vec Int))] Int x)")
(check-err/rx "List positional leaf is nullable"
              #rx"expected return Int, got Int[?]"
              "(defn f [([x] (List Int))] Int x)")
(check-err/rx "Map key without default is nullable"
              #rx"expected return Int, got Int[?]"
              "(defn f [({:keys [x]} (Map Keyword Int))] Int x)")
(check-err/rx "wrong map default type is rejected"
              #rx"destructuring default for x: expected Int, got String"
              "(defn f [({:keys [x] :or {x \"bad\"}} (Map Keyword Int))] Int x)")
(test-case "throwable record fields map-destructure by keyword"
  (check-not-exn
   (lambda ()
     (parameterize ([current-check-profile 3])
       (type-check!
        (parse-src
         (string-append
          "(defunion :throwable Boom (Boom [(message String)]))\n"
          "(defn f [({:keys [message]} Boom)] String message)")))))))
(test-case "parametric nominal aggregate projects substituted map fields"
  (check-not-exn
   (lambda ()
     (parameterize ([current-check-profile 3])
       (type-check!
        (parse-src
         (string-append
          "(defunion (Box T) (BoxValue [(value T)]))\n"
          "(defn unbox [({:keys [value]} (Box String))] String value)")))))))

(err/rx "arrow function type rejected"
        #rx"arrow function types are not supported.*Fn"
        "(defn f [(callback [Int -> Int])] Int (callback 1))")
(err/rx "bare Fn type rejected"
        #rx"bare Fn is an incomplete function type"
        "(def value Fn nil)")
(err/rx "malformed Fn type rejected"
        #rx"function type parameters must be a vector"
        "(def value (Fn Int Bool) nil)")
(err/rx "defrecord cannot shadow Fn in the type namespace"
        #rx"defrecord cannot declare `Fn`"
        "(defrecord Fn [(value Int)])")
(err/rx "defalias cannot shadow Fn in the type namespace"
        #rx"defalias cannot declare `Fn`"
        "(defalias Fn Int)")
(err/rx "defunion member cannot shadow Fn in the type namespace"
        #rx"defunion member cannot declare `Fn`"
        "(defunion Result Fn Ok)")
(err/rx "forall variable cannot shadow Fn"
        #rx"Fn is the built-in function type constructor"
        "(def value (forall [Fn] Fn) nil)")
(test-case "qualified nominal api/Fn remains legal"
  (check-not-exn (lambda () (parse-src "(def value api/Fn nil)"))))
(ok "value-level Fn binding remains legal"
    "(defn value-level [Fn Int] Int Fn)")
;; The slot is fixed; the parser never guesses whether a type-shaped symbol is
;; a body expression.
(err/rx "defn missing return slot"
        #rx"needs a return type and body"
        "(defn f [] 1)")
(err/rx "defn return without body"
        #rx"needs a return type and body"
        "(defn f [] Int)")
(err/rx "fn return without body"
        #rx"fn needs a return type and body"
        "(def f (fn [] Int))")
(err/rx "multi-arity return without body"
        #rx"needs a return type and body"
        "(defn f ([] Int))")
(err/rx "protocol missing return"
        #rx"must be.*ReturnType"
        "(defprotocol P (f [self]))")

(test-case "type-level and Clojure arrows remain separate surfaces"
  (check-not-exn
   (lambda ()
     (check-src
      "(defn f [(cb (Fn [Int] Int)) (x Int)] Int (-> x cb))"))))

(test-case "legacy and flat signatures lower to the same AST"
  (define legacy
    (parse-src
     "(defrecord P [(x Int) (y String)])\n(defn f [(p P) & (xs (Vec Int))] P p)"))
  (define flat
    (parse-src
     "(defrecord P [x Int y String])\n(defn f [p P & xs (Vec Int)] P p)"))
  (for ([target (in-list '(clj js nix))])
    (define emit (emitter-backend-emit-program (resolve-backend target)))
    (check-equal? (emit legacy) (emit flat) (symbol->string target))))

(test-case "odd flat vector reports the binder in structured details"
  (with-handlers ([beagle-parse-error?
                   (lambda (error)
                     (check-eq? (beagle-parse-error-kind error)
                                'missing-binding-type)
                     (check-equal?
                      (hash-ref (beagle-parse-error-details error) 'binder)
                      "age")
                     (check-true
                      (string-contains? (exn-message error)
                                        "parameter age has no following type")))])
    (parse-src "(defn f [name String age] String name)")
    (fail "expected missing type rejection")))

(test-case "mixed grouped and flat declarations have a structured kind"
  (with-handlers ([beagle-parse-error?
                   (lambda (error)
                     (check-eq? (beagle-parse-error-kind error)
                                'mixed-typed-bindings))])
    (parse-src "(defn f [x Int (y String)] Int x)")
    (fail "expected mixed declaration rejection")))

(ok "expression ascription" "(def answer (: 42 Int))")
(check-err/rx "ascription checks its expression"
              #rx"ascription: expected Int, got String"
              "(def answer (: \"no\" Int))")

(define (check-refinement-reserved src placement)
  (with-handlers ([beagle-diagnostic?
                   (lambda (error)
                     (check-eq? (beagle-diagnostic-kind error)
                                'refinement-not-implemented)
                     (define details (beagle-diagnostic-details error))
                     (check-equal? (hash-ref details 'error-code) "E031")
                     (check-equal? (hash-ref details 'status)
                                   "not-yet-implemented")
                     (check-equal? (hash-ref details 'placement) placement))])
    (check-src src)
    (fail "expected reserved refinement rejection")))

(test-case "inline refinement parses and is rejected by the checker"
  (check-refinement-reserved
   "(defn positive [x (Int where (> x 0))] Int x)"
   "inline"))

(test-case "signature where clause parses and is rejected by the checker"
  (check-refinement-reserved
   "(defn bounded [lo Int hi Int] Bool (where (<= lo hi)) true)"
   "signature"))
