# Beagle Stdlib and Per-Target Feature Organization

Report generated from codebase analysis of `private/stdlib-portable.rkt`,
`private/stdlib-clj.rkt`, `private/stdlib-cljs.rkt`, `private/stdlib-types.rkt`,
`private/emit-js.rkt`, `private/emit-clj.rkt`, `private/types.rkt`, and
`private/parse.rkt`.

---

## 1. Architecture

### Stdlib split

The stdlib is split across three files, each a disjoint `(hash ...)` with zero
overlap between them (confirmed by set-intersection checks):

| File | Variable | Scope |
|---|---|---|
| `stdlib-portable.rkt` | `STDLIB-PORTABLE` | Universal concepts—all targets |
| `stdlib-clj.rkt` | `STDLIB-CLJ` | JVM/Clojure-only: Java interop, STM, JVM types |
| `stdlib-cljs.rkt` | `STDLIB-CLJS` | ClojureScript/JS interop: `js/...` globals, DOM |

### Combination logic (`stdlib-for-target`)

`stdlib-types.rkt` defines one pre-merged hash and a dispatch function:

```racket
(define stdlib-clj-combined
  (merge-hashes STDLIB-PORTABLE STDLIB-CLJ STDLIB-CLJS))  ; all three

(define (stdlib-for-target target)
  (case target
    [(clj cljs) stdlib-clj-combined]   ; 696 entries, with CLJ-EXCLUDE warning for cljs
    [(js)       STDLIB-PORTABLE]       ; 269 entries only
    [(py)       STDLIB-PORTABLE]       ; 269 entries only
    [else ...]))
```

`target-excludes-for` returns `CLJ-EXCLUDE` (a set of 131 symbols) for the
`cljs` target and `#f` for all others. The checker calls `warn-target-exclude`
on every call site—this is a **warning only**, not a type error. JVM-only calls
in CLJS code still pass type checking; they just emit a stderr warning.

The JS and Python targets receive only `STDLIB-PORTABLE`. There is no
`target-excludes-for` set for these targets, meaning the type checker has no
mechanism to warn when a portable entry with no JS translation is called.

---

## 2. Entry Counts

| Hash | Count | Notes |
|---|---|---|
| `STDLIB-PORTABLE` | **269** | Disjoint from CLJ and CLJS |
| `STDLIB-CLJ` | **352** | Disjoint from PORTABLE and CLJS |
| `STDLIB-CLJS` | **75** | Disjoint from PORTABLE and CLJ |
| CLJ combined (`clj`/`cljs`) | **696** | All three merged |
| `CLJ-EXCLUDE` (warning set for cljs) | **131** | JVM-only, suppressed in CLJS |
| JS target stdlib | **269** | PORTABLE only |
| Python target stdlib | **269** | PORTABLE only |

The three source hashes are fully disjoint (no key appears in more than one).
The CLJ combined total is exactly 269 + 352 + 75 = 696.

---

## 3. JS `emit-core-call` Coverage

`emit-core-call` in `emit-js.rkt` (lines 42–269) is a `case` dispatch on the
function symbol that produces JS-specific translation strings. When it returns
`#f`, the call falls through to a generic `fnName(args)` emission using the
Beagle identifier mangling rules (hyphens → underscores, `?` → `_p`,
`!` → `_bang`).

Additionally, two pre-dispatch tables handle operators before `emit-core-call`
is reached:

- **`JS-INFIX-OPS`** (11 entries): `+`, `-`, `*`, `/`, `<`, `>`, `<=`, `>=`,
  `=` (→ `===`), `not=` (→ `!==`), `==` (→ `===`), `mod` (→ `%`),
  `identical?` (→ `===`). Arity requirement: ≥ 2 args.
- **`JS-UNARY-OPS`** (1 entry): `not` (→ `!`). Arity requirement: 1 arg.

### `emit-core-call` function list (108 case arms)

**I/O (4):** `str`, `println`, `print`, `pr`/`prn` (grouped)

