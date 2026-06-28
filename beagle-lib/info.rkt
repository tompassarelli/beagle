#lang info
(define collection "beagle")
(define deps '("base"))
(define version "0.17.2")
(define pkg-desc "Agent-native typed authoring layer — emits Clojure, ClojureScript, JavaScript, Nix, or Odin.")
(define pkg-authors '(tom))
(define license '(Apache-2.0))
(define raco-commands
  '(("beagle" beagle/private/raco-cmd "build, check, expand" #f)))
(define pkg-tags '("language" "compiler" "clojure" "javascript" "type-checking"))

(define compile-omit-paths '())
