+++
id = "polish-campaign-architecture"
title = "Post-drain polish campaign: Beagle, North, and Greywrought"
shape = "plan"
life = "active"
updated_at = "2026-08-18T06:20:00+08:00"
owners = ["codex:polish-architect"]
depends_on = ["polish-campaign"]
+++

# Polish campaign plan

This is a planning document only. The survey read the clean primary checkouts
of Beagle, North, and Greywrought; it made no source, test, workflow, fixture,
generated-output, or coordination edits. All paths below are candidates for
future worker lanes, not changes made by this plan.

The campaign begins only after the drain conditions in
`todo:polish-campaign.md` fire. Removal means absence: a worker must first
prove the surface has no live consumer, then remove the whole surface and its
tests. Historical receipts and migration readers are not automatically dead;
they remain until their named migration consumer is closed.

## Survey facts and operating rules

- Beagle `main` and North `main` were clean and at their current `origin/main`
  tracking state during the survey. Greywrought `main` was also clean.
- Beagle has 91 top-level compiler test files, 86 files named in the tier
  manifest, and 18 focused `bin/test` seams. The operator's current campaign
  count is 2,800+ compiler tests and 2,415 tier tests; those are assertion/test
  units, not file counts. The repository also contains a separate Native Core
  validation forest.
- North has 100 CLI test files, 191 SDK test files, 21 shell-test files, and 11
  legacy top-level test files in the current tree. Its SDK assertion volume is
  large enough that duplication must be measured by owned invariant, not by
  test-file count.
- One worker owns one seam and one disjoint file boundary. A worker may read
  neighboring code to establish callers, but may not edit outside its boundary.
- Every seam names its lowest deterministic check. A full repository gate is a
  final integration check, not a substitute for a seam-level proof.
- Every deletion seam ends with a tracked-tree token search for the removed
  name, followed by the owning focused gate. No worker deletes a compatibility
  path merely because its name sounds old.

## 1. Debt inventory

The following is the initial concrete candidate list. “Candidate” means the
surface deserves an ownership and caller proof; it does not mean the survey
has already established that it is safe to delete.

