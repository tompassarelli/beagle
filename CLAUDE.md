# beagle — session anchor

A multi-target authoring IR. Racket frontend with custom `#lang`, macros
(safe/unsafe/procedural with typed AST contracts), static type checking;
emits Clojure, ClojureScript, JavaScript, Nix, SQL, Python, or Typed Racket
source for runtime. `.bgl` is the primary file extension (`.rkt` still
accepted for backward compatibility).

**LLM authoring is a first-class concern.** Rich types, explicit forms, low
syntactic surface area, structured errors. One canonical idiom per concept.

**Quick reference:** `docs/cheatsheet.md` is the single-page language
summary designed to be loaded as system context for LLM workflows. Treat
it as canonical when explaining the language.


## Status

`#lang beagle` v0.12.0 — 1221 tests passing (+ 53 oracle/differential via `BEAGLE_ORACLE=1`).

- **Targets:** `beagle/clj` (default), `beagle/cljs`, `beagle/js`, `beagle/nix`, `beagle/sql`, `beagle/py`, `beagle/rkt`
- **Forms:** ~78 forms — ~50 cross-target (definitions, control flow, data structures, pattern matching, threading, interop) + 28 typed JS target forms (`js/*`). See `docs/cheatsheet.md` for the full catalog.
- **Types:** 8 primitives (`String`, `Int`, `Float`, `Bool`, `Keyword`, `Symbol`, `Nil`, `Any`), `Number` (`U Int Float`), parametric (`Vec`, `Map`, `Set`, `List`), union (`U`), nullable (`T?`), function types, `forall` (with optional `<:` bounds), parametric `defunion` (`(Result T E)`), `(Promise T)`
- **Stdlib:** ~696 entries total — portable (269), Clojure (352), CLJS (75), JS (38 native), Nix (120), SQL (43), Python (131)
- **Type checking:** flow-sensitive narrowing, cross-module import, collection/destructuring inference, exhaustive match warnings, refinement predicates
- **Diagnostics:** Rust-style errors with signatures, "did you mean?" suggestions, JSON mode
- **Tooling:** LSP, typed REPL, reactive daemon (~100ms re-check), repair compiler, property testing, distributed tracing, `beagle init --hooks` (scaffold Claude Code integration for any project)
- **Experiments:** 15 across 3 tracks (Beagle/Clojure/Python) — best config 287s avg (E13), per-bug faster than Python+mypy

See `docs/cheatsheet.md` for the full language reference.

## Architecture

```
parse → check → emit-dispatch → emit-{clj,js,nix,py,rkt,sql}
(all expand-time, inside our custom #%module-begin)
```

- `beagle-lib/lang/reader.rkt` — custom reader preserving `[]` vs `()` via
  `#%brackets` tag. Intercepts `{}` (map literals), `#{}` (set literals),
  `#"..."` (regex) via `MAP-TAG`/`SET-TAG`/`#%regex`.
- `beagle-lib/lang/reader-impl.rkt` — shared reader logic for all `#lang beagle/*` variants.
- `beagle-lib/private/types.rkt` — type AST, parser, compatibility checker.
  `MAP-TAG`/`SET-TAG` are well-known symbols (`#%map`/`#%set`), not gensyms.
- `beagle-lib/private/stdlib-types.rkt` — combined stdlib catalog; delegates to
  `private/stdlib-portable.rkt` (256 entries), `private/stdlib-clj.rkt` (365),
  `private/stdlib-cljs.rkt` (75).
- `beagle-lib/private/macros.rkt` — macro registry: template macros (safe/unsafe,
  naive substitution with hygiene), procedural macros (`beagle` kind, evaluated by
  macro-eval with syntax constructors and typed AST contracts). Depth-capped recursive expansion.
- `beagle-lib/private/macro-eval.rkt` — compile-time Beagle interpreter for
  `define-macro beagle` bodies. Datum-based evaluator (let, fn, if, cond, calls),
  closure support, built-in env with list/string ops + syntax constructors
  (make-defrecord, make-defn, make-param, syntax-name, syntax-type, etc.).
