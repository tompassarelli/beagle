# Phase 2 — exit report (S6 / gate G6)

The epoch stage is landed end to end: a program-to-program pass between native
lowering and the materializers, two obligations that keep it honest, real
arenas in the emitted C, and one surface form an author can write. This file
is the measurement that closes the phase — what the six stages shipped, what
the six gates observed, what the instruments say about the compiler and about
fram, and what is deferred with the name it is deferred under.

Reproduce the numbers below with `native-core/tests/epoch_reference_gate.sh`
(G6) and `native-core/tests/epoch_stage_gate.sh` (G1, the emitter-only subset).

## 1. What shipped

| stage | commit | what it made true |
|---|---|---|
| S1 | `d8d53eb9` | `native-core/analysis/epoch/` — the escape/affordance analyzer, the epoch-assignment fold, the G1 gate. Report-only. |
| S2 | `7e4f91cd` | `lower-epoch-stage`: region-tree minting, instruction retargeting, `ArenaCloseInstructionV0`, obligations 8 (epoch soundness) and 9 (leak freedom). |
| S3 | `7fc48622` | The stage becomes the seam every materializer sits behind, under epoch-0 identity: same bytes out of C17, fold, c11 and QBE. |
| — | `d233e46c` | Nine obligation projections accepted downstream. |
| S4 | `4fd3ec20` | Epochs become real arenas in the emitted C: open/close emission, caller-arena generalization, `native_value_promote`. |
| S5 | `d1d51013` | `(bgl/promote v)` — the one thing an author says about lifetime — with the epoch-free case lowered to a register move. |
| S6 | this commit | The exit measurement: `g6-gate.clj`, `epoch_reference_gate.sh`, this report. |

## 2. Gate ledger

| gate | claim | observed |
|---|---|---|
| G1 | ≥90% of allocating sites assigned in the stage/emitter modules; refusals TODO-EPOCH-coded; zero unexplained | **680/681 = 99.9%**, one `TODO-EPOCH-RETURN-PAST-ATTRIBUTED-REGION` |
| G2 | nine obligations green on rewritten fixtures; mint path forced; rejection depth named | `nine-valid-passes?`, `nine-negatives-named?`, `epoch-stage-mint-passes?` true; 18 rejection-depth fixtures; `obligation_rejection_matrix` 30/30 |
| G3 | the identity stage is a relabelling — every materializer emits the same bytes | 99 of 101 committed generated files byte-identical; the two that move are `slice-rt-core`'s ledgers, which hash the sources the commit edits. Zero C17/fold/c11/QBE artifact bytes changed |
| G4 | epochs physically reclaim; obligation 8 refuses old→young; `promote` fixes it | root-arena reserved bytes at 64 → 65536 iterations: **derived 0 → 0, identity 4096 → 1581056**; caller-owned epoch (E3) derived 0 → 0, identity 4096 → 1048576. Old→young refused, the same program with `promote` passes nine obligations and returns the bytes after the epoch is destroyed, clean under ASan+UBSan |
| G5 | the surface form types, lowers two ways, and collapses when it can | epoch-free promote emits `native_s_5 = native_s_4;`, handle-carrying promote emits `native_value_promote`; 2 promotes before the stage, 1 after; 0 under identity |
| G6 | ≥90% assigned on compiler-shaped programs; escapes are the stage products; fram stated unlaundered | **3457/3676 = 94.0%** assigned; escapes **98.0%** stage products of the typed, **zero** foreign retainers; §5 below |

## 3. G6 — assignment over the compiler-shaped reference programs

Sixteen modules: the compiler's own (`core`, `stages`, `lower`, `obligations`,
`slice`, `body-slice`), the four emitters, and the six validation-corpus
modules that construct programs. 3,676 allocating sites.

```
module                            sites  assigned      pct  static  stage  loop  caller  refused
native.body-c17                     256       256   100.0%       0    248     4       4        0
native.body-slice                    68        64    94.1%       0     31     2      31        4
native.c11                           96        96   100.0%       0     91     1       4        0
native.c11-validation-corpus         51        47    92.2%      37      9     0       1        4
native.core                         172       172   100.0%       0    168     0       4        0
native.epoch-validation-corpus      109       108    99.1%      84      6     0      18        1
native.fold-c17                     105       105   100.0%       0    100     1       4        0
native.fold-slice-corpus            127       119    93.7%      55     21     1      42        8
native.lower                       1462      1292    88.4%      63    457    64     708      170
native.obligations                  401       398    99.3%     335     36     0      27        3
native.promote-validation-corpus     15        11    73.3%       0      7     1       3        4
native.qbe                          172       172   100.0%       0    156     8       8        0
native.qbe-validation-corpus        421       419    99.5%     412      7     0       0        2
native.slice                         73        51    69.9%       0     35     3      13       22
native.stages                        52        51    98.1%       0     50     0       1        1
native.validation-corpus             96        96   100.0%      95      1     0       0        0
TOTAL                              3676      3457    94.0%
```

