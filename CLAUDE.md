# beagle — session anchor

A multi-target authoring IR. Racket frontend with custom `#lang`, macros
(safe/unsafe boundaries), static type checking; emits Clojure, ClojureScript,
JavaScript, or Nix source for runtime. `.bgl` is the primary file extension
(`.rkt` still accepted for backward compatibility).

**LLM authoring is a first-class concern.** Rich types, explicit forms, low
syntactic surface area, structured errors. One canonical idiom per concept.

**Quick reference:** `docs/cheatsheet.md` is the single-page language
summary designed to be loaded as system context for LLM workflows. Treat
it as canonical when explaining the language.


## Status

`#lang beagle` v0.8.0 — 550 tests passing.

- **Targets:** `beagle/clj` (default), `beagle/cljs`, `beagle/js`, `beagle/nix`, `beagle/py` (plumbed, no emitter)
- **Forms:** ~50 forms — definitions, control flow, data structures, pattern matching, threading, interop. See `docs/cheatsheet.md` for the full catalog.
- **Types:** 8 primitives (`String`, `Int`, `Float`, `Bool`, `Keyword`, `Symbol`, `Nil`, `Any`), parametric (`Vec`, `Map`, `Set`, `List`), union (`U`), nullable (`T?`), function types, `forall`, `(Promise T)`
- **Stdlib:** ~700 entries total — portable (269), Clojure (352), CLJS (75), JS (38 native), Nix (120)
- **Type checking:** flow-sensitive narrowing, cross-module import, collection/destructuring inference, exhaustive match warnings, refinement predicates
- **Diagnostics:** Rust-style errors with signatures, "did you mean?" suggestions, JSON mode
- **Tooling:** LSP, typed REPL, MCP server, reactive daemon (~100ms re-check), repair compiler, property testing, distributed tracing
- **Experiments:** 15 across 3 tracks (Beagle/Clojure/Python) — best config 287s avg (E13), per-bug faster than Python+mypy

See `docs/cheatsheet.md` for the full language reference.

## Architecture

```
parse → check → emit-dispatch → emit-{clj,js}
(all expand-time, inside our custom #%module-begin)
```

- `lang/reader.rkt` — custom reader preserving `[]` vs `()` via
  `#%brackets` tag. Intercepts `{}` (map literals), `#{}` (set literals),
  `#"..."` (regex) via `MAP-TAG`/`SET-TAG`/`#%regex`.
- `lang/reader-impl.rkt` — shared reader logic for all `#lang beagle/*` variants.
- `private/types.rkt` — type AST, parser, compatibility checker.
  `MAP-TAG`/`SET-TAG` are well-known symbols (`#%map`/`#%set`), not gensyms.
- `private/stdlib-types.rkt` — combined stdlib catalog; delegates to
  `private/stdlib-portable.rkt` (256 entries), `private/stdlib-clj.rkt` (365),
  `private/stdlib-cljs.rkt` (75).
- `private/macros.rkt` — macro registry, naive substitution, depth-capped
  recursive expansion, safe/unsafe boundary.
- `private/parse.rkt` — source → AST. Two passes: meta-form collection
  (mode, ns, macros, externs, requires, imports) then expr parsing with
  macro expansion.
- `private/check.rkt` — best-effort type checking against annotations and
  the built-in env. Record field registry for keyword-access type inference.
  Skipped in dynamic mode.
- `private/emit-dispatch.rkt` — dispatches to `emit-clj.rkt`, `emit-js.rkt`, or
  `emit-nix.rkt` based on `(program-target prog)`.
- `private/emit-clj.rkt` — AST → Clojure/ClojureScript source string (was `emit.rkt`).
- `private/emit-js.rkt` — AST → JavaScript source string.
- `private/emit-nix.rkt` — AST → Nix source string (curried fns, attrsets, let/in).
- `private/js-capabilities.rkt` — JS capability sets (JS-TRANSLATED, JS-VALUE-WRAPPERS,
  JS-RUNTIME-HELPERS). Imported by both emit-js and stdlib-js — no circular deps.
- `private/stdlib-js.rkt` — JS-specific: STDLIB-JS (38 JS-native type declarations),
  JS-NO-EMIT (computed from STDLIB-PORTABLE minus JS-TRANSLATED).
- `private/stdlib-nix.rkt` — Nix-specific: STDLIB-NIX (120 typed entries for
  builtins.*, lib.*, lib.types.*).
- `lib/beagle/core.js` — JS runtime helpers (12 finite functions: range, remove,
  mapcat, etc.). Auto-imported when referenced.
- `nix/main.rkt` — Nix target module (`#lang beagle/nix` → `define-target nix`).
- `nix/lang/reader.rkt` — reader hook for `#lang beagle/nix`.
- `private/expand-tool.rkt` — backend for `bin/beagle-expand`.
- `private/query.rkt` — type-system query engine for `beagle-sig`,
  `beagle-fields`, `beagle-callers`, `beagle-provides`, `beagle-impact`.
