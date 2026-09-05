---
name: fact-modeling-distilled
description: >-
  Design or review Beagle Store fact vocabularies, relations, identities, and typed admission before persisting semantic models.
---

# Fact modeling

Apply Fact Normal Form only within a fact-oriented profile. State required
relationships, memberships, and classifications as canonical Triples; do not
hide meaning in Atom spelling, positions, schema cells, or opaque row records.

- Outside that profile, preserve neutral recursive `Term := Atom | Triple`.
  Closed `:kernel/*` and `:rpc/*` vocabulary is not application ontology.
  Nested Triples are structural, not independently asserted.
- Atom equality comes from intrinsic kind and canonical payload. Mint resources
  only for continuity/lifecycle beyond representation.
- Keep Atom, structural proposition, and assertion-occurrence identity distinct.
- Review relations, membership, Atom kinds, and resources before admission;
  correct the model, then use `bin/beagle store validate`. Do not bypass a
  rejection or create a parallel validator.

Store operations belong to store-modeling. Examples, identity cases, and the
admission review live at `agents path fact-modeling-reference`.
