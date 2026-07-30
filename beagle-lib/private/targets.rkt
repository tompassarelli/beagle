#lang racket/base

;; THE canonical language-target table — one row per target, nothing else.
;;
;; Every place that used to hand-enumerate targets is now a DERIVED VIEW of
;; this list: extensions.rkt's EXTENSION-TARGET-MAP, the `bin/beagle` usage
;; line, `bin/beagle-build` / `bin/beagle-init`'s target case-arms (via the
;; generated share/targets.sh), `bin/beagle-doctor`'s emitter inventory,
;; cheatsheet.rkt's preamble, and every doc span wrapped in a
;; `<!-- beagle:langs … -->` marker (filled by `bin/beagle doc-fill`).
;;
;; Adding or removing a target is therefore ONE edit here plus
;; `bin/beagle doc-fill`; the drift test in beagle-test/tests/docfill.rkt
;; fails the build if a derived view was not regenerated.
;;
;; `facts` is deliberately NOT in this list. It is a lossless PROJECTION of the
;; same AST into CNF fact triples (emit-facts.rkt), not a language a program is
;; authored against — it has no #lang, no source extension, and no idiom. It is
;; carried separately in PROJECTIONS so views can mention it without letting it
;; drift back into "seven targets".

(require racket/string
         racket/list)

;; id         : symbol used on --target and in (define-target …)
;; name       : human display name (README prose, names view)
;; source-ext : authoring extension, with the dot
;; lang       : the `#lang` path an authored file opens with
;; out-ext    : emitted file extension, with the dot
;; status     : 'live — the only status any target currently holds. The field
;;              exists so beagle-doctor classifies from the table instead of
;;              probing for a dormant/ directory that no longer exists.
;; emitter    : emitter module, relative to beagle-lib/private/
;; note       : how this target is held correct (what backs the `live` status)
;; idiom      : comma-free phrase — how this target renders the shared surface
;; domain     : one-line domain-fit sentence (what you'd reach for it for)
(struct target (id name source-ext lang out-ext status emitter note idiom domain)
  #:transparent)

(define TARGETS
  (list
   (target 'clj "Clojure" ".bclj" "beagle" ".clj" 'live "emit-clj.rkt"
           "self-hosted, oracle-certified, fuzz-guarded"
           "eager persistent maps"
           "JVM and babashka Clojure: application code, tooling, and beagle's own self-hosted compiler.")
   (target 'js "JavaScript" ".bjs" "beagle/js" ".js" 'live "emit-js.rkt"
           "self-hosted, oracle-certified, fuzz-guarded"
           "plain objects and ES modules"
           "Browser, Node, and Bun JavaScript: anything that ships to a JS runtime.")
   (target 'nix "Nix" ".bnix" "beagle/nix" ".nix" 'live "emit-nix.rkt"
           "self-hosted, oracle-certified, fuzz-guarded"
           "lazy attrsets"
           "Nix expressions type-checked against the NixOS option schema: system and package configuration.")
   (target 'odin "Odin" ".bodin" "beagle/odin" ".odin" 'live "emit-odin.rkt"
           "Racket emitter; self-host port pending conformance goldens"
           "structs and explicit context"
           "Native Odin for graphics and systems work against wgpu and SDL3.")
   (target 'zig "Zig" ".bzig" "beagle/zig" ".zig" 'live "emit-zig.rkt"
           "Racket emitter with restored structural goldens"
           "explicit allocators and error unions"
           "Native Zig for standalone linked executables and low-level systems code.")
   (target 'scriptc "TypeScript" ".bsc" "beagle/scriptc" ".ts" 'live "emit-scriptc.rkt"
           "Racket emitter over the JS lowering; experimental boundary"
           "typed function boundaries over JS"
           "A narrow TypeScript boundary over the JS lowering: typed exports for TypeScript consumers (experimental; primitive-typed defn only).")))

;; Extensions that are real beagle sources but name no target.
(define NEUTRAL-EXTENSIONS
  '((".bgl" . "target-neutral — declare with `#lang beagle/<target>` or `(define-target …)`")
    (".rkt" . "legacy — no extension/header validation")))

;; Not language targets. A projection consumes the same AST and emits a
;; non-program artifact.
(struct projection (id name emitter note) #:transparent)

(define PROJECTIONS
  (list
   (projection 'facts "Fact graph" "emit-facts.rkt"
               "lossless CNF fact-triple projection of the AST (`bin/beagle facts-roundtrip`), a query surface rather than a language you author against")))

(define (target-ids) (map target-id TARGETS))
(define (target-count) (length TARGETS))

(define (target-by-id id)
  (findf (lambda (t) (eq? (target-id t) id)) TARGETS))

(define (live-targets)
  (filter (lambda (t) (eq? (target-status t) 'live)) TARGETS))

(provide (struct-out target)
         (struct-out projection)
         TARGETS
         NEUTRAL-EXTENSIONS
         PROJECTIONS
         target-ids
         target-count
         target-by-id
         live-targets)