**Predicates — null/boolean (7):** `nil?`, `some?`, `true?`, `false?`,
`zero?`, `pos?`, `neg?`

**Predicates — numeric (2):** `even?`, `odd?`

**Predicates — type (9):** `string?`, `number?`, `keyword?`, `fn?`,
`integer?`, `vector?`, `map?`, `set?`, `coll?`, `sequential?`, `seq?`

**Predicates — collection (2):** `empty?`, `not-empty`

**Collection access (9):** `count`, `first`, `second`, `last`, `rest`,
`nth`, `get`, `peek`, `pop`

**Collection construction (5):** `conj`, `vec`, `set`, `into`, `concat`

**Collection transformation (14):** `assoc`, `dissoc`, `update`, `merge`,
`keys`, `vals`, `contains?`, `map`, `mapv`, `filter`, `filterv`, `reduce`,
`reverse`, `sort`, `sort-by`

**Collection slicing (7):** `subvec`, `take`, `drop`, `take-last`,
`drop-last`, `partition`, `subvec`

**Collection higher-order (6):** `some`, `distinct`, `flatten`, `interleave`,
`frequencies`, `group-by`

**Math (6):** `inc`, `dec`, `abs`, `max`, `min`, `rand`, `rand-int`

**Logic (2):** `and`, `or`

**String (3):** `name`, `keyword`, `subs`

**Regex (1):** `re-find`

**Error/control (3):** `throw`, `ex-info`, `ex-message`, `ex-data`

**Atom operations (5):** `atom`, `deref`, `reset!`, `swap!`, `add-watch`,
`remove-watch`

**Array ops (3):** `aget`, `aset`, `to-array`, `array-seq`

**Function combinators (6):** `comp`, `partial`, `constantly`, `complement`,
`juxt`, `identity`

**Misc (5):** `pr-str`, `seq`, `boolean`, `not=`, `clj->js`, `js->clj`

**Total: 108 distinct case arms** covering approximately 112 function names
(a few arms match multiple symbols, e.g., `pr`/`prn`).

### Portable entries with NO JS translation

Of the 269 STDLIB-PORTABLE entries, approximately **151** have no
`emit-core-call` case and are not infix/unary operators. These fall through to
generic `fnName(args)` emission. At runtime in a JS environment, this call will
fail unless a global function with the mangled name happens to exist. The
checker does not warn about this.

Selected high-impact examples without JS translation:

| Category | Functions |
|---|---|
| Collection | `next`, `cons`, `ffirst`, `nfirst`, `fnext`, `nnext`, `butlast`, `find`, `key`, `val`, `list?` |
| Higher-order | `remove`, `mapcat`, `every?`, `keep`, `keep-indexed`, `map-indexed`, `run!`, `fnil`, `memoize`, `reductions`, `trampoline` |
| Collection construction | `vector`, `list`, `hash-map`, `hash-set`, `sorted-map` |
| Sequence generation | `range`, `repeat`, `iterate`, `cycle`, `interpose`, `repeatedly`, `take-while`, `drop-while` |
| Sequence transformation | `partition-by`, `partition-all`, `split-at`, `split-with`, `dedupe`, `replace`, `interleave` (3-arg) |
| Map/set ops | `assoc-in`, `update-in`, `update-keys`, `update-vals`, `select-keys`, `merge-with`, `rename-keys`, `map-keys`, `map-vals`, `disj`, `zipmap` |
| Regex | `re-pattern`, `re-matches`, `re-seq`, `re-groups` |
| Transducers | `transduce`, `sequence`, `eduction`, `completing`, `halt-when`, `cat`, `reduced`, `reduced?`, `unreduced`, `ensure-reduced`, `reductions` |
| Math | `quot`, `rem`, `compare`, `compare-and-set!` |
| Type coercion | `int`, `double`, `char` |
| Bit ops (14) | `bit-and`, `bit-or`, `bit-xor`, `bit-not`, `bit-shift-left`, `bit-shift-right`, etc. |
| I/O | `newline`, `format`, `printf`, `print-str`, `println-str`, `with-out-str`, `read-line` |
| Misc | `gensym`, `hash`, `meta`, `with-meta`, `vary-meta`, `namespace`, `parse-long`, `parse-double`, `parse-uuid`, `parse-boolean`, `random-uuid` |

