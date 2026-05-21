# 021 — Procedural macros with typed AST contracts

**Date:** 2026-05-21

**Update:** `define-macro beagle` now evaluates macro bodies as Beagle using syntax constructors (`make-defrecord`, `make-defn`, etc.) — no Racket context-switch. See `beagle-doc/scribblings/macros.scrbl` for current reference. The `define-macro proc` examples below are historical.

## The discovery

Beagle's transpiler architecture — one synchronous pass through its
own AST — accidentally makes typed macro contracts possible. In Typed
Racket, macros expand before types run; there's a phase boundary.
Beagle has no phase boundary. Macros expand during parse, the checker
sees the expansion output, same pipeline as hand-written code.

The thing everyone (including us) treated as the less prestigious
choice — building a transpiler instead of a "real" compiler — is the
structural reason this works. A separate macro expansion phase would
have the same blind spot as everyone else.

## What was built

Procedural macros with typed AST contracts. Three new concepts:

**1. `define-macro proc` — compile-time Racket functions**

```
(define-macro proc gen-getter
  [(rec : Symbol) (field : Symbol)] : Form
  `(defn ,(string->symbol (format "get-~a" field))
     ((obj : ,rec)) : Any
     (get obj ,(sym->kw field))))
```

The body is Racket code. It receives raw datums, returns a datum.
The datum goes through full parse → check → emit. No `unsafe-expr`
wrapping — the output is validated like any other code.

**2. Input/output contracts**

Params use Beagle's annotation syntax: `[(name : Symbol)]`. The
contract is checked before the body runs (inputs) and after it
returns (output). Contract types: `Symbol`, `String`, `Int`, `Bool`,
`Keyword`, `Expr`, `Form`, `Syntax` (any), `(Vec T)`.

Bad input → clear error: `macro gen-getter: arg rec: expected Symbol, got 42`
Bad output → clear error: `macro gen-getter: output: expected Form, got 42`
Body exception → wrapped: `macro gen-getter: body raised an error: ...`

**3. `(Vec Form)` top-level splice**

Proc macros with output type `(Vec Form)` produce multiple top-level
forms, spliced into the program. No `do`-wrapping limitation.

```
(define-macro proc defentity
  [(name : Symbol) (fields : (Vec Syntax))] : (Vec Form)
  ;; returns list of (defrecord ...) + (defn ...) forms
  ...)

(defentity User ((name : String) (age : Int) (active : Bool)))
;; expands to: defrecord + 3 typed getter defns, all top-level
```

## Implementation

| Component | Lines changed | What |
|-----------|:---:|---|
| `macros.rkt` | +120 | `proc-macro-def` struct, `compile-proc-body` (eval in sandbox ns), contract checker, `expand-proc-macro` |
| `parse.rkt` | +25 | Pass 1 recognizes `define-macro proc`, pass 2 splices `#%splice-forms` |
| `check.rkt` | 0 | Expansion output goes through normal checking |
| `emit-*.rkt` | 0 | Expansion output goes through normal emission |
| `ast.rkt` | 0 | No new AST nodes |

The proc macro body is `eval`'d at registration time in a sandbox
namespace with `racket/base`, `racket/list`, `racket/string`,
`racket/format`, plus Beagle helpers: `br` (bracket tag), `mp`
(map tag), `st` (set tag), `sym->kw` (symbol→keyword).

`strip-reader-tags` converts Beagle reader artifacts (`#%brackets`,
`#%map`, `#%set`) to bare lists for Racket eval, preserving `quote`
forms so macro authors can reference tag symbols.

## Test results

7 new parse tests (basic expansion, quasiquote, Vec splice, input
contract rejection, output contract rejection, body error message,
typed expansion). 1221 total tests passing.

Two integration fixtures:
- `proc-macro-basic.bgl` → Clojure, runs in Babashka
- `proc-macro-gen.bgl` → generates typed getters from record+field,
  runs in Babashka, output correct
- `proc-macro-crud.bgl` → `defentity` macro generates defrecord +
  accessors from a spec (5 lines → 15 lines of typed code),
  runs in Babashka, output correct

## Why this matters for agents

The macro body is Racket. Full `for/list`, `map`, `format`,
`string->symbol`, quasiquote. An agent that can write Racket
functions can write procedural macros. The feedback loop:

1. Write macro
2. `beagle-expand` shows expansion
3. `beagle-check` validates the expansion's types
4. Iterate

The checker validates the expansion output through the same pipeline
as hand-written code. Contract violations are caught at the macro
boundary with the macro's name, not as inscrutable downstream errors.

No other Lisp in the LLM-authoring space does typed macro contracts.
`defmacro` is table stakes. Contracts that catch malformed expansions
at define-time — using the same type vocabulary agents already know —
that's the moat.

## Experiment: E18 — procedural macro compression

### Question

How much code can a procedural macro compress compared to (a) no
macros, (b) template macros, (c) the equivalent higher-order function?

### Setup

3-4 real patterns where structural repetition exists:

1. **CRUD scaffold.** defrecord + constructor + accessors + validator
2. **State machine.** states + transitions → match arms + transition fns
3. **API client.** endpoint specs → typed request functions
4. **Test battery.** function + property specs → property tests

### Success criteria

Proc macros must compress **>3× vs hand-written** on at least 2/4
patterns, AND **>1.5× vs template macros** where both apply. If HOF
matches proc macro compression on all patterns, the macro system
isn't pulling its weight.

## Next question

Can an agent reliably *write* procedural macros that type-check on
first expansion? E18 measures the compression ceiling (human-written
macros). E19 measures whether agents can reach it.
