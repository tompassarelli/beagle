# Beagle host-leakage rules — second tranche

> **MOVED TO DECIDED AUTHORITY — 2026-08-18**

## Status and authority

Overall status: **MOVED — ALL TEN RULES ARE AUTHORITATIVE IN
`LEAKAGE-RULES-DECIDED.md` AS OF 2026-08-18**.

This document is retained as the tranche review record. The ten rules moved to
the single authoritative document
`beagle:beagle-test/conformance/authority/positioning/LEAKAGE-RULES-DECIDED.md` on
2026-08-18. It is not language authority and must not be read as a corpus
admission. No case payloads are authored here.

The selection uses the trace3 dimension universe and join shape in
`beagle:beagle-test/conformance/divergence-coverage.json`. The commander-stated
coverage ground truth for this tranche is **1,804 divergence dimensions with no
deciding rule**. The six dimension names used below are the universe's
`evaluation-order`, `strictness-laziness`, `allocation-representation`,
`effects`, `identity-equality`, and `failure-behavior` questions. A listed
dimension is a proposal target, not a claim that this document has decided it.

All four profiles are named explicitly because a host implementation is not a
profile exception. The profile table says what a future case must establish;
`case payload: not authored` is intentional.

## Selection evidence

Call-site counts were obtained from direct list-form matches of the form
`(builtin` followed by whitespace or `)` over the language sources in
`greywrought:main/src/` (`.bgl` and `.bjs`) and non-Racket language sources in
`beagle:beagle-lib/` (`.bgl`, `.bjs`, `.bclj`, `.bnix`, `.bb`, and `.clj`).
The split is shown so the counts are auditable and do not mistake the
compiler's Racket implementation calls such as Racket `format` for Beagle
call sites. Covered rows were not candidates; the remaining rows were ranked
by call-site frequency, then joined to the dimensions present for that builtin
in the trace3 universe.

| Rank | Builtin | greywrought | beagle-lib | Total call sites | Undecided dimensions in join |
|---:|---|---:|---:|---:|---:|
| 1 | `defn` | 3,667 | 22 | 3,689 | 6 |
| 2 | `=` | 2,044 | 0 | 2,044 | 3 |
| 3 | `if` | 1,995 | 5 | 2,000 | 6 |
| 4 | `js/export` | 1,839 | 0 | 1,839 | 5 |
| 5 | `nth` | 1,553 | 0 | 1,553 | 6 |
| 6 | `let` | 1,520 | 19 | 1,539 | 6 |
| 7 | `+` | 1,308 | 0 | 1,308 | 6 |
| 8 | `js/call` | 1,304 | 0 | 1,304 | 5 |
| 9 | `js/get` | 1,147 | 0 | 1,147 | 5 |
| 10 | `not` | 1,077 | 0 | 1,077 | 6 |

The call-site source roots are the cited real-code inputs for every count in
the table. The dimension join is the cited corpus input. The selected row IDs
are:

```text
defn::{evaluation-order,strictness-laziness,allocation-representation,effects,identity-equality,failure-behavior}
=::{strictness-laziness,effects,failure-behavior}
if::{evaluation-order,strictness-laziness,allocation-representation,effects,identity-equality,failure-behavior}
js/export::{evaluation-order,strictness-laziness,allocation-representation,effects,identity-equality}
nth::{evaluation-order,strictness-laziness,allocation-representation,effects,identity-equality,failure-behavior}
let::{evaluation-order,strictness-laziness,allocation-representation,effects,identity-equality,failure-behavior}
+::{evaluation-order,strictness-laziness,allocation-representation,effects,identity-equality,failure-behavior}
js/call::{evaluation-order,strictness-laziness,allocation-representation,effects,identity-equality}
js/get::{evaluation-order,strictness-laziness,allocation-representation,effects,identity-equality}
not::{evaluation-order,strictness-laziness,allocation-representation,effects,identity-equality,failure-behavior}
```

## Shared proposal conventions

These are proposal conventions only. They make the ten sections comparable and
do not silently decide dimensions outside a section.

- Every semantic key and future receipt must carry profile identity. A future
  case must run under `core`, `hosted-clj`, `hosted-js`, and
  `hosted-nix` where the surface is available. A profile that cannot provide a
  surface must produce the named target-availability error, not host success.
- If any author-observable strictness, resource, lifetime, effect, identity,
  failure, or promised-complexity behavior differs by profile, the operation
  must have a profile-qualified Beagle name or an explicit error contract; a
  shared name may not conceal the difference.
- Error identifiers are semantic identifiers. Hosts may add locations and
  explanations but may not replace them with a host exception class.
- Unless a rule says otherwise, arguments and subforms are evaluated
  left-to-right, values are immutable, and no allocation identity is
  author-observable.
- Every table below is a future case matrix, not a case payload or a proof.

## 1. `HL-DEFN-BINDING-AND-INVOCATION`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- The compiler represents a definition with name, parameters, rest parameter,
  return type, raises contract, documentation, and body facts:
  `beagle:beagle-lib/private/emit-facts.rkt:241`–`251`.
- Clojure emission lowers a `defn` form into a host `defn`, including callable
  signatures and body emission: `beagle:beagle-lib/private/emit-clj.rkt:561`–`577`.
