# Beagle / Fram lane audit — post-custodian state

Rewritten 2026-08-19 by the lane custodian after acting on the lanes, not just
reading them. The previous version of this file was a read-only snapshot taken
against Beagle main `83d3dd2a`; main has since advanced to `5ec85e82` and
several of its verdicts were wrong as a result. Numbers below are measured, and
every removal names the proof that justified it.

- Beagle main: `5ec85e82165dbefd061077c1227bcec86a2150b4`
- Fram main: `816a752ff8e08b47d4b00abd2faed625b9b263e8` (advanced during this pass from `f8fd6301`)
- Beagle lanes: **55 -> 23** (36 reaped, 1 restored after the incident below; 3 new lanes opened by other agents during the pass)
- Fram lanes: **7 -> 2** (3 reaped here; another actor landed `suite-latency` and reaped `beagle-a39` mid-pass)

## How a lane was proven dead

Name-matching and the prior audit's buckets were not trusted. A lane was
removed only on one of these, re-checked immediately before deletion:

- **ancestor** — lane HEAD reachable from main, so `main..HEAD` is empty.
- **path-identical** — for every path the lane touched since its merge-base,
  main's blob equals the lane's blob.
- **strict superset** — as above, but main only adds lines (numstat `N 0`) and
  `git log --cherry-pick` finds no unique lane commit.
- **landed-under-a-different-hash** — `git log --cherry-pick` finds no unique
  commit and each lane commit subject resolves to a real commit in main.
- **duplicate-of-active** — identical commit object, or byte-identical added
  lines, held by a branch a live sibling lane owns.

## Reaped — 36 Beagle lanes

**Ancestor of main (15).** Nothing unique whatsoever:
`beagle-hl-collection-ordering`, `beagle-hl-equality-hashing`,
`beagle-hl-host-macro-expansion`, `beagle-hl-native-core-gc-ownership`,
`beagle-hl-number-semantics`, `beagle-hl-symbol-behavior`,
`beagle-hl-truthiness`, `beagle-hl-unspecified-behavior-as-spec` (all at
`96e5d08b`), `corpus-diag`, `gate-infra`, `legacy-dispatch`, `lossy-syntax`,
`seal-finish`, `w5b-hygiene`, `w5c`.

**Store integration series (7).** Zero unique commits under cherry-pick, and
main drops no lane line at any touched path: `beagle-sp1-writer-admission`
(main is a strict +195/-0 superset of `store/writer_authority.clj`),
`beagle-sp2-atomic-batches`, `beagle-sp3-conflict`, `beagle-sp3-materialization`,
`beagle-sp4-miss-accounting`, `beagle-store-sp4-integration`,
`beagle-store-sp5-integration`.

**Already landed under a different hash (4).** Every commit subject resolves to
a real commit in main; main then evolved the same files further:
`beagle-trace1-profile-key` (-> `0b89256b`), `leak-fix` (-> `1941ced9`,
`4763f064`, `c9b0ee86`), `native-decode` (-> `1941ced9`, `4763f064`),
`w5c-prep` (-> `ac2922c2`, `76b93c0f`).

**The eight `hl-*` conformance lanes (8).** The prior claim that main's
`598a7ddc` integrated all 24 payloads *byte-for-byte* is **false**, and it is
worth being precise about why, because the correct conclusion is stronger than
the wrong one. All 24 payload files do exist in main, with byte-identical
`rule`, `coverage` and `decision` blocks. Every remaining delta is main
**repairing a broken lane stub**:

| Lane defect | Main's repair |
|---|---|
| `--profile core` / `--profile hosted-js` | `--profile 1` / `3` — numeric profiles are universal in main (245x`1`, 9x`3`, 4x`2`, 1x`0` across all 259 decided cases) |
| `probe/….bl` | `probe/….bgl`, the current extension |
| `(defn probe [] …)` | `(defn probe [] Any …)`, canonical typed return |
| `#lang beagle/js` on core/racket/native-core cases | `#lang beagle` |
| missing `exitCode` on failure cases | explicit `exitCode: 1` |
| `hl-truthiness-*`: a 199-byte stub calling a nonexistent `(truthiness-case)` | the real 1649-byte probe that actually produces the expected stdout |

