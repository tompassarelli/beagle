# Changelog

All notable changes to beagle are recorded here. This file is the canonical version history; git tags point to the corresponding commits.

Format: loosely [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Entries are grouped by impact, not by commit. Bullets describe behavior visible to authors or downstream tooling — internal refactors only appear when they changed something observable. Commit SHAs are cited for headline items only.

This file begins at v0.16.0. Prior history lives in git tags (v0.7.1 → v0.15.3).

## [0.17.0] — 2026-06-15

Where 0.16 locked the surface, 0.17 turns the compiler into something its own repair tooling can drive. Diagnostics now carry structured, machine-applicable data; `beagle-doctor` proves the repair loop *works* rather than merely runs; form dispatch unifies onto a single compile-time combiner registry; Odin joins as a live native target and the JS emitter returns to live. Five live targets: Clojure, ClojureScript, JavaScript, Nix, Odin.

### Highlights

- Repair loop is real and proven end-to-end: diagnostics carry structured types and machine-consumable conversion data (`MessageData`), `beagle-repair` applies them, and `beagle-doctor` demonstrates the loop functions, not just that the daemon is alive (d599fe17, 1cc1077f, a0e60513).
- Dispatch unified: one compile-time combiner registry resolves macros, builtins, and legacy forms; 21+ special forms plus the def/control/module/nix/js/sql families migrated onto it; the dead operative prototype was deleted (5d58d09 → b737821, 80c01a1).
- Odin is a live native target, replacing the now-parked zig backend; the JS emitter is promoted back from dormant to live (34fd382, e7823757).
- Deterministic paren-balancing is auto-enforced via the PostToolUse hook, and hooks are distributed from tracked templates (bdaae9f1, 8b13af3c).
- `!`-purity static pass (`check-purity!`) is on by default (c118f21, 0130145).

### Added

- In-compiler error-explanation registry with machine-applicable suggestions (17434043).
- Structured types in diagnostics via `MessageData`; structural fix-plans carry machine-consumable conversion data that `beagle-repair` consumes (d599fe17, f36d18cc, 1cc1077f).
- Exhaustive-match auto-fill: missing-case clause skeletons emitted as an applicable repair fix (cc30a6c2).
- Auto-apply `replace-head` suggestions in the repair loop (822fa136).
- Types-as-view: `beagle-explain-type` projects inferred types through an extensible delaborator registry; numeric unions fold to `Number`, with `--write` promotion (4145ce44, 13847b3d, f0ff58c6).
- `beagle-doctor` proves the repair loop works, with a dynamic target inventory and a correct `raco` probe (a0e60513, 2c5a56b2).
- Source positions carry origin/canonical with precise column propagation; macro expansions inherit the call-site source position (de155bae, 3a9af8f6).
- Generated, example-verified capability cheatsheet that can't rot (10d50241).
- Odin backend: `#lang beagle/odin`, numeric width types, `.bodin` build support, `defenum`, fixed arrays, range loops, pointer types, struct literals, keyword→enum variants, non-string map keys (`map[K]V`), `stdlib-odin` math/casts, and `defmacro` incl. the ECS `defcomponent` pattern (34fd382 + series).
- JS emitter live again: `@x` deref sugar, `js/import-meta`, `js/export-default`, async `loop`/`recur` via `js/await`, destructuring `:or`/`:as`, kebab-case property mangling, statement-position IIFE elimination (e7823757 + series).
- `!`-purity static pass (`check-purity!`), shipped dark then enabled by default as an error (c118f21, 0130145).
- `(:gen-class)` in `ns` for clj AOT/native entry; batch `declare-extern` — `(declare-extern [a b c] Type)` (f82e6fa, 47f093c5).
- Multi-module type awareness for package targets (odin); qualified-call resolution for clj/cljs with fixed sibling imports (f2b8f2f3, 8b927611).
- `stdlib-bb` babashka-runtime typed tranche (~130 entries) (da975a1c).
- Inline expected-diagnostic test harness with mechanical update (40da2b96).

### Changed

- Form dispatch unified onto one compile-time combiner registry — `do`/`if` seeded first, then the when/if conditional family, def, control, module, nix, js, and sql forms; a single resolver now handles macros, builtins, and legacy forms (5d58d09 → b737821).
- Odin replaces zig as the native target; zig is parked under `dormant/` (34fd382).
- Real mode-2 macro hygiene: definition-site free-variable resolution, across all live targets including odin (3fe36b75, 06bedfc2).
- Numeric-preserving arithmetic with `Int`→`Float` widening in the checker (63b62ca1).
- nil-narrowing extended to and/or composition and `not=`, with soundness fixes and a deeper clj stdlib (d77855eb).
- clj emitter: lean release mode; dropped `^long`/`^double` and unresolvable opaque-extern hints the JVM/AOT compiler rejects (b7ba4cc, 80233e0, a401115).
- CLI consolidated onto `beagle <cmd>`: 12 missing subcommands wired, 8 dead tools removed, `beagle init` unified onto the canonical scaffolder (54195516, 8b7ac681, adf8262e).
- Hooks distributed from tracked templates; pool mode is portable and scaffolded, and `--hooks` idempotently merges into existing repos (8b13af3c, c2319a90).
- PostToolUse hook auto-enforces deterministic paren-balancing (bdaae9f1).
- Version metadata bumped `0.15.3` → `0.17.0` (`info.rkt` was never advanced for 0.16.0); `pkg-desc` corrected to the live target set.

### Removed

- Dormant py / rkt / scheme / zig targets (SQL kept as a dormant emitter with live schema-typing) (4497259c).
- Dead operative prototype deleted; the one-compiler ground truth is documented (80c01a15).
- Game/kernel extracted out of the language repo to `~/code/games` (83773836).

### Fixed

- Don't crash compiling nested macro calls (`datum->syntax` on a raw-datum srcloc) (8290e667).
- Delaborator offset correctness across tabs/CRLF, with opt-in capture (45ab2a96).
- Repair-loop clause insertion: single-line matches and string-decoy anchors (afff6c4d).
- Structural fix-plan blames the differing type argument (e6a6562f).
- clj regex emission and a blame-path destructure crash (0389b8bc).
- JS `:as` whole-map binding across all three `let` paths; record-ctor partial gated to real records (973dd9b6).
- Hardened `(ns ...)` name extraction in `beagle-build` (74372947).
- Surface hardening: killed silent meaning-changers and closed LLM-prior gaps (2b38cad8).

## [0.16.0] — 2026-06-01

The surface stopped accreting. v0.16 locks beagle's authoring layer to a three-statement spec — typed Clojure, load-bearing divergence or it dies, idiomatic per target — and converts the Clojure and ClojureScript emitters from dormant to live alongside Nix.

### Highlights

- Surface lock: typed Clojure + inference; inline `:-` annotations replace `claim` on def/defn/defonce/let (6fefc09).
- Multi-target live loop: Nix, Clojure, ClojureScript all active; JS/Py/SQL/Rkt remain parked under `BEAGLE_ALL_TARGETS=1` (ce51c1b).
- Macros: `defmacro` + quasi-quote (`` ` ,  ,@ ``) shipped; legacy `define-macro` hard-removed (96e9138).
- Reader conditionals: `#?(:clj … :cljs … :nix … :default …)` and `#?@(…)` splice across the live-target tier.
- Sourcemap fidelity: diagnostics blame author position through every canonicalization — `sourcemap-fidelity.rkt` corpus 5/11 → 11/11 (2025b33).
- Typo suggestions against the real 16k NixOS schema: 96.9% Top-1 at 130 ms/query, +1.1% end-to-end overhead on the firn-validate corpus.

### Added

- Inline `:-` type annotations on `def`, `defn`, `defonce`, and `let` bindings (parse.rkt:418, 1364).
- `defmacro` with Scheme-style quasi-quote / unquote / unquote-splicing (parse.rkt:306, 2344).
- Clojure threading family: `->`, `->>`, `as->`, `cond->`, `cond->>`, `some->`, `some->>` (parse.rkt:2147).
- Reader conditionals `#?(…)` and splicing `#?@(…)` with `:clj :cljs :nix :default` tags (parse.rkt:450).
- Quoted self-evaluating containers `'[…]`, `'{…}`, `'#{…}` (2b2e258).
- Keyword access canonicalization: `(:k target)` and `(get target :k)` both lower to a single `kw-access` AST node (2eb7baa).
- Conditional family completed: `when`, `when-not`, `if-not`, `unless`, `if-let`, `when-let`, `if-some`, `when-some`, `cond`, `condp`.
- Stdlib sugar: `inc`, `dec`, `not=` typed in `stdlib-portable.rkt`.
- Per-target prefixes `nix/`, `js/`, `sql/` for forms whose meaning diverges from Clojure (e.g. `nix/assert`, `nix/with-cfg`, `js/await`).
- Structured diagnostic taxonomy: `cause-class?`, `surface-divergence`, `type-error`, `logic-error` exported from `diagnostic-kind.rkt`; consumed by `bin/beagle rejection-stats`.
- `bin/beagle rejection-stats <dir|glob> [verify-script]` aggregates failure causes by class.
- Schema-typed NixOS option paths: 16k options loaded into the typed environment via `nixos-schema.rkt`.

### Changed

- `claim` replaced by inline `:-` annotations on binding forms; same checker, less syntax (6fefc09).
- Keyword access is a single canonical AST node regardless of spelling — emitters and checkers see one shape (2eb7baa).
- Clj and Cljs emitters promoted to the active tier in `beagle-test/tiers.rktd`; default `bin/beagle test` run now covers them.
- Bare divergent forms now raise with a "use `(prefix/...)`" hint instead of silently emitting (parse.rkt:1577).
- README reframed around the typed authoring IR and the three-statement generative spec.

### Removed

- `claim` form (superseded by inline `:-`).
- Pipe threading family (replaced by Clojure `-> ->> as-> cond-> some->`) (1577987).
- `define-macro` (replaced by `defmacro` + quasi-quote) (96e9138).
- `deftype` residual surface; threading surface reconstruction completed (f24dcd4).
- Bare aliases for prefix-divergent forms — must spell as `nix/...` / `js/...` / `sql/...` (91a3abc).

### Fixed

- Sourcemap drift through canonicalization passes: diagnostics now point at the author's original token across every rewrite (2025b33).
- Validator false positives resolved by quarantining the experimental operative checker behind `BEAGLE_EXPERIMENTAL_OPERATIVE=1`.
- Levenshtein typo suggester is now segment-aware against the real schema: 96.9% Top-1, latency cut 57% (306 ms → 130 ms/query).

### Internal

- Phase 0 instrumentation + Phase 1 + Phase 2 batch migrations across the corpus (e273c35).
- Corpus migration tooling for the `:-` adoption pass (140 files touched in 6fefc09).
- CLAUDE.md formalizes ten standing rules and the three-statement spec — the surface is now spec-determined, not negotiated.

### Known limitations

- Free-variable resolution at definition site: macros are datum-based, not syntax-object-based.
- Bidirectional inference Layer 2 deferred until a corpus has enough `defn`s to justify it.
- Refinement types gated to a demo file behind a kill-switch.
- Operative checker quarantined behind `BEAGLE_EXPERIMENTAL_OPERATIVE=1`; not shipping in the default tool surface.
- JS / Py / SQL / Rkt emitters remain dormant; opt in with `BEAGLE_ALL_TARGETS=1` for structural-only runs.
