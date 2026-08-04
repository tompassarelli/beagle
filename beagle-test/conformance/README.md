# Conformance: certifying every backend against the oracle

The corpus (`corpus.rktd`) is beagle's per-backend executable spec — one row
per case: `(id path kind)`, where `path` is a beagle source file (target
derived from its extension) and `kind` is `emit` (golden = emitted target
source) or `reject` (source must fail check; golden = the diagnostic text).
The **oracle is the Racket beagle compiler at HEAD**: `--regen` sources every
golden from it; a gate run diffs the live compiler against that blessed
snapshot. Mechanics ported from jolt's `test/conformance/certify.clj`.

The gate kills semantic drift across targets in three independent dimensions:

1. **Golden diff** — emitted output byte-compared against the committed
   golden (`expected/<target>/<id>.<ext>`); diagnostics for `reject` rows
   (`expected/<target>/<id>.diag`, checkout prefix stripped).
2. **Target validity** — the emitted output is parsed by the *target's own
   tooling* (js: `bun build --no-bundle`; nix: `nix-instantiate --parse`,
   which also scope-checks; clj: the `bb` reader). This is what catches
   the **silent-miscompile class**, where output matches the golden but is
   not even parseable on the target. A golden diff alone would bless garbage
   forever. js is bun-or-skip deliberately: `node --check` only surfaces
   invalid assignment targets at runtime, and a half-detecting fallback turns
   ledger entries falsely stale.
3. **Accept/reject boundary** — a `reject` row that starts compiling is a
   `reject-mismatch` (the checker got looser); a changed diagnostic is
   `diag-divergent` (regen after review).

## What's here

- **`certify.rkt`** — classifies every row into buckets: `match` /
  `reject-match` (good), `divergent`, `invalid-output`, `compile-fail`,
  `reject-mismatch`, `diag-divergent`, `no-golden` (flagged). Run it only via
  `bin/beagle-certify`, which pins racket and routes the `beagle` collection
  at *this* checkout — a worktree certifies its own compiler.
- **`known-divergences-<target>.edn`** — THE RATCHET: accepted divergence
  debt, classified + justified, keyed `[:id :bucket]`. The gate fails on a
  **NEW** (unclassified) flagged row and on a **STALE** entry (listed but no
  longer firing) — the ledger only shrinks; fixing a bug forces deleting its
  entry in the same commit. Categories: `:bug` (tracked defect, carries a
  `:thread` ref) | `:host-model` (target-inherent gap) | `:strictness`
  (beagle intentionally stricter). There is no silent skip list anywhere —
  the ledger *is* the skip list. When a target's validity tool is absent,
  its `invalid-output` entries are reported unenforced, never stale.
- **`corpus/`** — sources that exist only for conformance (ratchet fixtures
  pinning known bugs, reject rows). Everything else in the corpus points at
  the shared `beagle-test/tests/fixtures/`.
- **`expected/`** — the committed goldens, sourced from the oracle.

## Running

```sh
bin/beagle-certify                    # the gate (CI: exit 0/1)
bin/beagle-certify --target js,clj    # subset of targets
bin/beagle-certify --regen            # re-source goldens from the oracle
```

CI runs the gate after the tiered suite (`.github/workflows/test.yml`), with
bun + nix installed so the validity dimension is fully armed.

## Adding / changing cases

Add a row to `corpus.rktd` (authored data, jolt-style — never generated),
then `bin/beagle-certify --regen` to source its golden, then run the gate.
A NEW flagged row means either a real bug (file a thread, classify the entry
`:bug` + `:thread`) or a deliberate delta (classify it `:host-model` /
`:strictness`). A STALE entry means the divergence was fixed — delete the
entry and, for a now-correct emission, `--regen` the golden in the same
commit.

Changing the compiler's output on purpose: review the `divergent` report,
then `--regen` and commit the golden delta alongside the compiler change —
the diff *is* the review surface.
