# Ontology

This document is the current modeling contract: it assigns roles to the [glossary vocabulary](glossary.md), supplies the one normalized example, and governs profiles and semantic hints.

## Kernel boundary

The kernel has one hard opinion: each of `t1`, `t2`, and `t3` accepts any Term, recursively, and history is occurrence-addressed. It does not adjudicate truth, consistency, uniqueness, cardinality, or domain sense. Those are projections and profile rules above the kernel.

Atom, Triple, proposition, occurrence, and fact occupy distinct layers. The
model target is that an Atom's term identity is its kind plus canonical
payload; this does not limit the identity of a resource the Atom may name. A
Triple's identity is recursive
structural equality. Constructing or nesting a Triple creates no assertion. A
profile may interpret and admit a Triple as proposition content; an occurrence
then records that a writer asserted or retracted that content. A fact is status
conferred by a view, not a stored type.

This yields three independent identities:

```text
Atom identity         Atom kind + canonical payload
Proposition identity  recursive structural Triple equality
Assertion identity    occurrence coordinate
```

That Atom row is the semantic contract; it does not imply that every current scalar
implementation already satisfies it. Float is the known gap: host interning
makes NaN unequal to itself and equates `+0.0` with `-0.0`, while the wire
canonicalizes NaN bits and distinguishes the two signed zeros. Until a Float
policy lands, do not use NaN or signed zero where stable identity matters; see
[guarantees](guarantees.md).

Equal proposition content can have several assertion occurrences with
different provenance. Withdrawing one assertion does not mutate either the
Triple or its Atoms, and Beagle Store records the assertion without certifying its
truth.

## Perspective and graph roles

An occurrence intrinsically records its action and logical order. Asserter and
wall-clock metadata exist only when the calling route supplies them. Put a
holder in proposition content when that perspective is itself the subject
matter; operation metadata says who performed an act, while proposition content
says whose perspective the statement represents. Do not substitute one for the
other.

Nodes and edges are roles, not kinds. Any Term may be graph structure in one
proposition and subject matter in another. A Triple nested in another Triple
may be a compound value without being independently asserted; only its own
occurrence gives it proposition status.

Positional and named records are projections of the same information. A schema maps `t1`/`t2`/`t3` to domain roles; named assertions expand those roles into separate propositions. Profiles may choose either discipline without forking the kernel.

The nested compound-value and recursive-annotation examples below are
kernel-valid, but admissible only in an unprofiled space or a custom profile
that permits nested Terms. The implemented `"relational"` profile rejects
both: R1 requires each of `t1`, `t2`, and `t3` to be an Atom.

Context never mutates an Atom. The integer `0` remains the same Atom when it
later participates in a quantity-shaped compound Term:

```text
(account-1, :has_balance, (:quantity, 0, :credits))
```

Here the outer Triple is intended proposition content. The nested Triple is a
compound value and is not independently asserted.

## Normalization

Fact Normal Form (FNF) is the admission discipline for propositions admitted by
a fact-oriented profile, not for every assertion or recursive Term. Every
semantic relationship that profile needs to interpret, join, classify, or
validate the domain must be represented by an admitted Triple. It must not
exist only in Atom spelling, an assumed position, or an out-of-band schema
cell. Other asserted profiles own their own admission discipline. FNF does not
require every proposition to receive another opaque identifier.

This is the canonical fact-oriented example. Each line is intended to be
asserted separately:

```text
(:contactable_at, :member_of, :contact_relations)
("alice@example.com", :member_of, :email_addresses)
("Alice", :contactable_at, "alice@example.com")
```

In this profile the middle Term names the relation being stated.
`:contactable_at` states reachability; the noun `:email` would not. Membership
is explicit rather than hidden in a slash-spelled domain term.
Contextualizing the String as an email address does not transform it into a new
Atom.

Using the String directly is correct only when ordinary String canonicalization
and equality are exactly the email-address equality contract. If intrinsic
validation, ordering, canonical encoding, or equality differs, introduce an
`EmailAddress` Atom kind through a deliberate kernel and codec extension; an
ontology cannot declare one by spelling. If the address instead has an
independent lifecycle or mutable representation, mint a resource identity:

```text
(address-1, :represented_by, "alice@example.com")
(address-1, :member_of, :email_addresses)
("Alice", :contactable_at, address-1)
```

Self-denoting value and resource name remain semantic roles of Atom; Beagle Store needs
no physical Literal/Identifier split. Minting a resource is a domain-identity
decision, not a prerequisite for assertion or annotation.

Recursive annotation therefore needs no statement identifier:

```text
(("Alice", :contactable_at, "alice@example.com"),
 :verified_by,
 "mail-checker-1")
```

Asserting the outer Triple does not independently assert the nested Triple. If
the nested content is also asserted, its separate occurrence refers to the same
structurally identified Triple. Operation and withdrawal history is exposed as
system relations, not manufactured domain propositions. Closed wire and kernel
tags are protocol syntax, never a pattern for application ontology.

## Profiles and anchoring

A space opts into an optional profile with the primitive `:kernel/profile`
proposition; the profile's remaining rules are ordinary stored propositions:

```text
(space-id, :kernel/profile, (profile-id, "relational", "observe"))
(profile-id, "includes", "R1")
...
(profile-id, "includes", "R4")
```

Current profile lint bootstrap-skips every Triple whose `t2` is exactly the
Keyword `:kernel/profile`. Only the correctly shaped declaration shown above,
accompanied by all four `includes` propositions for R1-R4, binds the
`"relational"` profile. Other `:kernel/profile` shapes receive the broad lint
exemption but do not bind a profile. Listing `R5` additionally requires a
namespaced non-`:kernel/*` predicate to have an asserted membership; omitting
R5 preserves the space's prior verdicts. Current enforcement status is in
[guarantees](guarantees.md#profiles).

The stored profile kind currently named `"relational"` applies the stronger
**entity** (t1), **attribute** (t2), and **value** (t3) EAV reading. The kernel
is already relational in the weaker formal sense of one recursive ternary
relation; a profile assigns domain roles and admission rules rather than making
Terms relational. Profile-aware surfaces such as
`text-match(entity, attribute, needle)` may speak EAV, while kernel and wire
vocabulary stays t1/t2/t3. The verdict and rejected bench are in the
[naming ledger](naming.md#profile--and-the-eav-reading--chosen-2026-08-04).

## Semantic hints and similarity

Similarity is retrieval guidance, never identity or a kernel primitive:

1. Prefer explicit shared structure. Relate items to the same domain Term and derive relatedness by a deterministic join.
2. When affinity is genuine but not co-reference, assert it as an ordinary proposition and attach score and provenance to its occurrence.
3. Keep embeddings in a disposable index versioned to its source snapshot; FRAMLOG remains authoritative.

For example, after declaring `:is_similar_to` with the normalization rule above,
let `op` denote the occurrence coordinate returned for the first proposition:

```text
(left, :is_similar_to, right)
(op, :scored_as, 0.86)
(op, :scored_by, model-run)
```

The score describes one occurrence, so another model may assert or retract independently. Never merge identities solely from similarity. Strict queries may ignore hints; exploratory projections may select approved model runs and thresholds without assigning semantics to any Triple position.

Naming verdicts and rejected alternatives remain in the [naming ledger](naming.md); executable behavior and gates remain in [guarantees](guarantees.md).
