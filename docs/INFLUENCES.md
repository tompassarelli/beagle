# Influences

Beagle is a typed Clojure subset that compiles one AST to idiomatic code in
many languages. None of its *ingredients* are new — typed Lisps exist, Lean's
error machinery exists, Kernel's combiner-uniformity exists. What makes Beagle
a thing is what those ingredients are pointed at:

> **The compiler is a feedback engine for an agent, not a translator for a
> human.** Most languages' errors are designed for a person to read and act on.
> Beagle's are designed for a *program* to act on — structured, located,
> canonicalization-aware diagnostics and machine-applicable fixes that re-verify.

Everything below earns its seat by serving that thesis.

## Lean — diagnostics, as a discipline

Lean 4 treats error reporting as a first-class subsystem, not an afterthought.
We stole the mechanisms, not the type theory (Beagle is not dependently typed):

- **Structured messages (MessageData).** Diagnostics carry typed, structured
  payloads (`expected-type`/`actual-type`, missing union cases, …), not just
  prose — so a consumer acts on data instead of re-parsing English.
- **Source-position fidelity.** Origin/canonical position model with precise
  columns, so a fix lands on the exact span after we know *which*
  canonicalization ran.
- **`#guard_msgs`-style inline diagnostic tests.** Expected-error assertions
  live next to the code and update mechanically — diagnostics are regression-
  tested like any other output.
- **Macro hygiene.** Definition-site free-variable resolution; call-site blame
  that degrades gracefully.
- **Types-as-view via a delaborator.** The type shown in an error is a *pure
  view* rendered from the type, storing nothing — zero drift by construction,
  the way Lean renders terms. (`explain-type`.)

*Why it matters here:* the repair loop is only as good as the precision of what
it repairs. Lean is the proof that this precision is achievable and worth the
engineering.

