# Design rationale

> Stability: this file records product boundaries and design constraints, not
> target inventories, form sets, signatures, or current implementation status.
> Those answers belong to the compiler and generated documentation. This file
> stays stable while Beagle's typed-authoring thesis and compilation boundary
> remain the product commitments.

These are the boundaries that explain what Beagle is for:

- **Not a schema language or general validation system** — static type
  information erases, and only an explicitly authored binding constraint emits
  its local predicate guard. There is no schema/spec registry or conforming
  runtime.
- **Not a new Lisp in spirit** — a strict typed subset of Clojure; divergence
  from Clojure must serve the type system or a backend, or it dies.
- **Not a universal idiomatic-native transpiler** — hosted emitters exist where
  generated source is a real interface; native code comes from one frozen
  native program and replaceable materializers.
