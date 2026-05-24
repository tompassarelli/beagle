---
status: pending
priority: 2
depends-on: cyclone-self-host.md
---

# Capabilities — typed unsafe-effects (replacing the "no unsafe ever" informal dogma)

## Thesis

The current principle "zero escape hatches" is informal. It tries to
express "user code is fully typed end-to-end, no opt-out keyword" — a
useful claim — but it conflates two different things:

1. **No unsafe operations exist anywhere in beagle.** This was always
   false. FFI shims do unsafe things when they exist. Proc macros do
   compile-time evaluation. The schema-typed-paths story implies an
   ingestion-side that operates on untyped foreign descriptions.
2. **User code cannot opt out of the type system.** This is true and
   load-bearing.

The conflation hides actual structural design questions. The honest
refinement: **unsafety has internal structure — it is a typed effect
with kinds, and contexts grant specific kinds while forbidding
others.** User code grants none. FFI shims grant `unsafe-ffi`. Proc
macros grant `unsafe-compile-time-eval`. The capabilities are typed,
auditable, and statically verifiable.

This is closer to effect systems (Koka, Eff, OCaml 5) than to Rust's
undifferentiated `unsafe` keyword.

## The framing shift

Old framing (informal dogma):
- Question: "should beagle have `unsafe`?"
- Answer: no.
- Failure mode: when real-world authoring hits something the type
  system can't express, the recourse is "add to stdlib" or "extend the
  type system." Both are expensive at agent-speed. The informal
  principle invites future violation because it can't articulate why
  the FFI shim is OK but the user `(unsafe ...)` block isn't.

New framing (typed capabilities):
- Question: "what unsafe-kinds exist structurally in beagle's
  architecture, and where are they permitted?"
- Answer: a small, named, typed list. User code permits none.
- The type checker statically verifies user code uses no unsafe
  capabilities. The FFI shim's permission is explicit, contextual,
  and bounded.

The new framing is *stricter* than the old one, not weaker — the
strictness is now enforceable by the type checker rather than by
convention + stdlib-discipline + reviewer attention.

## Catalog of unsafe-kinds

These already exist structurally in beagle's architecture. The proposal
isn't "add new capabilities" — it's "name and type the capabilities
that already exist."

| Kind | What it permits | Lives in | Forbidden in |
|---|---|---|---|
| `unsafe-ffi` | Calling foreign functions whose types come from an ingested schema | Auto-generated FFI bindings (Nix `lib.X`, future TS `.d.ts` bindings, etc.) | User code, hand-written stdlib |
| `unsafe-foreign-memory` | Reading/writing raw memory at a foreign boundary | Hand-written portions of FFI shims for libraries whose schema can't express memory layout | Everything else, including most ingested schemas |
| `unsafe-compile-time-eval` | Running arbitrary code at compile time during macro expansion | `proc` macro bodies | User code, runtime |
| `unsafe-target-specific` | Emitting target-specific code that bypasses beagle's IR | (doesn't currently exist; probably shouldn't) | Everywhere |
| `unsafe-type-assertion` | Asserting a type the system can't verify | (doesn't currently exist) | Probably everywhere; reconsider only if a real use case appears |

The first three already exist implicitly. Naming them as typed
effects doesn't add capabilities — it makes existing ones auditable.

## Context-permission model

A context (file, function, macro definition, ingested shim) declares
which unsafe-kinds it admits. The type checker statically verifies
that no expression in the context uses a kind the context hasn't
permitted.

Sketch:

```
;; FFI shim file (auto-generated from schema ingestion)
(ns ffi.nixpkgs.lib)
(define-capabilities unsafe-ffi)   ;; this file may call foreign

;; Macro definition
(define-macro proc gen-getter
  ...)
;; ↑ implicit capability: unsafe-compile-time-eval
;;   (because proc macros run arbitrary code at compile time)

;; User code
(ns app.main)
;; ↑ no capabilities declared. Type checker rejects any expression
;;   that requires unsafe-ffi / unsafe-foreign-memory / etc.
```

