# beagle — session anchor

A multi-target typed authoring IR. Racket frontend with custom `#lang`,
macros (safe template + procedural with typed AST contracts; no `unsafe`
kind), static type checking; emits Clojure, ClojureScript, JavaScript,
Nix, SQL, Python, or Typed Racket source for runtime. `.bgl` is the
primary file extension (`.rkt` still accepted for backward compatibility).

**Identity vs phase.** Beagle *is* multi-target — emitters for all seven
backends exist and the abstractions are proven portable. The current
*phase* is establishing beagle as the de facto authoring language for
Nix. Surface decisions during this phase are evaluated primarily against
Nix needs; portability is a secondary constraint rather than a blocking
one. Other targets (Clojure, JS, ClojureScript, Python, SQL, Typed
Racket) are supported at the abstraction level but are not the current
focus of test-pass investment or community-adoption work. When Nix
entrenchment is real, the phase shifts; the identity doesn't.

**LLM authoring is a first-class concern.** Rich types, explicit forms,
low syntactic surface area, structured errors. One canonical idiom per
concept.

## Status

`#lang beagle` v0.14.0 — 1382 tests passing (+ oracle/differential/bun-parity via `BEAGLE_ORACLE=1`).

- **Targets:** `beagle/clj` (default), `beagle/cljs`, `beagle/js`, `beagle/nix`, `beagle/sql`, `beagle/py`, `beagle/rkt`
- **Forms:** ~78 forms — ~50 cross-target (definitions, control flow, data structures, pattern matching, threading, interop) + 28 typed JS target forms (`js/*`).
- **Types:** 9 primitives (`String`, `Int`, `Float`, `Bool`, `Keyword`, `Symbol`, `Nil`, `Any`, `NixType`), `Number` (`U Int Float`), parametric (`Vec`, `Map`, `Set`, `List`, `NixType`), union (`U`), nullable (`T?`), function types, `forall` (with optional `<:` bounds), parametric `defunion` (`(Result T E)`), `(Promise T)`
- **Stdlib:** 1830 pre-typed — portable 269, Clojure 397, CLJS 132, JS 102, Nix 523, SQL 59, Python 348
- **Type checking:** flow-sensitive narrowing, cross-module import, collection/destructuring inference, exhaustive match warnings, refinement predicates
- **Diagnostics:** Rust-style errors with signatures, "did you mean?" suggestions, JSON mode
- **Tooling:** LSP, typed REPL, reactive daemon (~100ms re-check), repair compiler, property testing, distributed tracing, `beagle init --hooks` (scaffold Claude Code integration for any project)
- **Experiments:** 15 across 3 tracks (Beagle/Clojure/Python) — best config 287s avg (E13), per-bug faster than Python+mypy

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
- `beagle-lib/private/macros.rkt` — macro registry: template macros (`safe`
  kind only; naive substitution with hygiene), procedural macros (`proc`
  kind, evaluated by host Racket; `beagle` kind, evaluated by macro-eval
  with syntax constructors and typed AST contracts). Depth-capped recursive
  expansion. `unsafe` kind rejected at registration — there is no
  escape-hatch macro shape.
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
- `beagle-lib/private/stdlib-nix.rkt` — Nix-specific: STDLIB-NIX (280 typed entries for
  builtins.*, lib.*, lib.types.*). lib.types.* values typed as NixType (opaque).
