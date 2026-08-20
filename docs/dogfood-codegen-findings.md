# Historical codegen and check findings (2026-06-20)

A running ledger. These surfaced not
from a text→graph migration but from using Beagle in a downstream JavaScript
project: an externs sweep, a cross-module `:require` refactor, and a projector
subsystem. Each entry records either an incorrect emit or an incorrect checker
signal. Unresolved entries are historical findings, not product commitments.
For current language, target, and execution claims, use the README and the
current surface documentation rather than inferring them from this ledger.

The bar: a real wrong-emit, crash, or false check signal, with a minimal repro.

---

## 1. Statement-position lowering — `if`/`cond`/`when` emit ternaries even when the value is discarded  ★ highest leverage

**Surfaced by:** a refactor sweep that relied on byte-diffing emitted JS to prove
equivalence.

**The issue:** beagle lowers `if`/`cond` to a **ternary expression** even in
statement position (value unused). Two concrete consequences:

1. **It silently breaks the "byte-diff proves equivalence" method.** `(if c b nil)`
   and `(when c b)` are semantically identical, but emit *different bytes*:
   ```clojure
   (defn f [c] (if c (g) nil))   ; -> return (c ? g() : null);
   (defn f [c] (when c (g)))      ; -> if (c) { g(); }
   ```
   So a genuinely-safe `(if … nil)` → `when` cleanup *fails* a byte-identity check.
   Any verification discipline that treats "byte-identical ⇒ safe" now has false
   negatives: byte-identity is a strictly *stronger* test than equivalence, so the
   gate over-rejects safe refactors. (This is the load-bearing reason to fix it.)

2. **It produces a syntax error for a statement-form branch.** A `doseq` (which
   lowers to `xs.forEach(…)`, a statement) spliced into a ternary arm emits invalid
   JS:
   ```clojure
   (cond (node? v) (.push out v)
         (array? v) (doseq [e v] (.push out e)) ; -> ... ? v.forEach(...); : null
         :else nil)
   ```
   emits `... ? v.forEach((e) => {…}); : null` — **`Unexpected :`**. (Cost a real
   build crash; worked around by rewriting the `cond` as sequential `when`s.)

3. Output quality: throws/side-effects in expression position get IIFE-wrapped
   (`(() => { throw … })()`), which a statement-position `if` would emit plainly.

**Proposal:** when an `if`/`cond`/`when` is in statement position (value discarded),
lower it to an `if`-statement rather than a ternary. Restores byte-diff soundness,
removes the statement-in-ternary crash class, cleaner output.

**Status:** Unresolved at the time of this record; any change affects
`if`/`cond`/`when` emission broadly.

---

## 2. Unary `(- x)` emits `_(x)` (ReferenceError)

**Surfaced by:** computing a root-not-found sentinel in the JS projector.

**The issue:** `-` is in `JS-INFIX-OPS` but not `JS-UNARY-OPS` (which holds only
`not`), so 1-arg `(- x)` never matches the unary path and lowers to the bare
value-wrapper reference `_`:
```clojure
(def x (- 1))        ; -> const x = _(1);   →  ReferenceError: _ is not defined
```
Binary `(- a b)` is fine. Workaround was the literal `-1`.

**Fix:** add `'- "-"` to `JS-UNARY-OPS` in `beagle-lib/private/js-capabilities.rkt`.
The emit-js unary path is guarded by `(= 1 (length args))`, so binary `-` is
unaffected.

**Status:** Fixed in the historical change that recorded this finding.

---

## 3. Closed extern surfaces — an unknown selector emits with only a NOTE

**Surfaced by:** an externs sweep where a typo in
`(.roundmin Math min)` compiled to `Math.roundmin(min)` (a runtime
crash) with only a Levenshtein NOTE — caught by byte-diff, not by `check`.

**Why it's a NOTE (deliberate):** `check.rkt` documents that the typed catalog is
*deliberately partial*, so a missing member "can't be an error" (it might be a real
member just not yet typed).