- Compile-time binding walks and hygiene handling explicitly treat `defn` as a
  binding form: `beagle:beagle-lib/private/macros.rkt:884`–`928` and
  `beagle:beagle-lib/private/macros.rkt:1098`.

### DECIDED rule

1. `defn` creates one named Beagle function binding after its declaration is
   checked. Declaration checking is compile-time and executes no body, default,
   or user effect. A declaration with an unresolved type, malformed parameter,
   duplicate parameter, or invalid rest position is rejected with
   `BEAGLE-DEFN-SIGNATURE`.
2. A function has exactly its declared fixed arities plus one declared rest
   arity when present. A call with no matching arity is
   `BEAGLE-ARITY`; a call never falls through to a host overload or performs
   host varargs coercion. Fixed arguments bind left-to-right, then rest
   arguments in source order.
3. Definitions in one namespace are checked and bound as a definition SCC.
   Every function in that SCC is available by its semantic name throughout the
   SCC, so mutual recursion is valid without an explicit recursive-group form.
   The function body runs only on invocation. Its parameters and lexical
   captures are Beagle values, and a recursive reference resolves to the same
   semantic function binding. Definition order, host closure addresses, and
   generated function names are not observable identity. A function is not
   identity-bearing: `identical?` rejects it with
   `BEAGLE-NONIDENTITY-VALUE`, as required by `HL-EQUALITY-HASHING`.
4. A declared return contract is checked at the Beagle boundary. A mismatch is
   `BEAGLE-RETURN-DOMAIN`; a declared `raises` failure preserves its Beagle
   error identifier. Function construction and invocation do not acquire
   capabilities unless the body performs a separately declared effect.
5. All profiles expose the same arity, binding, error, and recursion behavior.
   A profile may lower the function differently, but cannot expose host
   overload selection, host closure identity, or host exception behavior.

### Per-profile case table — payload not authored

| Profile | Future case ID | Proposed assertion |
|---|---|---|
| Core | `draft-hl-defn-core` | Signature checking, arity, left-to-right binding, recursion, and return failure use this rule. |
| Hosted Clojure | `draft-hl-defn-hosted-clj` | Same semantic function and error behavior; no Clojure var/arity leakage. |
| Hosted JavaScript | `draft-hl-defn-hosted-js` | Same semantic function and error behavior; no JavaScript function identity or `arguments` leakage. |
| Hosted Nix | `draft-hl-defn-hosted-nix` | Same semantic function and error behavior; no Nix lambda or thunk leakage. |

### Error vocabulary

`BEAGLE-DEFN-SIGNATURE`, `BEAGLE-ARITY`, `BEAGLE-RETURN-DOMAIN`,
`BEAGLE-UNSUPPORTED-TARGET`, and the declared body error identifiers.

### Divergence dimensions and risk

This proposal covers `defn::evaluation-order`, `defn::strictness-laziness`,
`defn::allocation-representation`, `defn::effects`,
`defn::identity-equality`, and `defn::failure-behavior`. Host overloads,
lazy closures, generated names, and exception/arity differences can otherwise
make the same declaration mean different programs.

### Smallest deterministic conformance case — not authored

One source declaration exercises zero, one, multiple, and rest arities,
duplicate parameters, recursive self-call, an effectful body that must not run
at declaration time, and a return mismatch. It records only the expected
semantic outputs/errors for the four future profile cases; no payload is in
this document.

### Open Questions

- None. The operator decided on 2026-08-18 that `defn` provides namespace-level
  mutual recursion across a definition SCC.

## 2. `HL-EQUALITY-CALL-SEQUENCING`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

Verdict: **PROMOTE**.

### Current behavior observed

- The portable surface exposes `=` over `Any` values:
  `beagle:beagle-lib/private/stdlib-portable.rkt:139`.
- The decided equality rule defines the value relation and hashing algorithm,
  but the trace3 join still lists this builtin's strictness, effects, and
  failure rows as uncovered: `beagle:beagle-test/conformance/divergence-coverage.json`.
- The existing host implementations have different host evaluation and
  exception paths; the equality rule itself warns that host identity and
  coercion are not authority: `beagle:beagle-test/conformance/authority/positioning/LEAKAGE-RULES-DECIDED.md:152`–`229`.

### DECIDED rule

1. For every arity admitted by the portable surface, `=` evaluates operands
   left-to-right until the first unequal adjacent pair, then stops. It evaluates
   no operand after that point and never calls a host equality method as a
   hidden effect. Surface arity is parser/type authority, not invented here.
2. The comparison relation is exactly the domain-strict relation decided by
   `HL-EQUALITY-HASHING`. This rule adds sequencing: no lazy host collection
   traversal, coercion, callback, hash-seed dependency, or host pointer test is
   permitted.
3. Values that the equality contract does not admit produce
   `BEAGLE-UNSUPPORTED-VALUE-SEMANTICS` at the static boundary when their type
   is known and the same identifier at an `Any` boundary. An equality operation
   never returns a host sentinel or throws a host exception.
4. Equality is pure and allocation-free from the author's perspective. Any
   internal canonicalization is not an identity-bearing value and cannot
   change the result between profiles.

### Per-profile case table — payload not authored

