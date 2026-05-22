# Completed work

## v0.13.0

### Post-release audit (2026-05-22)

- Nix multi-arity fail-loud (both Racket + Bun emitters)
- CLJ behavioral test suite: 56 end-to-end tests (compile → bb → verify)
- defenum keyword emission fix (emitted symbols instead of keywords)
- defmethod return type annotation leak fix
- deftype/extend-type return type annotation leak fix
- Macro expander provenance: expansion-ctx struct, chain formatting, truncated input forms
- Provenance mirrored in self-hosted expander (self-host/macros.bjs)
- Zero-value todo audit: cancelled 18 items across 4 workstreams with documented reasoning
- `beagle-expand --trace`: expansion step tracing to stderr, depth-indented
- Macro provenance validation tests (nested error chain, trace handler capture)
- Bun oracle CI: 23/30 raco make pass + 22/30 emission parity (oracle-bun.rkt)

## v0.12.0

### Self-hosting bootstrap

- AST JSON bridge (`ast-json.rkt`, `bin/beagle-ast`)
- JS emitter (`self-host/emit-js.bjs`, ~950 lines, fixed-point verified)
- CLJ emitter (`self-host/emit-clj.bjs`, ~370 lines, match-verified)

### Developer experience

- `beagle init --claude-code`: daemon, hooks, system prompt — one command

### Security hardening (2026-05-20)

- `beagle-expand` command injection: all `bin/` scripts use `(current-command-line-arguments)`
- Nix emit-time escaping: all string emission routes through `escape-nix-string`
- JS regex + template literal escaping
- Parse-time identifier validation (`validate-identifier!`, `validate-module-path!`)
- Macro expansion DoS: depth cap on `expand-fully-no-marker`
- Nix import path traversal: `..` rejected at parse time

### Type system

- Exhaustive match errors (strict mode)
- `beagle.result` convention (Ok/Err/Result module)
- Bounded polymorphism (`forall [(T <: Bound)]`)
- Parametric `defunion` (`(defunion (Result T E) ...)`)
- `Number` built-in alias (`U Int Float`)
- Match emit fix (defunion field destructuring)

### JS target completeness

- `set!` for property mutation
- ~45 stdlib fns in `emit-core-call`
- Bare npm imports
- `letfn` mutual recursion
- Atom ops (atom, deref, reset!, swap!, add-watch, remove-watch)
- Core fns as higher-order values (JS-VALUE-WRAPPERS)
- JS-NO-EMIT safety net (139 symbols)
- `beagle.core.js` runtime (12 helpers)
- STDLIB-JS (38 JS-native type declarations)
- `beagle-js-coverage` report

### Doc consolidation

- Dead weight deleted (forms.md, cheatsheet-distilled.md, findings.md)
- CLAUDE.md experiment results stripped
- Single cheatsheet generation from Scribble
- `beagle-docs-sync` propagates canonical type names, counts
- Canonical example program (`examples/demo.bclj`)

### Packaging

- `info.rkt` with proper deps/metadata
- Composable lib/test/doc package split
- Racket package catalog registration

### Nix target (phases 1-2)

- Core emitter, stdlib-nix (120 typed entries), all nix-specific forms
- Target-form gating (15 nix forms + await)
- 183/183 equivalence tests vs old nisp output
- `beagle-build`, `beagle-schema`, `beagle-validate`, `beagle-rename`
- Wildcard path matching, HM root awareness, cross-file conflicts
- Auto-fix mode, firn-validate rewired

### Racket target

- `emit-rkt.rkt` — full emission (records, unions, scalars, parametric types, etc.)
- `beagle/rkt` target module + reader
- 58 unit tests, 13 positive fixtures, 2 negative fixtures
- Oracle CI + differential harness (9 fixtures)
- Value-position stdlib refs

## v0.1–v0.11.0

### Repair compiler (phases 1-5)

- beagle-blame: ratio analysis, confidence levels, call-graph tracing
- beagle-specfix: 9 candidate strategies, accessor swap, arg permutation
- beagle-trace: per-assertion arithmetic trace, source location correlation
- beagle-cascade: call graph impact, predictive blame, root cause detection
- beagle-repair: unified pipeline, --auto mode, --emit-patch

### Property testing & oracles (phases 6-8)

- beagle-proptest: record generators, return-type inference, differential testing, shrinking
- beagle-oracle: golden snapshot, assertion generation, differential mode
- beagle-muttest: 13 mutation operators, coverage gap reports

### Infrastructure

- LSP server: hover, diagnostics, document symbols, jump-to-definition, completion
- Typed REPL: persistent env, :type/:sig/:env, daemon integration
- Reactive daemon: file watcher, ~100ms re-check, 45x query speedup
- Distributed tracing: beagle-dtrace
- CLJS target: JS interop, source maps, shadow-cljs validated (Heist 40/40)
- Refinement predicates: compile-time literal checking + runtime :pre
- Query tools: beagle-sig, beagle-fields, beagle-callers, beagle-provides, beagle-impact

### Releases

- v0.4.0: unified CLI, consumer cheatsheet, error message audit
- v0.5.0: docs/prompts/, nix flake, beagle-docs-sync
- v0.6.0: form completeness, Scribble docs
- v0.6.1: Scribble polish
- v0.11.0: proc macros, typed JS target AST, multi-target, macro evaluator

### Experiments

- E1-E3: initial benchmarks (8 programs, refactoring, bug detection)
- E4: scaled experiment (13 modules, 8570 LOC, 35 bugs)
- E5: event-sourced pipeline (8 modules, 40 bugs)
- E9: repair toolchain (29% faster, 36% fewer tokens)
- E10: workflow compression (33% faster wall time)
- E11: model tier (Opus 33% gain, Sonnet 4%, Haiku 2%)
- E12: Python gap analysis + clj-kondo track
- E13: reactive daemon (287s avg, per-bug faster than Python+mypy)
- E14-E15: multi-agent pool (abandoned)
- E16: type checker makes agents 24% faster
- E18: proc macro compression (2-3x at realistic scale)
- E19: agent macro authoring
- E20: CNF visibility
- E21: macro composition
- E22: cross-target macro verification
