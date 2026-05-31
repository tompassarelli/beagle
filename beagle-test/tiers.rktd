;; Beagle test tier manifest.
;;
;; Three tiers:
;;
;;   active  — blocks iteration. Active failures fail the build.
;;   demoted — runs continuously but advisory only; doesn't block.
;;   gated   — opt-in only via env var (BEAGLE_ORACLE=1, etc). Runner
;;             treats as "not run this session" rather than pass/fail.
;;
;; --- structural-floor rule ---
;;
;; All emit-*.rkt STRUCTURAL tests stay active regardless of target status.
;; They catch "this surface change broke an entire emitter" before that
;; breakage rots invisibly. Only -behavioral.rkt tests for non-load-bearing
;; targets are demoted. The floor is cheap to maintain (no external
;; interpreter runs) and high-value (immediate visibility on entire-emitter
;; breakage).
;;
;; --- promotion criteria ---
;;
;; Demoted → active requires BOTH:
;;   (a) the surface is stable enough that reconciliation work won't be
;;       re-done immediately, AND
;;   (b) the target is load-bearing for actual work (real use case, not
;;       hypothetical optionality).
;;
;; Just (a) is not enough — keeping a target's behavioral suite current
;; costs ongoing maintenance, and that cost is only worth paying when (b)
;; says someone actually depends on the runtime correctness. A target that
;; never becomes load-bearing stays demoted indefinitely, and that is
;; correct: optionality is preserved (emitter code exists, structural tests
;; pass) at low cost (no behavioral maintenance).
;;
;; --- per-target tier summary (human-readable navigation) ---
;;
;; NOTE: this is a SUMMARY VIEW for navigation. The authoritative tier
;; assignment is the file-level list below — the runner reads from there.
;; "split" below is shorthand for "structural-active + behavioral-demoted";
;; the runner does not know about a "split" tier.

#hasheq(
  (nix     . (active   "Load-bearing via bnix dogfood (firnos config + heist work)"))
  (rkt     . (active   "Oracle target — Typed Racket validates Beagle's type promises via raco make; all current tests are structural"))
  (clj     . (active   "Promoted Phase D (2026-05): emit-clj structural + behavioral both active. Fixture-driven .bclj suites reconciled to v0.16 surface (claim form, no inline def/defn type annotations, defrecord+extend-type instead of deftype)"))
  (cljs    . (active   "Promoted Phase D (2026-05): emit-cljs path covered structurally by emit-clj suite (shared backend); .bcljs fixtures reconciled to v0.16 surface"))
  (js      . (split    "Structural active; behavioral demoted — JS target may become load-bearing via Bun work; currently aspirational"))
  (py      . (split    "Structural active; behavioral demoted — Python target is recent; no load-bearing use yet"))
  (sql     . (active   "Structural-only; no behavioral runner exists yet so nothing to demote"))
  (cyclone . (future   "Cyclone Scheme self-host target — not yet implemented. When it ships, its behavioral tests promote to active (self-host means Cyclone is the substrate Beagle runs on)")))


;; --- authoritative file-level classification ---
;;
;; One-time pass at manifest creation; do not trust filename convention
;; exhaustively. Edit this list directly when promoting/demoting suites.

#hasheq(
  (active . (;; target-agnostic infrastructure
             "check.rkt"
             "defmacro.rkt"
             "diagnostic-kind.rkt"
             "lint.rkt"
             "macro-hygiene.rkt"
             "parse.rkt"
             "quasi-quote-reader.rkt"
             "syntax.rkt"
             "test-tags.rkt"
             "threading.rkt"
             "types.rkt"
             ;; Nix (load-bearing target — the live happy path)
             "emit-nix.rkt"
             "nix-emit-errors.rkt"
             "nix-lints.rkt"
             "nix-parse.rkt"
             "nix-roundtrip.rkt"
             "validate-nix.rkt"
             ;; Clojure / ClojureScript — promoted Phase D (2026-05).
             ;; emit.rkt is the clj structural suite; emit-clj-behavioral.rkt
             ;; runs the emitted clj via bb (Babashka). cljs is covered by the
             ;; shared emit-clj backend; no separate emit-cljs.rkt test exists.
             "emit.rkt"                 ; emit-clj structural
             "emit-clj-behavioral.rkt")) ; requires bb (Babashka)

  (demoted . (;; behavioral runs that hit external interpreters
              "emit-js-behavioral.rkt")) ; requires bun

  (gated . (;; Non-Nix target tests — parked alongside the dormant
            ;; emitters. Opt in via BEAGLE_ALL_TARGETS=1 when revisiting
            ;; a quarantined target. See thread 20260528233608 and
            ;; beagle-lib/private/dormant/.
            "emit-js.rkt"
            "emit-py.rkt"
            "emit-rkt.rkt"
            "emit-sql.rkt"
            "js-fixtures.rkt"
            "js-quote.rkt"
            "jst.rkt"
            "py-fixtures.rkt"
            "sql-fixtures.rkt"
            "sql-roundtrip.rkt"
            "sql-schema-cache.rkt"
            ;; opt-in oracle/property/exec runners (env-gated)
            "differential.rkt"          ; BEAGLE_ORACLE=1
            "js-exec-oracle.rkt"        ; requires node/bun at runtime
            "nix-property.rkt"          ; BEAGLE_NIX_EVAL_CHECK=1
            "oracle.rkt"                ; BEAGLE_ORACLE=1
            "oracle-bun.rkt"            ; BEAGLE_ORACLE=1
            "py-exec-oracle.rkt"        ; requires python at runtime
            ;; Operative checker — experimental, quarantined.
            ;; BEAGLE_EXPERIMENTAL_OPERATIVE=1. See thread
            ;; 20260530180100-beagle_type_system_implementation_against_v0_15_surface.md
            "check-operative.rkt"
            "emit-operative.rkt"
            "operative-integration.rkt"
            "pipeline.rkt"
            "operative-quarantine.rkt")))