| Profile | Future case ID | Proposed assertion |
|---|---|---|
| Core | `draft-hl-equality-call-sequencing-core` | Left-to-right short-circuit and semantic error identifiers. |
| Hosted Clojure | `draft-hl-equality-call-sequencing-hosted-clj` | Same sequence; no Clojure `=` coercion or exception leakage. |
| Hosted JavaScript | `draft-hl-equality-call-sequencing-hosted-js` | Same sequence; no `===`, object identity, or coercion leakage. |
| Hosted Nix | `draft-hl-equality-call-sequencing-hosted-nix` | Same sequence; no lazy attrset comparison leakage. |

### Error vocabulary

`BEAGLE-UNSUPPORTED-VALUE-SEMANTICS`.

### Divergence dimensions and risk

This rule covers `=::strictness-laziness`, `=::effects`, and
`=::failure-behavior`. It is deliberately narrower than the already decided
value relation and hash algorithm. Host equality can invoke user code, walk a
different representation, or turn an unsupported value into a host boolean.

### Smallest deterministic conformance case — not authored

Compare admitted two- and four-operand calls with a rightmost effect marker,
first-unequal marker, unsupported value, and equal values represented by
different hosts. The future case checks both skipped effects and the semantic
error identifier.

### Open Questions

- None. `HL-EQUALITY-HASHING` already decides adjacent-pair short-circuiting,
  skipped later operands, and the exact unsupported-value error; this rule does
  not change the surface arity contract.

## 3. `HL-IF-BRANCH-EXECUTION`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

Verdict: **PROMOTE**.

### Current behavior observed

- The compiler's binding and macro machinery recognizes `if`-family forms and
  lowers them through host conditionals: `beagle:beagle-lib/private/macros.rkt:1007`–`1109`.
- The portable library documents the related nil-narrowing surface around
  `if` and `when`: `beagle:beagle-lib/private/stdlib-clj.rkt:93`.
- The decided truthiness rule supplies the intended truth table, but this
  builtin's full six-row host join remains undecided:
  `beagle:beagle-test/conformance/divergence-coverage.json`.

### DECIDED rule

1. `if` evaluates exactly one test expression once. It evaluates the then
   branch when the test is truthy under the Beagle truth table and otherwise
   evaluates the else branch, if present. The unselected branch is not
   evaluated and cannot produce an effect, allocation, or error.
2. The result is the selected branch's Beagle value. A host's falsey empty
   collection, zero, NaN, `undefined`, or missing value does not alter the
   Beagle truth table. The parser owns the accepted source arities; this rule
   does not invent an omitted-else result.
3. A foreign value crossing the test boundary without a Beagle domain is
   `BEAGLE-FOREIGN-VALUE`. No host conditional exception or sentinel is
   observable.
4. Test and selected-branch effects follow source order. `if` itself is pure,
   does not allocate an author-visible identity, and has the same behavior in
   every profile.

### Per-profile case table — payload not authored

| Profile | Future case ID | Proposed assertion |
|---|---|---|
| Core | `draft-hl-if-branch-execution-core` | Test once, selected branch only, Beagle truthiness, and named errors. |
| Hosted Clojure | `draft-hl-if-branch-execution-hosted-clj` | No Clojure falsey empty collection or lazy branch leakage. |
| Hosted JavaScript | `draft-hl-if-branch-execution-hosted-js` | No JavaScript falsy coercion, `undefined`, or eager branch leakage. |
| Hosted Nix | `draft-hl-if-branch-execution-hosted-nix` | No Nix thunk or null coercion leakage. |

### Error vocabulary

`BEAGLE-FOREIGN-VALUE` for an untagged foreign test value; parser-owned syntax
errors retain their existing semantic identifier.

### Divergence dimensions and risk

This rule covers all six `if` rows in the join. The load-bearing leak is
branch eagerness: a host may evaluate the unselected branch, use a different
falsey set, allocate a host sentinel, or report a host exception.

### Smallest deterministic conformance case — not authored

Use each falsey/truthy boundary, an effect marker in each branch, a failing
unselected branch, and a foreign-value boundary. The future case must show the
exact selected output and that the unselected marker is absent.

### Open Questions

- None. This rule is the operational projection of `HL-TRUTHINESS`; an
  untagged foreign value is `BEAGLE-FOREIGN-VALUE`, and an unobservable fast
  path is an implementation detail.

## 4. `HL-JS-EXPORT-BOUNDARY`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- `js/export` is registered as a compile-time combiner and strips or retains
  target export structure during parsing: `beagle:beagle-lib/private/parse.rkt:276`
  and `beagle:beagle-lib/private/parse.rkt:4197`–`4207`.
- The module interface describes `js/export` as the deliberate JavaScript
  publication surface: `beagle:beagle-lib/private/module-interface.rkt:237`–`240`.
- Deep checking is required for an export-wrapped definition, and the checker
  rejects a missing export wrapper at the module boundary:
  `beagle:beagle-lib/private/check.rkt:3997` and `beagle:beagle-lib/private/check.rkt:9078`.

### DECIDED rule

1. `js/export` is available only in the JavaScript profile. In `core`, hosted
   Clojure, and hosted Nix, use is a static `BEAGLE-TARGET-UNAVAILABLE` error;
   it is never silently ignored or reinterpreted as a host export form.
