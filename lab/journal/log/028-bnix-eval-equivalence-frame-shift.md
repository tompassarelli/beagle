# 028 — bnix converter: byte-identical baseline + reframe to eval-equivalence

This entry marks the bnix converter at commit `7ce87dc` as the
**byte-identical baseline** and records the frame shift away from
byte-identical round-trip as the primary correctness signal toward
**eval-equivalence on the Nix target runtime**. The byte-identity
metric is demoted to diagnostic-only — kept as a parallel signal
because divergence between it and eval-eq over time is itself a
claim-generator, but no longer load-bearing.

This is also the pre-run prediction record for the eval-equivalence
harness about to be built. Predictions logged before measurement is
the discipline; the contrast between prediction and result is the
signal that survives.

No release framing applies — bnix is not heading toward a v1.0 event.
The model is accumulating claims that survive contact: drvPath-eq
passed on a third-party flake I didn't author; scope tracking caught
the bug-class it was designed for; corpus N+1 round-tripped without
intervention. Version numbers, if they ever matter, lag the substrate.

---

## The byte-identical baseline at 7ce87dc

Two external corpora, both pinned (commit SHA + frozen `flake.lock`):

| Corpus       | Files | Clean | Dirty | Parse-fail | Build-fail | %     |
|--------------|-------|-------|-------|------------|------------|-------|
| Misterio77   | 233   | 193   | 32    | 8          | 0          | 82.8% |
| firnos (mine)| 185   | 177   |  6    | 2          | 0          | 95.7% |

The firnos vs Misterio77 gap is mostly a measurement artifact: firnos
was authored in beagle-think, so its "round-trip" tests whether my
dialect survives a no-op. Misterio77 is the only external signal of
arbitrary-third-party-Nix correctness — and almost the entire gap
there is `with pkgs;` scope resolution.

Real beagle upstream gaps caught by external-corpus testing during
this work (8 landed):
- Higher-order calls in parse (`((get x :y) arg)`)
- Singleton `(inherit ...)` / `(inherit-from ...)` in map literals
  and let-bindings
- Float literal tokenization (`0.9` no longer parses as `0 . 9`)
- Apostrophes in identifiers (`mapAttrs'`, `getExe'`)
- `++` / `//` in nix-infix-op table
- `(.attr target)` method-call emit for Nix
- Structured string parts preserving `\${` literal vs `${` interp
- `flake-input` typed form replacing the `nix-ident` escape hatch
  (`a201f6e`)

External-corpus testing IS coverage testing for beagle itself; this
was the load-bearing insight that justified the converter effort.

---

## Why byte-identical is the wrong primary signal

Half-cowardly arc, recorded here so the reasoning doesn't get
re-litigated:

1. Initial framing: byte-identical round-trip as the success metric.
2. First correction: switch to "AST-shape equivalence" (more
   permissive — paren/associativity tolerance).
3. Real correction (the actual right move): **escape the syntactic
   category entirely**. AST-shape is still a syntactic test on the
   converted source. For a compiler/converter, the only contract
   with standing is **semantic preservation on the target runtime**.
   Source-text shape, at any tolerance, is style.

Three structural candidates evaluated under the eval-equivalence frame:

| Candidate                                 | Verdict |
|-------------------------------------------|---------|
| Source-position tracking through the AST  | **Dead** — only bought byte-identical points; doesn't affect eval. |
| Abandoning stdlib auto-prefix of `map`/`filter` for Nix | **Dead** — `builtins.map` and `map` evaluate identically in interchangeable contexts; this is style. |
| Scope tracking for `with` / `let` / formals | **Survives** — bare `firefox` where it should resolve through `with pkgs;` is semantically different code. Same bug in all three frames (eval, AST, byte). |

The two dropped candidates are not to be reopened unless someone
produces evidence they affect eval-equivalence. Scope tracking is
the only structural item that survives the frame.

---

## The eval-equivalence harness shape

Generic across all beagle backends, because the same shape (target-
agnostic IR vs target-specific surface normalization) recurs for
every backend. bnix is the first test case for a methodology, not a
feature in isolation — the Clojure/CLJS/JS/Py/Rkt versions reuse the
same struct.

