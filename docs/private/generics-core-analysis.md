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

The commander resolved that conflict by redefining the slice as adoption of
the existing engine at portable core-library boundaries; no feature flag or
default behavior change is part of the implementation below.

## Adoption audit

The portable catalog is the precision choke point. `mapv` and `filterv` are
already schemes, but their collection argument is still `Any`; the other
high-traffic sequence combinators below are wholly or substantially dynamic.

| Callable | Current catalog signature | Precision lost at a call |
| --- | --- | --- |
| `map` | `(forall [A B] (Fn [(Fn [A] B) & Any] Any))` | input element and output collection shape |
| `mapv` | `(forall [A B] (Fn [(Fn [A] B) Any] (Vec B)))` | input element cannot constrain or validate the callback |
| `filter` / `remove` | `(forall [A] (Fn [(Fn [A] Any) Any] Any))` | input/output element and collection shape |
| `filterv` | `(forall [A] (Fn [(Fn [A] Any) Any] (Vec A)))` | input element cannot constrain or validate the predicate |
| `reduce` | `(Fn [Any Any & Any] Any)` | callback, element, accumulator, and result relation (the checker has a 3-argument return-only refinement) |
| `mapcat` | `(Fn [Any Any & Any] Any)` | callback input/output and flattened element |
| `sort-by` / `group-by` | `(Fn [Any Any & Any] Any)` / `(Fn [Any Any] Any)` | key function input/key type and result collection |
| `map-indexed` / `keep` / `keep-indexed` | `(Fn [Any Any] Any)` | callback inputs/output and result element |
| `some` / `every?` / `run!` | `(Fn [Any Any] Any)` / `(Fn [Any Any] Bool)` / `(Fn [Any Any] Nil)` | callback input cannot be checked against collection element |
| `reduce-kv` | `(Fn [Any Any Any] Any)` | map key/value, accumulator, callback, and result relation |

Authored variables already have a working surface spelling. `types.rkt`
parses `(forall [T] (Fn [T] T))` (a list of variables is also accepted), with
bounded entries spelled `(T <: Bound)`; bare `T` becomes the rigid `type-var`
only inside that scope. Existing check fixtures exercise both unbounded and
bounded forms. The missing work is discoverability, so the canonical vector
spelling should be added to the compiler-generated cheatsheet rather than
adding another parser form.

The smallest high-traffic landable slice is `mapv`, `filterv`, and both
`reduce` arities. Their runtime shapes are expressible today as `Vec`, and
`reduce` needs only arity selection inside an authored scheme whose body is a
union of function types. Lazy-sequence functions remain audited gaps rather
than being mislabeled as vectors.

## Verification status

The pinned Racket suites for type-inference core, definition inference, the
checker, and the generated cheatsheet pass (413 tests total). The focused
definition-inference case proves a game-shaped `filterv` → `mapv` → `reduce`
chain infers `(Fn [(Vec Enemy)] Int)` end to end and exercises both `reduce`
arities.

The mandatory native source-freeze and full typed-stage gates could not start:
`native-core/validation/store-checkout.sh` requires
`~/code/store/pins/24309a05927a59d7d495292a3b15a7e9b2adaf2c`, but the Store
repository and pin are absent. Restore the exact Store pin, then rerun both gates. Because
main is moving for the release repair, landing also requires a rebase and a
fresh rerun of every gate against the rebased commit.
