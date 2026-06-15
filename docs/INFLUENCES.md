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

## Typed Lisp lineage — Clojure surface, erased types

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

## The synthesis

The borrowings are not a remix — each is a means to the same end:

| Borrowed | Serves the repair loop by… |
|---|---|
| Lean diagnostics | giving the loop something *precise* to repair |
| Kernel uniformity | making the whole surface analyzable as one thing → one IR |
| Typed Lisp | generating the diagnoses (types) over a machine-editable medium (parens) |

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

- **Nix** — firnos, a complete NixOS system typed end-to-end against its
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
