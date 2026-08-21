# Test redundancy plan: Beagle and North

## Decision

No deletion is proposed from this survey. The apparently overlapping suites are
layered proofs of different contracts, and the lower layer alone cannot prove
the higher layer's owned boundary. This is intentionally a small plan: do not
open a removal lane until a candidate has an exact claim statement and the
replacement proves that same statement at a lower deterministic layer.

## Anchored inventory

| Surface | Observed shape | Anchor |
|---|---:|---|
| Beagle active tier | 75 suite files; 11 gated suite files; 90 test source files | `beagle:beagle-test/tiers.rktd:49`, `beagle:beagle-test/tiers.rktd:168` |
| Beagle scheduling | one `raco test` unit per file, except source-derived phase units; active tier blocks | `beagle:beagle-lib/private/tier-runner.rkt:5`, `beagle:beagle-lib/private/tier-runner.rkt:90` |
| Beagle headline baselines | 2,796+ compiler-binding tests and a 2,415-test tier were supplied for this review; not independently re-counted here | request baseline |
| Beagle self-host/corpus | 12 hosted compiler modules; 25 in-tree Store `.bclj` modules; self-host fixture plus Store corpus parity | `beagle:CLAUDE.md:25`, `beagle:self-host/verify-selfhost.sh:135` |
| North SDK | 162 `*.test.ts` files; 1,685 direct `test(` declarations (the runner, not text count, owns reported total) | `north:sdk/test/support/run-suite.sh:49`, `north:sdk/test/support/run-suite.sh:227` |
| North gates | four-file bounded SDK wave, then serialized isolated-Store files; per-file deadline 180 seconds | `north:sdk/test/support/run-suite.sh:20`, `north:sdk/test/support/run-suite.sh:57`, `north:sdk/test/support/run-suite.sh:138` |
| North non-SDK surfaces | 100 CLI test files and 19 `bin/tests` scripts; CI names the focused domain and boundary checks explicitly | `north:.github/workflows/ci.yml:115`, `north:.github/workflows/ci.yml:129` |

The requested counts are retained as planning baselines rather than inferred
from filename searches. The SDK runner’s final `Ran` totals are authoritative,
because it invokes Bun one file at a time and validates each summary.

## Overlap map — related coverage that must stay

| One-worker seam | Same-looking claim | Lowest deterministic proof to keep | Higher-layer proof that must also stay, and why |
|---|---|---|---|
| Beagle binding constraints | acceptance/rejection of a constrained binding appears in checker and interface suites | `binding-constraint-check.rkt`: checker creates the semantic contract and diagnostic `E025` | `binding-constraint-interface.rkt` publishes that contract through the versioned module interface. It proves inter-module schema preservation, not checker behavior. Keep both. Anchors: `beagle:beagle-test/tests/binding-constraint-check.rkt:70`, `beagle:beagle-test/tests/binding-constraint-interface.rkt:19`. |
| Beagle typed bindings | structural typed forms recur in parse and source-writer batteries | `annotation-parse.rkt`: parser/checker accepts and rejects the grammar | `annotation-printer.rkt` proves read/write identity across three writers; `annotation-macros.rkt` covers generated forms. A parser unit cannot prove a writer or macro preserves source. Keep all three. Anchors: `beagle:beagle-test/tests/annotation-parse.rkt:60`, `beagle:beagle-test/tests/annotation-printer.rkt:20`. |
| Beagle JS semantics | emitted-JS behavior and cross-target values both execute examples | `emit-js-behavioral.rkt`: direct JS runtime behavior | `conformance.rkt` proves agreement with the Clojure oracle, including equality, hash, membership, mutation, and value keys. The latter detects a coherent-but-wrong JS result. Keep both; gated `js-exec-oracle.rkt` remains opt-in runtime breadth. Anchors: `beagle:beagle-test/tiers.rktd:137`, `beagle:beagle-test/tiers.rktd:160`, `beagle:beagle-test/tiers.rktd:180`. |
| Beagle self-host oracle | multiple gates compare emitted Clojure bytes | `bin/beagle-remint`: seed compiler reproduces its own source bundle | `verify-selfhost.sh` isolates module self-test, AST, stage-emit, and full-chain parity over fixtures/corpus; `verify-native.sh` adds the native binary. The same byte comparison is evidence for three distinct producer boundaries. Keep all. Anchors: `beagle:bin/beagle-remint:4`, `beagle:self-host/verify-selfhost.sh:4`, `beagle:self-host/native/verify-native.sh:2`. |
| Beagle Nix | Nix schema and command behavior both reject invalid configuration | `validate-nix.rkt`: schema lookup/validation functions | `check-all-nix.rkt`: public `beagle check --agent` process and diagnostics. `nix-import-roundtrip.rkt` additionally owns importer-to-emitter preservation. Keep all. Anchors: `beagle:beagle-test/tests/validate-nix.rkt:41`, `beagle:beagle-test/tests/check-all-nix.rkt:51`, `beagle:beagle-test/tests/nix-import-roundtrip.rkt:3`. |
| North topology authority | SDK and CLI both deny worker orchestration | `sdk/test/topology-authority.test.ts`: pure SDK admission and no-provider/no-driver side effect | `cli/tests/topology-authority-test.clj`: real CLI commands, process exit, output, and generic mutation surfaces. The public CLI seam is not a dependency of the SDK unit. Keep both. Anchors: `north:sdk/test/topology-authority.test.ts:103`, `north:cli/tests/topology-authority-test.clj:82`. |
| North worktree/identity/delivery | SDK projections and CLI integration share nouns | SDK files prove parse/validate/project logic; CLI files prove real Git or Store-server transaction boundaries | Do not collapse `worktree-spawn`, `identity-projection`, or `delivery-evidence` into their named CLI integration counterparts without a claim-by-claim matrix. The CI descriptions explicitly identify real Git, isolated Store, and contention as separate risks. Anchors: `north:.github/workflows/ci.yml:141`, `north:.github/workflows/ci.yml:153`, `north:.github/workflows/ci.yml:205`. |
| North SDK runner | package test and runner self-test both mention the entrypoint | `sdk-test-entrypoint-test.sh` is the focused fake-Bun proof of timeout, summary parsing, and CI wiring | The 162-file SDK suite proves product behavior, not that its supervisor will discover, bound, and report it. Keep the runner test. Anchors: `north:bin/tests/sdk-test-entrypoint-test.sh:7`, `north:sdk/test/support/run-suite.sh:96`. |