| Candidate | Evidence and likely action | First proof |
|---|---|---|
| Store's `b4f30814` compiler-pin residue | `beagle:store/beagle-pin.txt:1` still names `b4f3081420a3be73d730802d2f4608d78d0c6cf4`; the dated policy at `beagle:store/AGENTS.md:27-37` requires the pin, flake input/lock, CI refs, and license record to advance as one unit. This is a real live pin until the next Store compiler cutover, then becomes removal residue. | Enumerate all tracked readers of the exact object, advance every named consumer, run Store native/cache and release-artifact gates, then require a zero-result tracked search for the old object. |
| Retired nominal/JVM and legacy parse dispatch | `beagle:beagle-lib/private/parse.rkt:1111` labels a legacy nominal/JVM path; the form classifier at `:2924-2963` and legacy fallback arms through `:3347` preserve a second dispatch vocabulary. `beagle:beagle-lib/private/emit-js.rkt:1301-1334` still builds `with-legacy-type-names`. These are the strongest compiler compatibility candidates. | Use `bin/beagle callers`/tracked references to classify real current consumers, then run parser, checker, all active emitters, self-host remint, and the relevant negative fixtures after each removal. |
| Lossy syntax-to-datum escape hatch | `beagle:beagle-lib/private/ast.rkt:128-135` says `beagle-syntax->datum` is intentionally lossy and legacy-only, while the new immutable syntax contract is exercised at `beagle:beagle-test/tests/syntax.rkt:436-503`. The escape hatch is a likely dead surface if no current compiler or consumer requires it. | Prove callers are limited to retired tests/tools; replace no caller by inference. If zero live callers remain, remove the export and its tests, then run syntax, macro, self-host, and AST JSON gates. |
| Superseded native-decode lane | The historical lane introduced `native-core/tests/native_stage_decode_gate.sh` and the decoder work in `native-core/src/native/stages.bclj`; the current Beagle main tree has no `native_stage_decode_gate.sh` path and no live reference to that test name. The campaign board explicitly records the native-decode pair as superseded by the leak-fix payload `1932dc3d`, `9e3940a8`, and `1556fcf5`. This is primarily lane/coordination residue, not an excuse to delete the live stage encoder. | Audit open worktrees, branches, todo records, and tracked references; reap only the superseded lane after proving no consumer or release receipt names it. Keep `beagle:native-core/src/native/stages.bclj` fields still consumed by `FrozenNativeStageV0` callers. |
| W1-W4 qualified-reference scaffold | The W1-W4 scaffold accessor was already removed by the landed campaign, but the guard remains at `beagle:bin/test/qualified-ref-scaffold/run.sh:5-20`, and the structural/legacy bridge vocabulary remains concentrated in `beagle:beagle-lib/private/ast.rkt:138-220`, `:664-712`, and `beagle:beagle-lib/private/parse.rkt:1111`, `:2924-3347`. The task is to burn down any reintroduced scaffold or bridge, not to remove the structural `qualified-ref` representation that is still live. | Run the guard, `git grep` for the old accessor and old spelling, branch-corpus identity checks, self-host remint, and Store code-as-facts checks. A nonzero old-accessor result blocks the wave. |
| North's retired `northd` bridge fixture | `north:sdk/test/fixtures/bridge-retiring-northd.ts:1-23` is explicitly a retiring-bridge fixture. Its consumers must be distinguished from current bridge protocol tests before deletion. | `rg`/import graph over `north:sdk/test`; run `bun run check` and the focused SDK test set with the fixture absent in a disposable worker lane. |
| North's deprecated Claude plugin distribution | `north:orchestration/AGENTS.md:20-24` says `.claude-plugin/` is deprecated and kept for history, not extended. Its manifest, marketplace, generated adapter, and packaging references are a coherent stale scaffold candidate. | Prove no current switchboard, package, install, or CI path consumes `north:orchestration/.claude-plugin/*`; run `node scripts/validate.mjs` and the orchestration parity tests before removing it. |
| North's stage vocabulary residue | `north:cli/store-rpc-client.clj:1009-1013` still emits `:stage :post-stage-1` for an unavailable subscription operation. This may be an intentional diagnostic or a retired stage label; it must be compared with current FRAMRPC v2 error vocabulary. | Search current protocol/error consumers and golden frames. Delete or rename only if the current contract has a canonical replacement; run the Store RPC client and protocol gates. |
| Greywrought Stage 4 receipt vocabulary | `greywrought:tools/stage-5-demo.mjs:23-32` loads `tests/fixtures/stage-4/real-history-receipt.json` and `failure-receipt.json`, and `:337-370` validates those exact bytes and digests. The files are not dead yet because Stage 5 still consumes them, but they are retired vocabulary embedded in the new path. | First migrate Stage 5 to a current receipt contract or explicitly retain a bounded migration reader; only then delete the two fixtures, their hashes, and the tests that exist solely for them. Run `bun test acceptance/stage-5-demo.test.mjs` and the shadow-engine focused suite. |
| Greywrought stale Stage 4 test paths | `greywrought:tests/shadow-engine.test.mjs:21-29` points at `/tmp/c145bm-stage4-real-history-receipt.json` and `/tmp/c145bm-stage4-failure-receipt.json`, while the live Stage 5 tool uses repository fixtures. These paths are stale scaffolding even if the surrounding shadow tests remain valuable. | Prove the constants are not read by the test body or replace them with a fixture-local temporary setup in one seam; run the shadow-engine test with `TMPDIR` isolated and assert no `/tmp/c145bm` dependency. |
| Greywrought retained v1 migration regime | `greywrought:tools/content-addressed-store.mjs:162-194` deliberately retains the v1 world codec in `RETIRED_CONTENT_ADDRESSED_CODECS`, and the migration tests exercise it. This is not immediate debt; it is a closure candidate once all real v1 inputs are migrated. | Inventory actual migration callers and retained data first. Do not remove the reader or tests until the migration corpus is empty and the operator's retention decision is recorded. |
| Scattered W1-W4 / Stage 4 explanatory scaffolding | The source tree has residual labels in focused comments and fixtures, while the durable handoff still describes W1-W4 and synthetic Stage 4 evidence as completed-but-historical. The live candidates are `beagle:native-core/validation/structured-params/drive.sh:222-223`, `beagle:self-host/verify-selfhost.sh:199-223`, `greywrought:tools/native-field-grid-benchmark.mjs:76`, and any active fixture named `stage-4`. | Separate executable vocabulary from historical docs. Delete only executable scaffolding whose current caller graph is empty; leave evidence history in Git and update only the owning current documentation when a code deletion makes it stale. |

