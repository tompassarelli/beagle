# Architecture

## How it compiles

<!-- beagle:langs pipeline -->
```
.bgl  ──▶ parse ──▶ check ──▶ freeze Native World ──▶ --materializer c17|qbe
.bclj / .bjs / .bnix  ──▶  parse ──▶ check ──▶ emit  ──▶  .clj / .js / .nix
                                       ▲
                         macros, schema, stdlib, type narrowing
                         all share one AST + diagnostic path
```
<!-- /beagle:langs -->

`.bgl` is a compilation-path decision: bare `#lang beagle` always enters
Native Core and produces a Native World. "Backend-neutral" describes that
frozen world, not the `.bgl` extension. C17 and QBE are the current
materializers; Wasm belongs at the same materializer layer. The lowering tool
may run from hosted `.bclj` during compiler bootstrapping without making `.bgl`
a hosted or target-neutral source profile.

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
- `native-core/src/native/{worlds,lower,obligations}.bclj` — the hosted implementation that lowers Core into one frozen Native World; `native-core/src/native/{body_c17,qbe}.bclj` implement its materializers.
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