Two modules sit under the threshold on their own and are worth naming rather
than averaging away. `native.slice` (69.9%) refuses 22 sites, every one
`TODO-EPOCH-MUTABLE-CELL-STORE`: the slice driver's projection tables are
built into atom cells, which v0 pins to the root. `native.lower` (88.4%) is
the compiler's largest module and carries 101 of the 131 cell-store refusals;
its shape is the honest one — 708 of its assignments are caller-owned, i.e.
lowering mostly allocates the values it exists to hand back.

### Refusal census — 219 refusals, five codes, zero unexplained

| n | code | what the real stage must do |
|---|---|---|
| 131 | `TODO-EPOCH-MUTABLE-CELL-STORE` | the store-owned region (design case B) |
| 67 | `TODO-EPOCH-RETURN-PAST-ATTRIBUTED-REGION` | whole-program, multi-level caller attribution |
| 14 | `TODO-EPOCH-RAISED-ERROR` | an error-path epoch |
| 6 | `TODO-EPOCH-UNKNOWN-FLOW` | stays heap / compile error |
| 1 | `TODO-EPOCH-CLOSURE-CAPTURE` | stays heap / compile error |

The fold is total on every module: assigned + refused = sites, checked per
module by the gate.

### Escapes census — G6's substantive claim

An escape here is a caller-owned site: a value that leaves through its
region's OWN crossing set, so the region allocates it into the caller's epoch.
The claim under test is "escapes are exactly the stage products". Each escape
is classified by the retaining type the analyzer observed, against the type
vocabulary the compiler declares in its own sources (356 records plus the
union names, read out of `native-core/src/native/*.bclj`).

| | n | share |
|---|---|---|
| escapes | 868 | |
| retains a compiler-declared type | 669 | **98.0% of typed, 77.1% of all** |
| retains only a scalar/text shape | 14 | 2.0% of typed |
| retains a type no compiler module declares | **0** | — |
| no retaining structure observed | 185 | 21.3% of all |

The rate is 98.0%, not 100%, and both exceptions are named:

- **The 14 text-only escapes** are the emitters' text products crossing an
  emitter driver's boundary — the emitted C/QBE source and the path it is
  written to at `emit-slice!` / `emit-slice-for-abi!` / `emit-dual-slice!`
  (`slice.bclj`, `body_slice.bclj`), a configuration digest
  (`stages.bclj:130`), the printable-ASCII table (`body_c17.bclj:32`), a
  verdict line, and two label vectors. They are products in the plainest
  sense — they ARE the artifact — but the classifier declines to credit them
  because a bare `String` names nothing the compiler declares. Credited by
  hand the typed share is 683/683; the gate reports the measured 98.0% and
  does not do that crediting.
- **The 185 untyped escapes** are reported unknown and never imputed to
  either side (analyzer LIMITS item 8). They are dominated by collection
  building — `conj`/`disj` 82, vector literals 29, `assoc`/record-assoc 29,
  `concat` 13, string concat 11 — intermediate accumulators that cross a
  boundary with no retaining record for the analyzer to observe; 144 of the
  185 are in `native.lower`.

The top declared retainers, so the label "stage product" can be judged rather
than trusted: `ExprResultV0` 229, `NativeLoweringCompleteV0` 93,
`TypingAcceptedV0` 62, `EpochLoweringCompleteV0` 41, `TypeResolutionV0` 39,
`(Vec core/NativeId)` 30, `(Vec FactSpecV0)` 25, `JumpTerminator` 20,
`BodyStateV0` 13, `SwitchCaseV0` 10, `ValueFlowSiteV0` 10,
`NativeCoreProgram` 7. Every one is IR, a stage result, a receipt or an
artifact.

**Honest summary of the claim.** "Escapes ≡ stage products" holds as a
tendency with a measured rate, not as an identity: 98.0% of the escapes whose
retaining type the instrument could see are compiler-declared products, zero
escapes retain something the compiler does not own, and 21.3% of escapes are
untyped and therefore prove nothing either way. The strongest form the
evidence supports is: *nothing that crosses a compiler stage's boundary is
foreign to the compiler's own vocabulary.*

## 4. The landed stage at IR level — a much smaller population, said plainly

The measurement above is over compiler SOURCE. The landed derived stage
consumes Native Core IR, and the compiler's own modules are hosted-dialect
`.bclj` — not natively lowerable — so the two instruments do not yet meet on
one program. What the derived stage can be run over today is the validation
corpus's own programs: 42 `NativeCoreProgram`s, 60 functions, **24 allocating
instructions** across the 18 input programs that contain one (excluding the
four stage-OUTPUT programs the corpus keeps for byte-comparison). Of those 24:
1 retargeted into a minted epoch, 17 kept at the root as escaping products, 6
kept at the parent under `TODO-EPOCH-AMBIGUOUS-ESCAPE` /
`TODO-EPOCH-NESTED-ARENA-OPERAND`.

That is a fixture census, not a reference-program measurement, and it is not
what G6 is gated on. Two facts from it are worth keeping:

