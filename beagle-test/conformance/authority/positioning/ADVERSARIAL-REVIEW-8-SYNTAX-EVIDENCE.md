# Adversarial review 8 — empirical syntax evidence

## Verdict

The fleet record does not support the strong claim that agents generally
underperform when authoring typed s-expression Beagle compared with C-family
code. It does support a narrower claim: Beagle-source dispatches in this
campaign encountered more blocked compiler/contract/deadline seams than the
small operational `.mjs`/`.nix`/shell control set. The syntax-specific record
is weak evidence for underperformance: three syntax defects are visible, all
were repaired or mechanically corrected, and zero cases show an agent unable
to self-repair an unparseable form. The sample is selected, mixed in difficulty,
and not a controlled comparison.

## Counting rule

The primary unit is a terminal dispatch row, not a unique project or worker.
Retries and closers therefore appear as separate rows; the retry section
groups them back into logical attempts. I counted only rows with enough source
evidence to classify them as authoring/compiler work. Beagle-source means a
mission explicitly editing or testing `.bgl`, `.bjs`, `.bnix`, or Beagle
compiler/self-host sources. The control set means source/control work explicitly
identified in the records as `.mjs`, `.nix`, or shell. I excluded planning-only,
documentation-only, Clojure/YAML-only, release-recording-only, and still-pending
rows. A `success-*blocked` row is counted as blocked when the requested gate or
integration was not green; a closer that completed the source work is a
separate completed row.

The assignment source is `/home/tom/code/todo/model-assignment-ledger.md`;
the execution source is `/home/tom/code/todo/agent-coord.md`. The latter is
authoritative where a dispatch row was still marked pending in the assignment
ledger but the execution ledger recorded a terminal result.

## 1. Mission outcomes

| cohort | terminal dispatch rows | completed | blocked | killed | completed rate |
|---|---:|---:|---:|---:|---:|
| Beagle source/compiler | 28 | 13 | 13 | 2 | 46.4% |
| `.mjs`/`.nix`/shell control | 13 | 10 | 1 | 2 | 76.9% |

The Beagle rows are the W5a/W5b/W5c/W5d syntax, hygiene, self-host, binding,
Store, DSL, and gate rows; the Beagle/Nix capability probe rows; the two
Firn-native closer pairs; the store-train source preparation; the
`syntax-atom` bisect; `rpc-lowering`; and the C131 hosted-Beagle projection.
Their exact assignment rows are visible at
`/home/tom/code/todo/model-assignment-ledger.md:279-321`,
`/home/tom/code/todo/model-assignment-ledger.md:328-385`, and
`/home/tom/code/todo/model-assignment-ledger.md:450-508`.

The Beagle outcome breakdown is therefore 13/28 complete, 13/28 blocked, and
2/28 killed. The killed rows were the W5b hygiene wave at its fixed oracle
deadline and the Firn-native3 worker past its stall line; the execution ledger
attributes both to deadline/stall or capability conditions, not syntax.

The 13-row control set contains the explicitly `.mjs`/`.nix`/shell-labelled
source/control rows for Fram re-point, fast-native-test, dig-prod, driver-land,
nix QA, the musl Nix module, Firn rebuild diagnosis, Fram local publication,
the v0.23 release train, and the North environment sweep, plus the two Fram
publication/re-point failures. This is a deliberately conservative control,
not a claim that those missions match Beagle compiler work in size or novelty.
The initial re-point kill is recorded as dispatch infrastructure, and the later
publication kill as meandering; neither is a syntax failure.

## 2. Incident classification

Counts below are incident families, not every repeated mention in the board.
They classify the cause of a red or stop, not whether the agent eventually
produced a useful checkpoint.

| class | incident families | count | evidence-backed reading |
|---|---:|---:|---|
| SYNTAX | delimiter/parenthesis defects | 3 observed; 0 unrepaired | C131 had one missing closing parenthesis in the hosted Beagle projection; a compiler worker had a delimiter error in `tier-runner.rkt`; a purity test gate hit a delimiter error. All were repaired; the purity gate was not rerun before the hard deadline. |
| SEMANTICS | type/union/store/hygiene contract defects | 5 | erased `Vec Int` accessor typing produced a real `Number`/`Any` error; a closed-union match missed `native.json/JsonEvent`; the daemon route had a Store-closure omission; the syntax-atom macro boundary needed datum unwrapping; and a slice/Store contract mismatch was surfaced. |
| NEITHER | environment, deadline, collision, stale-object, or apparatus | 9 | fixed compiler-time limits and contention; pre-existing native timeout trio; stale Beagle pin versus current-main disagreement; dead queue/session and stall kills; missing compiler capability for `.bnix` surfaces; lock/collision waits; and missing wasm toolchain. |

