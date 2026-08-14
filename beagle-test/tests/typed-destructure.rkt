#lang racket/base

;; End-to-end backend contract for `(binding-form Type)` parameters.

(require rackunit
         racket/list
         racket/string
         beagle/lang/reader-impl
         beagle/private/parse
         beagle/private/check
         beagle/private/emit
         beagle/private/emit-facts)

(define (read-forms source)
  (parameterize ([current-readtable beagle-readtable])
    (define in (open-input-string source))
    (let loop ()
      (define form (read-syntax 'typed-destructure-test in))
      (if (eof-object? form) '() (cons form (loop))))))

(define (compile target source)
  (define program
    (parse-program
     (read-forms
      (string-append
       "(ns typed.destructure)\n(define-target "
       (symbol->string target)
       ")\n"
       source))))
  (parameterize ([current-check-profile 3])
    (type-check! program))
  (emit-program program))

(define (compile-facts source)
  (define program
    (parse-program
     (read-forms
      (string-append
       "(ns typed.destructure)\n(define-target clj)\n"
       source))))
  (parameterize ([current-check-profile 3])
    (type-check! program))
  (facts-emit-program program))

(test-case "Clojure keeps one aggregate parameter and native nested pattern"
  (define output
    (compile
     'clj
     (string-append
      "(defrecord Config [(foo-bar String)])\n"
      "(defn unpack [([[x y] {:keys [foo-bar] :as cfg}] "
      "(HVec (HVec Int Float) Config))] String foo-bar)")))
  (check-true (string-contains? output "[[[x y] {:keys [foo-bar] :as cfg}]]")))

(test-case "JS defn recursively projects one hidden aggregate slot"
  (define output
    (compile
     'js
     (string-append
      "(defrecord Config [(foo-bar String)])\n"
      "(defn unpack [([[x y] {:keys [foo-bar] :as cfg}] "
      "(HVec (HVec Int Float) Config))] String foo-bar)")))
  (check-true (string-contains? output "function unpack($beagle$param$0)"))
  (check-true (string-contains? output "let x = $beagle$param$0[0][0];"))
  (check-true (string-contains? output "let cfg = $beagle$param$0[1];"))
  (check-true (string-contains? output "[\"foo_bar\"]")))

(test-case "JS fn, letfn, multi-arity, and JST methods use aggregate slots"
  (define output
    (compile
     'js
     (string-append
      "(def f Any (fn [([x y] (HVec Int Int))] Int x))\n"
      "(defn outer [] Int (letfn [(g [([x y] (HVec Int Int))] Int y)] (g [1 2])))\n"
      "(defn multi ([([x y] (HVec Int Int))] Int x) ([(x Int)] Int x))\n"
      "(js/class Pair (first [([x y] (HVec Int Int))] Int (js/return x)))")))
  (check-true (string-contains? output "$beagle$param$0"))
  (check-true (string-contains? output "...$beagle$args"))
  (check-false (string-contains? output "#(struct:")))

(test-case "JS let, for, doseq, and loop lower nested patterns without struct text"
  (define output
    (compile
     'js
     (string-append
      "(defn local [(rows (Vec (HVec Int Int)))] Int "
      "(let [([x y] (HVec Int Int)) [1 2]] x))\n"
      "(defn mapped [(rows (Vec (HVec Int Int)))] (Vec Int) "
      "(for [([x y] (HVec Int Int)) rows] x))\n"
      "(defn walked [(rows (Vec (HVec Int Int)))] Nil "
      "(doseq [([x y] (HVec Int Int)) rows] (println x)))\n"
      "(defn looping [] Int "
      "(loop [([x y] (HVec Int Int)) [1 2]] (if (> x 0) (recur [0 y]) y)))")))
  (check-true (string-contains? output "$beagle$binding$0"))
  (check-true (string-contains? output "$beagle$item"))
  (check-true (string-contains? output "$beagle$loop$0"))
  (check-false (string-contains? output "#(struct:")))

(test-case "Nix map parameters require defaults and emit an attrset pattern"
  (define output
    (compile
     'nix
     "(defn host [({:keys [host] :or {host \"localhost\"}} (Map Keyword String))] String host)"))
  (check-true
   (string-contains?
    output
    "let bgl____default__thunk__0__host = _: \"localhost\"; in"))
  (check-true
   (string-contains?
    output
    "{ host ? bgl____default__thunk__0__host null, ... }:")))

(test-case "Nix nominal-record map parameters require keys without defaults"
  (define output
    (compile
     'nix
     (string-append
      "(defrecord Config [(host String) (port Int)])\n"
      "(defn host [({:keys [host port]} Config)] String host)")))
  (check-true (string-contains? output "{ host, port, ... }:"))
  (check-false (string-contains? output " ? ")))

(define (nix-error source)
  (with-handlers ([exn:fail? exn-message])
    (compile 'nix source)
    ""))

(test-case "Nix Map aliases still require declaration-scope defaults"
  (check-regexp-match
   #rx"require :or defaults"
   (nix-error
    (string-append
     "(defalias ConfigMap (Map Keyword String))\n"
     "(defn host [({:keys [host]} ConfigMap)] Any host)")))
  (define output
    (compile
     'nix
     (string-append
      "(defalias ConfigMap (Map Keyword String))\n"
      "(def fallback String \"localhost\")\n"
      "(defn host [({:keys [host] :or {host fallback}} ConfigMap)] String host)")))
  (check-true
   (string-contains?
    output
    "let bgl____default__thunk__0__host = _: fallback; in")))

(test-case "Nix rejects primitive annotations as map aggregates"
  (check-regexp-match
   #rx"key patterns require a nominal record or homogeneous Map"
   (nix-error "(defn bad [({:keys [x]} String)] Any x)")))

(test-case "facts preserve one parameter whose name is a structured binding"
  (define output
    (compile-facts
     "(defn first-coordinate [([x y] (HVec Float Float))] Float x)"))
  (check-true (string-contains? output "\"form-kind\" \"param\""))
  (check-true (string-contains? output "\"form-kind\" \"seq-destructure\""))
  (check-true (regexp-match? #rx"\\[[0-9]+ \"name\" [0-9]+\\]" output))
  (check-false (string-contains? output "\"binding\"")))

(test-case "facts retain explicit constraint edges on binding owners"
  (define output
    (compile-facts
     (string-append
      "(defn positive? [(value Int)] Bool (> value 0))\n"
      "(defrecord Score [(value Int positive?)])\n"
      "(defn constrained [(input Int positive?)] (Vec (U Int Nil)) "
      "(let [(local Int positive?) input] "
      "(for [(item Int positive?) [local]] item)))")))
  (check-equal?
   (length (regexp-match* #rx"\\[[0-9]+ \"constraint\" (?:[0-9]+|\"positive\\?\")\\]" output))
   4)
  (check-true (string-contains? output "\"form-kind\" \"let-binding\""))
  (check-true (string-contains? output "\"form-kind\" \"for-binding\"")))

(test-case "facts preserve constrained union fields under their owning members"
  (define output
    (compile-facts
     (string-append
      "(defn positive? [(value Int)] Bool (> value 0))\n"
      "(defunion Choice "
      "  (Left [(value Int positive?)]) "
      "  (Right [(value Int positive?)]))\n"
      "(defunion :throwable Problem "
      "  (Bad [(value Int positive?)]) "
      "  (Worse [(value Int positive?)]))")))
  (define triples
    (for/list ([line (in-list (string-split output "\n"))]
               #:unless (string=? line ""))
      (read (open-input-string line))))
  (define (objects subject predicate)
    (for/list ([triple (in-list triples)]
               #:when (and (equal? (list-ref triple 0) subject)
                           (equal? (list-ref triple 1) predicate)))
      (list-ref triple 2)))
  (define group-ids
    (for/list ([triple (in-list triples)]
               #:when (and (equal? (list-ref triple 1) "form-kind")
                           (equal? (list-ref triple 2) "member-field-group")))
      (list-ref triple 0)))
  (check-equal? (length group-ids) 4)
  (check-equal?
   (sort (for/list ([group (in-list group-ids)]) (car (objects group "name")))
         string<?)
   '("Bad" "Left" "Right" "Worse"))
  (for ([group (in-list group-ids)])
    (define fields (car (objects group "fields")))
    (define field (car (objects fields "f0")))
    (check-equal? (length (objects field "constraint")) 1)))

(test-case "facts retain constrained protocol and implementation rest bindings"
  (define output
    (compile-facts
     (string-append
      "(defn nonempty? [(values (Vec Int))] Bool (> (count values) 0))\n"
      "(defprotocol Variadic "
      "(combine [(self Any) & (values (Vec Int) nonempty?)] Int))\n"
      "(extend-type String Variadic "
      "(combine [(self String) & (values (Vec Int) nonempty?)] Int "
      "(count values)))")))
  (check-true (string-contains? output "\"form-kind\" \"protocol-method\""))
  (check-true (string-contains? output "\"form-kind\" \"impl-method\""))
  (check-equal? (length (regexp-match* #rx"\"rest\"" output)) 2)
  (check-equal? (length (regexp-match* #rx"\"constraint\"" output)) 2))

(test-case "Nix rejects missing-key, positional, let, for, and loop patterns pointedly"
  (check-regexp-match
   #rx"require :or defaults"
   (nix-error "(defn f [({:keys [x]} (Map Keyword Int))] Any x)"))
  (check-regexp-match
   #rx"sequential destructuring in params"
   (nix-error "(defn f [([x y] (HVec Int Int))] Int x)"))
  (check-regexp-match
   #rx"destructuring in let bindings"
   (nix-error "(defn f [] Int (let [([x y] (HVec Int Int)) [1 2]] x))"))
  (check-regexp-match
   #rx"destructuring in for bindings"
   (nix-error
    "(defn f [(xs (Vec (HVec Int Int)))] (Vec Int) (for [([x y] (HVec Int Int)) xs] x))"))
  (check-regexp-match
   #rx"destructuring in loop bindings"
   (nix-error
    "(defn f [] Int (loop [([x y] (HVec Int Int)) [1 2]] x))")))
