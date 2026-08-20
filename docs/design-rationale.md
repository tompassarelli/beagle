# Design rationale

> Stability: this file records product boundaries and design constraints, not
> target inventories, form sets, signatures, or current implementation status.
> Those answers belong to the compiler and generated documentation. This file
> stays stable while Beagle's typed-authoring thesis and compilation boundary
> remain the product commitments.

These are the boundaries that explain what Beagle is for:

> Pure software artifacts are reproducible projections of durable semantic
> worlds; external reality is connected through explicit observations and
> capability-controlled effects.

- **Not merely a Clojure subset** — Beagle is an independent typed Lisp with a
  Clojure-derived authoring core. Clojure vocabulary is inherited where its
  semantics fit; types, effects, execution, and data are Beagle's own.
- **Not one universal identity or a universal trust domain** — one durable
  identity, explanation, dependency, and provenance model relates distinct
  content, assertion, revision, rule, and artifact identities. A world is a
  broad semantic snapshot, not a Store branch. Logical or type unification
  does not collapse clusters, transactions, physical Stores, access controls,
  execution domains, trust domains, or failure domains.
- **Not an effect system that confuses knowledge with action** — `Declared`,
  `Derived`, and `Observed` are epistemic origins. `Intent`, `Authorization`,
  `Attempt`, and `EffectReceipt` form a separate action protocol. Plans may be
  derived purely; an external effect needs an explicit capability and yields a
  receipt plus later observations.
- **Not a fixed target contract** — target outputs are replaceable
  materializations of shared checked input with explicit capability envelopes.
  Bare `.bgl` selects deliberate Native Core lowering; `.bclj` targets the
  Java/Clojure runtime and may admit JVM Clojure facilities.
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
- **Not a new Lisp in Clojure's name** — a Clojure-derived core whose
  divergence must serve the type system or a backend, or it dies.
- **Not a universal idiomatic-native transpiler** — hosted emitters exist where
  generated source is a real interface; native code comes from one frozen
  native program and replaceable materializers.