The strict syntax criterion in the mission—“mismatched delimiters or
unparseable output an agent could not self-repair”—therefore yields **zero**
unrepaired syntax incidents. The three observed syntax defects are real, but
the available evidence says agents corrected them. The most concrete syntax
transcript hits came from the sanctioned `convo` search:

- C131: “missing closing parenthesis” in the hosted compile, followed by a
  green focused gate (`convo --since 3d --role assistant
  --project=-home-tom-code-greywrought -x 'missing closing parenthesis'`).
- A compiler worker’s `tier-runner.rkt:581` delimiter error
  (`convo --since 7d --role assistant --project=-home-tom-code-beagle
  -x 'delimiter error'`).
- The purity gate’s `purity.rkt` delimiter error, fixed before a deadline hold
  (`convo --since 7d --role assistant --project=-home-tom-code-greywrought
  -x 'delimiter error'`).

The execution ledger corroborates the first item at
`/home/tom/code/todo/agent-coord.md:5362` and the semantic/compiler incidents
at `/home/tom/code/todo/agent-coord.md:20698-20704` and
`/home/tom/code/todo/agent-coord.md:20801-20824`. It also records the important
correction that the reported five Firn parse failures were a stale-pin artifact,
not a current-main parser failure, at
`/home/tom/code/todo/agent-coord.md:10780-10985`.

## 3. Retries to green

Only countable retry chains are reported; a row that merely says “pending” is
not treated as a retry or as a failure.

| logical mission | attempts visible | retries to green | what changed |
|---|---:|---:|---|
| C131 hosted-Beagle projection gate | 3 | 2 | first focused gate 195/198, second 197/198, final 198/198; the retries fixed deterministic evidence assertions, not Beagle syntax. |
| Firn-native1 | 2 | 1 | blocked on a stale pre-commit allowlist, then the closer landed the allowlist and seam. |
| Firn-native2 | 2 | 1 | blocked because its lane base predated the allowlist fix, then the rebased closer landed green. |
| Fram re-point | 2 | 1 | the first background shell was killed at ten minutes; detached relaunch completed. Infrastructure retry, not code syntax. |
| W5b full gate | 3 named rounds | 0 recorded | the final rounds remained blocked by latency/base failures; focused repairs were green but no full-gate green is recorded in the source set. |

The C131 retry evidence is explicit in
`/home/tom/code/todo/agent-coord.md:5362-5377`. The Beagle-side closer and
kill evidence is at `/home/tom/code/todo/model-assignment-ledger.md:313-385`;
the control-side re-point evidence is at
`/home/tom/code/todo/model-assignment-ledger.md:33-38`.

## What the numbers support

On this selected dispatch-row sample, Beagle authoring has a much higher
blocked rate (13/28 versus 1/13) and a lower completed rate (13/28 versus
10/13). That is enough to justify an engineering concern about Beagle’s
compiler/authoring seam and about the cost of typed semantic contracts. It is
not enough to attribute the gap to s-expression syntax: syntax defects were
few, visible, and repairable; the larger reds were semantic/compiler capability,
latency, stale pins, lock contention, baseline drift, and worker supervision.

The comparison is confounded in both directions. The Beagle cohort contains
compiler development, self-hosting, macro hygiene, closed unions, Store
integration, and cold native gates—harder and more novel work than most
control rows. The control cohort contains operational Nix/shell/release work,
not a matched set of equally difficult typed compiler changes. Rows are
dispatches rather than independent agents, some “completed” rows are
checkpoint-complete but not landed, and the corpus is one campaign window.
There is no denominator for all fleet authoring, no random assignment, and no
normalized task complexity. The defensible conclusion is therefore: **fleet
evidence supports semantic/compiler friction in Beagle, but does not support a
claim that agents underperform specifically because typed s-expression syntax
is harder than C-family syntax.**

SYNTAX-EV-DONE — counts and caveats written; no repository landings performed.