- `private/blame.rkt` — semantic property rules + static suspicion analysis.
- `private/daemon.rkt` — persistent query server (TCP, AST cache with mtime invalidation, 45× query speedup).
- `private/check-all.rkt` — batch type-checker (10x vs sequential `beagle-check`).
- `private/build-all.rkt` — batch compiler (9x vs sequential `beagle-build`).
- `private/lsp.rkt` — LSP server (JSON-RPC 2.0, Content-Length framing, hover/diagnostics/symbols/definition).
- `private/repl.rkt` — typed REPL with persistent environment (parse → check → emit per input).
- `lib/beagle/dtrace.clj` — distributed tracing runtime (Clojure/Babashka): span lifecycle, context propagation, Ring middleware, file/TCP exporters.
- `main.rkt` — language module; `#%module-begin` runs the pipeline,
  embeds resulting string, runtime `(display)`s it.

## Adding a new form (the pattern)

1. **Struct** in `parse.rkt` — new AST node
2. **Parse case** in `parse-list-form` — pattern-match the source
3. **Emit case** in `emit-clj.rkt` AND `emit-js.rkt` — produce target source
4. **Infer case** in `infer-expr` — return type (or `ANY`)
5. **Lint traversal** in `lint.rkt` — `check-shadow` and `collect-symbols`
6. **Provide** the struct in parse.rkt's provide list
7. **Tests** in parse/emit/check test files

## Test helpers

Tests can't use `[...]` or `{...}` syntax directly (Racket reader collapses
them). Use these helpers:

```racket
(define (br . xs) (cons BRACKET-TAG xs))   ; simulates [...]
(define (mp . xs) (cons MAP-TAG xs))       ; simulates {...}
```