Note that `array-seq`, `clj->js`, and `js->clj` are handled by
`emit-core-call` but live in `STDLIB-CLJS`, not `STDLIB-PORTABLE`. The JS
target's stdlib (PORTABLE only) does not type-declare these three functions, so
the type checker cannot validate their use in JS code—yet the emitter can still
translate them correctly if called.

---

## 4. Per-Target Form Support

### AST forms defined in `parse.rkt`

The parser defines the following AST node types (from struct definitions):

**Top-level forms:** `def-form`, `defonce-form`, `defn-form`, `defn-multi`,
`fn-form`, `record-form`, `defenum-form`, `defunion-form`, `defscalar-form`,
`protocol-form`, `defmulti-form`, `defmethod-form`, `deftype-form`,
`extend-type-form`

**Expression forms:** `let-form`, `if-form`, `cond-form`, `when-form`,
`when-let-form`, `if-let-form`, `when-some-form`, `if-some-form`, `do-form`,
`call-form`, `vec-form`, `map-form`, `set-form`, `loop-form`, `recur-form`,
`for-form`, `match-form`, `with-form`, `try-form`, `doseq-form`,
`dotimes-form`, `case-form`, `condp-form`, `letfn-form`, `with-open-form`,
`doto-form`, `await-form`, `set!-form`, `kw-access`, `method-call`,
`static-call`, `dynamic-var`, `new-form`, `quoted`, `regex-lit`,
`unsafe-clj`, `unsafe-expr`, `with-meta`

**Pattern forms (inside `match`):** `pat-wildcard`, `pat-literal`,
`pat-record`, `pat-map`, `pat-var`

### CLJ emitter (`emit-clj.rkt`) — target: `clj` and `cljs`

All forms are supported except:

- **`await-form`**: Hard error — `"await is only supported for JS target"`.

CLJS-specific adaptations within the same emitter:
- `try`/`catch`: CLJS uses `(catch :default e ...)` instead of
  `(catch ExceptionType e ...)`.
- `ns` declaration: CLJS omits `:import` section.
- The emitter switches behavior via `(eq? (current-emit-target) 'cljs)`.

`unsafe-clj` (raw Clojure string escape) is supported and passes through
verbatim. This is intentionally not available in the JS emitter.

### JS emitter (`emit-js.rkt`) — target: `js`

**Hard errors (compile-time, not runtime):**

| Form | Error message |
|---|---|
| `protocol-form` | `"protocol-form is not supported for JS target"` |
| `defmulti-form` | `"defmulti is not supported for JS target"` |
| `defmethod-form` | `"defmethod is not supported for JS target"` |
| `deftype-form` | `"deftype is not supported for JS target"` |
| `extend-type-form` | `"extend-type is not supported for JS target"` |
| `with-open-form` | `"with-open is not supported for JS target"` |
| `doto-form` | `"doto is not supported for JS target"` |
| `unsafe-clj` | `"unsafe Clojure strings are not supported for JS target"` |
| Java `import` declarations | `"Java imports are not supported for JS target"` |

**Partial support with restrictions:**

- `for`-form: Multi-binding with `:when` and `:let` works (via nested `.map`/`.filter`
  chains). Certain complex clause combinations (e.g., two `:when` at same
  nesting level) error with `"unsupported for clause combination"`.
- `doseq`: Only single-binding form supported. Multi-clause doseq errors
  with `"complex doseq clauses not yet supported for JS target"`.
