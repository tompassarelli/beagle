#lang info

(define collection "beagle")
(define deps '("base"))
(define build-deps '("rackunit-lib" "scribble-lib" "racket-doc"))
(define scribblings '(("scribblings/beagle.scrbl" ())))
(define raco-commands
  '(("beagle" beagle/private/raco-cmd "build, check, expand" #f)))
(define version "0.8.0")
(define pkg-desc "Agent-native typed authoring layer — emits Clojure, ClojureScript, or JavaScript.")
(define pkg-authors '(tom))
(define license '(MIT))
(define pkg-tags '("language" "compiler" "clojure" "javascript" "type-checking"))
(define test-paths '("tests"))
