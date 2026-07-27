# Conformance: certifying every backend against the oracle

The corpus (`corpus.rktd`) is beagle's per-backend executable spec — one row
per case: `(id path kind option ...)`, where `path` is a beagle source file
(target derived from its extension: `.bjs`→js, `.bclj`→clj, `.bnix`→nix,
`.bsc`→scriptc) and `kind` is one of:

| kind | contract |
|---|---|
| `emit` | golden = emitted target source |
| `reject` | source must fail check; golden = the diagnostic text |
| `static` | emit **+** the output compiles 100% statically on the target (scriptc), over **more than zero** statements |
| `native` | static **+** the native executable's stdout/stderr/exit equal the oracle runtime's (node) |
| `module` | multi-file row (`#:modules`); goldens live in `expected/<target>/<id>/`, then runs the static + native dimensions |

Options: `#:modules (path ...)` names a module row's siblings;
`#:diag-requires REGEX` / `#:diag-forbids REGEX` give a `reject` row a
**pointedness contract** — what a user-facing diagnostic must and must not
say. Without one, a reject row with an internal-detail message is a silent
pass: the rejection is "correct" and nothing ratchets.

The **oracle is the Racket beagle compiler at HEAD**: `--regen` sources every
golden from it; a gate run diffs the live compiler against that blessed
snapshot. Mechanics ported from jolt's `test/conformance/certify.clj`.

The gate kills semantic drift across targets in these independent dimensions:

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
   `diag-divergent` (regen after review); a diagnostic that breaks its
   pointedness contract is `diag-unpointed`.
4. **Static coverage (scriptc)** — `scriptc coverage` must analyze **more than
   zero** statements (`static-vacuous` otherwise — 0/0 is not 100%) and
   compile all of them statically (`static-incomplete` otherwise). Accepted
   rows print their statement counts, so the green is auditable, not asserted.
5. **Native differential (scriptc)** — the native binary's stdout, stderr and
   exit status must equal Node's on the same emitted `.ts`
   (`native-divergent` otherwise).

Dimensions 4–5 need the ScriptC CLI (`$BEAGLE_SCRIPTC`, or `scriptc` on PATH)
plus clang and node. ScriptC is **not** a beagle dependency and is used only
as a black-box executable oracle. When any of those tools is missing the
dependent dimensions report **`unenforced`** — a distinct state that is never
a pass, and whose ledger entries are reported unenforced rather than stale.

## What's here

- **`certify.rkt`** — classifies every row into buckets: `match` /
  `reject-match` (good), `divergent`, `invalid-output`, `compile-fail`,
  `reject-mismatch`, `diag-divergent`, `diag-unpointed`, `static-vacuous`,
  `static-incomplete`, `native-divergent`, `no-golden` (flagged), plus
  `unenforced` (not a pass). Run it only via
  `bin/beagle-certify`, which pins racket and routes the `beagle` collection
  at *this* checkout — a worktree certifies its own compiler.
- **`scriptc-oracle.rkt`** — the executable ScriptC oracle: tool discovery,
  static-coverage and native-vs-Node probes. Shared by `certify.rkt` and the
  focused suite `beagle-test/tests/emit-scriptc-behavioral.rkt` (run it with
  `raco test`; it is not in `beagle-test/tiers.rktd`).
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

# arm the scriptc static + native dimensions
BEAGLE_SCRIPTC="node /path/to/scriptc/packages/cli/dist/main.js" \
  bin/beagle-certify --target scriptc
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