Example: `(defn foo [(x : Int)] (+ x 1))` in test form:
```racket
(parse-one `(defn foo ,(br '(x : Int)) (+ x 1)))
```

## Conventions

- `ANY` is `(type-prim 'Any)` — the universal escape type
- Params can be `param`, `map-destructure`, or `seq-destructure` structs — always check with `(map-destructure? p)` / `(seq-destructure? p)` before calling `(param-name p)`
- `MAP-TAG` and `SET-TAG` are `'#%map` and `'#%set` (well-known symbols, NOT gensyms — gensyms break across Racket phase boundaries)
- The reader runs at phase 0, the parser at phase 1 (inside `define-syntax`) — shared symbols must be phase-stable
- `emit-form` handles top-level forms (def, defn, defrecord, etc.); `emit-expr` handles everything else
- `check-form` does top-level type checking; `infer-expr` does expression-level inference

## Tools

- `bin/beagle` — unified CLI: `beagle check`, `beagle build`, `beagle fix`, `beagle sig`, `beagle lsp`, `beagle repl`, `beagle mcp`, `beagle init`
- `bin/beagle-build SOURCE.bgl [OUT]` — single-file compile; auto-detects target from `#lang` line, outputs `.clj`/`.cljs`/`.js`/`.py` accordingly (`.rkt` sources accepted)
- `bin/beagle-build-all FILE-OR-DIR... [--out DIR] [--warn]` — batch compile (9x vs sequential); `--warn` emits despite type errors; auto-detects target per file
- `bin/beagle-check SOURCE.bgl` — type-check without emitting (`.rkt` sources accepted)
- `bin/beagle-check-all FILE-OR-DIR...` — batch type-check (10x vs sequential) + semantic suspicions
- `bin/beagle-expand SOURCE.bgl` — print source after macro expansion (`.rkt` sources accepted)
- `bin/beagle-blame BUILD-DIR VERIFY-SCRIPT` — run oracle with blame analysis (ratio → likely bug type)
- `bin/beagle-specfix BUILD-DIR VERIFY-SCRIPT` — oracle-guided speculative fix (9 strategies incl. accessor swap, arg permutation)
- `bin/beagle-trace BUILD-DIR VERIFY-SCRIPT [--focus FN]` — instrumented tracing with call-graph walk (arithmetic ops + function call/return chain, cross-module)
- `bin/beagle-repair SOURCE-DIR VERIFY-SCRIPT [--auto] [--threshold N] [--emit-patch]` — unified repair pipeline with cross-evidence correlation; `--emit-patch` emits unified diff to stdout (machine-consumable, `git apply` compatible)
- `bin/beagle-proptest SOURCE-DIR [--run] [--build-dir DIR] [--diff DIR2]` — property tests + differential testing (record generators, round-trips, behavioral comparison)
- `bin/beagle-cascade SOURCE-DIR VERIFY [--modified fn1,...] [--from-failures]` — call graph impact prediction and cascade root-cause analysis
- `bin/beagle-oracle GOLDEN-DIR [--out FILE] [--diff MODIFIED-DIR]` — behavioral oracle synthesis (golden code IS the test spec)
- `bin/beagle-lsp` — LSP server (stdio transport) for editor integration
- `bin/beagle-repl` — interactive REPL with type checking
- `bin/beagle-smap extract FILE.cljs` / `compose JS.map MAPPING.json` — source map: .bgl/.rkt → .cljs → .js
- `bin/beagle-muttest BUILD-DIR VERIFY [--limit N]` — mutation testing (13 operators, reports kill rate + oracle gaps)
- `bin/beagle-dtrace instrument BUILD-DIR [--services s1,s2] [--out DIR]` — auto-instrument cross-service calls with span creation
- `bin/beagle-dtrace collect [--port N] [--dir DIR]` — TCP collector daemon for span aggregation
- `bin/beagle-dtrace view TRACE-DIR [--trace-id ID]` — trace waterfall with ASCII timeline
- `bin/beagle-dtrace blame TRACE-DIR [--oracle-output FILE]` — cross-service blame with oracle failure correlation
- `bin/beagle-dtrace graph TRACE-DIR` — service dependency graph with impact analysis
- `bin/beagle-dtrace cascade TRACE-DIR [--trace-id ID]` — root cause analysis across service boundaries
- `bin/beagle-daemon start|stop|status|query CMD` — persistent query server (45× faster than cold tools)
- `bin/beagle-daemon start --watch DIR` — start with file watcher; re-checks .bgl/.rkt files on save, caches enriched results
- `bin/beagle-mcp` — MCP server exposing type system as tools (sig, fields, callers, provides, impact, check, check-enriched, build, expand); delegates to daemon when running
- `bin/beagle-verify-enriched BUILD-DIR VERIFY` — run verify + auto-diagnose failures (trace, cascade, pattern analysis)
- `bin/beagle-sig FN-NAME FILE-OR-DIR...` — print a function's typed signature (daemon-accelerated)
- `bin/beagle-fields RECORD FILE-OR-DIR...` — print record fields, types, and accessors (daemon-accelerated)
- `bin/beagle-callers FN-NAME FILE-OR-DIR...` — find all call sites of a function (daemon-accelerated)
- `bin/beagle-provides FILE-OR-DIR...` — list all exports with types from a module (daemon-accelerated)
- `bin/beagle-impact FN-NAME FILE-OR-DIR...` — show callers and impact of changing a signature (daemon-accelerated)
- `bin/beagle-fix --dry-run|--apply FILE-OR-DIR` — auto-apply high-confidence type-error fixes
- `bin/beagle-syntax FILE...` — fast paren/bracket balance check (<200ms); catches delimiter corruption before compile
- `bin/beagle-pool DIR` — repair agent pool watcher (abandoned E15; kept for reference)
- `bin/beagle-docs-sync [--dry-run] [--verbose]` — propagate mechanical facts (test count, stdlib size, devlog count) into docs
- `bin/beagle-js-coverage` — JS target stdlib coverage report (win condition: `silent fallback: 0`)
- `bin/gen-stdlib-types` — generate stdlib type entries from clojure.core metadata
- `raco test tests/` — test suite
- `experiments/` — benchmark framework (see `experiments/README.md`)

### Query tools for LLM agents

The `beagle-sig`, `beagle-fields`, `beagle-callers`, `beagle-provides`,
and `beagle-impact` tools expose the type system as a query interface.
Instead of reading source files to understand a codebase, agents can ask
the type system directly:

```bash
# "What does inv/can-fulfill? expect?"
bin/beagle-sig can-fulfill? path/to/inventory.bgl
# → can-fulfill? : [(Vec StockLevel) Int Int -> Bool]

# "What fields does an Invoice have?"
bin/beagle-fields Invoice path/to/billing.bgl
# → Invoice
#   id : Int           accessor: invoice-id
#   order-id : Int     accessor: invoice-order-id
#   ...

# "What does the billing module export?"
bin/beagle-provides path/to/billing.bgl
# → records: Invoice, Payment, CreditNote ...
#   functions: create-invoice : [...], invoice-balance : [...] ...

# "Who calls create-invoice and with what arity?"
bin/beagle-callers create-invoice path/to/
# → (create-invoice id order customer ...)  in audit-order (audit.bgl)

# "If I change create-invoice's signature, what breaks?"
bin/beagle-impact create-invoice path/to/
# → callers with current arg counts
```

Clojure-analog tools (`bin/clj-sig`, `bin/clj-fields`, `bin/clj-callers`,
`bin/clj-provides`) provide the same interface but without type information.
These exist so experiments can give both tracks the same structural query
tools, ensuring beagle's advantage comes from types, not tool availability.

## Lint warnings

Beagle prints lint warnings to stderr during compile (strict mode only):

- `untyped def NAME` — `(def x 42)` without type annotation
- `defn NAME has no return type annotation` — missing `: Ret`
- `defn NAME has untyped parameter(s): ...` — missing `(name : Type)`
- `(unsafe "...") inline escape` — beagle can't validate that code
- `let binding X shadows outer binding` — let/fn rebinds a name from enclosing scope
- `unused declare-extern: X` — extern declared but never referenced

Suppress with `BEAGLE_NO_LINT=1`. Warnings don't fail compile. Dynamic
mode skips lint (types are optional there by definition).

## Design decisions

### Confident (committed, well-reasoned)

| decision | reasoning |
|---|---|
| s-expressions, AST-based | non-negotiable foundation |
| Custom reader preserves `[]` vs `()` | Clojure cares (vectors); beagle needs to know |
| `(ns ...)` for namespace | universal Clojure idiom, in LLM training data |
| Wrapped `(x : T)` not inline | unambiguous parse, no lookahead, AI-friendly |
| Stdlib extern catalog | biggest single leverage point for AI type-safety |
| Safe / unsafe macro distinction | controlled boundary for "what the checker re-validates" |
| Macro expansion is inspectable | `beagle-expand` lets the LLM audit its own macros |
| Strict mode default | dynamic is escape-hatch for humans; AI should stay strict |
| Multi-target IR, not Clojure transpiler | same typed AST emits to Clojure, CLJS, JS, Nix (Python plumbed); target from `#lang` |
| Subset-of-Clojure, not full mimic | take Lisp universals + Clojure's good ideas; develop own for typed semantics |
| `:` as only annotation marker | `:-` removed; no measured benefit in 6-variant benchmark |
| Wrapped params only | inline removed; no measured benefit, less unambiguous parse |
| No type aliases | `Int`/`Float`/`Bool` only — zero ambiguity for LLMs |

### Cargo-cult — deliberately NOT added

Host-language idioms whose cost > benefit for beagle's goals:

- **`#(...)` anonymous fn shorthand** — alternate idiom for `fn`, more
  LLM confusion than value
- **`@deref`, `#'var-quote`** — Clojure-runtime concepts; use `unsafe`
- **Exotic reader macros (`#=`, `#_`, `#?`)** — Clojure-reader-specific

## Setup (one-time)

```
raco pkg install --link --auto /home/tom/code/beagle
```

## Doc maintenance

After changing type names, form signatures, or other facts that appear in
multiple docs, run `bin/beagle-docs-sync --verbose` to check consistency.
It propagates test counts, stdlib sizes, and validates that deprecated type
names (`Long`, `Double`, `Boolean`) don't appear in canonical docs.

Canonical Beagle type names: `Int`, `Float`, `Bool`, `String`, `Nil`, `Any`,
`Keyword`, `Symbol`. The old JVM names (`Long`, `Double`, `Boolean`) are
accepted as `#lang beagle/clj` compatibility sugar but must not appear in
docs, cheatsheets, or prompts as canonical Beagle types.

Files that define canonical facts (single source of truth):
- `private/types.rkt` → type names, PRIMITIVES list
- `private/stdlib-types.rkt` → stdlib catalog and counts
- `scribblings/beagle.scrbl` → Scribble docs (canonical form reference)
- `docs/cheatsheet.md` → LLM grounding reference
- `docs/cheatsheet-consumer.md` → consumer agent reference

## Devlog discipline

`docs/devlog/` is the scientific journal for beagle development.
Entries are written when meaningful discoveries happen — not for routine
commits. The pattern:

1. **Hypothesis** — what we expected and why
2. **Experiment** — what we ran (cite experiment ID, commit, setup)
3. **Result** — numbers, not prose
4. **Interpretation** — what this means for the project direction
5. **Next question** — what this result makes us want to test next

Keep entries concise (~30 lines). Link from `docs/devlog/README.md`.
When an experiment produces surprising or direction-changing results,
it gets a devlog entry. Routine feature additions do not.

## Reference

- `scribblings/beagle.scrbl` — Racket-native Scribble docs (build with `raco scribble --html scribblings/beagle.scrbl`).
- `docs/cheatsheet.md` — single-page LLM grounding reference (developer).
- `docs/cheatsheet-consumer.md` — 154-line consumer reference (for `beagle init`).
- `docs/devlog/README.md` — development journal (discoveries + experiments).
- `experiments/README.md` — benchmark framework for design decisions.
- `experiments/report.md` — full experiment report (E3b–E14, all tracks).
- `docs/todo.md` — roadmap and completed work.
- `docs/agent-workflow.md` — LLM agent workflow patterns.