2. On JavaScript, the inner declaration is checked completely before the
   module publication is formed. `js/export` publishes snapshot own-data
   bindings under canonical Beagle qualified names, deterministically and
   independently of source map, bundler, or property enumeration order. It
   does not publish live bindings or getters. `js/export-default` is a separate
   form; default-export behavior is not part of `js/export`.
3. Each exported name is published once. Duplicate or conflicting named
   exports are `BEAGLE-EXPORT-CONFLICT`; an unexportable value is
   `BEAGLE-EXPORT-DOMAIN`. Export construction has no author-observable side
   effect beyond the module publication boundary.
4. Values crossing the boundary retain their Beagle domain. Callbacks and
   returned values cross only through explicit capability/codec contracts; a
   mutable or foreign value requires its declared contract. `js/export` never
   exposes an arbitrary host callback, getter, or live host object.
5. No profile may expose a host module object, live-binding timing, property
   ordering, getter behavior, or host exception as a substitute semantic
   result.

### Per-profile case table — payload not authored

| Profile | Future case ID | Proposed assertion |
|---|---|---|
| Core | `draft-hl-js-export-boundary-core` | Reject with `BEAGLE-TARGET-UNAVAILABLE` before execution. |
| Hosted Clojure | `draft-hl-js-export-boundary-hosted-clj` | Reject with `BEAGLE-TARGET-UNAVAILABLE`; no namespace publication. |
| Hosted JavaScript | `draft-hl-js-export-boundary-hosted-js` | Publish canonical snapshot own-data named exports exactly once; default publication uses `js/export-default`. |
| Hosted Nix | `draft-hl-js-export-boundary-hosted-nix` | Reject with `BEAGLE-TARGET-UNAVAILABLE`; no attrset reinterpretation. |

### Error vocabulary

`BEAGLE-TARGET-UNAVAILABLE`, `BEAGLE-EXPORT-CONFLICT`,
`BEAGLE-EXPORT-DOMAIN`, `BEAGLE-FOREIGN-VALUE`, and
`BEAGLE-UNSPECIFIED-SEMANTICS` for an unclassified boundary value.

### Divergence dimensions and risk

This proposal covers `js/export::evaluation-order`,
`js/export::strictness-laziness`, `js/export::allocation-representation`,
`js/export::effects`, and `js/export::identity-equality`. Export lowering is a
host/module boundary: eager module evaluation, live bindings, default-export
conventions, object identity, and bundler ordering can all leak.

### Smallest deterministic conformance case — not authored

One module exports a scalar, function, mutable/foreign boundary value, named
binding, duplicate name, and default binding under each profile. The future
case checks publication names and errors only; it does not prescribe a case
payload here.

### Open Questions

- None. The operator decided on 2026-08-18 that `js/export` is the snapshot
  own-data boundary, that callbacks and returned values require explicit
  capability/codec contracts, and that `js/export-default` is separate; live
  bindings, getters, and default-export behavior on `js/export` are excluded.

## 5. `HL-NTH-INDEX-ACCESS`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- The portable signature gives `nth` a vector and an `Int` index:
  `beagle:beagle-lib/private/stdlib-portable.rkt:28`–`30`.
- The collection accessor audit calls out `nth` with the other element
  accessors, indicating a shared host-sensitive surface:
  `beagle:beagle-lib/private/stdlib-clj.rkt:457`.
- The decided collection rule constrains collection ordering, but the six
  `nth` dimensions remain a separate join target:
  `beagle:beagle-test/conformance/divergence-coverage.json`.

### DECIDED rule

1. The canonical `nth` contract is exactly `Vec × Int -> element`. `nth`
   evaluates the vector expression, then the index expression, requires a
   Beagle `Vec` and exact `Int`, and returns the element at zero-based index
   `i`. No other sequential domain, implicit sequence conversion, host array
   coercion, or lazy realization is admitted.
2. A negative index or index at least the vector count is exactly
   `BEAGLE-INDEX-OUT-OF-RANGE`. A non-`Vec` collection or non-`Int` index is
   `BEAGLE-NTH-DOMAIN`. Bounds violations have no non-error result: there is no
   host `IndexOutOfBoundsException`, `undefined`, or nil fallback.
3. Access does not mutate the vector, allocate author-visible identity, or
   invoke user code. The returned value has the vector element's Beagle domain
   and any identity-bearing element retains its identity token.
4. Core, hosted Clojure, hosted JavaScript, and hosted Nix use the same bounds,
   ordering, representation, and errors, regardless of the host collection
   implementation.

### Per-profile case table — payload not authored

| Profile | Future case ID | Proposed assertion |
|---|---|---|
| Core | `draft-hl-nth-index-access-core` | Exact vector indexing and named domain/bounds errors. |
| Hosted Clojure | `draft-hl-nth-index-access-hosted-clj` | No Clojure sequential coercion or host exception leakage. |
| Hosted JavaScript | `draft-hl-nth-index-access-hosted-js` | No array negative-property, `undefined`, or sparse-array leakage. |
| Hosted Nix | `draft-hl-nth-index-access-hosted-nix` | No list/thunk coercion or attrset lookup leakage. |

### Error vocabulary

`BEAGLE-NTH-DOMAIN`, `BEAGLE-INDEX-OUT-OF-RANGE`,
`BEAGLE-FOREIGN-VALUE`, and `BEAGLE-UNSPECIFIED-SEMANTICS` only for a value
class not yet admitted by the collection contract.