```racket
(struct target-adapter
  (name            ; symbol
   evaluator       ; (path target-spec) → result
   canonicalize    ; result → canonical-result  (identity for nix; non-trivial for clj/js)
   primary-cmp     ; (canonical canonical → bool) — pass/fail signal
   diagnostic-cmp  ; (canonical canonical → divergence-report) — failure localization
   ))
```

Design notes:
- `evaluator` takes `(path, target-spec)` not `path` alone — encoding
  the host into the file path would have quietly become load-bearing.
  `{:host "X"}` for nix, `{:entry-point ...}` for clj/js.
- `canonicalize` separated from `evaluator` so backends that need
  pre-comparison normalization (JS structural-equal, Clojure
  keyword/string handling, lazy-seq realization) don't have to jam
  it into either side.
- Per-adapter comparator means Nix's `string=` on drvPath, Clojure's
  `=`, JS structural-equal all sit at the same level of the
  abstraction — the harness doesn't pretend they're all "values."

Nix adapter primary signal: **drvPath equivalence**, not outPath.

```
nix eval --raw .#nixosConfigurations.HOST.config.system.build.toplevel.drvPath
```

In a pinned corpus, drvPath is deterministic-equivalent to outPath
(same drv produces same out by construction) but doesn't require
realization — orders of magnitude faster, no fetching, no building,
no disk thrash. outPath stays available as a stricter "paranoid"
mode but would only ever surface a divergence drvPath missed if
there's a non-determinism bug somewhere in Nix itself, which isn't
this project's bug to find.

Nix adapter diagnostic-cmp: curated stable-leaf value comparator
(`hostName`, `system.stateVersion`, package `pname` not derivation,
`services.X.enable` flags) — its job is failure localization, not
the pass/fail signal.

The harness is a **continuous instrument, not a gate**. Runs on
every converter change, cheap to add corpora to, emits results into
`lab/journal/log/` so the journal directory becomes the durable
artifact rather than the binary itself.

---

## Pre-run predictions

Logged before the harness runs. The contrast between prediction and
result is the signal — without writing this down, the natural
tendency is to rationalize whatever the actual result is as "what
was expected."

### Headline (drvPath-eq pass rate)

**Prediction:** both corpora at ~95%+ immediately.

| If holds | If misses |
|----------|-----------|
| Byte-residual was normalization noise; eval-equivalence frame validated; scope tracking is the targeted next step with ~5pt of remaining value. | Byte-residual was correctness bugs masquerading as normalization; scope tracking is more central than thought, *and* there are likely other correctness gaps in the converter not yet identified. Bigger structural signal than the polyglot-harness story. |

### Distribution (diagnostic-cmp over the residual)

**Prediction:** ~80% of failing diffs localize to `with`-resolution
divergences; the remainder is long-tail.

| Headline + distribution outcome | Implication |
|---------------------------------|-------------|
| Headline holds + distribution holds (~80% `with`-shaped) | Scope tracking is exactly the right next item, ~5pt of remaining value, polyglot harness story confirmed. |
| Headline holds + distribution misses (e.g. ~30% `with`-shaped) | Scope tracking real but smaller than thought; other structural work hiding, and the distribution localizes where to look. |
| Headline misses | Distribution still informative — it tells me which class of correctness bug dominates. Scope tracking still relevant but not necessarily the top item. |

The distribution prediction is doing independent epistemic work —
without it, I'd over-fit to whatever the post-hoc dominant pattern
turned out to be.

---

## Next

- Build `bin/beagle-roundtrip-eval` with the `target-adapter` struct
  above; ship the nix adapter first.
- Re-baseline both corpora on drvPath-eq.
- Read the result against both predictions, record outcome and
  implication.
- Then: scope tracking implementation (or whatever else the
  distribution surfaces) against the eval-eq residual.

Byte-identical metric stays in the harness as a parallel diagnostic.
Tracking how it diverges from drvPath-eq over time is itself a
claim-generator: tight tracking validates the normalization-noise
story; persistent divergence becomes a richer "what is the IR
throwing away" story.

— Claude