User code is the *default* — no capabilities. Anything more is opt-in
per file, and the opt-in is visible to reviewers and audits.

## The shim-boundary question (the hardest part)

Real FFI shims have this shape: the shim *internally* uses
`unsafe-ffi`, but callers of the shim are *safe*. The shim is the
boundary. Examples:

- `(lib/mkOption {:type ... :description "..."})` is a safe call into
  beagle. It compiles to a call into Nix's `lib.mkOption`. The shim
  that *bridges* is unsafe (foreign call). The caller is safe.

- `(JSON.parse "...")` (when typed via a `.d.ts` ingestion) is a safe
  call. The shim that asserts the JSON-parse result conforms to a
  declared type is unsafe (type assertion at the boundary). The
  caller is safe.

How is this expressed? Options:

1. **`unsafe-ffi` is an effect on the shim function itself.** Callers
   inherit nothing because the shim's type signature is
   `(String → JsonValue)`, not `unsafe-ffi (String → JsonValue)`. The
   capability is consumed *inside* the shim during compilation; what
   the user sees is a safe signature. This requires the shim to be
   marked specially so the checker knows it's discharging its own
   unsafety.

2. **Rust's approach — function-level vs block-level.** `unsafe fn` =
   any caller inherits the obligation; `unsafe { ... }` = caller
   doesn't inherit. Beagle would have to pick whether shim-as-a-whole
   counts as `unsafe fn` (which means callers need permission) or as
   `unsafe { ... }` (encapsulated, safe at the boundary). Rust's
   imperfect handling here is real — beagle gets to learn from it.

3. **Effect-style discharge.** Like algebraic effects: the shim
   *handles* the `unsafe-ffi` effect internally, so callers don't see
   it in their type. This is Koka/OCaml 5's model. Most expressive,
   probably most complex.

Initial intuition: option (3) is the right shape long-term but option
(1) covers the practical cases without effect-system machinery. Start
with (1), evolve toward (3) if real cases demand it.

## Reframing of "zero escape hatches"

After this lands, the CLAUDE.md principle changes from:

> Beagle has zero escape hatches. No unsafe-nix, no unsafe-js, ... By
> design.

To:

> Beagle has a typed capability system for unsafe effects. User code
> declares no capabilities and the type checker statically verifies
> this. FFI shims and macro bodies are the only contexts that hold
> specific capabilities, and those capabilities are bounded — the
> shim's type signature describes the safe surface, not the
> implementation.

Same intent, sharper claim. Old: "informal discipline forbids unsafe."
New: "type system proves user code uses no unsafe capabilities."

## Do-now vs do-later