*Provenance:* life-os umbrella `20260614120020` ("steal proven mechanisms from
lean4") and children `…0021`–`…0025`.

## Kernel (John Shutt) — one combiner rule

Kernel unifies macros and special forms under a single idea: *operatives* —
head-tagged combiners that receive their operands and dispatch by one rule.
Beagle takes that uniformity and makes one deliberate amputation:

- **No runtime fexprs.** True Kernel operatives receive *unevaluated* operands
  plus the live environment at runtime. Beagle emits Nix (and JS, Clojure, …) —
  targets with no runtime `eval` or reified environment. Runtime fexprs are
  therefore impossible, by construction, not by choice.
- **Operatives at compile time.** The achievable, correct realization: resolve
  combiners at compile time. One registry where every head — built-in
  (`let`/`if`/`match`/…) and user macro alike — is dispatched by one resolver
  and lowered to the *same typed IR* before any backend runs. A compile-time
  operative *is* a unified macro/special-form.
- **Naming discipline.** We call these **compile-time combiners**, not
  "operatives." The word "operative" implies runtime fexprs and cost months of
  confusion (it once spawned a quarantined runtime-evaluator prototype that
  never ran on the live path — since deleted).

*Why it matters here:* one dispatch rule → one IR means the *entire* surface is
uniformly analyzable and repairable. Two checkers and a bolted-on macro path
cannot be reasoned about as one thing — which is exactly why the phantom was
killed.

*Provenance:* `20260528223000` (operative-evaluator foundation),
`20260528214742` (Role-Locality design argument), and the definitive
ground-truth in `20260615034227` (compile-time combiner unification). See also
`CLAUDE.md` → "Architecture".

## ML family — type semantics, not ML's grammar

Beagle's type discipline is ML-lineage in *semantics*, deliberately not in
*surface*: algebraic data types, exhaustiveness checking over their cases,
explicit and bounded polymorphism, variance, and heterogeneous positional
types (`HVec`) all read as "what would a Hindley-Milner-family checker
enforce here" — realized as `defrecord`/`match`/`forall (T <: Bound)` inside
Clojure's own grammar, never ML's `let ... in`/`match ... with` concrete
syntax. Two amputations are deliberate, not oversights:

- **No ML grammar.** The borrowing stops at what the checker *proves*, not
  what the source *looks like* — see "The Lisp/Clojure/EDN surface" below for
  why the authoring medium stays s-expressions.
- **No claim to full Hindley-Milner.** Beagle infers interiors under explicit
  top-level annotations (`:-`); it does not claim principal-type global
  inference, unification-driven generalization, or any of the rest of HM's
  machinery. "ADTs and exhaustiveness" is a much smaller, honestly-scoped debt
  than "we implemented ML."

*Why it matters here:* exhaustiveness and bounded polymorphism are exactly
the failures the repair loop is best at — a missing match arm or a bound
violation is structured, located, and machine-fixable in a way an untyped
runtime error never is.

## Unison — names versus identity, realized as FRAM stable binding identity

Unison's core insight is that a definition's *name* and its *identity*
(content hash) are separate concerns — you can rename freely without
breaking a reference, because references bind to identity, not to a string.
Beagle (via FRAM) borrows that **separation**, not Unison's runtime:

- **Stable binding identity.** A binding's identity in FRAM survives rename —
  callers, the fact graph, and the repair loop track *what a definition is*,
  not the string that currently labels it.
- **Not content-addressed code.** Beagle does not adopt Unison's
  content-addressed storage, its hash-as-filename codebase model, or its
  structural-diff-as-deployment story. FRAM's identity is a stable binding
  key inside the ordinary compiler pipeline, not a replacement runtime or
  storage substrate.

*Why it matters here:* the repair loop rewrites code (renames, clause
skeletons, tree splices). A fix that survives a rename — because it targets
identity, not a name string — is a fix that doesn't shatter the next time
someone edits nearby.

## Datalog — recursive, stratified derivations, scoped to FRAM's graph

Datalog contributes a narrow, specific borrowing: recursive and stratified
derivation over a fact graph — the way FRAM computes transitive closures
(callers-of-callers, blast radius, leverage) as a fixpoint over base facts,
not as hand-written recursive traversal code.

- **Scoped to FRAM's graph layer.** This is how the *coordination and
  code-graph substrate* answers relational questions (`codegraph`'s "who
  calls X, transitively"), not a claim that Beagle's ordinary compiled
  programs execute as Datalog or that logic programming is a language
  feature.
- **Not ordinary computation.** A `.bclj` function body is still eager,
  typed, imperative-shaped Clojure-family code lowered to its target. The
  Datalog borrowing lives one layer up, in how the graph that *represents*
  the code answers queries about itself.

*Why it matters here:* the repair loop's diagnoses ("this call site breaks
if you change that signature") are graph-shaped questions. Stratified
recursive derivation is the right tool for exactly that shape, without
smuggling logic-programming semantics into the compiled language itself.

## The Lisp/Clojure/EDN surface — the one small structural authoring medium

- **Clojure as the surface.** Beagle is "Clojure plus types, nothing else." Any
  divergence from Clojure must be load-bearing for the type system or a backend,
  or it gets removed. Inline `:-` annotations only; interiors inferred.
- **Types that erase before emit** (closer to Typed Racket's stance than to a
  type system that drives codegen). Types check at compile time and vanish — the
  emitted Nix/JS/Clojure is idiomatic for its host, never a typed-runtime
  artifact.
- **Parens as a machine-editable medium.** A fix is a tree splice, not a regex
  over free-form syntax. The s-expression surface is what makes auto-apply
  tractable.
- **Exact Clojure syntax is not inevitable; the typed EDN/Lisp *family* is
  what wins.** Nothing about the repair loop requires parentheses spelled
  exactly Clojure's way — a different bracket convention or reader could carry
  the same property. What is load-bearing is the *family*: a small,
  homoiconic, structurally-editable EDN/Lisp medium, because that is what
  makes "the fix is a tree splice, not a regex" true. Clojure was the specific
  member of that family Beagle picked to start from; the family, not the
  specific grammar, is the thing the thesis depends on.

## The synthesis

The borrowings are not a remix — each is a means to the same end, and each is
scoped to a specific concern rather than an adopted surface or runtime:

| Borrowed from | Concern it supplies | Serves the repair loop by… |
|---|---|---|
| Lean | diagnostics discipline | giving the loop something *precise* to repair |
| Kernel | combiner uniformity | making the whole surface analyzable as one thing → one IR |
| ML family | type semantics (ADTs, exhaustiveness, explicit/bounded polymorphism, variance, heterogeneous positional types) — not ML's grammar, no full-HM claim | generating diagnoses (types) that are structured and machine-fixable, without importing a second concrete syntax |
| Unison | names-vs-identity separation, realized as FRAM stable binding identity — not content-addressed code | letting a repair (rename, splice) target *what a binding is*, so it survives edits instead of shattering on the next rename |
| Datalog | recursive/stratified derivation inside FRAM's graph — not Beagle's ordinary computation | answering the graph-shaped questions ("what breaks if this changes") the repair loop's diagnoses depend on |
| Lisp/Clojure/EDN | one small structural authoring surface — the family, not Clojure's exact grammar | making the medium itself machine-editable, so fixes are tree splices instead of textual guesses |

On top of that foundation sits the part with no upstream analogue: the
**auto-repair loop** — `detect → diagnose → fix → re-verify` — where the
compiler enumerates missing match cases, emits clause skeletons, and applies
fixes that typecheck. That is Beagle's own frontier, not a steal.

## The thesis, carried to its conclusion

The bet is that **one typed authoring IR with a repair loop can target many
real ecosystems at once** — and that authoring against it beats writing each
target by hand. The breadth is not a distraction from the pitch; it *is* the
pitch. A single AST that lowers idiomatically to lazy Nix attrsets *and* eager
Clojure maps *and* JS — never a lowest-common-denominator transpile — is the
proof that the approach generalizes across genuinely different runtime models.

This is already demonstrated where it is hardest, not merely aspired to:

- **Nix** — firn, a complete NixOS system typed end-to-end against its
  16k-option schema. The target where the pain is most real (untyped,
  error-hostile) and writing it by hand is worst.
- **Clojure** — a different runtime model entirely (eager maps, JVM), driven by
  real `.bclj` code.
- **JavaScript** — gjoa, a Firefox overlay UI, 43 `.bjs` modules ported from
  TypeScript.

Each target that lands clean is the same thesis carried one ecosystem further.
The frontier is the *depth* of the repair loop, not the count of targets.

---

*The full development history lives as ~70 threads in life-os (tag `beagle`).
This document is the distilled lineage; the threads are the devlog.*