### Divergence dimensions and risk

This proposal covers all six `nth` rows. Host indexing differs on negative
indices, sparse arrays, lazy sequences, bounds exceptions, and whether access
preserves or manufactures object identity.

### Smallest deterministic conformance case — not authored

Index an empty, singleton, and multi-element vector at both bounds, negative
indices, a large index, and a vector containing an identity-bearing element;
also use a non-vector and non-Int index. No payload is included here.

### Open Questions

- None. The operator decided on 2026-08-18 that the contract is exactly
  `Vec × Int -> element`, zero-based, with `BEAGLE-INDEX-OUT-OF-RANGE` and no
  other sequential domain or non-error bounds result.

## 6. `HL-LET-BINDING-SEQUENCE`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- The compiler has a dedicated lexical `let` binding walker and records
  binding targets and values: `beagle:beagle-lib/private/macros.rkt:796`–`804`.
- Clojure emission lowers `let` through an explicit binding emitter and body
  emitter: `beagle:beagle-lib/private/emit-clj.rkt:837`–`840`.
- The facts emitter records each let binding's target, annotation, constraint,
  and value: `beagle:beagle-lib/private/emit-facts.rkt:135`–`142`.

### DECIDED rule

1. `let` owns name introduction for the whole binding vector. Every leaf name
   introduced across that vector, including every name introduced by a
   destructuring pattern, must be unique. Any duplicate is rejected with
   `BEAGLE-DUPLICATE-BINDING`; shadowing an outer binding is allowed.
2. This rule pins name existence and uniqueness only. Destructuring-pattern
   matching and evaluation semantics, including binding RHS order and the
   visibility of names during evaluation, remain outside this rule for a
   separate future rule.
3. A malformed binding vector or invalid name-introduction shape is
   `BEAGLE-LET-FORM`. This rule does not assign a destructuring mismatch or
   evaluation failure to a host-specific result.
4. Host stack slots, JavaScript `let`/`const`, Clojure locals, and Nix thunks
   are implementation strategies only. They must not change the set of names
   introduced by one binding vector or the duplicate-name rejection.

### Per-profile case table — payload not authored

| Profile | Future case ID | Proposed assertion |
|---|---|---|
| Core | `draft-hl-let-binding-sequence-core` | Every introduced leaf name is present once; duplicates reject independent of destructuring evaluation. |
| Hosted Clojure | `draft-hl-let-binding-sequence-hosted-clj` | Same name set and duplicate rejection; no local or lazy-seq leakage. |
| Hosted JavaScript | `draft-hl-let-binding-sequence-hosted-js` | Same name set and duplicate rejection; no temporal-dead-zone or `const` leakage. |
| Hosted Nix | `draft-hl-let-binding-sequence-hosted-nix` | Same name set and duplicate rejection; no thunk or attrset binding leakage. |

### Error vocabulary

`BEAGLE-DUPLICATE-BINDING`, `BEAGLE-LET-FORM`, and any error identifier owned
by the separate destructuring matching/evaluation rule.

### Divergence dimensions and risk

This rule covers the name-introduction portion of all six `let` rows. The
dangerous host leaks are different leaf-name enumeration, duplicate acceptance,
and host-specific binding identity; RHS matching and evaluation are deliberately
reserved for a separate rule.

### Smallest deterministic conformance case — not authored

Use one binding vector containing simple names, outer shadowing, and
destructuring patterns with a duplicate leaf name. The future case asserts the
complete introduced-name set and exact duplicate rejection; matching and
evaluation cases belong to the separate future rule.

### Open Questions

- None. The operator decided on 2026-08-18 that this rule owns name
  introduction and uniqueness across the whole binding vector, including every
  destructuring leaf, while matching and evaluation remain a separate future
  rule.

## 7. `HL-PLUS-NUMERIC-DISPATCH`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- The portable signature exposes variadic `+` over `Number`:
  `beagle:beagle-lib/private/stdlib-portable.rkt:114`.
- Numeric host behavior is already recognized as divergent in the decided
  document, including host promotion and printing:
  `beagle:beagle-test/conformance/authority/positioning/LEAKAGE-RULES-DECIDED.md:35`–`67`.
- The trace3 join still names all six `+` dimensions as uncovered, so this is
  a proposal for the call/dispatch boundary, not a replacement decision for
  the numeric model: `beagle:beagle-test/conformance/divergence-coverage.json`.

### DECIDED rule

1. `+` evaluates operands left-to-right. Zero operands returns `Int(0)`; one
   operand returns the validated operand `x`; more operands fold in source
   order.
2. Dispatch and promotion use only the Beagle numeric domains. No host numeric
   tower, JavaScript `Number`, Clojure ratio, or Nix coercion is consulted.
   Ranges, rounding, overflow, NaN, signed zero, and serialization are exactly
   those of the decided `HL-NUMBER-SEMANTICS`. In particular, `U64` has no
   implicit generic arithmetic or mixed-Float route.
3. A non-number operand or a numeric domain excluded from generic arithmetic is
   `BEAGLE-NUMERIC-DOMAIN`; overflow is `BEAGLE-NUMERIC-OVERFLOW`. The first
   failing operand stops the fold.