- `beagle-lib/private/ast.rkt` — 144 AST struct definitions, shared utilities
  (tag helpers, symbol predicates, source location tracking), parse injection
  parameters (`current-parse-expr`, `current-parse-params`).
- `beagle-lib/private/parse.rkt` — source → AST. Two passes: meta-form collection
  (mode, ns, macros, externs, requires, imports) then expr parsing with
  macro expansion. Delegates to target-specific parse modules.
- `beagle-lib/private/parse-jst.rkt` — typed JS target (`js/*`) parse helpers.
- `beagle-lib/private/parse-js-quote.rkt` — JS/quote AST parse helpers.
- `beagle-lib/private/parse-sql.rkt` — SQL-specific parse helpers.
- `beagle-lib/private/check.rkt` — best-effort type checking against annotations and
  the built-in env. Record field registry for keyword-access type inference.
  Skipped in dynamic mode. Includes `jst-*` type inference + JS target gating.
- `beagle-lib/private/emit-dispatch.rkt` — dispatches to `emit-clj.rkt`, `emit-js.rkt`,
  `emit-nix.rkt`, `emit-py.rkt`, or `emit-rkt.rkt` based on `(program-target prog)`.
- `beagle-lib/private/emit-clj.rkt` — AST → Clojure/ClojureScript source string (was `emit.rkt`).
- `beagle-lib/private/emit-js.rkt` — AST → JavaScript source string. Delegates to
  target-specific emission modules.
- `beagle-lib/private/js-emit-utils.rkt` — shared JS emission utilities (name mangling,
  escaping, `current-emit-expr` parameter).
- `beagle-lib/private/emit-jst.rkt` — typed JS target (`jst-*`) emission helpers.
- `beagle-lib/private/emit-js-quote.rkt` — JS/quote AST rendering.
- `beagle-lib/private/emit-py.rkt` — AST → Python source string (dataclasses, match/case, snake_case).
- `beagle-lib/private/emit-rkt.rkt` — AST → Typed Racket source string. Also serves as oracle:
  `raco make` on output independently validates Beagle's type promises.
- `beagle-lib/private/emit-nix.rkt` — AST → Nix source string (curried fns, attrsets, let/in).
- `beagle-lib/private/js-capabilities.rkt` — JS capability sets (JS-TRANSLATED, JS-VALUE-WRAPPERS,
  JS-RUNTIME-HELPERS). Imported by both emit-js and stdlib-js — no circular deps.
- `beagle-lib/private/stdlib-js.rkt` — JS-specific: STDLIB-JS (38 JS-native type declarations),
  JS-NO-EMIT (computed from STDLIB-PORTABLE minus JS-TRANSLATED).
- `beagle-lib/private/stdlib-nix.rkt` — Nix-specific: STDLIB-NIX (120 typed entries for
  builtins.*, lib.*, lib.types.*).
- `beagle-lib/private/stdlib-py.rkt` — Python-specific: STDLIB-PY (131 typed entries for
  builtins, os.path, json, math, re, functools, itertools, collections, dataclasses).
- `beagle-lib/lib/beagle/core.js` — JS runtime helpers (12 finite functions: range, remove,
  mapcat, etc.). Auto-imported when referenced.
- `beagle-lib/nix/main.rkt` — Nix target module (`#lang beagle/nix` → `define-target nix`).
- `beagle-lib/nix/lang/reader.rkt` — reader hook for `#lang beagle/nix`.
- `beagle-lib/py/main.rkt` — Python target module (`#lang beagle/py` → `define-target py`).
- `beagle-lib/py/lang/reader.rkt` — reader hook for `#lang beagle/py`.
- `beagle-lib/rkt/main.rkt` — Racket target module (`#lang beagle/rkt` → `define-target rkt`).
- `beagle-lib/rkt/lang/reader.rkt` — reader hook for `#lang beagle/rkt`.
- `oracle/bin/check-oracle` — oracle check script: emit → raco make → classify.
- `oracle/MAPPING.md` — Beagle → Typed Racket type correspondence table.
- `beagle-lib/private/expand-tool.rkt` — backend for `bin/beagle-expand`.
- `beagle-lib/private/query.rkt` — type-system query engine for `beagle-sig`,
  `beagle-fields`, `beagle-callers`, `beagle-provides`, `beagle-impact`.
