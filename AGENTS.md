# beagle — agent instructions

Operational quick-map for agents. **What beagle is, which targets are live,
and the surface syntax → `README.md` and the compiler — not here.**
This file deliberately restates no fact that rots (target list, form set,
stdlib); those drift fast, so query the source of truth instead of trusting
a stale copy. (`bin/beagle` with no args prints the full command list.)

## Test

```
bin/beagle test                        # the full sweep — the release gate
bin/beagle test --changed              # dev loop: only what your change can affect
bin/beagle test --explain-selection    # print that selection, run nothing
source bin/_beagle-racket              # select Beagle's pinned Racket
"$RACO" make beagle-lib/private/parse.rkt
"$RACO" test beagle-test/tests/parse.rkt
```

`--changed` reads the changed file set from git (working tree plus every commit
since the merge base with main) and runs only the phases and suites those paths
can affect. Selection is an ALLOWLIST: a path the table does not recognize —
the checker, the type system, the reader, the stdlib tables, shared lowering,
anything new — selects the full sweep. Only a genuinely target-local change
narrows. The table and its reasons are `bin/_beagle-test-selection`.

A narrowed run is a first pass, never a release proof. The release gate is the
plain command with no flag, and it is unchanged.

### Read the gate's exit status before you believe it

The gate CLASSIFIES its outcome. The last line of output is the verdict:

```
beagle-test: VERDICT=PASS|FAIL|DIAGNOSTIC gating=yes|no phase=... exit=N load=...
```

| exit | verdict | means | do |
|---|---|---|---|
| 0 | `PASS` | every phase ran and passed | land it |
| 1 | `FAIL` | a phase **ran to completion** and found a defect | fix the code |
| 124 | `DIAGNOSTIC` | a phase **or a single test unit** exceeded its deadline and was killed unfinished | re-run; do NOT touch the code |
| 2 | — | harness or supervisor contract failure | fix the harness |

**A 124 is not a verdict on your work.** The work never finished, so it proved
nothing — usually the machine was simply busy (the verdict used to track load
rather than code, and lane owners abandoned correct work over it). It is not a
pass either: re-run it. Every phase line carries `wall=Ns load=<1min>/<cores>`
so you can see for yourself.

The tier runner draws the same distinction one level down. A test unit that
was killed at its own deadline prints with a `⏱` glyph, is counted apart from
failures, and is detailed under `ACTIVE DIAGNOSTIC DETAIL -- NOT PRODUCT
FAILURES`. **A completed failure outranks a breach at every level**: if any
unit ran to completion and failed, the run is `FAIL`/exit 1 no matter what
timed out beside it, so a diagnostic can never hide a real defect.

## Check / build

```
bin/beagle check [--profile N] PATH...  # type-check, no emit
bin/beagle build [PATH...]              # compile to target (--out DIR, --warn)
bin/beagle syntax FILE                  # parse-check (fix delimiters first)
```

## When you need to know something — ask the compiler

There is no static reference; the surface churns. Query it:

| question | tool |
|---|---|
| does this file parse? | `bin/beagle syntax FILE` |
| signature of X? | `bin/beagle sig X FILE...` |
| fields of record R? | `bin/beagle fields R FILE...` |
| who calls X? | `bin/beagle callers X FILE...` |
| what does FILE export? | `bin/beagle provides FILE` |
| what can the language DO? | `bin/beagle-cheatsheet` (or read `docs/CHEATSHEET.md`) |
| the form set / surface syntax? | read `beagle-lib/private/parse.rkt` |
| what's in the stdlib? | read `stdlib-nix.rkt` / `stdlib-portable.rkt` |
| the full command list? | `bin/beagle` (no args) |
| which targets exist, and for what? | `bin/beagle langs` (`--view domains`) |

## Rules with teeth

- No escape hatches anywhere (`unsafe-*`, `nix-ident`, raw passthrough).
- After an edit, the PostToolUse hook runs `beagle syntax` and **auto-balances
  deterministic paren/delimiter imbalance** (high-confidence + re-verified only);
  it re-reads cleanly. Only ambiguous cases (e.g. unclosed string) need you.
- Never count parens by hand (the tool does it deterministically); don't grep
  for signatures when `bin/beagle sig` exists.
- Active-tier failures: fix. Demoted/gated failures during surface
  iteration: leave alone (that's what the tiering is for).

## Where docs and surface design live

Design papers (role-locality, public-contracts, quarantine, …) live in
`~/code/life-os/threads/` with YAML front matter. `docs/` holds ONLY
distilled or generated artifacts that can't rot — `docs/INFLUENCES.md`
(lineage + thesis) and the generated `docs/CHEATSHEET.md`. Do NOT put
hand-maintained reference prose in `docs/` — that is what rotted the
previous `docs/` into deletion. Reference lives in `README.md` or the
compiler.

## Phase-stable invariants (easy to get wrong)

- `MAP-TAG` / `SET-TAG` are `'#%map` / `'#%set` (well-known, NOT gensyms).
- Reader runs at phase 0, parser at phase 1 — shared symbols must be
  phase-stable.
- `ANY` is `(type-prim 'Any)`.
