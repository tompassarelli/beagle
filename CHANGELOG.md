# Changelog

All notable changes to beagle are recorded here. This file is the canonical version history; git tags point to the corresponding commits.

Format: loosely [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Entries are grouped by impact, not by commit. Bullets describe behavior visible to authors or downstream tooling — internal refactors only appear when they changed something observable. Commit SHAs are cited for headline items only.

This file begins at v0.16.0. Prior history lives in git tags (v0.7.1 → v0.15.3).

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
- Structured diagnostic taxonomy: `cause-class?`, `surface-divergence`, `type-error`, `logic-error` exported from `diagnostic-kind.rkt`; consumed by `bin/beagle-rejection-stats`.
- `bin/beagle-rejection-stats <dir|glob> [verify-script]` aggregates failure causes by class.
- Schema-typed NixOS option paths: 16k options loaded into the typed environment via `nixos-schema.rkt`.

### Changed

- `claim` replaced by inline `:-` annotations on binding forms; same checker, less syntax (6fefc09).
- Keyword access is a single canonical AST node regardless of spelling — emitters and checkers see one shape (2eb7baa).
- Clj and Cljs emitters promoted to the active tier in `beagle-test/tiers.rktd`; default `bin/beagle-test` run now covers them.
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