- `beagle-lib/private/blame.rkt` — semantic property rules + static suspicion analysis.
- `beagle-lib/private/daemon.rkt` — persistent query server (TCP, AST cache with mtime invalidation, 45× query speedup).
- `beagle-lib/private/check-all.rkt` — batch type-checker (10x vs sequential `beagle-check`).
- `beagle-lib/private/build-all.rkt` — batch compiler (9x vs sequential `beagle-build`).
- `beagle-lib/private/lsp.rkt` — LSP server (JSON-RPC 2.0, Content-Length framing, hover/diagnostics/symbols/definition).
- `beagle-lib/private/repl.rkt` — typed REPL with persistent environment (parse → check → emit per input).
- `beagle-lib/lib/beagle/dtrace.clj` — distributed tracing runtime (Clojure/Babashka): span lifecycle, context propagation, Ring middleware, file/TCP exporters.
- `beagle-lib/main.rkt` — language module; `#%module-begin` runs the pipeline,
  embeds resulting string, runtime `(display)`s it.

## Adding a new form (the pattern)

1. **Struct** in `ast.rkt` — new AST node (add to provide list)
2. **Parse case** in `parse-list-form` (in `parse.rkt`) — pattern-match the source
3. **Emit case** in `emit-clj.rkt` AND `emit-js.rkt` — produce target source
4. **Infer case** in `infer-expr` — return type (or `ANY`)
5. **Lint traversal** in `lint.rkt` — `check-shadow` and `collect-symbols`
6. **Provide** the struct in ast.rkt's provide list
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

## Session start

1. Confirm daemon: `bin/beagle-daemon status` — start with `bin/beagle-daemon start --watch .` if not running
2. The daemon auto-starts via the PostToolUse hook, but confirming at session start avoids cold-start delay on first edit

## Agent loop

1. After edits, trust hook output. Fix syntax errors before type errors.
2. Use query tools (`sig`, `fields`, `callers`, `provides`) before opening large files.
3. Use `--emit-patch` tools before manual repair.
4. Escalate to `trace`/`blame`/`cascade` only when stuck.

### After every edit (automatic)

The PostToolUse hook fires on Edit/Write to any beagle file
(`.bgl`, `.bclj`, `.bcljs`, `.bjs`, `.bnix`, `.bsql`, `.bpy`, `.rkt`).

If it reports a syntax error, fix delimiters first — do not type-check
or inspect deeper errors until delimiters pass.

- `bin/beagle-syntax FILE` — structural check (use `--ledger` for depth trace, `--repair --emit-patch` for suggested fixes)
- `bin/beagle-daemon query check-enriched FILE` — type errors with field context and fix hints
- `bin/beagle-fix .` — report fixable type errors (advisory only, does not modify files)

### During normal development

- `bin/beagle-check SOURCE` / `bin/beagle-check-all DIR...`
- `bin/beagle-build SOURCE` / `bin/beagle-build-all DIR...`
- `bin/beagle-expand SOURCE` — show macro expansion
- `raco test tests/`

### When navigating — prefer query tools over grep

- `bin/beagle-sig NAME FILE...` — typed signature
- `bin/beagle-fields RECORD FILE...` — fields, types, accessors
- `bin/beagle-callers NAME FILE...` — call sites
- `bin/beagle-provides FILE...` — module exports
- `bin/beagle-impact NAME FILE...` — callers + change impact

### When stuck — after ordinary checks fail

