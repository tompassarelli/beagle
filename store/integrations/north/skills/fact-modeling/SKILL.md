---
name: fact-modeling
description: >-
  Model Beagle Store facts and their typed admission: design or review
  ontologies, vocabularies, canonical Triple propositions, Atom and resource
  identity, fact schemas, compiler/build/provenance/dependency facts, Store
  query models, and persisted semantic models. Use whenever semantic shape
  must be settled before writing or admitting fact-oriented data.
---

# Fact modeling

**Mandatory ground rule — Fact Normal Form (FNF):** for every proposition
admitted by a fact-oriented profile, state each semantic relationship as its
canonical Triple. Do not hide a relationship in Atom spelling, an assumed
position, or an out-of-band schema cell. Keep Store operations in
`store-modeling`; settle semantic shape here before writing or admitting
fact-oriented data.

## 1. Establish the ontology and profile boundary

- Apply FNF only to propositions admitted by a fact-oriented profile. Preserve
  recursive `Term := Atom | Triple` and neutral `Triple := (Term, Term, Term)`
  semantics for every other profile, nested Term, and unasserted structure.
- Keep closed `:kernel/*` and `:rpc/*` protocol vocabulary outside application
  ontology checks. Do not copy those namespaces into domain vocabulary.
- Name the relationship actually stated in the relation Term. Use an affordance
  such as `:contactable_at`, not a noun such as `:email`.
- Assert every relationship vocabulary and membership needed for
  interpretation, joins, classification, or validation. Never recover it by
  parsing an Atom's namespace, prefix, suffix, punctuation, or assumed slot.
  Cosmetic un-namespacing does not normalize hidden structure.

## 2. Normalize propositions

Admit each fact-profile proposition as one canonical Triple. Reject a bespoke
domain relation or table whose row identity or columns stand in for
relation/subject/slot/value facts that the profile can express as Triples.

Assert each line separately for the fact-oriented contact model:

```text
(:member_of, :member_of, :relationships)
(:contactable_at, :member_of, :relationships)
(:represented_by, :member_of, :relationships)
(:contactable_at, :member_of, :contact_relations)
("alice@example.com", :member_of, :email_addresses)
("Alice", :contactable_at, "alice@example.com")
```

Reject these shapes:

```text
("Alice", :email, "alice@example.com")
("Alice", :contact/email, "alice@example.com")
(module-a, :program/node, binding-a)
(fact-42, :relation, :program/node)
(fact-42, :subject, module-a)
(fact-42, :slot, :name)
(fact-42, :value, "helper")
```

The first puts a noun in the relation position. The second hides domain
membership in spelling; `:program/node` repeats that namespaced application
error exactly. The final four rows reify one proposition behind an opaque
per-proposition identity and relation/subject/slot/value fields instead of
admitting the relationship as its canonical Triple.

## 3. Choose identity deliberately

- Use an Atom directly when its kind and canonical payload are the intended
  equality contract. Add an Atom kind only for different intrinsic scalar
  validation, ordering, encoding, or equality.
- Mint a resource only for continuity or lifecycle beyond its representation.
  Never mint an opaque identity merely because a proposition exists.
- Keep these identity layers separate:

  ```text
  Atom identity target  Atom kind + canonical payload
  Proposition identity  recursive structural Triple equality
  Assertion identity    occurrence coordinate
  ```

Use a resource only when the address has identity or lifecycle beyond the
String:

```text
(address-1, :represented_by, "alice@example.com")
(address-1, :member_of, :email_addresses)
("Alice", :contactable_at, address-1)
```

## 4. Preserve nesting and query consequences

Preserve nesting neutrality. A nested Triple is a structural Term and is not
independently asserted. Admit it only under a profile that permits its
position; the built-in relational profile's R1 requires Atom positions.

Model every required relationship and membership as an admitted Triple so
queries can join, classify, and validate it directly. A query must not infer
meaning by parsing Atom text or assume an unasserted slot; proposition identity
is recursive structural Triple equality, while assertion identity remains the
occurrence coordinate.

## 5. Use the typed admission gate

- Run the public whole-space gate through `bin/beagle store validate` after
  setting the Store space described in `store:README.md`.
- For engine work, use `fact-normal-form-admission-errors : (Vec Triple) ->
  String -> Triple -> (Vec String)` through `lint-declared-profile`, Store's
  existing typed profile admission and whole-space lint path. Do not create a
  parallel validator or bypass a rejection by dropping the profile rule.

## 6. Seven-question gate

Require seven yes answers before admission:

1. Is the gate restricted to propositions admitted by a fact-oriented profile
   rather than every asserted proposition or nested Term?
2. Does each admitted proposition actually state a relationship under its
   profile instead of placing a noun in the relation role?
3. Can every required relationship and membership be queried as a Triple
   instead of recovered by parsing Atom text?
4. Does each Atom kind's canonical payload provide the intended equality
   contract?
5. Is a new Atom kind used only for different intrinsic scalar semantics?
6. Is a resource identity minted only for identity or lifecycle beyond the
   representation, never merely because a proposition exists?
7. Are Atom, proposition, and assertion-occurrence identity still distinct?

Correct any no answer in the model, then rerun `bin/beagle store validate`.
Read `store:docs/ontology.md` and `store:docs/naming.md` for the current
semantic contract; treat the typed validator as the executable verdict.
