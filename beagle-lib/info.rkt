#lang info
(define collection "beagle")
(define deps '("base"))
(define version "0.13.0")
(define pkg-desc "Agent-native typed authoring layer — emits Clojure, ClojureScript, JavaScript, Nix, or SQL.")
(define pkg-authors '(tom))
(define license '(MIT))
(define raco-commands
  '(("beagle" beagle/private/raco-cmd "build, check, expand" #f)))
(define pkg-tags '("language" "compiler" "clojure" "javascript" "type-checking"))
