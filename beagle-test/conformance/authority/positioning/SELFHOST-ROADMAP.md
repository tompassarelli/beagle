# Beagle self-hosting roadmap

## Position

Beagle already has a bootstrap-capable compiler. self-host/seed/selfhost/*.clj
runs under Babashka, and the matching GraalVM native image is the distributable
stage0 compiler. It reads, parses, type-checks, projects a checked AST, and
emits Clojure, JavaScript, Nix, and facts without Racket. The machine remains
Racket-hosted in the public compiler CLI, the tier gate, the differential
oracle, and most developer queries. Racket-free compilation is a routing and
parity project, not bootstrap from zero.

No repository measurement states native-stage0, Babashka, or Racket compile
speed; beagle:docs/self-hosting.md:31-32 says so. CPU payoff below therefore
means processes removed, never invented seconds.

## Exactly what still requires Racket

### Compilation

The public dispatcher sources pinned-Racket setup before it chooses a
subcommand: beagle:bin/beagle:8-13. That setup resolves/links Racket and, when
stale, runs parallel raco make across tracked .rkt files:
beagle:bin/_beagle-racket:97-201. Even the self-hosted facts-roundtrip route
at beagle:bin/beagle:321-323 therefore pays the Racket front door.

| Surface | Anchor | Racket work |
| --- | --- | --- |
| build | beagle:bin/beagle-build:20,149-157 | Invokes private/build-one-cli.rkt for hosted Clojure, JavaScript, and Nix. |
| check | beagle:bin/beagle-check:22,67 | Loads beagle/private/check-all in Racket. |
| ast and ast-bundle | beagle:bin/beagle-ast:13,97-103; beagle:bin/beagle-ast-bundle | Produces checked-program projection in Racket. |
| closed bundle compilation | beagle:bin/beagle-build-all:17,38 | Loads beagle/private/build-all. |
| Core, materializers, native executable, Wasm | beagle:bin/beagle-build-core:22,368,629; beagle:bin/beagle-native-exe:22,216; beagle:bin/beagle-materialize-wasm:12,285,364 | Racket builds and verifies Core before materialization. |
| language implementation | beagle:beagle-lib/main.rkt:16-24,33-142 | Racket macro-expansion invokes parse, check, lint, and emit. |

The seed driver exposes ast, check, emit, emit-from-ast, and facts-roundtrip
only: beagle:self-host/src/selfhost/main.bclj:3-6,784-850. Its emitters cover
clj, js, and nix only: selfhost/main.bclj:554-558. It does not replace Core,
materializers, or the public source-profile CLI.

### Gates and tiers

bin/beagle-ci runs raco test beagle-test/tests:
beagle:bin/beagle-ci:50-51. bin/beagle-test runs Racket-scope, checkout, and
consumer probes before invoking the Racket tier runner:
beagle:bin/beagle-test:31-37. That runner schedules a raco test child per test
file or phase and uses racket/future:
beagle:beagle-lib/private/tier-runner.rkt:3-21,44-65. Those children, rather
than one shell wrapper, are the routine Racket CPU load.

The active tier is the Racket corpus beagle:beagle-test/tests/*.rkt named by
beagle:beagle-test/tiers.rktd, not a self-hosted fixture manifest. Replacing
tier-runner.rkt alone would remove one coordinator, not the expensive raco
workers.

### Oracle, remint, and tooling

| Path | Anchor | Racket role |
| --- | --- | --- |
| bin/beagle-remint --oracle | beagle:bin/beagle-remint:86-111 | Compiles the closed self-host bundle through Racket and requires seed = self-host = oracle bytes. Plain remint/promotion are Babashka-only until this option. |
| self-host/verify-selfhost.sh | beagle:self-host/verify-selfhost.sh:1-42,179-256,593-745 | Racket emit, AST, and bundle-build are the parity-oracle legs. |
| native verification | beagle:self-host/native/verify-native.sh:32-109 | Requires native = Babashka seed = Racket oracle. |
| fuzz differential | beagle:fuzz/harness/run.sh; beagle:fuzz/harness/harness.clj; .github/workflows/fuzz-nightly.yml:3-5 | Fresh-program comparison against Racket. |
| facts certification | beagle:bin/beagle-certify-facts-roundtrip:7,43-109 | Compares self-host facts emit/render with facts-roundtrip.rkt. |

The Racket-backed public tooling is: beagle-ast, beagle-ast-bundle,
beagle-build, beagle-build-all, beagle-build-core, beagle-callers,
beagle-callgraph, beagle-cheatsheet, beagle-check, beagle-check-all,
beagle-daemon, beagle-daemon-foreground, beagle-doc-fill, beagle-doctor,
beagle-downstream, beagle-expand, beagle-explain, beagle-explain-type,
beagle-facts, beagle-fields, beagle-fmt, beagle-impact, beagle-init,
beagle-langs, beagle-materialize-wasm, beagle-native-exe, beagle-provides,
beagle-rename, beagle-rewrite, beagle-roundtrip, beagle-schema,
beagle-semantic-index, beagle-sig, beagle-test, beagle-test-tag,
beagle-ts-externs, and beagle-validate. This is the exact current source list
matched by RACKET, RACO, or _BEAGLE_RACKET under beagle:bin/.

Two Store-facing examples are beagle:bin/beagle-facts:13,35 and
beagle:bin/beagle-roundtrip:11-12. They remain Racket despite the existing
selfhost.facts-roundtrip and dispatcher seed route. The persistent Racket
daemon is beagle:bin/beagle-daemon:3,100,136-151.

## What the seed proves

The seed is generated Clojure for Beagle-authored compiler sources, with a
hand-written host-I/O shim copied verbatim:
beagle:self-host/README.md:20-29. Its fixed point is real: seed emits
self-host/src/selfhost/*.bclj and must reproduce tracked seed bytes; promotion
also requires generation-one equals generation-two convergence and module
self-tests: beagle:bin/beagle-remint:1-33,54-85,113-152. Native stage0 is the
same seed in a reproducible native image and Babashka is the fallback:
beagle:docs/self-hosting.md:15-28.

It can already run without Racket as Babashka or native stage0; resolve explicit
source bundles/module roots; parse, check, and emit Clojure/JS/Nix; produce and
validate checked-program projections; run facts roundtrip; and remint without
--oracle. The implementation anchors are
beagle:self-host/src/selfhost/main.bclj:55-68,540-558.

It is not yet a production replacement. Public build/check/ast do not route to
it; it has no Core/materializer/native-executable path; it deliberately has
narrower host namespace admission, unported cross-module defmacro, and
parametric-union constructor/accessor imports:
beagle:self-host/README.md:107-180. It also has the 44-label red parity
baseline below.

W5 matters directly. Main is W5a at 96e5d08b. W5b scope hygiene is still a
worktree candidate; W5c through W5e remain planned. The required order is
syntax membrane, scope hygiene, syntax-match, expansion dependencies, then
restricted reflection:
beagle:beagle-test/conformance/authority/positioning/W5-METAPROGRAMMING-WAVES.md:1-35.
Their final lineage requires remint/oracle agreement:
beagle:beagle-test/conformance/authority/positioning/W5-METAPROGRAMMING-WAVES.md:374-385.

## The 129/44 verified backlog

129 passed, 44 failed is a pinned differential-parity baseline, not permission
to ignore failures. At W5a landing the exact 44 normalized labels were verified
unchanged from the pre-W5a baseline; SHA-256 is
67df2590d488903ae74cf0c4adec2eddb864e64ca2cfede48d587c9261d2cbcd:
todo:w5b-final-binding-gate.md:95-104 and todo:agent-coord.md:20687-20688.
Any new label is a regression; the 44 existing labels are debt.

There is no checked-in current per-label catalog on main. It would be false
precision to invent a named 44-item implementation plan. The recorded
families establish this useful division:

| Family | Classification |
| --- | --- |
| accept/reject, error-core, emitted-byte, AST/extern, and purity-verdict divergence | Blocker: self-host has different language behavior or output. |
| stage-isolated or full-chain byte parity divergence | Blocker: bootstrap/output trust failure. |
| module or oracle-mint failure | Mechanical only when the seed proves the same closed-bundle contract and the failure is oracle/corpus closure; otherwise it masks a blocker. |
| stale output, missing oracle artifact, timeout, or changed rung accounting | Mechanical/infrastructure: no semantic divergence proven. |

The predecessor evidence contains both types: diagnostic core, acceptance, and
purity differences were semantic; several oracle-mint/module-oracle failures
were corpus-closure failures: todo:agent-coord.md:19194-19238. Reclassify the
saved exact 44 labels before assigning individual repairs. Every semantic
label remains a release blocker.

## Staged path to Racket-free compilation

Each stage is a one-worker seam and has one named acceptance gate. Ordering is
by Racket CPU removed; claimed latency waits for measurement.

| Stage | Seam and acceptance | Racket processes removed |
| --- | --- | --- |
| 1. Hosted front door | One compatibility adapter routes hosted build, check, and ast to selfhost.main while preserving flags, closed bundles, atomic output, diagnostics, and checked-program v4. Gate against the existing oracle corpus. | Routine hosted compile/check/AST no longer starts Racket or the .zo freshness gate. High-frequency developer payoff. First seam: selective dispatch in beagle:bin/beagle before line 13. |
| 2. Facts and Store source interface | Move bin/beagle-facts, bin/beagle-roundtrip, and Store-facing calls to selfhost.main facts-roundtrip. Gate with byte-identical emit/render corpus. | Racket facts-roundtrip children disappear from code-as-facts and Store tooling. Certification remains temporary. |
| 3. Repeated compilation pipelines | Move hosted portions of branch-compile corpus and downstream compile drivers to native stage0; leave Core explicitly Racket-owned. Gate with existing branch-corpus identity/cone receipt. | Repeated Racket hosted-compile children disappear. Likely largest pre-gate CPU reduction; measure it. |
| 4. Parity closure | One owner works the saved 44-label ledger: reproduce/classify every label, fix semantic blockers, remint seed, and prove no new labels. Acceptance is zero semantic divergences plus a machine-readable deferred-infrastructure ledger. | None immediately. This safety stage makes later removal honest; the 129/44 waiver cannot replace it. |
| 5. Compiler conformance gate | Port release compiler behavior to a language-neutral fixture manifest run by native stage0, rather than wrapping raco test. Keep Racket-only implementation tests quarantined until removed. Acceptance reproduces active-tier release behavior. | Parallel compiler raco workers and tier-runner.rkt disappear: largest gate CPU payoff. A shell-only runner rewrite is insufficient. |
| 6. Oracle demotion and bootstrap closure | Make seed/native fixed point, fixture manifest, native/seed agreement, and differential fuzz the normal gate; retain Racket as infrequent historical oracle until an explicit retirement decision. | Normal verify-selfhost oracle mints, remint --oracle, and native three-way oracle processes disappear. |
| 7. Core and tooling retirement | Self-host Core/materializers or remove unsupported Core products; port query, daemon, and remaining tools; delete Racket only after no public route loads it. Acceptance is a tracked-tree search plus release receipt showing no production RACKET/RACO dependency. | Remaining compiler, daemon, materializer, query, and maintenance-tool Racket processes disappear. |

Stages 1 through 3 can ship as selected-profile routes while Stage 4 is open.
Stages 5 through 7 must not ship merely because the seed converges: convergence
proves a fixed point, not agreement with the language contract.

## Risks and current protection

- Bootstrap common-mode failure: self-compilation can preserve a bug forever.
  Keep three-way comparison, generated-seed review, generation convergence,
  native/seed parity, and fresh differential fuzz until independent fixture
  evidence replaces the oracle.
- Output and diagnostic drift: byte identity catches output while the verifier
  separately checks AST shape, acceptance/rejection, error cores, modules, and
  purity: beagle:self-host/verify-selfhost.sh:1-22,198-256,593-745. Closed
  bundles prevent accidental provider resolution.
- Performance regression: native stage0 may be faster, equal, or slower. Measure
  cold and warm compile/gate phases before changing defaults; keep identity
  checks outside timing measurements.
- Incomplete cutover: Core/materializers and tools are load-bearing. Routing
  hosted emit alone leaves a Racket system; count process roots at every stage.
- W5 churn and cache soundness: do not stabilize a self-host API across W5b-e
  before their parity and final-lineage gates pass.

SELFHOST-ROADMAP-DONE stage-count=7 first-seam=selective-hosted-dispatch-in-beagle-bin-before-pinned-racket

