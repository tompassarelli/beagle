# C9 checker-tail repair plan

Date: 2026-08-18

## Outcome

C9 is **not one checker-precedence defect**. Its eighteen rows split into three
causes:

| Cause | C9 rows | Count | Verdict |
|---|---|---:|---|
| A. Open type grammar in the self-host parser | 18–19, 21, 23–26, 31–34, 37 | 12 | The mandatory return-type slot accepts a non-type datum, or an unknown lowercase name, instead of rejecting it. The oracle therefore stops at the declaration while self-host continues to a later error. |
| B. Definition-inference causal error is discarded | 22, 29 | 2 | Self-host suppresses the concrete initializer error and emits the consequential “omitted type did not resolve” summary first. |
| C. Parser diagnostic text differs | 27–28, 30, 36 | 4 | Both parsers select the same malformed `defn` or `fn`; only the exact error core differs. |

C10 rows 20 and 35 share cause A exactly. They are not a separate narrowing or
union-checker defect. In those two inputs the fail-open return type becomes
`Any`, and the remaining body emits no diagnostic, so self-host accepts the
whole program. Closing cause A changes both C10 verdicts from accept to reject.

No commander ruling is required. The mandatory return-type slot and the closed
type grammar are already locked language rules. Reporting a concrete
initializer error before its failed-inference consequence is principled. Cause
C is arbitrary Racket wording, but exact error-core parity is an existing
verifier contract; matching it is an implementation compatibility task, not a
new language-design decision.

## Evidence boundary and how the core is selected

The authoritative failing cores are the 44-row ledger
`~/code/todo/beagle-program-handoff/positioning/SEMANTIC-GAP-TRIAGE.md`
and `/tmp/beagle-tier-repair-failures.txt`. The tracked inputs are under
`beagle:fuzz/repros/checker-tail-20260704/`.

`beagle:self-host/verify-selfhost.sh` section 5b runs the oracle and self-host
checker for every tracked repro, converts exit zero/nonzero to `A`/`R`, and
uses the first line matching `beagle: (?:beagle: )?(.*)` as the error core.
Therefore the observable self-host core is the first parser error printed by
`parse.bclj::err!`, or, if parsing succeeds, the first string in
`check.bclj`'s `STATE["diagnostics"]`. `main.bclj::parse-file-target!` exits
before checking when `parse-errors` is nonempty; `main.bclj::check-or-die!`
prints checker diagnostics in vector order. Do not change the verifier,
normalize its strings, reorder the repro corpus, or weaken exact comparison.

## Per-row characterization

Every “Input” below names the tracked input and reproduces the complete
top-level form or forms that determine the first core. Reader headers and
namespace declarations are omitted from the display but remain in the named
file.

### Cause A — open return-type grammar (12 C9 rows)