- `bin/beagle-repair ... --emit-patch`
- `bin/beagle-trace ... --focus FN`
- `bin/beagle-cascade ... --from-failures`
- `bin/beagle-blame ...`
- `bin/beagle-specfix ...`

Full tool reference with all flags: `docs/tool-reference.md`

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
| P2 checker profile default | E16-T experiments: P2 (exhaustive match, narrowing) is the sweet spot for agent-assisted dev. P3 effects add no measured value; P1 false positives actively hurt (3.4× slower). Types help agents build features (reasoning scaffold) not find bugs (tests win). See beagle-lab `e16-workflow-scheduler/results/type/RESULTS.md` |
| Multi-target IR, not Clojure transpiler | same typed AST emits to Clojure, CLJS, JS, Nix (Python plumbed); target from `#lang` |
| Subset-of-Clojure, not full mimic | take Lisp universals + Clojure's good ideas; develop own for typed semantics |
| `:` as only annotation marker | `:-` removed; no measured benefit in 6-variant benchmark |
| Wrapped params only | inline removed; no measured benefit, less unambiguous parse |
| No user type aliases | `Number` is the only built-in alias (`U Int Float`); prefer `Int`/`Float` when the concrete type is known |

### Cargo-cult — deliberately NOT added

Host-language idioms whose cost > benefit for beagle's goals:

- **`#(...)` anonymous fn shorthand** — alternate idiom for `fn`, more
  LLM confusion than value
- **`@deref`, `#'var-quote`** — Clojure-runtime concepts; use `unsafe`
- **Exotic reader macros (`#=`, `#_`, `#?`)** — Clojure-reader-specific

## Setup (one-time)

```
raco pkg install --link beagle-lib/ beagle-test/ beagle-doc/ beagle/
```

## Doc maintenance

**Scribble is the single source of truth for the language reference.**
Edit `beagle-doc/scribblings/*.scrbl`, then run `bin/beagle-docs-sync --verbose`
to regenerate cheatsheets and propagate counts.

- `bin/beagle-gen-cheatsheet` — regenerates `docs/cheatsheet.md` and
  `docs/cheatsheet-consumer.md` from Scribble docs
- `bin/beagle-docs-sync` — runs the generator, then propagates test counts,
  stdlib sizes, and validates type name consistency

Canonical Beagle type names: `Int`, `Float`, `Bool`, `String`, `Nil`, `Any`,
`Keyword`, `Symbol`. The old JVM names (`Long`, `Double`, `Boolean`) are
accepted as `#lang beagle/clj` compatibility sugar but must not appear in
docs, cheatsheets, or prompts as canonical Beagle types.

Files that define canonical facts (single source of truth):
- `private/types.rkt` → type names, PRIMITIVES list
- `private/stdlib-types.rkt` → stdlib catalog and counts
- `beagle-doc/scribblings/*.scrbl` → Scribble docs (canonical form reference, generates cheatsheets)
- `docs/cheatsheet.md` → generated LLM grounding reference
- `docs/cheatsheet-consumer.md` → generated consumer agent reference

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

Experiment tasks, results, and data live in `~/code/beagle-lab/` (separate
repo). Devlog entries here summarize findings and link to beagle-lab for
full methodology. When running a new experiment, create its directory in
beagle-lab (e.g. `e23-foo/`), work there, then write the devlog entry here.

## Reference

- `scribblings/beagle.scrbl` — Racket-native Scribble docs (build with `raco scribble --html scribblings/beagle.scrbl`).
- `docs/cheatsheet.md` — single-page LLM grounding reference (developer).
- `docs/cheatsheet-consumer.md` — 154-line consumer reference (for `beagle init`).
- `docs/devlog/README.md` — development journal (discoveries + experiments).
- `~/code/beagle-lab/` — experiment archive (E0–E22, benchmark framework, all results).
- `docs/todo.md` — roadmap and completed work.
- `docs/agent-workflow.md` — LLM agent workflow patterns.