## 2. Build pipeline: remaining suboptimal work

The publication win is landed: the campaign brief records the publication
path improving from roughly 40 minutes to roughly one minute. The tier fixture
sharing work is in flight, and the current tree already contains the important
shape: `beagle:beagle-test/tests/wasm-materializer.rkt:38-80` has a phase registry,
selection, and completeness contract, while `:139-180` owns a canonical fixture
that shards can copy. The remaining work is to make the performance claim
durable across CI and cold machines.

The first-cold compiler result is still an open item at about 134.4 seconds;
the recurring warm loop is already within the latency bar. The musl-gcc gap is
also open: release CI installs musl-tools at
`beagle:.github/workflows/release.yml:159-164`, but that toolchain assumption
must be made explicit and reproducible for every native path that claims musl
coverage. The current Beagle CI has four tier shards and separate gate jobs at
`beagle:.github/workflows/test.yml:73-133`, `:135-193`, and the following Store
gate job; the remaining cost is setup repetition, cold compilation, and cache
boundary ambiguity rather than a lack of parallel workers.

Pipeline acceptance bars:

1. Every shard reports the same complete unit partition as an unsharded run;
   no cache hit may bypass source, compiler, ABI, or toolchain identity.
2. A cold run and a warm run report separate timings. The 134-second first-cold
   result is either reduced with byte-identical artifacts or retained as an
   explicitly bounded backlog item with its dominant phase named.
3. Musl results identify compiler path, libc target, source closure, and
   artifact digest. “musl-gcc exists on one release runner” is not sufficient.

## 3. Test redundancy method and first candidates

The first pass is a measurement, not a deletion sweep.

1. Build an inventory keyed by owned invariant, not filename. For each test,
   record its direct product entrypoints, fixture/fixture generator, layer
   (pure logic, controlled seam, packaging, process, or end-to-end), and
   external dependency touched.
2. Build a lower-layer proof map. A higher-layer test is redundant only when
   the lower layer proves the same owned behavior, with the same failure
   contract, and the higher test adds no consumer-facing seam or packaging
   guarantee.
3. Mark tests that assert dependency internals. Keep the narrow adapter
   contract; move dependency behavior to the dependency's own suite or delete
   the assertion if North/Beagle does not own it.
4. Compare assertion labels and fixture inputs after normalizing names. A
   different test title is not evidence of distinct behavior; a different
   failure boundary is.
5. For each candidate, run the focused lower-layer suite, remove or demote one
   duplicate in a worker lane, then run the former higher-layer test once as a
   falsification check. Only after the pair is understood may a deletion land.

First candidates for this analysis:

- Beagle downstream gates: compare `beagle:beagle-test/tests/downstream-registry.rkt`,
  `beagle:beagle-test/tests/downstream-runner.rkt`, and
  `beagle:bin/test/downstream-ci-gate/run.sh`, `downstream-drift/run.sh`, and
  `downstream-receipt-lifecycle/run.sh`. The focused Racket tests can own
  registry/runner semantics; the shell seams should retain only process,
  cleanup, and receipt-lifecycle guarantees that the lower layer cannot prove.
- Beagle native/Wasm artifact coverage: compare
  `beagle:beagle-test/tests/wasm-materializer.rkt`,
  `beagle:beagle-test/tests/native-c17-parallel.rkt`,
  `beagle:beagle-test/tests/native-wasm32.rkt`, and
  `beagle:bin/test/native-exe-smoke/run.sh`. Separate compiler artifact
  construction, ABI admission, and executable smoke; do not let three suites
  all prove the same receipt shape or dependency tool behavior.
- Beagle facts and code-as-facts coverage: compare
  `beagle:beagle-test/tests/build-edn-datum-ir.rkt`,
  `beagle:beagle-test/tests/facts-render-roundtrip.rkt`,
  `beagle:beagle-test/tests/code-as-facts-rename.rkt`, and
  `beagle:bin/test/code-as-facts/run.sh`. Preserve exact-byte and semantic
  identity as separate claims; remove only repeated proof of the same layer.
- North identity publication: compare
  `north:cli/tests/agent-identity-publication-integration-test.clj`,
  `north:sdk/test/identity-projection.test.ts`,
  `north:sdk/test/identity-reuse.test.ts`,
  `north:sdk/test/identity-writer-recovery.test.ts`,
  `north:bin/tests/native-identity-test.sh`, and
  `north:bin/tests/identity-alias-test.sh`. The likely split is pure identity
  projection, SDK writer recovery, and native hook/process integration; the
  first pass must prove whether any scenario is repeated across all three.
- North spawn and process lifecycle: compare
  `north:cli/tests/spawn-process-integration-test.clj`,
  `north:cli/tests/spawn-process-diagnostics-test.clj`,
  `north:cli/tests/spawn-process-settled-tail-test.clj`,
  `north:bin/tests/north-on-spawn-stress-test.sh`, and
  `north:bin/tests/north-on-tooluse-stress-test.sh`. Keep one process-tree
  integration proof and retain stress cases only for concurrency, timeout, and
  hostile-input properties not proven below.
- North dependency-boundary tests: inspect
  `north:sdk/test/mcp-driver-lifetime-integration.test.ts` and the Store/FRAMRPC
  fixture helpers it starts. The North-owned claim is selector/lifetime
  binding; Store graph serialization and server internals belong in Beagle
  Store's gates. This is the clearest “tests proving dependency internals”
  candidate.

## 4. Numbered campaign waves

The wave graph is `1 -> (2, 3) -> 4 -> 5`; Wave 1 establishes the live
surface boundary, Waves 2 and 3 can then run in parallel, Wave 4 uses the
surviving surface to make abstractions, and Wave 5 proposes notation only after
the duplication measurements exist.

### Wave 1 — debt closure and boundary proofs

Estimated independently-parallel units: 10.