| Row / input | Decisive input | Racket core | Self-host core | Why they differ |
|---|---|---|---|---|
| 18 — `044333dc85bd.bclj` | `(defn f__16 [p__17] (get (get "hello world" :y) :b) [p__18 p__19 p__20] (first (->> nil (- 1))))` | `bad type expression: '(get (get "hello world" :y) :b)` | `call to -: arg 2 expected Number, got Nil` | `(get ...)` occupies the mandatory return-type slot. Racket rejects it as a non-type. Self-host maps the unrecognized list to `Any`, then descends into the later body and reports `-`. |
| 19 — `1c04be588e62.bclj` | `(defn f__22 [p__23] (count :x) [p__24 p__25 p__26] (nth (-> -2147483648 (conj -42) (conj 1) (- 10)) (min 1000 2)))` | `bad type expression: '(count :x)` | `call to -: arg 1 expected Number, got Any` | `(count :x)` is parsed as the return type. Racket rejects there; self-host substitutes `Any` and reaches the threaded arithmetic in the body. |
| 21 — `20b1c0026a1f.bclj` | `(defn f__14 [p__15] (let [v__18 (mapv (fn [p__19] :y) \a)] (- 1000)) [p__16 p__17] (nth {:b 3 :k2 100.0} (count "unicode λé")))` | `bad type expression: '(let (#%brackets v__18 (mapv (fn (#%brackets p__19) :y) #\a)) (- 1000))` | `call to nth: arg 1 expected (Vec Any), got (Map Keyword Any)` | The `let` is the invalid return-type datum. Self-host ignores its structure as `Any` and checks the later map-valued `nth`. |
| 23 — `3d41f6a456b1.bclj` | `(defn f__10 [] (cond (not (string? g__3)) (get nil :b) (not g__3) (mapv (fn [p__14] p__14) g__3) (< *dyn__4* *dyn__4*) (first true) :else #{:k2}) [p__11 p__12 p__13] (:k2 (binding [*dyn__4* 1000] p__13)))` | `bad type expression: '(cond (not (string? g__3)) (get nil :b) (not g__3) (mapv (fn (#%brackets p__14) p__14) g__3) (< *dyn__4* *dyn__4*) (first true) :else (#%set :k2))` | ``binding: *dyn__4* is not a dynamic var — only `(def ^:dynamic *dyn__4* ...)` vars can be rebound with `binding` `` | The `cond` is in the return slot. Racket rejects it before the body; self-host turns it into `Any` and reaches the later dynamic binding. |
| 24 — `42ad2d259ad2.bclj` | `(defn f__9 [p__10] g__1 [p__11 p__12 p__13] [(assoc -42 :b g__1) (f__7 (nil? g__1) 10 "  padded  ")])` | `unknown type: g__1` | `defn f__9: expected return g__1, got (Vec Any)` | Racket admits primitives, known aliases/constructors, registered qualified names, uppercase nominals, and JVM class names; lowercase `g__1` is not a type. Self-host accepts every string as a nominal type and reports only the later return mismatch. |
| 25 — `509a72f87c74.bclj` | `(defn f__2 [p__3] (let [n__6 nil] -2147483648) [p__4 p__5] (nth (->> p__4 (+ 0)) (+ 10 255)))` followed by `(defn bad__11 [] (let [(z String) 100] z))` | `bad type expression: '(let (#%brackets n__6 nil) -2147483648)` | `malformed defn bad__11 — expected (defn bad__11 [params] ReturnType body...)` | Racket rejects the first function's return slot. Self-host silently accepts that slot as `Any`, continues parsing, and the next malformed definition becomes its first emitted error. |
| 26 — `5b7b4c8034e8.bclj` | `(defn f__19 [p__20] {:a (fn [p__24 p__25] *dyn__3*)} [p__21 p__22 p__23] (nth (-> 255 (conj "  padded  ") (+ 3)) (+ *dyn__3* *dyn__3*)))` | `bad type expression: '(#%map :a (fn (#%brackets p__24 p__25) *dyn__3*))` | `call to +: arg 1 expected Number, got Any` | A map literal is not a type. Self-host's catch-all returns `Any` and exposes a later arithmetic error. |
| 31 — `94c783024a2d.bclj` | `(defn f__15 [p__16] (->> (filterv (fn [p__20] true) p__16) (inc) (- (inc 42))) [p__17 p__18 p__19] (doseq [x__21 255 :let [y__22 (str x__21)] :when (< 2147483647 -2147483648)] (filterv (fn [p__23] (some? p__23)) 2147483647)))` | `bad type expression: '(->> (filterv (fn (#%brackets p__20) true) p__16) (inc) (- (inc 42)))` | `fn needs (fn [params] ReturnType body...)` | The threaded expression is the invalid return type. Self-host fails open, then the later body exposes a malformed anonymous function. Cause C's wording change alone cannot close this row; strict type parsing must make the earlier oracle core win. |
| 32 — `9e37d4c1f2b7.bclj` | `(defn f__8 [] (int? *dyn__3*) [p__9 p__10] (first (some-> -2147483648 (str *dyn__3*) (- -65536))))` | `bad type expression: '(int? *dyn__3*)` | `call to -: arg 1 expected Number, got String` | The predicate call is in the return slot. Self-host converts it to `Any` and reaches the later subtraction. |
| 33 — `c12eeda88def.bclj` | `(defn f__13 [p__14] (if true "12345" g__9) [p__15 p__16] (nth (cond false 1.5 (int? p__15) *dyn__3* :else true) *dyn__3*))` | `bad type expression: '(if true "12345" g__9)` | `call to nth: arg 1 expected (Vec Any), got (U Float Bool)` | The `if` is a value expression in the return-type slot. Self-host accepts it as `Any` and reports the later union-valued `nth`. |
| 34 — `c7786bec88f8.bclj` | `(defn f__11 [p__12] (str :x 256) [p__13 p__14 p__15] (cond->> "  padded  " (not true) (+ (+ 255 7)) (> 10 1000) (inc) false (inc)))` | `bad type expression: '(str :x 256)` | `call to +: arg 2 expected Number, got String` | The `str` call is not a type. Self-host's `Any` fallback defers failure to arithmetic in the body. |
| 37 — `fbeb9210ee4d.bclj` | `(defn f__16 [p__17] #{:id :x} [p__18 p__19 p__20] (cond (not (string? g__3)) (let [[a__21 b__22] :c {:keys [b id]} true] 0.0) (not g__3) "" (int? p__19) (first :k1) :else (mapv (fn [p__23] 999999) p__20)))` | `bad type expression: '(#%set :id :x)` | `fn needs (fn [params] ReturnType body...)` | The set literal is the invalid return type. Self-host accepts it as `Any` and continues to the later malformed anonymous function. |