- `beagle-lib/private/emit-nix-strings.rkt` — string escaping + interp/multiline/indented
  emitters (single unified escape-nix #:multiline? #:keep-interp?).
- `beagle-lib/private/validate-nix.rkt` — schema-driven validator; user config externalized
  to .beagle-cache/validate-config.json with HM-root auto-discovery from HM schema.
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
- `beagle-lib/private/daemon.rkt` — persistent query/build server (TCP, AST cache with mtime invalidation, 45× query speedup, ~0.6s warm builds vs ~3s cold).
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

## REQUIREMENT: NEVER author escape hatches, for any reason

Beagle has **zero** escape hatches. No `unsafe-nix`, no `unsafe-js`, no
`unsafe-clj`, no `unsafe-py`, no `unsafe-rkt`, no `unsafe`, no
`define-macro unsafe`, no `''...''` raw passthrough. By design.

When you hit a gap:

1. **Missing stdlib function?** Add a one-line type signature to the
   appropriate `beagle-lib/private/stdlib-{clj,js,py,nix,rkt,portable}.rkt`.
2. **Missing surface form?** Add an AST struct + parse case + emit case.
   Same as every other form.
3. **Genuinely-untypable target snippet?** Write a sibling file in the
   target language (e.g. `foo.nix` next to `foo.bnix`) and import it.
   The filesystem boundary is auditable; an inline backdoor is not.

Do NOT propose adding `unsafe-*` back "just for one case." Every typed
language that shipped an escape hatch (TypeScript `any`, Rust `unsafe`,
Java `Object`-casting, Python `Any`-as-bailout) regretted it. The hatch
becomes the path of least resistance, untyped code rots invisibly inside
otherwise-checked files, and the type guarantee loses its meaning. The
discipline of "no escape" forces the stdlib to mature and makes
hallucinations show up as compile errors instead of shipping silently.

This rule applies to all targets, all phases, all helpers, all macros.
If you're about to write the word `unsafe` in code, stop.

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

### Delimiter rule: tools before inference

Try to use tools to debug paren issues before falling back to inference
to diagnose/count. When a delimiter issue needs diagnosing — a build fails,
the hook reports a structural error, something looks off after a large
edit — reach for the tools first:

1. `bin/beagle-syntax FILE` — instant structural check, exact line:col
2. `bin/beagle-syntax --ledger FILE` — depth trace showing where nesting diverges
3. `bin/beagle-syntax --repair --emit-patch FILE` — machine-generated fix

Apply the patch or use the ledger to make a targeted edit. If `--emit-patch`
gives the wrong fix, use `--ledger` output to identify the exact line, then
edit that line.

This applies to **all beagle-family files** (`.bgl`, `.bjs`, `.bclj`, `.bcljs`,
`.bnix`, `.bsql`, `.bpy`) **in any repo** — including heist, beagle-lab, etc.
For cross-repo files, use the full path: `~/code/beagle/bin/beagle-syntax FILE`.

### After every edit (automatic)

The PostToolUse hook fires on Edit/Write to any beagle file
(`.bgl`, `.bclj`, `.bcljs`, `.bjs`, `.bnix`, `.bsql`, `.bpy`, `.rkt`).

If it reports a syntax error, fix delimiters using the sequence above — do
not type-check or inspect deeper errors until delimiters pass.

- `bin/beagle-syntax FILE` — structural check (use `--ledger` for depth trace, `--repair --emit-patch` for suggested fixes)
- `bin/beagle-daemon query check-enriched FILE` — type errors with field context and fix hints
- `bin/beagle-daemon query build OUT-DIR SRC-DIR` — warm build (~0.6s vs ~3s cold beagle-build-all)
- `bin/beagle-fix .` — report fixable type errors (advisory only, does not modify files)

### During normal development

- `bin/beagle-check SOURCE` / `bin/beagle-check-all DIR...`
- `bin/beagle-build SOURCE` / `bin/beagle-build-all DIR...`
- `bin/beagle-expand SOURCE` — show macro expansion
- `bin/beagle-test` — **tiered** test runner (active blocks, demoted advisory).
  Use this, NOT `raco test beagle-test/tests/` directly — `raco test` bypasses
  tier logic and will block iteration on demoted-tier failures that shouldn't
  block. Local default: active-only (fast loop). CI runs the full suite (sets
  `CI=true`). Local opt-in to full suite: `BEAGLE_FULL_SUITE=1 bin/beagle-test`
  or `--full` flag. Tier classification in `beagle-test/tiers.rktd`; demoted
  failures logged to `lab/surface-debt.md` for batch reconciliation.

### Tiering discipline during surface iteration

**Thoroughness-redirection rule.** When working on a surface drop or change:
the "be thorough, fix everything" instinct is correct — but it goes to
**active-tier code + debt-file entries**, never to **demoted-tier code**
during iteration.

- Active-tier failures from surface changes: **fix**. The build is blocked
  until they pass.
- Demoted-tier failures from surface changes: **log to `lab/surface-debt.md`**
  with a "Was checking" entry describing what the failing test verified.
  Do NOT edit the demoted test file to fix it. The tiering exists
  precisely so demoted-tier maintenance doesn't slow surface iteration.

Why this matters: each demoted fix feels cheap (small mechanical migration).
Accumulated across drops, the cost is the full cross-target test-update tax
that the tiering was built to eliminate. The reflexive "this fix is small,
just do it" is the workflow analog of "this form is small, just add it" —
locally-justified, globally-expensive. Same asymmetric-burden lens applies.

Workflow per surface drop:
1. Make the active-tier change (parse, check, structural emit).
2. Run `bin/beagle-test`.
3. Active failures: fix until green.
4. Demoted failures: open `lab/surface-debt.md`, append entry with
   per-failure "Was checking" detail, update the `## Total debt:` counter.
5. Commit. Move on.

What counts as a "demoted-tier file" right now (per `beagle-test/tiers.rktd`):
- `emit-clj-behavioral.rkt`
- `emit-js-behavioral.rkt`

When you find yourself opening one of those to edit during a surface drop,
stop. The fix goes to `surface-debt.md`, not the file.

Corpus migrations (fixtures in `beagle-test/tests/fixtures/`, `oracle/fixtures/`,
`examples/`) are not test code — they are test INPUTS. They MUST be migrated
when surface changes break them; the tiering discipline doesn't apply.

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

## Lint warnings

Beagle prints lint warnings to stderr during compile (strict mode only):

- `untyped def NAME` — `(def x 42)` without type annotation
- `defn NAME has no return type annotation` — missing `: Ret`
- `defn NAME has untyped parameter(s): ...` — missing `(name : Type)`
- `let binding X shadows outer binding` — let/fn rebinds a name from enclosing scope
- `unused declare-extern: X` — extern declared but never referenced

Suppress with `BEAGLE_NO_LINT=1`. Warnings don't fail compile. Dynamic
mode skips lint (types are optional there by definition).

The historical `(unsafe-{js,clj,py,nix,rkt} "...") inline escape` lint
is gone — those forms are parse-time errors, not warnings.

## Design decisions

### The dominant principle: consistency compounds, ergonomic savings don't

A surface form earns its place by being **part of a system** —
reinforcing patterns that show up elsewhere in beagle. Forms that
exist for local ergonomic savings, with no broader pattern they
reinforce, are net-negative even when they save characters at
authoring time.

The test for every form: **does this make the rest of the surface
more predictable, or is it a separate fact to memorize?**

If it makes the surface more predictable: keep / add (pattern-extending).
If it's a separate fact: drop / reject (pattern-isolated), regardless
of Clojure-precedent, character-savings, training-data reflex, or
corpus-usage statistics.

Full rationale: `lab/journal/synthesis/design-principle.md`. This is
the load-bearing reference for any future surface decision.

### Confident (committed, well-reasoned)

| decision | reasoning |
|---|---|
| s-expressions, AST-based | non-negotiable foundation |
| Custom reader preserves `[]` vs `()` | Clojure cares (vectors); beagle needs to know |
| `(ns ...)` for namespace | universal Clojure idiom, in LLM training data |
| Wrapped `(x : T)` not inline | unambiguous parse, no lookahead, AI-friendly |
| Stdlib extern catalog | biggest single leverage point for AI type-safety |
| Template macros are always type-checked end-to-end | The expansion is parsed as beagle source and runs through the checker like any other expression — no escape-hatch shape exists. (Pre-2026-05 had `safe` vs `unsafe` kinds; `unsafe` was dropped.) |
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
- **`@deref`, `#'var-quote`** — Clojure-runtime concepts; not needed
- **Exotic reader macros (`#=`, `#_`, `#?`)** — Clojure-reader-specific

### Dropped (surface redesign, 2026-05)

Forms removed because they were sugar/redundant or had ~zero real
usage. See `lab/journal/log/024-surface-friction-observation.md` for
the empirical basis and `lab/journal/log/027-night-audit.md` for the
deferred-items audit.

- **`defmulti` / `defmethod`** — value-dispatch alternative to `match`;
  no broader pattern. Use `defprotocol` + `extend-type` (type dispatch)
  or `match` (value dispatch).
- **`deftype`** — bundled `defrecord` + protocol impls into one form.
  Two distinct concepts: use `(defrecord Name [fields])` for the data
  shape and `(extend-type Name Protocol (method ...))` for the protocol
  attachment.
- **`->`** — first-arg threading. Positional convenience, not semantic
  uniqueness. Use `->>` or a let-chain.
- **`as->` / `cond->` / `cond->>` / `some->` / `some->>`** — compositions
  of threading + conditional / threading + nil-check. Use let-chains.
- **`when`** — sugar over `(if c body)` (single-body) or `(if c (do …))`
  (multi-body). The if-no-else form returns nil when condition is false.
- **`when-not` / `if-not`** — sugar. Use `(if (not c) …)`.
- **`when-some` / `if-some`** — superseded by the broader nil-semantics
  decision; the typed nullable-narrowing form is pending design.
  Interim: `(let [x v] (if x then else))`.
- **`when-let` / `if-let`** — Clojure-shaped truthy-binding sugar; carries
  semantics the typed nullable-narrowing form should not inherit. Interim:
  `(let [x v] (if x then else))`. Do not reintroduce these names when the
  typed form lands.
- **`dotimes`** — sugar over `(doseq [i (range n)] body…)`.
- **`case`** — folded into `match` with the `or` pattern extension
  (`(match x [(or 1 2) "small"] [_ "big"])`). The case-fold optimization
  in emit-clj/emit-rkt lowers literal-only or-patterns to target-native
  `case` so the migration ships no perf regression.
- **`(:keyword target)`** — keyword-as-fn on maps overloaded one shape for
  two concepts (record field access vs map keyed lookup). Records use the
  typed auto-accessor `(field-name r)`; maps use `(get m :key)`. JS interop
  property access `(.-field obj)` is a separate concept and stays.
- **`inc` / `dec`** — sugar. Use `(+ x 1)` / `(- x 1)`.
- **`not=`** — sugar. Use `(not (= a b))`.
- **`deferror`** — unified into `(defunion :throwable Name ...)`.
  Same structural shape; throwable is now a keyword on defunion.
- **`unsafe` macro kind** — escape hatch on the macro shape; rejected at
  registration. Template macros are always type-checked end-to-end via
  the only remaining kind, `safe`.

Kept after empirical re-evaluation (Day 0 friction-list verdict
reversed): `loop`/`recur` (agent reflexively reaches for it — that's
the canonical signal), `->Name` constructor (beagle has no `(Name ...)`
alternative; no redundancy to drop), `->>` (canonical threading; sits
alone in its concept space, low corpus count reflects let-chain-heavy
style not redundancy), `cond` (sequential independent-predicate
dispatch — distinct concept from `match`'s pattern-against-target
dispatch), `do` (multi-expression sequencing, useful even after `when`
drop — see `lab/journal/log/issue-86-do-form-audit.md`).

Audited and confirmed as distinct concepts (not redundancy):
- **`nth` vs `get`** — `nth` is positional-int into vector; `get` is
  keyed lookup on map. Same predictability test as `cond` vs `match`.
- **`for` vs `doseq` vs `map`/`filter`/`reduce`** — collection
  comprehension that yields vs side-effect iteration that returns nil
  vs higher-order function calls. Three concepts, three forms.
- **Record field access** — `(field-name r)` for records,
  `(get m :key)` for maps, `(.-field obj)` for JS interop. Three
  concepts (post `(:foo m)` drop), not redundancy.

## Setup (one-time)

```
raco pkg install --link beagle-lib/ beagle-test/ beagle/
```

## Reference

The hand-written form-reference manual was deleted 2026-05-25 — it was
drifting from the moving surface faster than it could be maintained.
The compiler is the source of truth for everything mechanical.

For mechanical questions ("what forms exist?", "what's the signature of X?",
"what fields does R have?"):
- `bin/beagle-sig NAME FILE...` — typed signature lookup
- `bin/beagle-fields RECORD FILE...` — record fields, types, accessors
- `bin/beagle-provides FILE...` — module exports
- `bin/beagle-callers NAME FILE...` — call sites
- Or read `beagle-lib/private/parse.rkt` for the form set, `stdlib-*.rkt` for the typed extern catalog

For non-mechanical questions ("why does the surface look this way?",
"what was dropped and why?"):
- `README.md` — what beagle is, the five principles, the lock-in discipline
- `lab/journal/synthesis/design-principle.md` — long-form principles + audit-endpoint discipline
- `lab/journal/log/` — chronological audit notes (logs 024-027 cover the 2026-05 redesign)
- `lab/plans/` — workstream plans (active + done, with frontmatter status)
- `lab/experiments/` — experiment archive (mirrors `~/code/beagle-lab/`)
- `~/code/beagle-lab/` — full experiment results (E0–E22+)
- `~/code/beagle-lab/` — historical experiment archive (E0–E22, benchmark framework, results)