**Proposal (design, not a bug-fix):** allow marking a stdlib namespace as **closed**
(complete surface) — `Math`, `JSON`, `Number` have fixed, fully-enumerable member
sets. For a closed extern surface, an unknown selector becomes an ERROR and
catches the `.roundmin` class at check time. The same mechanism applied to a
user-declared host object is the enabling precondition for typed Firefox-API
seams: today `(.bogusMethod gBrowser x)` emits freely (see #7).

**Status:** Unresolved in this historical record; it needs a closed-namespace
marker.

---

## 4. False "undefined function" notes for `:require :refer`'d symbols

**Surfaced by:** every tool that imports node/bun builtins.

**The issue:** a symbol brought in via `(:require [fs :refer [readFileSync]])` and
called still emits `note: call to undefined function 'readFileSync'`. The checker
doesn't credit the `:refer` import. Constant noise that dilutes real notes.
```clojure
(ns t (:require [fs :refer [readFileSync]]))
(defn f [p] (readFileSync p "utf8"))   ; -> note: call to undefined function 'readFileSync'
```
**Status:** Unresolved in this historical record.

---

## 5. Transitive `unused declare-extern` lint leaks across `:require`

**Surfaced by:** converting cross-module chrome refs from `declare-extern` to real
`:require` (the "Path B" refactor).

**The issue:** when module A `:require`s module B, checking A surfaces *B's own*
`declare-extern`s as `unused declare-extern: B/X` — externs A never declared.
```clojure
;; log.bjs:  (declare-extern [PathUtils IOUtils] Any)
;; consumer: (:require [app.log :refer [create-logger!]])
;;   -> beagle [lint]: unused declare-extern: log/PathUtils   (in the CONSUMER)
```
`:refer [x]` should scope to `x`; the unused-extern lint should only consider the
current file's own `declare-extern`s. (Benign — verbose-profile only — but wrong.)
**Status:** Unresolved in this historical record.

---

## 6. Member values use direct property access

**Surfaced by:** probing whether Firefox host-global properties could be typed.

Property reads are direct and explicit. A static selector names the foreign
member without becoming a value on its own:
```clojure
(declare-extern gBrowser Any)
(def t Any (.selectedTab gBrowser))
```
Member names are static selectors.

---

## 7. Declared host objects are not closed-world

**Surfaced by:** evaluating whether typed member declarations could enforce the
Firefox API seam surface.

**The issue:** `(.bogusMethod gBrowser x)` emits
`gBrowser.bogusMethod(x)` freely when `gBrowser` has the open `Any` boundary.
The selector makes the member identity explicit, but it does not claim that the
host object's member set is complete. Same root as #3.
**Status:** Unresolved in this historical record; related to #3.

---

## 8. Direct object access uses static selectors

`aset` remains an array operation. JavaScript object members use direct
property access and assignment with static selectors:

```clojure
(set! (.-knownMember obj) value)
(.-knownMember obj)
```

This keeps array indexing and foreign object membership as separate operations.

---

## 9. Selectors preserve foreign member identity

Selectors are not Beagle bindings and never pass through binding-name mangling.
An authored `_` therefore remains `_`, and a map key/property read round-trip
uses one spelling:

```clojure
(let [m {:emit_sha256 "abc"}]
  (.emit_sha256 m))
```

Static selectors emit dot access when their exact bytes form a legal JavaScript
member identifier and escaped bracket access otherwise. Dynamic expressions
always emit bracket access.

---

## 10. Emitted import specifier keeps source hyphens, but the emitted filename is snake_cased — they don't match

**Surfaced by:** resolving a module's relative-import graph (to track audit-
dependency edges) — the import targets pointed at files that didn't exist.

**The issue:** a `.bjs` file named with hyphens (`drag-overlay.bjs`) is emitted to a
**snake_cased** filename (`drag_overlay.js`), but a sibling that imports it emits the
specifier with the **original hyphen**:
```js
// drawer/index.js (emitted)
import { make_drag_overlay_bang } from './drag-overlay.js';   // ← hyphen
// but the emitted file on disk is:  drawer/drag_overlay.js   // ← underscore
```
So the two disagree. Under a bundler that resolves by module name this is masked,
but as **plain ESM the import fails to resolve** (`./drag-overlay.js` does not
exist). Same root family as #9 — the emitter applies different name normalization in
two positions — but here it's the **filename ↔ import-specifier** pair rather than
map-key ↔ property-read.

**Repro:** two files `a-b.bjs` (exports something) and `c.bjs` that `:require`s it;
build both and observe `c.js` imports `./a-b.js` while the file is `a_b.js`.

**Fix direction:** the filename lowering and the import-specifier lowering must
share one normalization (snake_case both, or preserve hyphens in both).

**Status:** Unresolved in this historical record. Plain ESM import resolution
requires one shared normalization.

---

## 11. Inline arrow fn with a map-literal body emitted a JS block, not an object return

**Surfaced by:** building a manifest generator — an inline
`(fn [g] {map})` passed to an array's `map` method produced JS that wouldn't
parse.

**The issue:** an inline anonymous fn whose body is a single map literal lowered to
an arrow with a BLOCK body:
```clojure
(.map xs
  (fn [(g Any)] Any
    {:pref (.name g) :what (.vector g)}))
;; emitted:  xs.map((g) => {pref: g.name, what: g.vector})   ← {…} is a JS block
;;           -> SyntaxError: "Expected ; but found :"
;; correct:  xs.map((g) => ({pref: g.name, what: g.vector}))  ← ({…}) returns the object
```
A NAMED `defn` returning a map is fine (it emits `return {…};`). Only the inline
arrow expression-body case was broken. Workaround at the time: a named `defn`.

**Fix:** in `emit-js.rkt` (fn-form case), wrap the expression body in parens
when it emits starting with `{` — catching anything that lowers to an object
literal in expression position, not only the syntactic map-form. Non-object bodies
(`(x) => (x + 1)`) are unchanged. Regression test: `beagle-test` oracle
`js-arrow-object`.

**Status:** Fixed in the historical change that recorded this finding.