### Cause B — concrete inference failure replaced by a summary (2 C9 rows)

| Row / input | Decisive input | Racket core | Self-host core | Why they differ |
|---|---|---|---|---|
| 22 — `3a907432853b.bclj` | `(defonce g__2 (nth (->> 0.5 (* 65535)) (- 256)))` | `call to nth: arg 1 expected (Vec Any), got Float` | `defonce g__2: omitted type did not resolve to a concrete monomorphic type; add a type annotation, or write Any explicitly for an intentional dynamic boundary` | Racket's definition solver treats the concrete `nth` argument violation as the causal failure. Self-host's `infer-value-definition-types!` records it during a provisional attempt, restores the old diagnostics vector, and then emits the generic unresolved-definition message. |
| 29 — `6f151ff4eece.bclj` | `(def g__4 (nth (if-let [w__5 100.0] 0.0 -1) (if true 0 3)))` | `call to nth: arg 1 expected (Vec Any), got Float` | `def g__4: omitted type did not resolve to a concrete monomorphic type; add a type annotation, or write Any explicitly for an intentional dynamic boundary` | This is the same suppression path for `def` rather than `defonce`: the initializer's concrete type error is discarded and its inference consequence is emitted first. |

### Cause C — same selected malformed form, different text (4 C9 rows)

| Row / input | Decisive input | Racket core | Self-host core | Why they differ |
|---|---|---|---|---|
| 27 — `62bd65163f0f.bclj` | `(defn f__16 [] (first (cond (string? g__2) :y true -3.14 :else *dyn__3*)))` | `malformed defn — expected (defn name "doc"? [params...] ReturnType body...) or multi-arity (defn name ([params] ReturnType body...) ...); got: '(defn f__16 (#%brackets) (first (cond (string? g__2) :y true -3.14 :else *dyn__3*)))` | `malformed defn f__16 — expected (defn f__16 [params] ReturnType body...)` | Both select the same two-slot tail: it has a parameter vector and would-be return type but no body. Only the diagnostic template/projection differs. |
| 28 — `677470581f1a.bclj` | `(defn f__2 [(p__3 Any) (p__4 Int)] (first (cond true -3.14 false :k2 false p__4 :else -2147483648)))` | `malformed defn — expected (defn name "doc"? [params...] ReturnType body...) or multi-arity (defn name ([params] ReturnType body...) ...); got: '(defn f__2 (#%brackets (p__3 Any) (p__4 Int)) (first (cond true -3.14 false :k2 false p__4 :else -2147483648)))` | `malformed defn f__2 — expected (defn f__2 [params] ReturnType body...)` | Same malformed `defn` shape and same message-template mismatch as row 27. |
| 30 — `7e9a14983210.bclj` | `(defonce g__14 "a doc" (->> (filterv (fn [p__15] true) 1000) (dec) (map inc) (map inc)))` | ``fn needs a return type and body — write `(fn [params] ReturnType body...)` `` | `fn needs (fn [params] ReturnType body...)` | Both select the anonymous function missing its mandatory return type and body. The self-host message omits the oracle's words and repair spelling. |
| 36 — `f036de687e29.bclj` | `(def g__9 (cond->> "tab\there" (int? \u0020) (conj (mapv (fn [p__10] nil) nil)) (= 2 999999) (- 255) false (dec)))` | ``fn needs a return type and body — write `(fn [params] ReturnType body...)` `` | `fn needs (fn [params] ReturnType body...)` | Exact duplicate of row 30's diagnostic-template mismatch. |

