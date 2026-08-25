---
name: fact-modeling-reference
description: >-
  Detailed Fact Normal Form examples, identity cases, nesting consequences,
  typed admission internals, and the seven-question review gate. Load when
  fact-modeling-distilled routes here or the user explicitly requests details.
---

# Fact modeling reference

## Canonical contact example

```text
(:member_of, :member_of, :relationships)
(:contactable_at, :member_of, :relationships)
(:represented_by, :member_of, :relationships)
(:contactable_at, :member_of, :contact_relations)
("alice@example.com", :member_of, :email_addresses)
("Alice", :contactable_at, "alice@example.com")
```

Examples that fail Fact Normal Form:

```text
("Alice", :email, "alice@example.com")
("Alice", :contact/email, "alice@example.com")
(module-a, :program/node, binding-a)
(fact-42, :relation, :program/node)
(fact-42, :subject, module-a)
(fact-42, :slot, :name)
(fact-42, :value, "helper")
```

The first uses a noun as a relation. The next two hide domain classification in
Atom spelling. The last four replace one relationship with an opaque row and
field vocabulary.

## Identity examples

Identity layers:

```text
Atom identity target  Atom kind + canonical payload
Proposition identity  recursive structural Triple equality
Assertion identity    occurrence coordinate
```

When an address has continuity beyond its current String representation:

```text
(address-1, :represented_by, "alice@example.com")
(address-1, :member_of, :email_addresses)
("Alice", :contactable_at, address-1)
```

The built-in relational profile's R1 accepts Atom positions. Other profiles may
admit nested structural Terms according to their declared positions.

## Typed gate details

Engine work reaches the existing admission path through:

```text
fact-normal-form-admission-errors : (Vec Triple) -> String -> Triple -> (Vec String)
```

`lint-declared-profile` supplies typed profile admission and whole-space lint.
The current semantic contract lives in `store:docs/ontology.md` and
`store:docs/naming.md`.

## Seven-question review

1. Is the rule limited to propositions admitted by a fact-oriented profile?
2. Does each proposition state a relationship rather than put a noun in the
   relation role?
3. Can every required relationship and membership be queried as a Triple?
4. Does each Atom kind's canonical payload supply the intended equality?
5. Does each new Atom kind add intrinsic scalar semantics?
6. Does each resource have continuity or lifecycle beyond its representation?
7. Are Atom, proposition, and assertion-occurrence identity still separate?
