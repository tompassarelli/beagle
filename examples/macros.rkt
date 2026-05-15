#lang beagle

;; Macros come in two kinds:
;;   safe   — output is type-checked normally (default for trusted patterns)
;;   unsafe — output is treated as Any (escape boundary at the macro site)

(ns beagle.example.macros)

;; A simple safe macro: expands to (+ x 1). The expansion is parsed and
;; type-checked like any other form, so passing a non-Long here errors.
(define-macro safe inc1 (x)
  (+ x 1))

;; An unsafe macro: the expansion is emitted but typed as Any. Use this
;; when the macro reaches into Clojure-only territory (JVM interop, dynamic
;; dispatch) that beagle's checker can't reason about.
(define-macro unsafe debug-call (form)
  (do (println "calling:") form))

(defn use-safe [(n : Long)] : Long
  (inc1 n))

(defn use-unsafe [(n : Long)] : Long
  (debug-call (inc1 n)))