## Dependency and platform-conformance candidates

None confirmed.

The reviewed external-looking surfaces remain owned seams:

- Beagle’s Nix importer test bootstraps a tracked Rust helper and verifies the
  Beagle importer/emitter contract; it is not a test of Cargo or rnix alone
  (`beagle:beagle-test/tests/nix-import-roundtrip.rkt:41`).
- North’s runner tests Bun’s *output protocol as consumed by North*; the
  parser, deadline, skip policy, and failure reporting are North behavior
  (`north:sdk/test/support/run-suite.sh:96`).
- `north:sdk/src/vendor/eso/eso.test.ts` tests the retained vendor source that
  North ships and calls. It is a vendored-product contract until a replacement
  dependency boundary exists, not upstream platform conformance.
- Installed-Codex and read-only-shell checks are capability integrations; they
  should remain optional/coded where unavailable, not be relabeled unit tests.

## Cheaper-focused-test candidates

None approved. The survey found no higher-level test whose *entire* claim is
already made by a cheaper test. The pairings above share examples or nouns but
not a complete claim.

Before proposing any future removal, the worker must write this four-row
evidence table in the change description:

| Required proof | Required evidence |
|---|---|
| Exact old claim | One sentence naming inputs, observable result, and owner boundary. |
| Cheaper replacement | Existing test path and exact assertion that proves the same sentence. |
| Layer gap | Explicitly show that no process, serialization, compiler, runtime, Store, or public-CLI behavior is lost. |
| Cost | Measured cold and warm saved time; do not remove for assumed cost. |

## Keep-list rule

Keep a test only when it can be named by the one thing it alone proves. Apply
these labels to every candidate before deletion:

- `binding-constraint-check`: checker records/rejects the binding constraint
  contract and diagnostics.
- `binding-constraint-interface`: module interface preserves that contract for
  consumers.
- `annotation-parse`: language grammar parses and checks typed binding forms.
- `annotation-printer`: compiler-owned source writers round-trip typed forms.
- `conformance`: a runnable target agrees with the Clojure value oracle.
- `beagle-remint`: bootstrap seed is a byte fixpoint of self-host source.
- `verify-selfhost`: independently implemented reader/parser/checker/emitter
  agrees with the Racket oracle by stage.
- `verify-native`: released native compiler agrees with both seed and oracle.
- `topology-authority.test.ts`: SDK denies unauthorized orchestration before
  any admission, driver, or provider side effect.
- `topology-authority-test.clj`: public CLI surfaces deny unauthorized
  orchestration with correct process-visible behavior.
- `sdk-test-entrypoint-test.sh`: the SDK suite supervisor discovers, bounds,
  isolates, and reports each file correctly.

If no singular sentence exists, first split or delete the test. If the sentence
names an owned seam not covered below it, keep it even when another layer uses
the same fixture.

## Execution order

Each row below is independently reviewable and is one worker seam; do not
combine them into a broad cleanup.

1. Beagle binding/source-form matrix: compare assertion labels in the three
   binding suites and approve only exact same-layer duplicates.
2. Beagle target/oracle matrix: compare JS behavior, conformance, and the
   three self-host gates by input corpus and producer boundary.
3. Beagle Nix matrix: map validator, public command, and importer claims.
4. North SDK-to-CLI matrix: map topology, worktree, identity, and delivery
   pairs; preserve real Git/Store/process claims.
5. North runner/platform matrix: classify each environment-facing test as a
   North protocol seam, a coded optional capability, or genuine upstream-only
   conformance.

No seam is authorized to edit tests until its matrix identifies an exact
replacement. Run only the nearest existing suite for any approved deletion.

TEST-REDUNDANCY-DONE — approved removals: 0; confirmed dependency/platform cuts: 0; confirmed cheaper-focused replacements: 0; review seams: 5.