## Precise repair specification

### Repair A — make the self-host type grammar fail closed

**Files and functions**

- Primary: `beagle:self-host/src/selfhost/parse.bclj`, `parse-type!`.
- Diagnostic support in the same file: `type-error!` plus a new private
  Racket-value-style datum renderer; reuse it from `parse-defn-tail!` for
  Repair C.
- If exact qualified-nominal admission cannot be derived from the existing
  preloaded alias/constructor tables, thread a preloaded nominal-name set
  through `parse-program-with-imports!` and
  `parse-program-with-syntax-and-imports!`; derive it in
  `beagle:self-host/src/selfhost/main.bclj` from the already loaded closed
  module surfaces. Do not retain a permissive qualified-name fallback.

**Current behavior**

`parse-type!` ends with two fail-open arms:

1. every string becomes `(make-prim t)`, so lowercase `g__1` is admitted as a
   nominal type;
2. every otherwise unrecognized datum becomes `(make-prim "Any")`, so calls,
   `let`, `if`, maps, sets, threading forms, and other expressions are accepted
   in a type slot.

The parser then parses the remaining `defn` tail as ordinary body forms. A
later parser/checker diagnostic becomes the first core, or no later diagnostic
exists and C10 is accepted.

**Required behavior**

Port the oracle's closed final arms from `beagle-lib/private/types.rkt::parse-type`:

1. Keep the existing recognized `Fn`, `forall`, `U`, `Dyn`, declared/built-in
   parametric constructor, alias, nullable, and `Number` paths.
2. Admit a bare string only when it is a primitive, a Clojure alias, an active
   type variable, an active declared alias/constructor, an uppercase nominal,
   an exactly registered qualified nominal, or a JVM fully qualified class
   name whose last segment is capitalized. Preserve the oracle's constructor
   arity checks.
3. For any other string, call `type-error!` with the oracle core beginning
   `unknown type: NAME`; include the oracle's following help lines if ordinary
   CLI parity requires them, but the first line must be byte-identical because
   section 5b extracts that line.
4. For any other datum, call `type-error!` with exactly
   `bad type expression: '<racket-written-datum>` and return an `invalid-type`
   sentinel, never `Any`. Parsing may continue under the existing collector,
   but this error must be appended before any later body error.
5. Implement one private datum renderer that reproduces the oracle's `~v`
   representation for the self-host reader encoding: lists use parentheses;
   `#%brackets`, `#%map`, and `#%set` remain explicit tagged list data; strings
   are quoted and escaped; characters render as `#\\x`; nested values recurse;
   the whole value receives the leading quote used by `~v`. Reuse this renderer
   for Repair C rather than hard-coding the twelve fuzz inputs.
6. Add inline parser tests for one invalid compound return type, lowercase
   `g__1`, and valid primitive, uppercase nominal, registered qualified
   nominal, alias, and parametric types. Assert the exact first parse-error
   strings, not only nonempty errors.

**Side and policy**

