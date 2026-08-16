# Changelog

All notable changes to beagle are recorded here. This file is the canonical version history; git tags point to the corresponding commits.

Format: loosely [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Entries are grouped by impact, not by commit. Bullets describe behavior visible to authors or downstream tooling — internal refactors only appear when they changed something observable. Commit SHAs are cited for headline items only.

This file begins at v0.16.0. Prior history lives in git tags (v0.7.1 → v0.15.3). It is not continuous: v0.18.0 → v0.21.1 were released without sections here, and the gap is recorded below rather than reconstructed.

## [Unreleased]

### Fixed

- **An exported definition keeps its signature.** `js/export` parses to a struct wrapping the definition, and the passes that dispatch on definition shape matched the wrapper instead of looking through it: the top-level type environment, the datum-level cross-module importer, and the query commands all skipped exported definitions. A module's public API was therefore precisely the part with no types — `(exported-fn "string")` where a `Float` was declared passed `check` clean, in-module and across modules, and `beagle provides` reported nothing for a module whose every definition was exported. `unwrap-definition-form` (ast.rkt) is now the one place that sees through `with-meta` / `jst-export` / `jst-export-default`, and every such pass routes through it.
- **A multi-arity definition is importable.** The raw-source importer matched only single-arity `defn` shapes, so a consumer's call to an imported multi-arity function resolved to nothing and went unchecked. Imported as the union of its clause types, matching `ast-interface-bindings`, so a call resolves against the clause with its arity.
- **A qualified call to an imported export emits a member access.** Once the importer made exported names known to the consumer, the bound-name early-out in the call path returned the raw `sim/step` spelling and emitted the syntactically invalid `sim/step(...)`. A local binding never carries a namespace prefix, so a slash-bearing name is now dotted regardless of whether the interface makes it known — in both the Racket and self-hosted emitters.
### Added

- **`beagle ts-externs ENTRY.d.ts`** — typed beagle wrappers generated from a package's TypeScript declarations. Beagle could not read `.d.ts`, so every npm dependency was hand-declared as `Any` and unchecked; the declaration corpus that already describes those packages was unreachable. The mapping is lossy by design and degrades rather than guesses: primitives, arrays, and promises map; classes, generics, tuples, and function types become `Any`. Optional parameters become clauses of one multi-arity `defn`, TS overloads collapse into the same name, variadic signatures become a rest param forwarded with `js/spread`, and primitive-typed properties get a reader and a writer. What survives is what beagle can enforce: arity, primitive argument types, and whether the member exists at all.

## [0.22.0] — 2026-08-16

Native Core becomes a practical substrate for standalone command programs and interactive Wasm engines, and the first compiler-owned semantic-unit reuse seam lands. Whole-program compilation remains the authoritative release path.

### Added

- **Wasm entry ABI v1** (db8949d, 2108b3b): repeated `--entry` flags now produce distinct, qualified `beagle_wasm_entry_v1__<ns>__<name>` exports. Resource-bearing entries share an instance arena, expose explicit reset, and retain the zero-import reactor contract. The v1 runtime I/O surface lets a host feed byte records through the exported environment mailbox and read registered Buffer storage directly from linear memory; entry results, seams, adapter source, and runtime policy stay bound into the build receipts.
- **Native programs own their operating-system boundary** (c7c7465, 7886228, 9287f9f): typed capabilities now cover bounded filesystem inspection and reads, atomic writes, directory creation, append, wall-clock formatting, sleep, inherited and captured processes, and explicit streaming child-process lifecycles. `beagle native-exe` takes one typed `(Vec String)` argument vector as its entry boundary (a2cb465), so a command-line executable no longer needs hosted wrapper logic for arguments or output.
- **Native data tooling** (9becba9, a880b23, 6f455f3): compiler-shipped Beagle libraries add datum reader events, strict JSON and EDN event codecs with structured failures, and structural Nix option-path extraction and suggestion utilities.
- **Coherent multi-module native builds** (0ce9aa8): native lowering composes complete source bundles, resolves qualified cross-module calls, preserves imported unions and match context, and derives vector-literal types without downstream decoy declarations.
- **Bounded semantic-unit reuse** (fa3ed1e, 4b04546, ab5803e): the compiler can extract, validate, select, and deterministically reassemble exact typed/native unit payloads across layout-only, private-body, and public-interface mutations, over a lossless unit wire and a host runtime lifecycle. This is compiler groundwork — not a production incremental cache and not a new artifact format.

### Fixed

- Nullable text-index results, imported union-member coercion, zero-variant constructors, callback lowering, scalar conversions, source provenance, root-arena lifetime, and Wasm/POSIX shim separation now fail or lower at their owning boundary (fb03973).
- JavaScript emission preserves qualified aliases under local shadowing (d63de10) and detects asynchronous work nested inside emitted call and assignment forms.
- Native build reports and semantic identities remain deterministic and fail closed when source, interface, obligation, or payload claims disagree.
- The Nix package ships the complete native toolchain, including the native supervisor tools (ebff12f, 0e4b707).
- The declared package version is the released version again. `beagle-lib/info.rkt`, `beagle/info.rkt`, and `flake.nix` had drifted to 0.21.1, 0.18.0, and 0.17.1 with nothing keeping them in step; a tag-keyed CI assertion now fails the release when any of the three disagrees with the tag.

### Changed

- **Breaking (pre-1.0).** The Wasm executable surface replaces the single `beagle_wasm_entry_v0` export with qualified v1 entry exports; a host using the old entry name must migrate. The new native host and codec surfaces are additive.

## Gap: 0.18.0 through 0.21.1 — no sections in this file

Five releases were tagged and published without a changelog section: v0.18.0 (2026-06-28), v0.19.0 (2026-07-27), v0.20.0 (2026-08-07), v0.21.0 and v0.21.1 (both 2026-08-15). They are deliberately not reconstructed here, because the surviving source material differs by version:

- **0.18.0, 0.19.0, 0.20.0** — the published GitHub release bodies are substantive authored change summaries and are the source of record: [v0.18.0](https://github.com/tompassarelli/beagle/releases/tag/v0.18.0), [v0.19.0](https://github.com/tompassarelli/beagle/releases/tag/v0.19.0), [v0.20.0](https://github.com/tompassarelli/beagle/releases/tag/v0.20.0).
- **0.21.0, 0.21.1** — the published release bodies describe only the attached `beagle-selfhost` binary and carry no change list. Nothing authored survives for either; their content exists only as `git log v0.20.0..v0.21.1`.

The `[Unreleased]` entries above predate this gap and shipped in v0.21.0 — e7b2e01, c3a803e, and d2d70f5 are first contained in that tag. They are left where they are rather than relabelled, because they are not the whole of that release and promoting them would misstate what v0.21.0 was.

## [0.17.1] — 2026-06-16

A patch release of JS-target hardening, driven entirely by authoring a real downstream app (the gjoa Firefox fork) in `#lang beagle/js`. Each item is a silent miscompile or footgun the port hit — now an emit fix or a loud compile-time guard. Active suite 1377/1377.

### Fixed

- **Async IIFEs are awaited in value/statement position** (678bbd1): a `try`/`loop`/`doseq` containing `js/await` compiles to an async IIFE; bound in a `let` without an enclosing `js/await`, it was emitted *without* `await`, so the binding held a pending Promise that downstream code then read synchronously. `emit-js` now awaits async IIFEs in value/statement position — tail position correctly left alone, and the exact `(async () => ` prefix match never double-awaits.
- **Macro-only `:refer`s are no longer emitted as runtime imports** (69c718a): a refer that resolves to a macro is compile-time only and has no runtime export, but it was emitted in `import { … }` — silently fine when a bundler tree-shakes the dead import, a load-time "does not provide an export named X" for any *unbundled* ESM consumer. `emit-module-header` now drops macro refers and omits the import line entirely when a require's refers are all macros.
- **The purity check now covers exported functions** (5e18635): `check-purity!` descended only into list-shaped wrapper forms, so `js/export` / `js/export-default` (which parse to *structs*) hid every exported defn — the public API — from the `!`-effect check. Now descends into `jst-export` / `jst-export-default` / `with-meta`.

### Added

- **`swallowed-binding` guard (E020)** (004d291): a `let` binding one paren short silently absorbs the following `name value` pair as body forms, emitting the swallowed name as a bare `name;` statement → runtime `ReferenceError`, while `beagle syntax` reports "ok" (parens net-balance). A non-final body statement that is a bare unbound symbol now errors with a pointed message; tail-position bare symbols (legitimate returns) are not flagged.
- **`%` rejected as a call head — `percent-not-modulo`** (2f7a441): `(% a b)` emitted `_pct(a, b)` (`%` is the `#()` anonymous-arg shorthand) → undefined call. Now a pointed parse error naming `rem`/`mod` for modulo; `%` inside `#(…)` lambdas is unaffected.
- **camelCase JS-export lint** (7b5b6d5): kebab names mangle to `snake_case` and camelCase emits as-is, so a camelCase export referenced cross-module in kebab resolves to a *different* identifier (undefined in the bundle). A lint warns and names the kebab fix; it runs in `lint-program!` (fires at `build` and `check`) and is counted by `count-lint-warnings`, so the `--agent` authoring loop surfaces it too.

## [0.17.0] — 2026-06-15

Where 0.16 locked the surface, 0.17 turns the compiler into something its own repair tooling can drive. Diagnostics now carry structured, machine-applicable data; `beagle-doctor` proves the authoring loop *works* rather than merely runs; form dispatch unifies onto a single compile-time combiner registry; and the JS emitter returns to live.

### Highlights

- Authoring loop is real and proven end-to-end: diagnostics carry structured types and machine-consumable conversion data (`MessageData`), `beagle-repair` applies them, and `beagle-doctor` demonstrates the loop functions, not just that the daemon is alive (d599fe17, 1cc1077f, a0e60513).
- Dispatch unified: one compile-time combiner registry resolves macros, builtins, and legacy forms; 21+ special forms plus the def/control/module/nix/js/sql families migrated onto it; the dead operative prototype was deleted (5d58d09 → b737821, 80c01a1).
- Deterministic paren-balancing is auto-enforced via the PostToolUse hook, and hooks are distributed from tracked templates (bdaae9f1, 8b13af3c).
- `!`-purity static pass (`check-purity!`) is on by default (c118f21, 0130145).

### Added

- In-compiler error-explanation registry with machine-applicable suggestions (17434043).
- Structured types in diagnostics via `MessageData`; structural fix-plans carry machine-consumable conversion data that `beagle-repair` consumes (d599fe17, f36d18cc, 1cc1077f).
- Exhaustive-match auto-fill: missing-case clause skeletons emitted as an applicable repair fix (cc30a6c2).
- Auto-apply `replace-head` suggestions in the authoring loop (822fa136).
- Types-as-view: `beagle-explain-type` projects inferred types through an extensible delaborator registry; numeric unions fold to `Number`, with `--write` promotion (4145ce44, 13847b3d, f0ff58c6).
- `beagle-doctor` proves the authoring loop works, with a dynamic target inventory and a correct `raco` probe (a0e60513, 2c5a56b2).
- Source positions carry origin/canonical with precise column propagation; macro expansions inherit the call-site source position (de155bae, 3a9af8f6).
- Generated, example-verified capability cheatsheet that can't rot (10d50241).
- JS emitter live again: `@x` deref sugar, `js/import-meta`, `js/export-default`, async `loop`/`recur` via `js/await`, destructuring `:or`/`:as`, kebab-case property mangling, statement-position IIFE elimination (e7823757 + series).
- `!`-purity static pass (`check-purity!`), shipped dark then enabled by default as an error (c118f21, 0130145).
- `(:gen-class)` in `ns` for clj AOT/native entry; batch `declare-extern` — `(declare-extern [a b c] Type)` (f82e6fa, 47f093c5).
- Multi-module type awareness for package targets; qualified-call resolution for clj/cljs with fixed sibling imports (f2b8f2f3, 8b927611).
- `stdlib-bb` babashka-runtime typed tranche (~130 entries) (da975a1c).
- Inline expected-diagnostic test harness with mechanical update (40da2b96).

### Changed

- Form dispatch unified onto one compile-time combiner registry — `do`/`if` seeded first, then the when/if conditional family, def, control, module, nix, js, and sql forms; a single resolver now handles macros, builtins, and legacy forms (5d58d09 → b737821).
- Real mode-2 macro hygiene: definition-site free-variable resolution across all live targets (3fe36b75, 06bedfc2).
- Numeric-preserving arithmetic with `Int`→`Float` widening in the checker (63b62ca1).
- nil-narrowing extended to and/or composition and `not=`, with soundness fixes and a deeper clj stdlib (d77855eb).
- clj emitter: lean release mode; dropped `^long`/`^double` and unresolvable opaque-extern hints the JVM/AOT compiler rejects (b7ba4cc, 80233e0, a401115).
- CLI consolidated onto `beagle <cmd>`: 12 missing subcommands wired, 8 dead tools removed, `beagle init` unified onto the canonical scaffolder (54195516, 8b7ac681, adf8262e).
- Hooks distributed from tracked templates; pool mode is portable and scaffolded, and `--hooks` idempotently merges into existing repos (8b13af3c, c2319a90).
- PostToolUse hook auto-enforces deterministic paren-balancing (bdaae9f1).
- Version metadata bumped `0.15.3` → `0.17.0` (`info.rkt` was never advanced for 0.16.0); `pkg-desc` corrected to the live target set.

### Removed

- Dormant py / rkt / scheme targets (SQL kept as a dormant emitter with live schema-typing) (4497259c).
- Dead operative prototype deleted; the one-compiler ground truth is documented (80c01a15).
- Game/kernel extracted out of the language repo to `~/code/games` (83773836).

### Fixed

- Don't crash compiling nested macro calls (`datum->syntax` on a raw-datum srcloc) (8290e667).
- Delaborator offset correctness across tabs/CRLF, with opt-in capture (45ab2a96).
- Authoring-loop clause insertion: single-line matches and string-decoy anchors (afff6c4d).
- Structural fix-plan blames the differing type argument (e6a6562f).
- clj regex emission and a blame-path destructure crash (0389b8bc).
- JS `:as` whole-map binding across all three `let` paths; record-ctor partial gated to real records (973dd9b6).
- Hardened `(ns ...)` name extraction in `beagle-build` (74372947).
- Surface hardening: killed silent meaning-changers and closed LLM-prior gaps (2b38cad8).

## [0.16.0] — 2026-06-01

The surface stopped accreting. v0.16 locks beagle's authoring layer to a three-statement spec — typed Clojure, load-bearing divergence or it dies, idiomatic per target — and converts the Clojure and ClojureScript emitters from dormant to live alongside Nix.

### Highlights

- Multi-target live loop: Nix, Clojure, ClojureScript all active; JS/Py/SQL/Rkt remain parked under `BEAGLE_ALL_TARGETS=1` (ce51c1b).
- Macros: `defmacro` + quasi-quote (`` ` ,  ,@ ``) shipped (96e9138).
- Reader conditionals: `#?(:clj … :cljs … :nix … :default …)` and `#?@(…)` splice across the live-target tier.
- Sourcemap fidelity: diagnostics blame author position through every canonicalization — `sourcemap-fidelity.rkt` corpus 5/11 → 11/11 (2025b33).
- Typo suggestions against the real 16k NixOS schema: 96.9% Top-1 at 130 ms/query, +1.1% end-to-end overhead on the firn-validate corpus.

### Added

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

- Keyword access is a single canonical AST node regardless of spelling — emitters and checkers see one shape (2eb7baa).
- Clj and Cljs emitters promoted to the active tier in `beagle-test/tiers.rktd`; default `bin/beagle test` run now covers them.
- Bare divergent forms now raise with a "use `(prefix/...)`" hint instead of silently emitting (parse.rkt:1577).
- README reframed around the typed authoring IR and the three-statement generative spec.

### Removed

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
