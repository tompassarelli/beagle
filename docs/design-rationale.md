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
- **Not one universal identity or a universal trust domain** — a program world
  is a durable semantic explanation, related through named layered equivalence
  relations. Content, assertions, revisions, and artifacts retain distinct
  identities; content identity does not grant authority. Logical unification
  does not collapse physical storage, execution, deployment, or security
  domains.
- **Not an effect system that confuses intent with reality** — `Declared`,
  `Derived`, `Observed`, `Desired`, `EffectAttempt`, and `EffectReceipt` are
  non-interchangeable modes. Plans are pure; an external effect needs an
  explicit capability, leaves a receipt, and needs observation before it
  justifies a claim about the outside world.
- **Not a fixed target contract** — target outputs are replaceable
  materializations with explicit capability envelopes. Versioned
  representations and migrations are the production model, not a promise of
  backwards compatibility.

- **Not a schema language or general validation system** — static type
  information erases, and only an explicitly authored binding constraint emits
  its local predicate guard. There is no schema/spec registry or conforming
  runtime.
- **Not a new Lisp in Clojure's name** — a Clojure-derived core whose
  divergence must serve the type system or a backend, or it dies.
- **Not a universal idiomatic-native transpiler** — hosted emitters exist where
  generated source is a real interface; native code comes from one frozen
  native program and replaceable materializers.