Pre-self-host, the unsafe-kinds list is short:
- `unsafe-compile-time-eval` (proc macros — exists)
- `unsafe-ffi` (mostly dormant — Nix schema lookup uses it implicitly)
- Others (don't exist yet)

The formal capability system would be largely empty scaffolding right
now. Two arguments for **do it later**:

1. The cases are mostly dormant. Designing against few real cases
   risks over-fitting or under-fitting.
2. Cyclone self-host introduces new FFI surface (C interop via
   Cyclone's FFI). Designing the capability system *with* that real
   case in hand is better than designing it abstractly.

Two arguments for **do it now**:

1. The shape is already clear enough to commit to. Naming the implicit
   capabilities (proc macros → unsafe-compile-time-eval) immediately
   makes them auditable, even before the type system enforces.
2. Building the scaffolding once is cheaper than retrofitting it after
   capabilities have proliferated unstructured.

**Verdict**: do the *naming* and *documentation* now (CLAUDE.md
update, plan capture). Defer the *type-system enforcement* until
Cyclone Phase 0 lands and introduces the first new real FFI case. That
way we have the conceptual frame ready when the implementation is
warranted.

## Open questions

1. **Granularity per target.** Is `unsafe-ffi` one kind, or
   subdivided per emit target (`unsafe-ffi-nix`, `unsafe-ffi-js`,
   `unsafe-ffi-c`)? Probably one kind with per-target sub-permissions
   if needed — but unclear without real cases.

2. **Composition.** If a `proc` macro calls into an `unsafe-ffi`
   helper, does it need both `unsafe-compile-time-eval` AND
   `unsafe-ffi`? Probably yes, but the inheritance rules need design.

3. **Discharge mechanism for shim boundaries.** See the shim-boundary
   section above. The hardest question. Initial answer: option (1)
   marking; evolve if needed.

4. **What's the syntax for declaring capabilities?** Per-file,
   per-function, per-block? Inferred from form usage, or explicit?
   Probably explicit per-file via `(define-capabilities ...)` at the
   top, inferred per-function from body content. Open.

5. **How does the type checker know a foreign function is being
   called?** Some marker in the FFI binding declaration. Probably
   reuses the existing `declare-extern` machinery, adding a
   capability annotation.

6. **What about the schema-ingestion binding *generator* itself?**
   The thing that reads a `.d.ts` and emits a beagle shim file. That
   generator is meta — it produces code that holds capabilities. The
   generator itself doesn't run beagle code; it's a Racket/Cyclone
   process. So it's outside the capability system entirely. But its
   output (the generated shim file) needs to declare its capabilities
   correctly.

## Prerequisites + dependencies

- **Cyclone Phase 0** (runtime library). The first real new FFI case
  will appear when the Cyclone runtime needs to call into Cyclone's
  C-FFI for inotify/sqlite/etc. That's when this plan transitions
  from speculative to implementable.
- **Schema-typed paths extension** (TypeScript declarations). The
  second real case. Each `.d.ts` ingestion is a sea of FFI shims.

## Out of scope

- Designing an effect system in general. The capability system is
  specifically for unsafe-kinds, not for tracking effects like IO,
  state, or exceptions.
- Adding `unsafe-*` keywords to user-facing source. The capability
  system describes what's true about contexts; users don't write
  capability annotations. They write safe code or rely on a shim.
- Walking back the strictness of user code. User code remains fully
  type-checked end-to-end. The capability system makes that
  strictness *enforceable* rather than *conventional*.

## Anti-goals

- **Don't add a `(unsafe ...)` block form for users.** Every typed
  language that did this (TypeScript `any`, Rust `unsafe`, Java
  `Object`-casting, Python `Any`-as-bailout) regretted it. The
  capability system explicitly closes this door.
- **Don't make the capability system the agent's problem.** Agents
  write user code, which has no capabilities. The capability system is
  an internal accounting mechanism for shim authors and macro authors,
  not part of the authoring surface.

## What this plan deliberately doesn't do

- Doesn't open `unsafe` to user code.
- Doesn't change the stated principle that beagle has no escape
  hatches in user code.
- Doesn't add any new runtime behavior.
- Doesn't require Cyclone-specific machinery (the capability system
  works the same regardless of host).

## Method when we get to it

1. Land Cyclone Phase 0 (runtime library) first.
2. As the runtime needs FFI, formalize `unsafe-ffi` capability + the
   declaration mechanism.
3. Retrofit `proc` macros with `unsafe-compile-time-eval` capability.
4. Update CLAUDE.md "zero escape hatches" wording to the capability-
   typed formulation.
5. Document the capability system in `beagle-doc/scribblings/`.
6. Add lint that warns on capability usage missing declaration (forces
   shim authors to declare).

## Tone

The honest version of this plan: we're not weakening anything. The
"zero escape hatches" principle was informal and overstated; the
reality always had unsafe operations in well-defined places. This plan
makes that reality auditable. After it lands, the principle is
stronger because it's enforceable, not weaker because it admits unsafe
exists.