Only self-host changes. The oracle's selection is principled: a mandatory type
slot must validate as a type before the body can be checked. This one repair
closes C9 rows 18–19, 21, 23–26, 31–34, and 37, and C10 rows 20 and 35.

### Repair B — preserve the causal initializer diagnostic

**Files and functions**

- `beagle:self-host/src/selfhost/check.bclj::infer-value-definition-types!`.
- Propagate success/failure through `infer-definition-types!` and gate the
  later work in `type-check!` if needed to preserve the oracle's coherent
  one-solver-failure behavior.

**Current behavior**

For each unannotated `def`/`defonce`, `infer-value-definition-types!` snapshots
`STATE["diagnostics"]`, calls `infer-expr!`, and, whenever the inferred type is
not concrete, restores the snapshot unconditionally. At a no-progress fixed
point it emits `omitted type did not resolve...`. That is correct for a silent
unresolved dependency or cycle, but wrong when `infer-expr!` already found a
concrete type violation such as `nth` on `Float`.

**Required behavior**

1. Distinguish “no concrete type and no diagnostic” from “initializer emitted
   a concrete diagnostic.” Only the former may be retried or summarized as an
   omitted-type failure.
2. If an initializer emits diagnostics, preserve them in their existing
   depth-first order, mark definition inference failed, and do not put the
   generic omitted-type diagnostic ahead of them. Stop the definition solver
   after that coherent failure, or gate the later normal form pass, matching
   the oracle's `inference-ok?` behavior rather than manufacturing cascades.
3. Emit the generic omitted-type message only for an unresolved initializer
   that reached the fixed point without a concrete diagnostic.
4. Add inline checker tests for the exact row-22 `defonce` and row-29 `def`
   shapes. Assert that the first diagnostic is
   `call to nth: arg 1 expected (Vec Any), got Float` and that no generic
   omitted-type message precedes it. Retain an unresolved-cycle test proving
   the generic message still exists when it is genuinely causal.

**Side and policy**

Only self-host changes. This is not arbitrary error preference: the concrete
invalid operation causes inference to fail; the omitted-type message is only a
consequence. This repair closes rows 22 and 29.

### Repair C — copy the oracle's malformed-function diagnostic projection

**File and functions**

- `beagle:self-host/src/selfhost/parse.bclj::parse-defn-tail!` and its callers
  in `parse-list-form!`.
- The `fn` fallback arm in `parse-list-form!`.
- The same private Racket-value-style datum renderer introduced for Repair A.

**Current behavior and required behavior**

1. `parse-defn-tail!` currently emits the name-specific short form
   `malformed defn NAME — expected (defn NAME [params] ReturnType body...)`.
   Pass the original whole datum into the helper (do not reconstruct it after
   dropping a docstring or metadata) and emit exactly:

   `malformed defn — expected (defn name "doc"? [params...] ReturnType body...) or multi-arity (defn name ([params] ReturnType body...) ...); got: '<racket-written-datum>`

2. Change the `fn` fallback string from
   `fn needs (fn [params] ReturnType body...)` to exactly
   ``fn needs a return type and body — write `(fn [params] ReturnType body...)` ``.
3. Add exact-string parser tests for one malformed `defn` and one malformed
   `fn`. Do not change the accepted grammar or the verifier.

**Side and policy**

Only self-host changes. The particular prose is arbitrary reference wording;
matching it is justified solely by the existing exact-core gate. This closes
rows 27–28, 30, and 36.

## C10 soundness analysis

| Row / input | Racket result | Self-host result | Exact missing rejection |
|---|---|---|---|
| 20 — `1ecc23512d15.bclj` | Rejects with `bad type expression: '(->> (cond->> true false (map inc) false (* 100) true (- 10)) (dec) (* 42) (* (let (#%brackets n__18 999999) 65535)))` | Accepts | The threaded value expression occupies `f__14`'s return-type slot. `parse-type!` converts it to `Any`; the following vector/ref body is also `Any`-compatible and emits no error. |
| 35 — `e6a120c21932.bclj` | Rejects with `bad type expression: '(->> (some-> 1 (str "back\\slash") (+ 65535)) (inc) (conj (some? g__3)))` | Accepts | The threaded value expression occupies `f__4`'s return-type slot. It becomes `Any`; the later vector and valid `let` body do not create another rejection. |