4. `+` is pure and has no allocation or identity effect. Every profile exposes
   the same zero/one/variadic arity and failure order.

### Per-profile case table — payload not authored

| Profile | Future case ID | Proposed assertion |
|---|---|---|
| Core | `draft-hl-plus-numeric-dispatch-core` | Numeric domain dispatch, fold order, and named failures. |
| Hosted Clojure | `draft-hl-plus-numeric-dispatch-hosted-clj` | No ratio/promotion/host numeric exception leakage. |
| Hosted JavaScript | `draft-hl-plus-numeric-dispatch-hosted-js` | No binary64-only coercion or `NaN` sentinel leakage. |
| Hosted Nix | `draft-hl-plus-numeric-dispatch-hosted-nix` | No Nix numeric coercion or lazy fold leakage. |

### Error vocabulary

`BEAGLE-NUMERIC-DOMAIN`, `BEAGLE-NUMERIC-OVERFLOW`, and
`BEAGLE-NUMERIC-RANGE` only for an explicit conversion or result whose range is
invalid under `HL-NUMBER-SEMANTICS`.

### Divergence dimensions and risk

This proposal covers all six `+` rows. It closes the high-frequency call-site
boundary where a host can change evaluation order, promotion, intermediate
representation, overflow, identity, or failure while appearing to implement
the same arithmetic.

### Smallest deterministic conformance case — not authored

Use zero, one, mixed-domain, boundary, overflowing, non-number, signed-zero,
and NaN operands with an effect marker in each position. The future case must
reference the decided numeric expected values rather than introduce payloads
here.

### Open Questions

- None. The operator decided on 2026-08-18 that zero and one arity are admitted:
  `(+ )` evaluates to `Int(0)` and `(+ x)` evaluates to validated `x`.

## 8. `HL-JS-CALL-DISPATCH`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- `js/call` is a registered target combiner requiring a receiver, member key,
  and optional arguments: `beagle:beagle-lib/private/parse.rkt:4141`–`4149`.
- The checker has a dedicated callable-type diagnostic and form record for
  `js/call`: `beagle:beagle-lib/private/check.rkt:6167`–`6178`.
- The public cheatsheet shows both static and dynamic member calls, making
  receiver/key evaluation and host `this` binding observable:
  `beagle:beagle-lib/private/cheatsheet.rkt:92`–`98`.

### DECIDED rule

1. `js/call` evaluates receiver, member key, and arguments left-to-right, then
   performs one member lookup and one call. The receiver is the explicit Beagle
   receiver and is the only permitted `this`/method context.
2. A missing member is `BEAGLE-JS-MEMBER-MISSING`; a non-callable member is
   `BEAGLE-JS-NONCALLABLE`; getters and Promises are rejected at this boundary.
   A JavaScript throw crosses the boundary as `BEAGLE-JS-THROWN` with the fixed
   data-only semantic payload, never as an arbitrary host exception class.
3. The call requires the declared foreign-effect capability. A Beagle value may
   be returned directly only under its declared codec contract; every returned
   object is wrapped as an identity-bearing foreign handle. Callbacks cross only
   under an explicit capability/codec contract. Promises are never silently
   awaited or coerced.
4. Lookup and call have no hidden retry, getter duplication, argument reorder,
   host overload selection, or author-visible allocation identity beyond the
   returned foreign-handle identity mandated above. Non-JS profiles reject with
   `BEAGLE-TARGET-UNAVAILABLE`.

### Per-profile case table — payload not authored

| Profile | Future case ID | Proposed assertion |
|---|---|---|
| Core | `draft-hl-js-call-dispatch-core` | Reject as target unavailable before foreign execution. |
| Hosted Clojure | `draft-hl-js-call-dispatch-hosted-clj` | Reject as target unavailable; no Clojure interop reinterpretation. |
| Hosted JavaScript | `draft-hl-js-call-dispatch-hosted-js` | One ordered lookup/call with explicit receiver and named failures. |
| Hosted Nix | `draft-hl-js-call-dispatch-hosted-nix` | Reject as target unavailable; no Nix function coercion. |

### Error vocabulary

`BEAGLE-TARGET-UNAVAILABLE`, `BEAGLE-JS-MEMBER-MISSING`,
`BEAGLE-JS-NONCALLABLE`, `BEAGLE-JS-THROWN`, `BEAGLE-JS-GETTER`,
`BEAGLE-JS-PROMISE`, `BEAGLE-FOREIGN-EFFECT`, and `BEAGLE-FOREIGN-VALUE`.

### Divergence dimensions and risk

This proposal covers `js/call::evaluation-order`, `js/call::strictness-laziness`,
`js/call::allocation-representation`, `js/call::effects`, and
`js/call::identity-equality`. JavaScript getters, method receiver rules,
promises, thrown values, and object identity are direct host leaks.

### Smallest deterministic conformance case — not authored

Call a static member, dynamic member, missing member, non-callable member,
getter, Promise, throwing member, returned object, and callback with effect
markers in receiver/key/args. Run the profile matrix without adding any case
payload here.

### Open Questions

- None. The operator decided on 2026-08-18 that this is the closed interop
  boundary: getters and Promises reject, throws use the fixed data-only payload,
  and every returned object is an identity-bearing foreign handle.

