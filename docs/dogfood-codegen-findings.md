# Codegen / check findings from dogfooding (gjoa authoring, 2026-06-20)

A running ledger, companion to `text-as-source-latent-bugs.md`. These surfaced not
from a text→graph migration but from **using beagle to author a real project**
(gjoa: an externs sweep, a cross-module `:require` refactor, and a from-scratch JS
projector subsystem). The meta-signal: every failure here is "beagle emitted bad JS"
or "beagle gave a false signal" — none is "the agent couldn't drive the language."
The bottleneck moved to codegen quality, which is the encouraging direction.

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
         (array? v) (doseq [e v] (.push out e))   ; -> ... ? v.forEach(...); : null
         :else nil)
   ```
   emits `... ? v.forEach((e) => {…}); : null` — **`Unexpected :`**. (Cost a real
   build crash; worked around by rewriting the `cond` as sequential `when`s.)

3. Output quality: throws/side-effects in expression position get IIFE-wrapped
   (`(() => { throw … })()`), which a statement-position `if` would emit plainly.

**Proposal:** when an `if`/`cond`/`when` is in statement position (value discarded),
lower it to an `if`-statement rather than a ternary. Restores byte-diff soundness,
removes the statement-in-ternary crash class, cleaner output.

**Status:** PROPOSAL — invasive (changes emit for `if`/`cond`/`when` across the
board); deserves a deliberate build, not a bolt-on.

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

**Status:** FIXED (this change) — genuinely one line + a regression test.

---

## 3. Closed stdlib namespaces — `Math/roundmin` emits `Math.roundmin(…)` with only a NOTE

**Surfaced by:** an externs sweep converting `(.round Math x)` → `(Math/round x)`;
a typo `(Math/round min)` → `(Math/roundmin)` compiled to `Math.roundmin(min)` (a
runtime crash) with only a levenshtein NOTE — caught by byte-diff, NOT by `check`.

**Why it's a NOTE (deliberate):** `check.rkt` documents that the typed catalog is
*deliberately partial*, so a missing member "can't be an error" (it might be a real
member just not yet typed).

**Proposal (design, not a bug-fix):** allow marking a stdlib namespace as **closed**
(complete surface) — `Math`, `JSON`, `Number` have fixed, fully-enumerable member
sets. For a closed namespace, an unknown `NS/member` becomes an ERROR (catches the
`Math/roundmin` class at check time). Bonus: the same closed-world mechanism applied
to user `(declare-extern [Obj/member] …)` is the **enabling precondition for typed
Firefox-API seams** — today an undeclared `(gBrowser/bogusMethod x)` emits freely
(see #5), which is exactly why typed seams can't enforce.

**Status:** FILED — needs a closed-namespace marker; design call.

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
**Status:** FILED — `:refer`-imported names should not be flagged undefined.

---

## 5. Transitive `unused declare-extern` lint leaks across `:require`

**Surfaced by:** converting cross-module chrome refs from `declare-extern` to real
`:require` (the "Path B" refactor).

**The issue:** when module A `:require`s module B, checking A surfaces *B's own*
`declare-extern`s as `unused declare-extern: B/X` — externs A never declared.
```clojure
;; log.bjs:  (declare-extern [PathUtils IOUtils] Any)
;; consumer: (:require [gjoa.tabs.log :refer [create-logger!]])
;;   -> beagle [lint]: unused declare-extern: log/PathUtils   (in the CONSUMER)
```
`:refer [x]` should scope to `x`; the unused-extern lint should only consider the
current file's own `declare-extern`s. (Benign — verbose-profile only — but wrong.)
**Status:** FILED.

---

## 6. `Obj/member` in value position doesn't translate `/`→`.`

**Surfaced by:** probing whether Firefox host-global properties could be typed.

**The issue:** call position translates (`(gBrowser/addTab x)` → `gBrowser.addTab(x)`),
but **value position emits the slash literally** — invalid JS, silently:
```clojure
(declare-extern [gBrowser/selectedTab] Any)
(def t gBrowser/selectedTab)   ; -> const t = gBrowser/selectedTab;   (division — broken)
```
**Status:** FILED — value-position `Obj/member` should translate `/`→`.` or error.

---

## 7. `Obj/method` externs are not closed-world

**Surfaced by:** evaluating whether typed `Obj/method` externs could enforce the
Firefox-API seam surface (gjoa task #73).

**The issue:** an undeclared `(gBrowser/bogusMethod x)` emits `gBrowser.bogusMethod(x)`
freely, no error — even when no `(declare-extern [gBrowser/bogusMethod] …)` exists.
So declaring the surface gains no enforcement (a typo / a removed upstream method is
not caught). This is why typed Firefox seams were rejected as "documentation churn,
no teeth." Same root as #3 (closing the world on `Obj/member`).
**Status:** FILED — couples with #3.

---

## 8. `aset` is array-only (no object string-key form)  · minor

**Surfaced by:** building an id→records index in the projector.

**The issue:** `(aset obj "key" v)` → `beagle: call to aset: arg 2 expected Int, got
String`. There's no clean form to set a dynamic string key on a JS object;
workaround was a JS `Map` (`.set`/`.get`). An `aset`/`oset` accepting string keys
for objects would help.
**Status:** FILED — minor ergonomics.