| Seam / one-worker boundary | Verification owned by that worker |
|---|---|
| W1.1 Store pin advance: `beagle:store/beagle-pin.txt`, `beagle:store/AGENTS.md`, and the exact Store flake/CI pin readers | Enumerate exact-object readers; run Store native build-cache and native/Cloudflare release-artifact gates; zero-result search for `b4f3081420a3be73d730802d2f4608d78d0c6cf4` after the consumer advances. |
| W1.2 Legacy compiler dispatch: `beagle:beagle-lib/private/parse.rkt:1111,2924-3347` and `beagle:beagle-lib/private/emit-js.rkt:1301-1334` | Compiler caller query plus parser/checker/emitter active tier, self-host remint, and exact negative fixtures for the removed legacy forms. |
| W1.3 Lossy syntax escape hatch: `beagle:beagle-lib/private/ast.rkt:128-135,392-500`, its exports, and direct tests | Tracked caller census, syntax/macro/self-host gates, then token search for the removed export. |
| W1.4 Superseded native-decode lane closure: lane/branch/todo references to `native_stage_decode_gate.sh`; preserve live `beagle:native-core/src/native/stages.bclj` consumers | Prove no current main consumer or release receipt names the lane; close/reap the lane and run Native stage compilation plus current cache gate. |
| W1.5 W1-W4 scaffold guard: `beagle:bin/test/qualified-ref-scaffold/run.sh` and structural-name bridge callsites in `beagle:beagle-lib/private/ast.rkt` | Guard zero, branch-corpus identity/rename gates green, and no old accessor token in tracked source. |
| W1.6 Retired North bridge fixture: `north:sdk/test/fixtures/bridge-retiring-northd.ts` and its imports | Import census; `cd north:sdk && bun run check`; focused SDK tests without the fixture. |
| W1.7 Deprecated North distribution: `north:orchestration/.claude-plugin/*` and packaging references | `node scripts/validate.mjs`, orchestration parity tests, and a packaged-tree search proving current switchboard consumers do not require it. |
| W1.8 North stage-label residue: `north:cli/store-rpc-client.clj:1009-1013` plus current FRAMRPC error fixtures | Protocol vocabulary search, Store RPC client tests, and golden-frame comparison. |
| W1.9 Grey Stage 4 receipt migration boundary: `greywrought:tools/stage-5-demo.mjs:20-32,337-370` and `greywrought:tests/fixtures/stage-4/*` | Do not delete until a replacement or explicit migration reader proves the same matched/diverged history contract; run Stage 5 acceptance. |
| W1.10 Grey stale temp receipt constants: `greywrought:tests/shadow-engine.test.mjs:21-29` | Isolated `TMPDIR` run and search proving no `/tmp/c145bm-stage4-*` dependency remains. |

### Wave 2 — build and gate pipeline

Estimated independently-parallel units: 7.

| Seam / one-worker boundary | Verification owned by that worker |
|---|---|
| W2.1 CI cache topology: `beagle:.github/workflows/test.yml:90-133,148-154` and the equivalent native/Store setup blocks | Cold versus restored job timing; cache keys include compiler/toolchain/source identity; no stale-green replay. |
| W2.2 Tier shard economics: `beagle:beagle-lib/private/tier-runner.rkt:480-564` and the `test.yml` shard matrix | Unit partition property, full-unsharded equivalence, explicit progress/deadlines, and one bounded timing comparison. |
| W2.3 Shared Wasm fixture publication: `beagle:beagle-test/tests/wasm-materializer.rkt:38-80,139-180` | Concurrent cache miss/hit/corrupt-entry cases, READY/digest validation, exact union of selected phases, and observed hit ratio on a warm run. |
| W2.4 First-cold Native compiler path: `beagle:bin/beagle-build-core:1960-2085`, Native checkpoint cache tests, and the source-closure manifest | Profile each cold phase, preserve artifact byte identity, and either lower the 134-second first-cold result or record the dominant irreducible phase and bounded follow-up. |
| W2.5 Musl toolchain parity: `beagle:.github/workflows/release.yml:159-164,485-540`, flake toolchain declarations, and native packaging scripts | Run the native target with an explicit musl compiler; record compiler revision, target, and artifact digest; fail visibly when musl is unavailable rather than silently using glibc. |
| W2.6 Publication path post-win: release publication scripts/workflow and their exact receipt/artifact handoff | Reproduce the one-minute publication result from a clean checkout, prove publication consumes the exact preflight commit, and keep publication asynchronous to landing. |
| W2.7 North fixture/process setup: `north:sdk/package.json`, `north:sdk/scripts/check-builds.sh`, `north:sdk/test/internal/test-runtime.ts`, and `north:docs/building-and-testing.md:62-112` | `cd north:sdk && bun run check && bun run test`; separate dependency installation/setup timing from North-owned test time and preserve sandbox-home hermeticity. |

