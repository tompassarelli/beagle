# Architecture

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
