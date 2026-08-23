# Design rationale

> Stability: this file records product boundaries and design constraints, not
> target inventories, form sets, signatures, or current implementation status.
> Those answers belong to the compiler and generated documentation. This file
> stays stable while Beagle's typed-authoring thesis and compilation boundary
> remain the product commitments.

These are the boundaries that explain what Beagle is for:

- **Not merely a Clojure subset** — Beagle is an independent statically typed
  Lisp with a Clojure-derived authoring core. Clojure vocabulary is inherited
  where its semantics fit; types, effects, execution, and data are Beagle's
  own.
- **Not a Store-defined language** — source and the checked AST own syntax and
  program meaning. Store is optional tooling for Terms and Triples, occurrence
  history, queries, indexes, provenance records, and caches; it does not define
  the frontend or checker.
- **Not a fixed target contract** — Clojure, JavaScript, and Nix are the primary
  hosted profiles and emit idiomatic source. Bare `.bgl` selects the
  experimental Native Core path: one frozen checked program followed by an
  explicitly selected C17, QBE, or C17/WASI Wasm bootstrap materializer.
- **Not a schema language or general validation system** — static type
  information erases, and only an explicitly authored binding constraint emits
  its local predicate guard. There is no schema/spec registry or conforming
  runtime.
- **Not a new Lisp in Clojure's name** — a Clojure-derived core whose
  divergence must serve the type system or a backend, or it dies.
- **Not a universal idiomatic-native transpiler** — hosted emitters exist where
  generated source is a real interface; native code comes from one frozen
  native program and replaceable materializers.