### Wave 3 — redundancy reduction

Estimated independently-parallel units: 6.

| Seam / one-worker boundary | Verification owned by that worker |
|---|---|
| W3.1 Beagle downstream registry/runner seam: the two Racket tests plus the three downstream shell gates named in §3 | Produce an invariant matrix; retain process/cleanup/receipt claims once and remove only exact duplicates; run the focused downstream gates. |
| W3.2 Beagle native/Wasm seam: `wasm-materializer.rkt`, `native-c17-parallel.rkt`, `native-wasm32.rkt`, native-exe smoke | Separate artifact, ABI, and executable claims; run each surviving lower layer and one former duplicate as a falsifier. |
| W3.3 Beagle facts/code-as-facts seam: the four files named in §3 | Compare semantic identity, exact bytes, and process integration; preserve one proof per claim and run branch-corpus plus facts roundtrip gates. |
| W3.4 North identity seam: CLI, SDK identity tests, and native shell hooks | Map each scenario to projection, recovery, or process integration; run SDK check/test and native hook tests after each bounded deletion. |
| W3.5 North spawn seam: CLI process tests and spawn/tool-use stress shells | Keep one lower process-tree proof; retain only concurrency/timeout/hostile-input cases that add a distinct invariant; run bounded stress cases with visible deadlines. |
| W3.6 North dependency seam: MCP/Store/FRAMRPC fixture tests | Remove assertions of Store internals from North-owned tests; retain selector/lifetime boundary assertions; run the North SDK suite against the selected Store output. |

### Wave 4 — craftsmanship and real abstraction wins

The new hygiene and syntax-match machinery is valuable only where it removes
repeated structural plumbing while preserving source spans, origin, and type
errors. It must not become a generic matcher used merely because it exists.

Estimated independently-parallel units: 6.

| Seam / one-worker boundary | Verification owned by that worker |
|---|---|
| W4.1 Macro structural matcher core: `beagle:beagle-lib/private/macro-eval.rkt:145-275` and `beagle:beagle-lib/private/macros.rkt` | Replace one repeated list/vector/identifier destructuring family with `syntax-match`; test malformed pattern categories, splice placement, source-pointed diagnostics, and macro hygiene. |
| W4.2 Parser macro/builtin boundary: `beagle:beagle-lib/private/parse.rkt:2380-2963` | Use syntax-match only for the declaration/form shapes where it removes nested arity/tag checks; preserve macro-over-builtin-over-current fallback order; run parse, diagnostics, and all active emitters. |
| W4.3 Syntax-origin and diagnostic propagation: `beagle:beagle-lib/private/ast.rkt:1046-1091`, `macro-eval.rkt`, and `beagle:beagle-test/tests/syntax.rkt`, `macro-hygiene.rkt` | Assert caller span, definition-site free references, generated origin, and error location through one macro expansion; run the focused syntax/macro tier. |
| W4.4 Self-host mirror: `beagle:self-host/src/selfhost/macros.bclj`, `self-host/src/selfhost/check.bclj`, `self-host/seed/selfhost/macros.clj`, and `self-host/fixtures/syntax-match.bclj` | Three-way Racket/seed/self-host parity, remint fixpoint, syntax-match fixture, and byte-identical generated seed. |
| W4.5 Match-heavy compiler tests: `beagle:beagle-test/tests/syntax-match.rkt`, `defmacro.rkt`, `macro-eval.rkt`, `scrutinee-narrowing.rkt` | Collapse only repeated test fixture construction into a small test helper; keep negative cases distinct; prove assertion count and failure messages remain stable. |
| W4.6 Store walker abstraction boundary: `beagle:store/src/resolve_walk.bclj:498-575`, `resolve_mint.bclj`, and their generated `out/` projections | Measure whether ordinary typed walkers remove repeated `nth`/shape plumbing. Do not force compiler-time syntax-match into runtime graph data; run Store codegraph and compiler lexical-edge tests. |

