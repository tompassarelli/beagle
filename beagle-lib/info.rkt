#lang info
(define collection "beagle")
(define deps '("base"))
(define version "0.15.1")
(define pkg-desc "Agent-native typed authoring layer — emits Clojure, ClojureScript, JavaScript, Nix, or SQL.")
(define pkg-authors '(tom))
(define license '(MIT))
(define raco-commands
  '(("beagle" beagle/private/raco-cmd "build, check, expand" #f)))
(define pkg-tags '("language" "compiler" "clojure" "javascript" "type-checking"))

;; emit-scheme.rkt is forward-looking Cyclone-target scaffolding. The
;; Cyclone self-host target is not yet implemented; this file has bit-
;; rotted against AST refactors (references dropped form structs +
;; renamed fields). Excluded from compilation until Cyclone work begins
;; — at that point the implementer can revive this file as a reference
;; or write the emitter fresh against the current AST.
(define compile-omit-paths
  '("private/emit-scheme.rkt"))