**Landing these lanes would have regressed the repaired conformance corpus.**
Reaped: `hl-collection-ordering`, `hl-equality-hashing`,
`hl-host-macro-expansion`, `hl-native-core-gc-ownership`, `hl-number-semantics`,
`hl-symbol-behavior`, `hl-truthiness`, `hl-unspecified-behavior-as-spec`.

**Codex-era duplicates (2).**
- `callee-lowering` `931c9def` — its 147 added lines are byte-identical to the
  dynamic-vector-nth commit inside the active `call-lowering` lane. Worktree
  removed; **the branch ref is deliberately retained** as insurance, because the
  sibling rebases frequently. Delete the ref once `call-lowering` reaches main.
- `call-closure` `e82fb947` — reaped, then **restored** (see incident below).

No `docs/private/` notes were lost. The only such file in any reaped lane was
`generics-core-analysis.md`, byte-identical (md5 `50879e97…`) in main and eight
lanes.

## Reaped — 3 Fram lanes

`beagle-04b319d2` (`2c847bbf`), `beagle-base` (`e876e1b8`),
`gates-fram-order-slots` (`170539b6`) — all ancestors of Fram main, all verified
free of live processes and open file handles before removal.

## Landed

**Nothing.** No landing was completed, and this is a deliberate refusal rather
than an omission — see the gate section below. One lane was fully prepared:
`demo-driver-v2` is rebased onto current main and ready.

## Remaining Beagle lanes, in priority order

