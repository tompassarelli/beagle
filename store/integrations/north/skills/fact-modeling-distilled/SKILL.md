---
name: fact-modeling-distilled
description: >-
  Model Beagle Store facts and their typed admission: design or review
  ontologies, vocabularies, canonical Triple propositions, Atom and resource
  identity, fact schemas, compiler/build/provenance/dependency facts, Store
  query models, and persisted semantic models. Use whenever semantic shape
  must be settled before writing or admitting fact-oriented data.
---

# Fact modeling

Apply Fact Normal Form only within a fact-oriented profile. State every needed
relationship, membership, and classification as a canonical Triple; never hide
meaning in Atom spelling, positions, schema cells, or opaque field records.

Outside that boundary preserve recursive `Term := Atom | Triple` and neutral
Triples. Exclude closed `:kernel/*` and `:rpc/*` vocabulary from application
ontology checks. Nested Triples are structural, not independently asserted.

Choose identity by contract: use an Atom for intrinsic kind plus canonical
payload equality; mint a resource only for continuity or lifecycle beyond its
representation. Keep Atom identity, recursive structural proposition identity,
and assertion-occurrence identity distinct.

Before admission, review the profile, relations, memberships, Atom kinds, and
resources; correct the model, then run `bin/beagle store validate`. Do not
create a parallel validator or bypass a profile rejection.

Keep Store operations in Store modeling. For canonical and rejected examples,
identity variants, typed admission internals, and the full seven-question gate,
resolve and read `agents path fact-modeling-reference`.