C10 therefore shares Repair A and should be implemented in the same batch.
Treat the two verdict changes as the highest-priority assertions: after the
repair both must report `tail parity (R)`, never merely a matching message when
one side accepts.

## Verification recipe

After editing authored source, update the generated seed through the normal
bootstrap route, then force the parity verifier to execute that current seed
rather than any ambient native binary:

```sh
cd ~/code/beagle/worktrees/c9-checker-parity
bin/beagle-remint --promote --oracle
BEAGLE_NATIVE_BIN= self-host/verify-selfhost.sh
```

`verify-selfhost.sh` has no row filter for section 5b; module arguments do not
filter the checker-tail loop. The single invocation above is therefore the
exact verifier invocation for every C9 and C10 row. Other open clusters may
still make the overall script exit nonzero while this batch is being applied;
row closure is proved by these exact per-row receipts:

- Repair A C9: `PASS: <id> tail parity (R)` for `044333dc85bd`,
  `1c04be588e62`, `20b1c0026a1f`, `3d41f6a456b1`, `42ad2d259ad2`,
  `509a72f87c74`, `5b7b4c8034e8`, `94c783024a2d`, `9e37d4c1f2b7`,
  `c12eeda88def`, `c7786bec88f8`, and `fbeb9210ee4d`.
- Repair B: `PASS: 3a907432853b tail parity (R)` and
  `PASS: 6f151ff4eece tail parity (R)`.
- Repair C: `PASS: 62bd65163f0f tail parity (R)`,
  `PASS: 677470581f1a tail parity (R)`,
  `PASS: 7e9a14983210 tail parity (R)`, and
  `PASS: f036de687e29 tail parity (R)`.
- C10: `PASS: 1ecc23512d15 tail parity (R)` and
  `PASS: e6a120c21932 tail parity (R)`.

At campaign completion the same invocation must exit zero. Do not use direct
checker commands as a substitute for section 5b: only the verifier proves both
exit-status parity and its exact error-core extraction contract.

## Ordered application plan

1. After the live self-host owner releases the tree, create one Beagle lane
   `~/code/beagle/worktrees/c9-checker-parity` from current main. Re-read the
   named functions because current line numbers may have moved; preserve the
   function-level contract in this plan.
2. Implement the shared datum renderer and Repair A in `parse.bclj`. If
   qualified nominal admission needs plumbing, add only the closed nominal-name
   set to `parse.bclj`/`main.bclj`; do not weaken the new fallback. Add the
   parser unit tests in the same source module.
3. In the same file, apply Repair C's two exact message changes and tests. This
   reuses the renderer and avoids a second diagnostic projection mechanism.
4. Implement Repair B in `check.bclj` and add the two causal-error tests plus
   the unresolved-cycle control.
5. Run `bin/beagle-remint --promote --oracle`. Review and stage the authored
   source and corresponding generated seed files together; expected generated
   changes are `self-host/seed/selfhost/parse.clj`,
   `self-host/seed/selfhost/check.clj`, and `self-host/seed/selfhost/main.clj`
   only if nominal-name plumbing changed `main.bclj`.
6. Run `BEAGLE_NATIVE_BIN= self-host/verify-selfhost.sh` once. Check the twenty
   exact receipts above. A remaining C9/C10 failure is a defect in this batch;
   an unrelated pre-recorded cluster does not invalidate a present row-level
   receipt.
7. Commit the coherent source-plus-seed batch with enumerated paths, land it
   through the repository's normal safe-push route, and rerun no broader gate
   unless the campaign owner has named it as the next release check.

## Acceptance boundary

The batch is complete when all eighteen C9 rows and both C10 rows print the
listed `tail parity (R)` receipts. It does not include changing Racket,
rewriting the verifier, weakening exact comparison, deleting fuzz repros,
normalizing messages after the fact, or repairing any other semantic-gap
cluster.