## 9. `HL-JS-GET-DISPATCH`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- `js/get` is a registered combiner requiring exactly a receiver and member
  key: `beagle:beagle-lib/private/parse.rkt:4132`–`4139`.
- The checker has a dedicated `js/get` form and diagnostic path:
  `beagle:beagle-lib/private/check.rkt:6137`–`6140`.
- The cheatsheet documents both static and dynamic key access:
  `beagle:beagle-lib/private/cheatsheet.rkt:92`–`98`.

### DECIDED rule

1. `js/get` evaluates the receiver then the member key exactly once and reads
   one property under the declared JavaScript interop capability. It does not
   search Beagle maps, prototype chains, or host representations implicitly.
2. The read is own-property and data-only. A missing member is exactly
   `BEAGLE-JS-MEMBER-MISSING`; there is no inherited-property search and no
   `Undefined` result. Getters and proxies are rejected, not invoked. A
   non-object receiver is `BEAGLE-JS-RECEIVER-DOMAIN`; an invalid key is
   `BEAGLE-JS-KEY-DOMAIN`.
3. The result is a declared Beagle value or foreign handle; every returned
   object is wrapped as an identity-bearing foreign handle. Getter/proxy
   behavior and host allocation identity are never invisible implementation
   details, and no getter throw is exposed as a host result.
4. Non-JavaScript profiles reject with `BEAGLE-TARGET-UNAVAILABLE`. No profile
   may turn a missing property into a host sentinel without the explicit
   reviewed conversion contract.

### Per-profile case table — payload not authored

| Profile | Future case ID | Proposed assertion |
|---|---|---|
| Core | `draft-hl-js-get-dispatch-core` | Reject as target unavailable before lookup. |
| Hosted Clojure | `draft-hl-js-get-dispatch-hosted-clj` | Reject as target unavailable; no map/Java interop fallback. |
| Hosted JavaScript | `draft-hl-js-get-dispatch-hosted-js` | One ordered property read with explicit missing/domain behavior. |
| Hosted Nix | `draft-hl-js-get-dispatch-hosted-nix` | Reject as target unavailable; no attrset fallback. |

### Error vocabulary

`BEAGLE-TARGET-UNAVAILABLE`, `BEAGLE-JS-MEMBER-MISSING`,
`BEAGLE-JS-RECEIVER-DOMAIN`, `BEAGLE-JS-KEY-DOMAIN`, `BEAGLE-JS-GETTER`,
`BEAGLE-JS-PROXY`, `BEAGLE-FOREIGN-EFFECT`, and `BEAGLE-FOREIGN-VALUE`.

### Divergence dimensions and risk

This proposal covers `js/get::evaluation-order`, `js/get::strictness-laziness`,
`js/get::allocation-representation`, `js/get::effects`, and
`js/get::identity-equality`. The principal leaks are JavaScript `undefined`,
prototype/inherited lookup, getters/proxies, and host object identity.

### Smallest deterministic conformance case — not authored

Read an own data property, inherited property, missing property, getter, proxy,
dynamic key, invalid key, and invalid receiver with ordered effect markers. The
future case asserts own-data success and the named rejection for every excluded
boundary behavior.

### Open Questions

- None. The operator decided on 2026-08-18 that `js/get` is the closed own-data
  boundary: missing members error, returned objects wrap as foreign handles,
  and inherited properties, getters, proxies, and `Undefined` are excluded.

## 10. `HL-NOT-BOOLEAN-NEGATION`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

Verdict: **PROMOTE**.

### Current behavior observed

- The portable signature currently advertises `not` as taking `Bool`:
  `beagle:beagle-lib/private/stdlib-portable.rkt:156`.
- The decided truthiness rule says `not` accepts any admitted value and returns
  the negated Beagle truth value, creating an explicit signature/semantic
  boundary to review: `beagle:beagle-test/conformance/authority/positioning/LEAKAGE-RULES-DECIDED.md:313`–`369`.
- The trace3 join lists all six `not` dimensions as uncovered:
  `beagle:beagle-test/conformance/divergence-coverage.json`.

### DECIDED rule

1. `not` evaluates exactly one operand once and returns a Beagle `Bool`. It
   applies the same truth table as `HL-TRUTHINESS`: only `false` and `nil` are
   falsey; every other admitted Beagle value is truthy.
2. `not` is pure, constant-time after required closed-union tag dispatch, and
   allocates no author-visible value identity. It does not call host Boolean
   coercion, inspect collection emptiness, or turn `undefined` into false.
3. A foreign value without a Beagle domain is `BEAGLE-FOREIGN-VALUE`. The
   current Bool-only portable signature must migrate: every admitted Beagle
   value is a valid operand, exactly as `HL-TRUTHINESS` decides.
4. The result and all failures are deterministic and independent of host
   object representation, exception classes, and optimization.

### Per-profile case table — payload not authored

| Profile | Future case ID | Proposed assertion |
|---|---|---|
| Core | `draft-hl-not-boolean-negation-core` | Exact Beagle truth table, Bool result, and foreign-value rejection. |
| Hosted Clojure | `draft-hl-not-boolean-negation-hosted-clj` | No Clojure falsey-set or host Boolean leakage. |
| Hosted JavaScript | `draft-hl-not-boolean-negation-hosted-js` | No JavaScript falsy coercion, `undefined`, or object conversion leakage. |
| Hosted Nix | `draft-hl-not-boolean-negation-hosted-nix` | No Nix null/empty coercion leakage. |

