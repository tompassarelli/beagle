# Design rationale

> Stability: this file records product boundaries and design constraints, not
> target inventories, form sets, signatures, or current implementation status.
> Those answers belong to the compiler and generated documentation. This file
> stays stable while Beagle's typed-authoring thesis and compilation boundary
> remain the product commitments.

These are the boundaries that explain what Beagle is for:

> Pure software artifacts are reproducible projections of sealed semantic
> ModelRevisions; external reality is connected through explicit observations and
> capability-controlled effects.

- **Not constrained by a hosted profile** — Beagle's native direction is
  proposition-first. Current Clojure-derived and target-specific hosted
  profiles remain explicit surfaces, but they do not define the native semantic
  model, planner, identity rules, or execution protocol.
- **Not one universal identity or a universal trust domain** — one durable
  identity, explanation, dependency, and provenance model relates distinct
  Model, ModelRevision, BranchRevision, content, assertion, rule, plan, and
  artifact identities. A ModelRevision is an immutable semantic admission, not
  a Store branch. Logical or type unification does not collapse clusters,
  transactions, physical Stores, access controls, execution domains, trust
  domains, or failure domains.
- **Not an effect system that confuses knowledge with action** — `Declared`,
  `Derived`, and `Observed` are epistemic origins. `Intent`, `Authorization`,
  `Attempt`, and `EffectReceipt` form a separate action protocol. Plans may be
  derived purely; an external effect needs an explicit capability and yields a
  receipt plus later observations.
- **Not a fixed target contract** — target outputs are replaceable
  materializations under explicit target and capability envelopes. The native
  destination derives them from sealed ModelRevisions and checked plans;
  current hosted profiles remain explicit rather than being silently treated
  as that native path.
- **Not a separate database product inside the language** — Store is Beagle's
  cohesive durable semantic substrate. A brownfield consumer may use a
  database-, storage-, or cache-shaped boundary without redefining Store's
  identity, provenance, or transaction model.
- **Not opaque incremental magic** — reusable-result keys are measured for
  completeness, narrowness, identification cost, stability, and compiler-rule
  identity. Warm work is bounded by the invalidated semantic region plus
  identification/authentication overhead, and warm equals clean.

- **Not a schema language or general validation system** — static type
  information erases, and only an explicitly authored binding constraint emits
  its local predicate guard. There is no schema/spec registry or conforming
  runtime.
- **Not a compatibility museum** — current main is the supported line. Once
  in-tree consumers migrate, retired source profiles, switches, tests, and
  lowering paths are removed; Git history is their recovery mechanism.
- **Not a universal idiomatic-native transpiler** — hosted emitters exist where
  generated source is a real interface; native code comes from one frozen
  native program and replaceable materializers.
