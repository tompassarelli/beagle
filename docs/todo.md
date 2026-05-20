# beagle — todo

## Now: Developer experience

### `beagle init --claude-code` ✓

One command wires up everything for Claude Code: daemon, hooks, system prompt.

- [x] `--claude-code` flag on existing `beagle init`
- [x] Generate `.claude/settings.json` with PostToolUse hook (daemon diagnostics on .rkt edit/write)
- [x] Generate `.claude/hooks/beagle-check.sh` — daemon-first, CLI fallback
- [x] Generate `CLAUDE.md` snippet with beagle context (from consumer cheatsheet)
- [x] Print setup summary (what was created, how to start daemon)

## Open

### Type system improvements

Corner agent mistakes mechanically. See [`docs/type-system.md`](type-system.md) for full rationale.

- [x] Phase 1: Exhaustive match errors — missing `defunion` match cases are hard errors in strict mode (wildcards don't suppress)
- [x] Phase 2: `beagle.result` convention — `Ok`/`Err`/`Result` module + cross-module defunion import
- [x] Phase 3: Bounded polymorphism — `(forall [(T <: Bound)] ...)` constraining type variables
- [x] Phase 4: Parametric `defunion` — `(defunion (Result T E) ...)` for typed error returns
- [x] `Number` built-in alias — `(U Int Float)`, docs steer toward `Int`/`Float` when concrete
- [x] Match emit fix — defunion match arms now destructure fields in emitted Clojure/JS

### Target-aware code generation

`fmt` → `js-template` → `js/quote`: three levels of codegen support.

- [x] `fmt` — interpolated string templates: `(fmt "hello ${name}")` → `(str "hello " name)`. Works with heredocs. Parse-time rewrite, all targets.
- [ ] `js-template` — typed splice sites: `${stmt body}`, `${expr x}`, `${json data}`, `${indent block 4}`. Reject invalid splices (stmt where expr expected).
- [ ] `js/quote` — structural JS quasiquotation. Beagle represents JS AST, not text. The north star.

### JS target gaps

- [x] `set!` for property mutation — `(set! (.-value el) "")` parsed and emitted for CLJ + JS
- [x] ~45 stdlib fns in `emit-core-call`: mapv, filterv, sort-by, dissoc, update, merge, get, subvec, pop, peek, some, take, drop, vector?, map?, distinct, flatten, complement, constantly, partial, comp, frequencies, group-by, partition, interleave, juxt, not-empty, take-last, drop-last, sequential?, seq?, coll?, set?, pr-str, to-array, aget, aset, array-seq, clj->js, js->clj, seq, not=
- [x] Bare npm imports — single-word requires emit as bare package imports
- [x] `letfn` — mutual recursion local fns (CLJ + JS emit, lint, 796 tests)
- [x] Atom ops in emit-core-call — `atom`, `deref`, `reset!`, `swap!`, `add-watch`, `remove-watch`
- [x] Core fns as higher-order values — JS-VALUE-WRAPPERS emit lambda wrappers in value position; binding-aware (user defs shadow stdlib)
- [x] JS-NO-EMIT safety net — compile-time warning for portable stdlib fns with no JS translation (139 symbols)
- [x] `beagle.core.js` runtime — 12 finite helpers: range, remove, mapcat, every?, keep, map-indexed, assoc-in, update-in, select-keys, merge-with, take-while, drop-while
- [x] STDLIB-JS — 38 JS-native type declarations (Math, JSON, Promise, fetch, timers, Object, Array, console)
- [x] `beagle-js-coverage` — coverage report showing `silent fallback: 0`

### Doc consolidation

- [x] Delete dead weight: `forms.md`, `cheatsheet-distilled.md`, `findings.md`, prompts stubs
- [x] Strip CLAUDE.md experiment results into experiments/report.md only
- [x] Single cheatsheet generation from Scribble

### Doc generation / single source of truth

- [x] Extend `beagle-docs-sync` to propagate canonical type names from `private/types.rkt`
- [x] Add `CLAUDE.md` instructions to use `beagle-docs-sync` after type/form changes
- [x] Scribble as single source → `bin/beagle-gen-cheatsheet` renders Scribble → markdown cheatsheets
- [x] `beagle-docs-sync` runs generator before propagating counts
- [x] Canonical example program: `examples/demo.bclj` (defrecord, defunion, Result, match, multi-arity)

### Proper packaging

Package beagle as a proper Racket package so it can be installed via `raco pkg install`
from the catalog (not just `--link`).

- [x] Add `info.rkt` with proper deps, collection, pkg metadata, tags, test-paths
- [x] Composable lib/test/doc package split — see [`docs/plan-racket-package-reorg.md`](plan-racket-package-reorg.md)
- [x] Register on [Racket package catalog](https://github.com/racket/racket/wiki/Creating-Packages)

### Nix target: full nisp replacement

`beagle/nix` replaces nisp as the authoring layer for NixOS configs.
Same typed AST, better tooling, integrated repair compiler.

**Phase 1 — Module-writing core:** ✓
- [x] Core emitter, stdlib-nix (120 typed entries), all nix-specific forms
- [x] Target-form gating (15 nix forms + `await`)
- [x] 183/183 equivalence tests vs old nisp output

**Phase 2 — Toolchain parity (replacing `nisp` CLI):**
- [x] `beagle-build` — .bnix → .nix compilation (firn-build uses it)
- [x] `beagle-schema` — interactive NixOS option queries (replaces `nisp schema`)
- [x] `beagle-validate` — source-level validation with schema, types, duplicates, cross-file conflicts (replaces `nisp validate`)
- [x] `beagle-rename` — option path refactoring across .bnix files (replaces `nisp rename`)
- [x] `nixos-schema.rkt` — schema loading, wildcard matching, type checking, did-you-mean
- [x] Wildcard path matching for `attrsOf submodule` boundaries
- [x] Home Manager root awareness (skip HM-only namespaces)
- [x] Cross-file conflict detection with mkDefault/mkForce awareness
- [x] Auto-fix mode (Levenshtein ≤ 2, unambiguous)
- [x] firn-validate rewired to call beagle-validate

**Phase 3 — Zero validation errors:**
- [ ] HM schema loading — load separate Home Manager schema for HM-context paths (`programs.git.settings.*`, `programs.atuin.*`, `programs.delta.*`, `programs.walker.*`, `programs.yazi.*`, `xdg.*`, `gtk.*`)
- [ ] Freeform attrs expansion — `virtualisation.podman.defaultNetwork.settings.*`, `nix.settings.*` etc. are freeform and should be permissive
- [ ] Stylix module schema — `stylix.targets.*` needs stylix flake input schema
- [ ] Duplicate detection refinement — skip expected module pattern (options + config sections set same path)
- [ ] Custom option validation — `myConfig.modules.kanata.capsLockEscCtrl` in template needs the module's own schema

**Phase 4 — Beyond nisp:**
- [ ] LSP completion for NixOS option paths from schema
- [ ] LSP completion for package names from packages.json
- [ ] LSP hover showing NixOS schema type + enum for option paths
- [ ] `beagle-import` — .nix → .bnix conversion (reuse rnix parser)
- [ ] Package name validation — cross-check `pkgs.X` against nixpkgs attrs

### Experiment metadata

- [x] Add version + dialect table to `experiments/report.md` (v0.1–v0.5, all `#lang beagle` / Clojure target)
- [ ] E13 confound isolation: full prompt vs cheatsheet, daemon vs no daemon

## Completed

<details>
<summary>v0.1–v0.6.1 (click to expand)</summary>

### Repair compiler (phases 1–5)

- beagle-blame: ratio analysis, confidence levels, call-graph tracing
- beagle-specfix: 9 candidate strategies, accessor swap, arg permutation, cross-evidence correlation
- beagle-trace: per-assertion arithmetic trace, source location correlation, call-graph walk
- beagle-cascade: call graph impact, predictive blame, root cause detection
- beagle-repair: unified pipeline, --auto mode, --emit-patch (unified diff output)

### Property testing & oracles (phases 6–8)

- beagle-proptest: record generators, return-type property inference, differential testing, shrinking
- beagle-oracle: golden snapshot, assertion generation, differential mode
- beagle-muttest: 13 mutation operators, coverage gap reports

### Infrastructure

- LSP server: hover, diagnostics, document symbols, jump-to-definition, completion
- Typed REPL: persistent env, :type/:sig/:env, daemon integration
- Reactive daemon: file watcher, ~100ms re-check, 45× query speedup
- Distributed tracing: beagle-dtrace (instrument, collect, view, blame, graph, cascade)
- CLJS target: JS interop, source maps, shadow-cljs validated (Heist 40/40)
- Refinement predicates: compile-time literal checking + runtime :pre
- Query tools: beagle-sig, beagle-fields, beagle-callers, beagle-provides, beagle-impact

### Releases

- v0.4.0: unified CLI, consumer cheatsheet, error message audit, type checker hardening
- v0.5.0: docs/prompts/, nix flake, beagle-docs-sync, README update
- v0.6.0: form completeness (when-not, if-not, condp, dotimes, defonce, comment), Scribble docs
- v0.6.1: Scribble polish

### Experiments

- E1–E3: initial benchmarks (8 programs, refactoring, bug detection)
- E4: scaled experiment (13 modules, 8570 LOC, 35 bugs — first correctness divergence)
- E5: event-sourced pipeline (8 modules, 40 bugs)
- E9: repair toolchain (29% faster, 36% fewer tokens)
- E10: workflow compression (33% faster wall time)
- E11: model tier (Opus 33% gain, Sonnet 4%, Haiku 2%)
- E12: Python gap analysis + clj-kondo track
- E13: reactive daemon (287s avg, per-bug faster than Python+mypy)
- E14–E15: multi-agent pool (abandoned — 0 activations across 7 runs)

### Language

471 tests. ~678 stdlib entries. All core Clojure forms implemented.
Pattern matching, multi-arity defn, guard narrowing, union types,
cross-module import, macros (safe/unsafe), defrecord/defscalar/defenum/defunion,
destructuring, threading, Java interop, metadata, for/doseq/dotimes,
try/catch, loop/recur, all conditional forms.

</details>