| # | Lane | Verdict | Why |
|---:|---|---|---|
| 1 | `demo-driver-v2` `c324f0c8` | **READY TO LAND** | Converts the Stage 5 demo from a no-op `comment-layout` edit to a real `private-implementation` semantic edit and adds behavioural proof (builds native executables for baseline and candidate and compares their run output). Premise re-verified against current main: the `private-implementation/foundation.bgl` fixture, `corpus/app.bgl`'s `run-score` entry, the `private-offset` definition and the `native-exe` command all exist. Already rebased onto `5ec85e82`; merges clean; no test tier invokes the file, so landing risk is low. Blocked only by the contended gate.  |
| 2 | `dsl-wire` `0430b134` | VALUABLE | 711 insertions of private wire-codec schema DSL across three Store `.bgl` codecs. All three files still exist in main and main has barely touched them since the lane's base (one file, +4/-5), so the premise holds. Merges clean. |
| 3 | `w1.5-migration` `4c791522` | VALUABLE, needs an owner decision | Premise still holds — main still defines and exports the forward structural-name bridge. This is the **complete** removal: it drops both bridge directions and rewires `check.rkt` (`reference-structural-name`, `reference-hash-qualified-ref`) so nothing needs them, leaving no dangling callers. It collides with `scaffold-guard`, which does a partial version of the same removal — see below. |
| 4 | `w12-migration` `68f4c384` | VALUABLE but risky | Retires legacy compiler dispatch: -470 lines in `parse.rkt` plus shape-sensitive definition names. Merges clean textually, but main has added +157/-31 to the same file since the lane's base, so a clean textual merge is NOT evidence of correctness here. Do not land without the full gate green. |
| 5 | `store-gate2` `83abe046` | **BLOCKED — real dependency** | Advances `native-core/validation/store.ref` from `24309a05` to `711c02c1`. That Store commit is **not on Store main** (`f8fd6301` at time of check); it exists only on the Store lane `store-layout-rename` and a protected Store pin. Landing it would point Beagle's validation at an unpublished commit. The Store layout rename must land first. |
| 6 | `rpc-lowering` `13e21ac0` | VALUABLE, **owner-blocked** | Native global dependency lowering fix, merges clean. It edits `native-core/src/native/lower.bclj`, which the live sibling lanes own and which was explicitly out of bounds for this pass. Hand to whoever owns the native lowering seam. |
| 7 | `surface-syntax-reader` `6f36af38` | STALE-CONFLICTED | 30-file flat typed binding surface; conflicts with current main and touches 5 sibling-owned native/selfhost files. Needs its author. |
| 8 | `w13-migration` `2ae1a009` | STALE-CONFLICTED | Structured syntax-value migration, 15 files, conflicts; 2 sibling-owned files. |
| 9 | `div-enumerate` `cbed0183` | STALE-CONFLICTED | 237-file divergence enumeration against a conformance tree that has since been repaired wholesale. Very likely superseded by events; re-derive rather than rebase. |
| 10 | `w5d-prep` `935c5195` | STALE-CONFLICTED | 5-commit W5d expansion-cone corpus, conflicts in several files. |
| 11 | `selfhost-dispatch` `51a4ab78` | STALE-CONFLICTED | 3-commit selfhost dispatch series, conflicts, 5 sibling-owned files. |
| 12 | `pregate-selfhost` `f59818ab` | STALE-CONFLICTED | 2-commit hosted-AST route, conflicts, 4 sibling-owned files. Overlaps `selfhost-dispatch` (it is that lane's first two commits). |
| 13 | `beagle-sp6-budgets` `06f22f56` | STALE-CONFLICTED | Routine budget accounting; 8 of its 9 commits are already in main, leaving 1 unique commit inside a 26-file conflicting delta. Cherry-pick the one commit rather than rebasing the lane. |
| 14 | `bnix-cap` `cf4e7959` | STALE-CONFLICTED | Compiler-owned Nix project membership, conflicts. |
| 15 | `store-pin-advance` `00b6f5f0` | STALE-CONFLICTED | Superseded in spirit by `store-gate2`, and blocked by the same unpublished Store commit. |
| 16 | `scaffold-guard` `bee9d25b` | **owner decision** — see below |
| 17-19 | `operands-closure`, `literals-closure`, `call-lowering` | **ACTIVE — do not touch** | Live sibling agents. `literals-closure` currently has 1 uncommitted tracked file. |
| 20 | `call-closure` `e82fb947` | duplicate, restored | Proven duplicate of `call-lowering`, but restored after the incident below. Safe to reap once its build processes exit and `call-lowering` lands. |

## `scaffold-guard` — the uncommitted work, now committed by someone else

The brief flagged this lane as holding 2 uncommitted tracked files, to be
reported and not resolved. **During this pass another actor committed them** as
`bee9d25b "wip: preserve found uncommitted state in scaffold-guard lane"`. The
lane is now clean and 1 commit ahead. Exactly what it contains:

- `beagle-lib/private/ast.rkt` — deletes the forward structural-name bridge (the
  definition and its export). It leaves the reverse structural-name bridge in
  place, which still has 3 uses in `ast.rkt` and 1 in `check.rkt`.
- `bin/test/qualified-ref-scaffold/run.sh` — turns the single forbidden-string
  check into a loop over both the retired symbol accessor and the forward
  structural-name bridge.

It is self-consistent (no dangling callers) but it is a **half** of what
`w1.5-migration` does completely. The two conflict. The decision the commander
owns: land `w1.5-migration` and discard this WIP, or keep the stricter guard
from this lane and drop its `ast.rkt` change. Landing both as-is is not possible.

## Fram lanes

Fram moved under this audit while it was being written: another actor landed
`suite-latency` and reaped `beagle-a39`, and Fram main advanced from
`f8fd6301` to **`816a752f`** ("ci: reuse Babashka runtime for revision identity
gate"). Both outcomes match the verdicts reached here. **2 Fram lanes remain.**

| Lane | Verdict | Why |
|---|---|---|
| `pin-advance` `50a03e18` | **ACTIVE — do not touch** | Advances the Beagle pin to `63b54bf4` (on Beagle main) and bounds native emission workers. Live work, parked on a real dependency. |
| `compile-projection` `4b161854` | UNCLEAR — needs its author | A 1711-line experiment (`compile_projection.clj` + a 560-line test) validating native compile projections. Merges clean and is 3 days old. Nothing in Fram main references it, so it is neither rotting nor load-bearing. Whether the experiment's contract is still wanted is an author call, not a custodian call. |
| ~~`beagle-a39`~~ | reaped by another actor | Classified here as SUPERSEDED BY EVENTS: its pin target `4c05adc3` (Aug 17) is an **ancestor of** `63b54bf4`, which the live `pin-advance` lane already targets, so the pin work was overtaken. Its remaining content was v0.8.0 release-prep prose premised on the stale pin. Re-cut that prep against the new pin if v0.8.0 is still wanted. |
| ~~`suite-latency`~~ | landed | Babashka runtime reuse for the revision identity gate is now Fram main's tip. |

## New Beagle lanes that appeared during this pass

Other agents opened these; none is stale and none was touched.

| Lane | State |
|---|---|
| `compiler-proof` `20ad66b3` | 0 ahead of main, clean, 3h old |
| `store-baseline` `5ec85e82` | 0 ahead of main, clean, 2h old |
| `store-lineage` `5ec85e82` | 0 ahead of main, **9 uncommitted tracked files**, 2h old — live work |

## Why nothing was landed — the gate cannot return a trustworthy verdict today

**Main is not broken.** The gate's phase deadlines are simply shorter than the
work takes while three sibling closure builds pin about six of the 24 cores at
~99% CPU, several for 20+ minutes at a stretch.

| # | Run | Where | Result | 1-min load |
|---:|---|---|---|---|
| 1 | `bin/beagle test` | `demo-driver-v2` rebased onto `5ec85e82` | phase `consumer-smoke` TIMEOUT (124), 279s | 7.32 -> 7.68 |
| 2 | `bin/test/consumer-smoke/run.sh` | control lane at **unmodified main** `5ec85e82` | **same phase, same failure**, 241s | 9.20 -> 9.61 |
| 3 | same, `BEAGLE_CORE_COMPILER_TIMEOUT_SECONDS=900` | control lane at unmodified main | **PASS**, 308s | 7.07 -> 8.13 |
| 4 | `bin/beagle test`, same scaled deadline | `demo-driver-v2` rebased | phase `racket-scope` TIMEOUT (124) at 73s — a phase that passed in run 1 | 9.03 -> **13.82** |

Run 2 proves the failure is **not attributable to any lane**. Run 3 proves main
is green given headroom: the binding constraint was the 180-second default on
`beagle-core-compiler-projection`. Run 4 then failed at a *different, earlier*
phase whose 70-second deadline had been comfortably met in run 1 — while load
climbed to 13.8, past the ~12 ceiling for this 24-core box.

Chasing that would mean scaling every phase deadline in turn until the gate went
green, which is manufacturing a pass, not earning one. This is precisely the
false-failure-under-contention mechanism that stranded many of these lanes in the
first place, so the run was stopped instead.

**Landing queue, in order, for the next quiet window:**

1. `demo-driver-v2` — **already rebased onto `5ec85e82` and ready**; just gate and push.
2. `dsl-wire`
3. `w1.5-migration` — after the `scaffold-guard` decision above.
4. `w12-migration` — needs the gate genuinely green, not merely a clean merge.

Run the gate at a 1-minute load below ~12 and record the load beside the result.
If phases still time out at low load, scale deadlines **visibly** and say so.

## Incident — a sibling build was disrupted

A sibling agent had a Native Core build running with its working directory
inside `beagle:worktrees/call-closure` when that lane was reaped. Eight
processes were left holding a deleted working directory and their in-flight
build output is gone; those runs will fail and must be re-run.

- **No commit was lost.** `e82fb947` is intact in the object store and its
  content is independently reproduced in the active `call-lowering` lane.
- **The lane was restored** to the same path, detached at the same commit,
  clean — identical to how it was found.
- **Blast radius was verified as exactly one lane** by sweeping every
  `/proc/*/cwd`; the other 35 reaps had no process running in them.
- **Cause**: the live-process sweep was run after the first reap batch instead
  of before it. A `/proc/*/cwd` sweep must precede any reap, and it did precede
  the Fram reaps that followed.
