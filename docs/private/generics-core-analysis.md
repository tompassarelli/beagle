# Generics core architecture blocker

The requested type foundation is already live, unflagged, on Beagle v0.24.0.

`beagle:beagle-lib/private/types.rkt` represents rigid authored variables with
`type-var`, inference variables with mutable identity-based `type-meta`, and
schemes with `type-poly`. `bind-type-meta!` preserves an unsolved meta when it
meets `Any` and runs `type-occurs?` before solving. `unify-types!` handles
function, application, union, and invariant types. `generalize-type` quantifies
free metas, while `instantiate-type` freshens inferred schemes.

`beagle:beagle-lib/private/check.rkt` seeds inference slots in
`build-initial-env`, constrains definition bodies through
`constrain-inference-clause!`, solves definition SCCs in
`infer-definition-types!`, generalizes completed functions in
`finalized-definition-type`, and instantiates inferred schemes in the
`infer-expr` call-form arm. `type-check!` reaches this path unconditionally
through `prepare-and-infer-definition-types!`; there is no generics flag.

The lowest-layer obligations are already explicit in
`beagle:beagle-test/tests/type-inference-core.rkt`: metavariable identity,
structural/directional unification, occurs rejection, non-poisoning `Any`,
generalization, capture avoidance, environment exclusion, and independent
instantiation. `beagle:beagle-test/tests/definition-inference.rkt` requires
unflagged generalization and independently instantiated polymorphic calls,
including recursive and multi-arity cases.

This makes the requested opt-in contract internally inconsistent. Preserving
flag-off output byte-for-byte means preserving today's unflagged generalization
and instantiation. Enabling those operations only under an explicit flag means
turning them off by default, changing current behavior and invalidating the
existing unflagged inference and freeze obligations. A no-op flag would not
satisfy the opt-in requirement.

Landing therefore needs one commander decision: either accept the default
behavior change and update the existing obligations, or redefine this slice
against the generics foundation that has already landed. The positioning note
at `todo:beagle-program-handoff/positioning/types-design/surface.md` contained
no type-variable syntax, so this analysis had no surface spelling to adopt or
choose.