### Wave 5 — DSL evidence spikes, not implementation

At most three notation proposals survive this wave. Each worker must show a
representative before/after reduction, a parser/validation ownership boundary,
and a reason ordinary typed data or existing Beagle forms are insufficient.

Estimated independently-parallel units: 3.

| Proposal / one-worker boundary | Evidence and kill condition |
|---|---|
| W5.1 Gate-phase declaration notation: `beagle:beagle-test/tests/wasm-materializer.rkt:38-80`, all 19 `phase-test` declarations, and `beagle:beagle-lib/private/tier-runner.rkt:209-280,516-564` | A small declarative phase table could generate phase IDs, expected-phase checks, shard units, and deadlines, eliminating the current duplicated registry/static-scan/environment protocol. Keep it only if it reduces names and failure modes without hiding per-phase code or weakening completeness. Kill if the declaration is harder to review than the current explicit `phase-test` calls. |
| W5.2 Receipt-schema notation: `beagle:store/clients/cloudflare-do/capacity/receipt.mjs`, `assemble-receipt.mjs`, `receipt.test.mjs`, and `beagle:native-core/src/native/stages.bclj:300-396` | There are repeated field-order, version, digest, bounds, and pass/fail projections across JavaScript capacity receipts and Native pass/build receipts. Propose a schema only if it can generate validators/field order/test fixtures while leaving security-critical checks explicit. Kill if two wire regimes would acquire accidental shared semantics. |
| W5.3 Nix/module surface notation: `beagle:beagle-lib/private/parse.rkt:3820-3920`, `emit-nix.rkt:700-790`, `bin/beagle-import-nix`, and `beagle-test/tests/nix-parse.rkt`, `nix-roundtrip.rkt`, `nix-import-roundtrip.rkt` | The evidence question is whether repeated flake-input/module/attribute-set declarations and `.nix` ↔ `.bnix` round trips form one stable declaration algebra. Propose a DSL only if it removes real duplicated parser/emitter/validation rules while preserving exact bytes and Nix evaluation. Kill if it is only a prettier wrapper over existing syntax or would require a second generated `.nix` authority. |

## 5. Worker dispatch and acceptance order

1. Dispatch Wave 1 only after the board drain trigger. Its ten seams are
   independent except where a consumer proof must precede a deletion.
2. Dispatch Waves 2 and 3 in parallel once Wave 1 has published the current
   live-surface map. Pipeline workers may measure without waiting for test
   deletions; redundancy workers must not delete a file named by an open
   pipeline gate.
3. Dispatch Wave 4 after the redundancy map identifies the structural families
   worth abstracting. A craftsmanship worker may refactor only its named files
   and must keep the old and new checks side by side until the seam-level gate
   proves equivalence.
4. Dispatch the three Wave 5 evidence spikes in parallel. Their outputs are
   proposals for a later campaign, not permission to add a notation during the
   polish campaign.
5. Finish with one supervised integration run of the named Beagle, North, and
   Greywrought focused gates, then the repository's ordinary local gates. Do not
   wait on remote CI for landing; remote results are asynchronous confirmation.

## 6. Counts

- Numbered waves: 5.
- Independently parallel seams: Wave 1 = 10, Wave 2 = 7, Wave 3 = 6,
  Wave 4 = 6, Wave 5 = 3; total = 32 seams.
- Maximum immediate fan-out after the drain: 10 workers in Wave 1; after the
  boundary map, 13 workers across Waves 2 and 3.
- DSL candidates: 3, subject to the evidence/kill bars above.
- Code edits made while drafting this plan: 0.

POLISH-PLAN-DONE — 5 waves, 32 seams, 3 DSL candidates.