- `letfn-form`: Present in `contains-await?` detection but **absent from
  `emit-expr-core`**. Falls through to the catch-all `[else (error ...)]` —
  effectively unsupported (silent until used).

**Supported with JS-specific translation:**

- `defn` → `function` (auto-`async` when body contains `await`).
- `defn-multi` (multi-arity) → variadic `function` with `arguments.length`
  dispatch.
- `def` / `defonce` → `const`.
- `fn` → arrow function.
- `let` → IIFE (`(() => { const x = ...; return ...; })()`), auto-`async`.
- `record-form` → `Object.freeze({_tag: "Name", ...})` factory + per-field
  accessor functions.
- `defenum` → `new Set([...])` assigned to `Name_values`.
- `defunion` → comment line (type erasure).
- `defscalar` → identity constructor + raw-value accessor.
- `match` → IIFE with `_tag` comparisons for record patterns.
- `with` (record update) → `Object.freeze({...rec, field: val})`.
- `await` / async detection → `async function`, `async () =>`, `async` IIFE.
- Method calls (`.method obj args`) → `obj.method(args)`.
- Static calls (`Class/method args`) → `Class.method(args)`.

**Python target:**

No emitter backend is registered for `'py'`. `stdlib-for-target` returns
`STDLIB-PORTABLE` (type-checking works), but calling `emit-program` on a
`py`-target program errors at runtime: `"no emitter backend registered for
target: py"`. The Python target is type-check only; there is no code
generation.

---

## 5. Type System

### Canonical primitive types

Defined in `private/types.rkt`:

```racket
(define PRIMITIVES
  '(String Int Float Bool Keyword Symbol Nil Any))
```

These are the only primitives. `Any` is universal (matches everything in both
directions). The type system is **fully target-neutral**—the same `types.rkt`
is used for CLJ, CLJS, JS, and PY. Target-specific behavior is in the stdlib
catalog and the emitter, not in type representation.

### CLJ-ALIASES (accepted sugar for `#lang beagle/clj`)

```racket
(define CLJ-ALIASES
  '((Long . Int) (Double . Float) (Boolean . Bool) (Integer . Int)))
```

These are resolved to canonical names before the checker sees them. They are
JVM compatibility names and must not appear in documentation, cheatsheets, or
prompts as canonical Beagle types.

### REJECTED-ALIASES (hard error with guidance)

```racket
(define REJECTED-ALIASES '(Number))
```

Using `Number` as a type produces an error directing the user to use `Int`,
`Float`, `Bool`, `String`, or `Nil`.

### Parametric type constructors

`Vec`, `List`, `Set`, `Map`, `Promise` — used as `(Vec T)`, `(Map K V)`, etc.

### Additional type forms

- **Nullable sugar**: `T?` expands to `(U T Nil)`.
- **Union**: `(U A B C)`.
- **Polymorphic**: `(forall (A B) body-type)`.
- **Function**: `[A B -> R]` (fixed), `[A B & T -> R]` (variadic rest-type `T`).
- **Type variables**: scoped within `forall`.

---

## 6. Gaps and Asymmetries

### 6.1 Portable stdlib entries with no JS emit translation

As documented in Section 3, approximately 151 of the 269 portable entries fall
through to generic `fnName(args)` emission in the JS target. The JS runtime
does not provide implementations for these. Examples of particularly common
ones likely to be called by Beagle code targeting JS:

- `every?`, `remove`, `range`, `repeat`, `take-while`, `drop-while` — common
  sequence operations with direct JS alternatives (`.every`, `.filter` with
  negation, array spread, etc.) that are not translated.
- `mapcat` — equivalent to `.flatMap` in JS; no translation.
- `assoc-in`, `update-in` — deeply nested immutable update helpers; no
  translation.
- `select-keys`, `merge-with` — map operations with no direct JS equivalent
  without a helper library.
- All regex functions except `re-find` (`re-pattern`, `re-matches`, `re-seq`,
  `re-groups`).