### Error vocabulary

`BEAGLE-FOREIGN-VALUE`.

### Divergence dimensions and risk

This rule covers all six `not` rows. The current type surface and decided
truthiness prose disagree about accepted inputs; allowing each host to choose
would make a one-token negation vary by type checking, coercion, allocation,
and failure behavior.

### Smallest deterministic conformance case — not authored

Apply `not` to `nil`, `false`, `true`, zero, empty String, empty collection,
NaN, a record, a function, and a foreign value under each profile. The future
case asserts the decided Bool result or `BEAGLE-FOREIGN-VALUE`.

### Open Questions

- None. `HL-TRUTHINESS` already decides the polymorphic operand domain,
  foreign-value rejection, result, purity, and profile-independent behavior.

## Review closure

All ten tranche rules moved to `LEAKAGE-RULES-DECIDED.md` on 2026-08-18. This
review adds no corpus cases, alters no `beagle:beagle-test/conformance/` payload,
and authorizes no implementation change. The decided document is the single
authority afterward.

## Review Record

| Rule | Verdict | Break found | Repair made or question left |
|---|---|---|---|
| `HL-DEFN-BINDING-AND-INVOCATION` | HOLD | Function identity was posed as open despite `HL-EQUALITY-HASHING`; mutual-recursion scope remains unsupported by cited evidence. | Rejected function identity; operator must choose namespace SCC mutual recursion versus self-recursion/explicit groups. |
| `HL-EQUALITY-CALL-SEQUENCING` | PROMOTE | Invented `BEAGLE-EQUALITY-DOMAIN` contradicted the decided unsupported-value vocabulary; all three claimed dimensions were already decided. | Replaced the error and closed the redundant questions from `HL-EQUALITY-HASHING`. |
| `HL-IF-BRANCH-EXECUTION` | PROMOTE | The draft invented omitted-else and form-error semantics and reopened foreign-value treatment already decided by `HL-TRUTHINESS`. | Removed invented syntax semantics and made the rule the exact operational projection of decided truthiness. |
| `HL-JS-EXPORT-BOUNDARY` | HOLD | Live/snapshot timing, default exports, getters, callback capabilities, and boundary identity are author-observable and unsupported by the cited evidence. | Operator must choose the snapshot/data-only boundary or explicitly admit named alternatives. |
| `HL-NTH-INDEX-ACCESS` | HOLD | The portable signature is evidence, not authority for collection domain, bounds result, or exact errors. | Operator must choose exact Vec/Int/error semantics or admit other sequential/bounds behavior. |
| `HL-LET-BINDING-SEQUENCE` | HOLD | The draft invented duplicate/destructuring semantics beyond the cited binding/emission evidence. | Operator must decide whether this rule owns destructuring and cross-pattern duplicates. |
| `HL-PLUS-NUMERIC-DISPATCH` | HOLD | The draft treated settled numeric semantics as pending, admitted a future division error, mislabeled unavailable domains as range errors, and left zero/one arity undecided. | Aligned dispatch, `U64`, and errors with `HL-NUMBER-SEMANTICS`; operator must decide zero/one arity. |
| `HL-JS-CALL-DISPATCH` | HOLD | Getter, Promise, throw-payload, and returned-object identity semantics were invented or left host-shaped. | Operator must choose the closed interop boundary or explicitly admit named alternatives. |
| `HL-JS-GET-DISPATCH` | HOLD | Missing/inherited/getter/proxy/result-identity behavior remained a silent same-name divergence surface. | Operator must choose the own-data/error/foreign-handle boundary or explicitly admit named alternatives. |
| `HL-NOT-BOOLEAN-NEGATION` | PROMOTE | The Bool-only alternative directly contradicted decided `HL-TRUTHINESS`. | Required every admitted Beagle value, retained `BEAGLE-FOREIGN-VALUE`, and removed invented alternatives. |

Resolution 2026-08-18 — `HL-DEFN-BINDING-AND-INVOCATION`: namespace-level mutual recursion across a definition SCC.
Resolution 2026-08-18 — `HL-JS-EXPORT-BOUNDARY`: snapshot own-data bindings; explicit capability/codec crossings; separate `js/export-default`; no live bindings or getters.
Resolution 2026-08-18 — `HL-NTH-INDEX-ACCESS`: exactly `Vec × Int -> element`, zero-based, with `BEAGLE-INDEX-OUT-OF-RANGE` and no alternatives.
Resolution 2026-08-18 — `HL-LET-BINDING-SEQUENCE`: unique leaf-name introduction across the whole vector, including destructuring; matching/evaluation remain separate.
Resolution 2026-08-18 — `HL-PLUS-NUMERIC-DISPATCH`: zero arity is `Int(0)` and one arity returns the validated operand.
Resolution 2026-08-18 — `HL-JS-CALL-DISPATCH`: closed boundary rejecting getters and Promises, using a fixed data-only throw payload, and wrapping returned objects as foreign handles.
Resolution 2026-08-18 — `HL-JS-GET-DISPATCH`: closed own-data boundary with missing-member error, foreign handles for returned objects, and no inherited properties, getters, proxies, or `Undefined`.