- S2 already recorded the same shape from the other side: the pipeline fixture
  programs mint **zero** epochs because *their allocations all escape as stage
  products* — the in-compiler corroboration of §3's escapes claim.
- S4 measured that derived assignment mints exactly two epochs across the
  entire validation corpus (fram.text-ops, and fram.rt-core `fn_14`), and that
  those are the only two generated C files that move.

The gap between 3,676 source sites and 24 IR instructions is the honest state
of Phase 2: the analysis is broad, the mechanism is proven, and the population
the mechanism runs on is still small because the corpus's natively-lowered
programs are small.

## 5. The fram half — stated, not laundered

These are the v3 numbers (measurement patch W2), restated unchanged. **They
are pre-arena**: the defect-4 store-owned generation arena had not landed when
they were taken, so they measure the fram that exists TODAY, not the fram the
recast is about.

| measure | v2 | v3 |
|---|---|---|
| fram sites | 1,219 | 1,220 |
| provably interior | 11.0% | 11.0% (134) |
| interior-or-crossing | 71.7% | **68.4%** |
| generation-scope class, provably interior | 10.3% (29 sites) | **7.1%** (42 sites) |
| generation-scope class, interior-or-crossing | 48.3% | **54.8%** |
| fram crossing-escape domain identity, % of classified | 47.3% | **39.5%** (269/681) |
| … absolute ceiling (every unknown credited domain) | 64.5% | **41.1%** |

The reopen clause (re-argue the store-heap ruling if fram crossing-domain
exceeds 50% of classified) did **not** fire, and cannot fire on an honest
resolution of the residue: the ceiling is 41.1%. Both remaining instrument
defects were flattering, and fixing them moved fram down.

The two sentences that must stay apart:

- **What fram measures today:** its own generation brackets are the corpus's
  worst boundary class (7.1% provably interior against the corpus's 40.3%),
  and what crosses those brackets is mostly not domain facts — 39.5% of the
  classified crossing set, ceiling 41.1%. The store-heap unification claim as
  stated is dead on these numbers.
- **What construction is expected to change:** none of the above. The live
  line is the recast — fram's generation brackets becoming EXPLICIT
  store-owned epochs, with `bgl/promote` (S5) as the surface the values that
  must outlive a fold say so through. The fold-inside-epoch floor fix is that
  recast's first artifact and its first `promote` consumer. It is a design
  obligation to be earned by construction; it is **not** a prediction that
  re-measuring today's fram will give a different number, and no number in
  this report may be quoted as if it were.

## 6. What the machinery enables next

1. **The fram fold-inside-epoch floor fix.** The fold runs inside a
   store-owned epoch; the values that outlive it are promoted. S5 shipped the
   consumer surface, S4 shipped the runtime copy (`native_value_promote`), and
   obligation 8 is the check that catches the case where the promote is
   missing. This is Phase 3's opening move.
2. **E2 — loop epochs.** The S1 analysis already assigns 64 loop-body sites in
   `native.lower` and 8 in `native.qbe`; the compiler stage mints only
   function-local (E1) and caller-passed (E3) epochs. A loop-header epoch with
   a per-iteration reset is the next mint kind, and the warm-reset flag it
   needs is already in the shim.
3. **QBE epoch parity.** QBE currently shims the same `native_arena_alloc` ABI
   and is handed the identity program by a deliberate double-run of the stage
   (`emit-dual-slice-for-abi!`, the two capability slices). Lifting it to
   emit epoch open/close is a sibling of S4, now that the C17 shape is proven.
4. **Broader adoption as code grows epoch-shaped.** The 94.0% is a property of
   code that already allocates in stage-shaped regions. The three refusal
   codes that dominate (cell store, return past an attributed region, raised
   error) are each a named piece of stage work, not a wall.

## 7. Deferred, by name

- **QBE epoch parity** — deferred past S6 by the design; QBE receives the
  identity program until it lands.
- **E2 loop epochs** and **multi-level (E3-beyond-one-hop) callee summaries**.
- **`TODO-EPOCH-MUTABLE-CELL-STORE` (131)** — the store-owned region, design
  case B; the same shape fram's recast needs.
- **`TODO-EPOCH-RETURN-PAST-ATTRIBUTED-REGION` (67)** — whole-program caller
  attribution; the analyzer's one-level attribution is the limit.
- **`TODO-EPOCH-RAISED-ERROR` (14)** — an error-path epoch.
- **`TODO-EPOCH-ATOM-STORE`, `TODO-EPOCH-NESTED-ARENA-OPERAND`,
  `TODO-EPOCH-AMBIGUOUS-ESCAPE`** — the IR-level equivalents inside
  `epoch-rewrite-function`.
- **Labelled `promote`** — arity stays one until Phase 3 has a consumer.
- **Static epoch sizing and warm-reset policy** — v0 is growable-chunk epochs
  with reset-always on loop back edges; sizing is a measurement, not a design.
- **The 185 untyped escapes** — resolvable only by a retaining-type model
  stronger than the analyzer's best-effort `held` label, which is a Phase-3
  instrument question, not a Phase-2 debt.
