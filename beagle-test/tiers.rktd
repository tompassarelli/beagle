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
  (clj     . (active   "Promoted Phase D (2026-05): emit-clj structural + behavioral both active. Fixture-driven .bclj suites reconciled to v0.16 surface (claim form, no inline def/defn type annotations, defrecord+extend-type instead of deftype)"))
  (cljs    . (active   "Promoted Phase D (2026-05): emit-cljs path covered structurally by emit-clj suite (shared backend); .bcljs fixtures reconciled to v0.16 surface"))
  (js      . (split    "Structural active; behavioral demoted — JS target may become load-bearing via Bun work; currently aspirational"))
  (sql     . (active   "Schema-typing live in check.rkt; emitter dormant (BEAGLE_ALL_TARGETS=1). Structural-only"))
  (odin    . (active   "Native target — Odin + wgpu/SDL3. Structural goldens + pointed rejections")))


;; --- authoritative file-level classification ---
;;
;; One-time pass at manifest creation; do not trust filename convention
;; exhaustively. Edit this list directly when promoting/demoting suites.

#hasheq(
  (active . (;; target-agnostic infrastructure
             "check.rkt"
             "cheatsheet.rkt"           ; capability cheatsheet — every example must parse+check
             "claims-render-roundtrip.rkt" ; #17 — renderer reconstructs #lang from leading (define-target)
             "defmacro.rkt"
             "diagnostic-kind.rkt"
             "expand-tool.rkt"          ; #32 — `beagle expand` reads+renders the full surface (canonical reader)
             "error-explanation.rkt"    ; in-compiler explanation registry
             "exhaustive-match-fix.rkt" ; missing-case clause-skeleton repair fix
             "repair-apply.rkt"         ; beagle-repair clause-insertion (python unit tests)
             "expected-errors.rkt"      ; inline #guard_msgs-style diagnostics

             "lint.rkt"
             "macro-hygiene.rkt"
             "parse.rkt"
             "purity.rkt"               ; `!`-purity enforcement (Phase 6, dark by default)
             "quasi-quote-reader.rkt"
             "reader-conditionals.rkt"
             "reader-path-parity.rkt"   ; #19 guard — parse path & #lang path read identically (one table)
             "reader-shorthand.rkt"     ; #() fn shorthand (2026-06-12)
             "sourcemap-fidelity.rkt"   ; diagnostic srcloc fidelity benchmark
             "syntax.rkt"
             "test-tags.rkt"
             "threading.rkt"
             "threading-marker.rkt"
             "type-view.rkt"            ; types-as-view delaborator (explain-type)
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
             "emit-clj-behavioral.rkt"  ; requires bb (Babashka)
             ;; Odin backend — native target (2026-06-13).
             "emit-odin.rkt"
             ;; Form × live-backend matrix: every cell emits or rejects
             ;; pointedly (cracks thread 20260613013145 #2).
             "emit-matrix.rkt"
             ;; Query-tool extractors (beagle-sig/-fields/-callers) —
             ;; pinned against the canonical surface after rotting twice.
             "query.rkt"
             ;; Cross-target VALUE-CONFORMANCE harness (2026-06-21): CLJ is the
             ;; ORACLE (bb); each runnable target (currently JS via node) must AGREE
             ;; on value semantics. Expanded corpus, categorized: A nested/mixed
             ;; equality, B hash consistency, C set/map membership, D immutability
             ;; (no input mutation), E dedup-by-value, F compound-value map keys.
             ;; 53/53 GREEN. F (3 cases) + count-of-set (2 cases) are 'known-gap,
             ;; SOFT-reported (no hard assert): native JS object keys can't key by
             ;; value (needs the P3 HAMT) and `(count <set>)` emits `.length` on a
             ;; JS Set (→ undefined) — both fixes live in emit-js/check.rkt, owned
             ;; elsewhere. A separate DIVERGENCES list pins 3 deliberate Beagle-JS
             ;; ≠ Clojure differences (0/""-truthiness, kw→string) in BOTH directions
             ;; so a resolved divergence fails loudly and graduates into the corpus.
             ;; A real correctness gate.
             "conformance.rkt"
             ;; P3 rep-selection SOUNDNESS gate (2026-06-21): the "trust spine"
             ;; audit. Asserts (a) no false promotion (scalar/native code emits
             ;; ZERO hamt refs) and (b) no correctness hole (compound-key maps /
             ;; value-dedup sets DO route to the HAMT), plus an INDEPENDENT oracle
             ;; that re-derives provably-compound from the type table and
             ;; cross-checks the HAMT-site count against the emitter's actual
             ;; output. Structural (emits + inspects JS strings; no node/bb), so
             ;; it stays active as a permanent regression lock on rep-selection.
             "rep-soundness.rkt"))

  (demoted . (;; behavioral runs that hit external interpreters
              "emit-js-behavioral.rkt")) ; requires bun

  (gated . (;; Non-Nix target tests parked behind BEAGLE_ALL_TARGETS=1.
            ;; SQL emitter is dormant (its schema-typing in check.rkt is live).
            ;; (py/rkt/scheme/zig removed 2026-06-15 — tag
            ;; dormant-targets-archive-2026-06-15 to revive.)
            "emit-js.rkt"
            "emit-sql.rkt"
            "js-fixtures.rkt"
            "js-quote.rkt"
            "jst.rkt"
            "sql-fixtures.rkt"
            "sql-roundtrip.rkt"
            "sql-schema-cache.rkt"
            ;; opt-in property/exec runners (env-gated)
            "js-exec-oracle.rkt"        ; requires node/bun at runtime
            "nix-property.rkt")))       ; BEAGLE_NIX_EVAL_CHECK=1
            ;; (The quarantined "operative" checker/evaluator prototype was
            ;; deleted 2026-06-15 — it never ran on the live build path. The
            ;; operative *vision* is realized as the compile-time combiner layer
            ;; in the live compiler; see CLAUDE.md "Architecture" + thread
            ;; 20260615034227.)
