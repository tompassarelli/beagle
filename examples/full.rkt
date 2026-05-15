#lang beagle

;; Exercises the v0 feature set:
;;   - ns, require
;;   - declare-extern (typing Clojure functions from other namespaces)
;;   - union types in annotations
;;   - variadic function types (via built-in env)
;;   - safe + unsafe macros, including &rest with splice
;;   - cond, when, do, let, fn, inline unsafe escape

(ns beagle.example.full)

(require clojure.string :as cstr)

;; --- typing external Clojure functions -------------------------------------

(declare-extern cstr/upper-case [String -> String])
(declare-extern cstr/lower-case [String -> String])

(defn loud [(name : String)] : String
  (str "HEY " (cstr/upper-case name) "!"))

;; --- union types in annotations -------------------------------------------
;; Note: v0 doesn't do type narrowing on `if`, so to USE a union value you
;; typically pass it through unsafe or branch via an unsafe macro. The
;; annotation itself is the check at definition sites.

(def maybe-name : (U String Nil) "Jane")
(def absent-name : (U String Nil) nil)

;; --- variadic arithmetic via the built-in env -----------------------------

(defn sum-three [(a : Long) (b : Long) (c : Long)] : Long
  (+ a b c))

;; --- safe macro: expansion is re-checked ----------------------------------

(define-macro safe inc1 (x)
  (+ x 1))

(defn next [(n : Long)] : Long
  (inc1 n))

;; --- macro with &rest + splice --------------------------------------------

(define-macro safe call-with (f & args)
  (f (splice args)))

(defn use-call-with [] : Long
  (call-with + 1 2 3 4))

;; --- unsafe macro: expansion typed Any ------------------------------------

(define-macro unsafe debug-call (form)
  (do (println "trace") form))

(defn use-unsafe [(n : Long)] : Long
  (debug-call (inc1 n)))

;; --- inline unsafe escape -------------------------------------------------

(unsafe "(defn show-all [conn]
  ;; arbitrary Clojure that beagle won't validate
  (clojure.pprint/pprint @conn))")

(defn main []
  (println (loud "world"))
  (println (next 41))
  (println (sum-three 1 2 3))
  (println (use-call-with))
  (println (use-unsafe 10)))
