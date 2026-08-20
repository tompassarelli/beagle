# Architecture

## One semantic substrate

Beagle is one durable programming system, not a language bolted to a database.
Its architectural spine is:

> Pure software artifacts are reproducible projections of durable semantic
> worlds; external reality is connected through explicit observations and
> capability-controlled effects.

A program world (`WORLD`) is a versioned semantic explanation, not a process,
database row, deployment, or universal identity. The destination protocol
relates content, assertion occurrences, world revisions, judgments,
materializations, executions, and receipts through named equivalence and
provenance relations. Those layers do not share one key: content identity is
not assertion identity, artifact identity, or authority, and content identity
is not trust.

The repository currently ships four surfaces:

- the Beagle language authors code and data through one structural model;
- the compiler and runtime check, query, incrementally materialize, and execute
  language programs;
- Beagle Store owns durable terms, transactions, occurrences, history,
  querying, indexing, snapshots, and cold persistence;
- capability interfaces expose only the Store-shaped part to an existing
  application through the native/Wasm ABI, Store RPC, or a cache policy.

The compiler's AST and fact projections and Store's Term and occurrence model
are separate current surfaces. Connecting them through the world protocol is
the direction, not a claim that every layer already shares one representation.
Within that direction, facts are view-admitted propositions, judgments select
or derive conclusions, and target outputs are replaceable materializations.
The durable world distinguishes `Declared`, `Derived`, `Observed`, `Desired`,
`EffectAttempt`, and `EffectReceipt`; desired state cannot satisfy observed
state, and a receipt does not replace a subsequent observation. Hashes identify
records while authority, evidence, freshness, and policy determine what they
justify.

Pure planning describes effects. A host executes an external effect only when
it holds the target's declared capability, then returns a receipt as a new
semantic record. Planning, scheduling, reconciliation, and effect semantics
remain part of the system even when native execution removes steady-state host
scripts.

The external boundary is a capability boundary, not an ownership boundary.
Adapters may select transport, deployment, retention, and materialization
policy, but may not define operations, identities, transaction behavior, query
rules, or encoding. A brownfield application can therefore use Store without
shipping the language frontend or Racket, while the engine remains built,
versioned, and tested in this repository.

Semantic agreement does not collapse physical or security domains. Separate
worlds, Store spaces, processes, deployments, and trust domains can agree on
content while retaining different authority, retention, availability, and
execution policy.

The detailed contracts and runnable storage-only examples live in
[`store/README.md`](../store/README.md#storage-only-capability) and
[`store/docs/isolation-and-deployment.md`](../store/docs/isolation-and-deployment.md#capability-profiles).

## How it compiles

<!-- beagle:langs pipeline -->
```
.bgl  ──▶ parse ──▶ check ──▶ freeze native program ──▶ --materializer c17|qbe|wasm
.bclj / .bjs / .bnix  ──▶  parse ──▶ check ──▶ emit  ──▶  .clj / .js / .nix
                                       ▲
                         macros, schema, stdlib, type narrowing
                         all share one AST + diagnostic path
```
<!-- /beagle:langs -->

`.bgl` is a compilation-path decision: bare `#lang beagle` always enters
Native Core and produces an immutable validated Native Core program.
"Backend-neutral" describes that frozen native program, not the `.bgl`
extension. C17, QBE, and a C17/WASI Wasm bootstrap are the current
materializers. The Wasm path is explicitly a bootstrap, not a direct emitter;
its toolchain step is isolated behind `bin/beagle-materialize-wasm`, preserving
the frozen-program boundary if the materializer changes. Its
first executable seam exports and runs only a validated parameterless `Int`
entry; an entryless build remains an explicitly non-executable projection. The
lowering tool may run from hosted `.bclj` during compiler bootstrapping without
making `.bgl` a hosted or target-neutral source profile.

`check` is where the NixOS option schema (loaded from a cache at compile time)
becomes typed context: unknown option paths fail at parse time, wrong-typed
values fail at type-check time, ahead of any build. Sourcemap fidelity is
preserved through every canonicalization, so diagnostics point at the author's
position — not a desugared intermediate.

## Project layout

- `beagle-lib/private/parse.rkt` — surface form set; the source of truth.
- `beagle-lib/private/check.rkt` — type checker.
- `beagle-lib/private/targets.rkt` — the canonical source-profile and
  materializer registry; every inventory in this repo is a rendered view of it
  (`bin/beagle langs`).
<!-- beagle:langs emitters -->
- `native-core/src/native/{stages,lower,obligations}.bclj` — the hosted implementation that lowers Core into one immutable validated Native Core program; `native-core/src/native/body_c17.bclj` implements C17 and the explicit C17/WASI Wasm bootstrap; `native-core/src/native/qbe.bclj` implements the direct QBE materializer.
- `beagle-lib/private/emit-{clj,js,nix}.rkt` — the live target emitters (one row each in
  `beagle-lib/private/targets.rkt`, the canonical target table).
- `beagle-lib/private/emit-facts.rkt` — the compact, lossy projection of the parsed AST into CNF analysis facts, represented as three-slot vectors (`bin/beagle-facts`): a query surface, not an authoring language. The verbose, program-lossless source↔fact projection is `beagle facts-roundtrip`, where lossless means reader-datum identity, not byte identity.
<!-- /beagle:langs -->
- `beagle-lib/private/nixos-schema.rkt` — the typed NixOS-option environment.
- `beagle-lib/private/diagnostic-kind.rkt` — the `cause-class?` taxonomy.
- `beagle-lib/lang/reader-impl.rkt` — the readtable: what `` ` ``, `~`, `~@`,
  `,`, `'`, `\` and `#` mean in Beagle source.
- `beagle-test/` — tiered test suite; `beagle-test/tiers.rktd` is the
  authoritative tier classification.
- `self-host/` — the `clj`-target compiler written in Beagle, plus its blessed
  seed and parity harnesses.
- `contrib/docfill/sites.rktd` — the registry of committed files whose
  target-dependent spans the compiler owns.
- `CLAUDE.md` — the operating discipline; its three-statement generative spec
  (Clojure + types / load-bearing divergence / idiomatic per target) is the
  canonical anchor for any surface question.
- `docs/` — distilled, rot-resistant artifacts: `INFLUENCES.md` (lineage +
  thesis) and the generated `CHEATSHEET.md`.

## Generated spans

The two blocks above between `<!-- beagle:langs … -->` markers are filled by
`bin/beagle doc-fill` from `beagle-lib/private/targets.rkt`. A file carrying such
markers must be registered in `contrib/docfill/sites.rktd` for
`beagle-test/tests/docfill.rkt` to guard it against drift.