- All transducer functions (`transduce`, `sequence`, `eduction`, etc.) — no
  transducer runtime in JS.
- All bit operations (14 entries) — these would actually work as JavaScript
  bitwise operators but are not wired up.

**The checker does not warn when any of these are used in JS-target code.**
There is no `target-excludes-for` set for JS. This is an architectural gap:
JS and Python targets have no equivalent of the CLJS `CLJ-EXCLUDE` warning
mechanism.

### 6.2 `emit-core-call` entries not declared in JS stdlib

Three functions handled by `emit-core-call` are not in `STDLIB-PORTABLE`:
`array-seq`, `clj->js`, `js->clj`. They live in `STDLIB-CLJS` and thus are
not in the JS target's type environment (`stdlib-for-target 'js` returns
PORTABLE only). The emitter can translate them, but the type checker will
report them as unknown if called in JS code, because the JS stdlib has no
entry for them. This is a checker-emitter mismatch.

### 6.3 CLJ-specific entries arguably belonging in portable

Several `STDLIB-CLJ` entries have direct JS equivalents and could reasonably
be portable or have JS-specific translations added:

| CLJ entry | JS equivalent |
|---|---|
| `clojure.string/join` | `Array.prototype.join` |
| `clojure.string/split` | `String.prototype.split` |
| `clojure.string/replace` | `String.prototype.replace` |
| `clojure.string/trim` | `String.prototype.trim` |
| `clojure.string/upper-case` | `String.prototype.toUpperCase` |
| `clojure.string/lower-case` | `String.prototype.toLowerCase` |
| `clojure.string/includes?` | `String.prototype.includes` |
| `clojure.string/starts-with?` | `String.prototype.startsWith` |
| `clojure.string/ends-with?` | `String.prototype.endsWith` |
| `clojure.string/index-of` | `String.prototype.indexOf` |
| `clojure.string/last-index-of` | `String.prototype.lastIndexOf` |

These are in `STDLIB-CLJ` (not portable) because they are qualified with the
`clojure.string/` namespace. They are unavailable to JS-target code entirely.

### 6.4 CLJS entries relevant to JS target

`STDLIB-CLJS` is merged into CLJ/CLJS combined but not into the JS target
stdlib. Several CLJS entries are directly relevant to JS target code:

- `js/console.log`, `js/console.warn`, `js/console.error` — JS console
- `js/JSON.stringify`, `js/JSON.parse` — JSON serialization
- `js/Math.*` variants — math operations
- `js/setTimeout`, `js/setInterval`, `js/clearTimeout`, `js/clearInterval`
- `js/Promise`, `js/Error` — async and error construction
- `js/Object.keys`, `js/Object.values`, `js/Object.assign`, etc.
- `undefined?`, `object?`, `array?` — type predicates

A JS-target file using `js/console.log` or `js/JSON.stringify` gets no type
information. The emitter translates the call via `static-call` (the `Class/method`
path, since `js/foo.bar` is parsed as a qualified static call), but the type
checker has no entry for it.

### 6.5 Higher-order value limitation for inline-expanded functions

In the JS emitter, several functions are only translated when called with
explicit arguments via `emit-core-call`. When used as higher-order values
(passed as arguments to `map`, `reduce`, etc.), they emit as their mangled
name string instead:

```
(map inc [1 2 3])
```

This emits as `[1, 2, 3].map(inc)` — but `inc` as a JS value is `undefined`
because the emitter treats `inc` as a symbol reference (mangled to `inc`)
rather than generating a function wrapper. Functions affected:
`+`, `-`, `*`, `/`, `<`, `>`, `inc`, `dec`, `not`, `and`, `or`, and all other
infix/unary operators.

This is a fundamental consequence of the inline-expansion approach: the
operators have no runtime representation as callable objects.

### 6.6 CLJ and CLJS use the same combined stdlib (asymmetric intent)

`stdlib-for-target` returns `stdlib-clj-combined` for both `clj` and `cljs`.
This means CLJS sees all of `STDLIB-CLJ` (352 JVM-specific entries) plus all
of `STDLIB-CLJS` (75 JS-specific entries), with CLJ-only ones producing
warnings rather than errors. The intent is CLJS ≈ CLJ minus JVM APIs plus
CLJS APIs, but the implementation allows JVM-API calls to pass type-checking
in CLJS code (warning only).

---

## 7. Target Matrix

| Feature | CLJ | CLJS | JS | PY |
|---|---|---|---|---|
| **Stdlib entries** | 696 (all three) | 696 (all three) | 269 (portable) | 269 (portable) |
| **CLJ-EXCLUDE warning** | n/a | yes (131 entries warned) | no | no |
| **emit-core-call translations** | n/a (CLJ is direct emit) | n/a (CLJ emitter) | 108 case arms | no emitter |
| **JS-infix/unary translations** | n/a | n/a | 11 infix + 1 unary | no emitter |
| **`protocol` / `defmulti` / `deftype`** | yes | yes | ERROR | no emitter |
| **`defrecord`** | yes | yes | yes (`Object.freeze` + factory) | no emitter |
| **`defenum`** | yes | yes | yes (`new Set(...)`) | no emitter |
| **`defunion`** | yes | yes | yes (comment only) | no emitter |
| **`defscalar`** | yes | yes | yes (identity ctor/accessor) | no emitter |
| **`with-open`** | yes | yes | ERROR | no emitter |
| **`doto`** | yes | yes | ERROR | no emitter |
| **`letfn`** | yes | yes | falls to error (unimplemented) | no emitter |
| **`await` / async** | ERROR | ERROR | yes (auto-async detection) | no emitter |
| **`unsafe` Clojure strings** | yes | yes | ERROR | no emitter |
| **`try`/`catch`** | yes (typed) | yes (`:default`) | yes (no exception type) | no emitter |
| **`doseq`** | yes (multi-binding) | yes | single-binding only | no emitter |
| **`for`** | yes | yes | single/nested (some combos error) | no emitter |
| **`match`** | yes | yes | yes (`_tag` dispatch) | no emitter |
| **`with` (record update)** | yes | yes | yes (`Object.freeze({...})`) | no emitter |
| **Java `import`** | yes | no | ERROR | no emitter |
| **Method calls (`.method`)** | yes | yes | yes (`obj.method()`) | no emitter |
| **Static calls (`Class/method`)** | yes | yes | yes (`Class.method()`) | no emitter |
| **Module imports (`require`)** | yes | yes | yes (ES `import * as`) | no emitter |
| **Async interop model** | JVM futures/promises | JS Promises | `async`/`await` | n/a |
| **Interop model** | Java reflection/interop | ClojureScript JS interop | Native JS, no CLJS bridge | n/a |
| **`(Promise T)` type** | in stdlib | in stdlib | in stdlib (type-neutral) | in stdlib |
| **Code generation** | yes | yes | yes | no (type-check only) |

### Notes on the matrix

- **CLJ and CLJS share one emitter** (`emit-clj.rkt`), with minor behavioral
  switches on `(current-emit-target)`. The emitter does not enforce CLJ-EXCLUDE
  at emit time—that is purely a checker concern.
- **JS target has no `target-excludes-for`**. Any portable stdlib entry can be
  referenced in a type annotation without warning, even if it has no runtime
  implementation in JS.
- **Python target is a stub**. The `#lang beagle/py` header sets target to
  `'py`, `stdlib-for-target` returns PORTABLE (type checking works), but
  `resolve-backend` will error if emission is attempted. There is no Python
  emitter and no Python-specific stdlib entries.
- **CLJ type aliases** (`Long`, `Double`, `Boolean`, `Integer`) are accepted
  syntactically for `#lang beagle/clj` compatibility but are resolved to
  canonical names (`Int`, `Float`, `Bool`) before the checker processes them.
  They must not appear in documentation or prompts.
