#lang info

(define collection "beagle")
(define deps '("base"))
(define build-deps '("rackunit-lib" "scribble-lib" "racket-doc"))
(define scribblings '(("scribblings/beagle.scrbl" ())))
(define raco-commands
  '(("beagle" beagle/private/raco-cmd "build, check, expand" #f)))
(define version "0.6.1")
(define pkg-desc "Typed authoring layer that compiles to Clojure source.")
(define pkg-authors '(tom))
