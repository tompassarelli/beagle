+++
id = "beagle-w5-spike-syntax"
title = "W5 spike A: syntax-object data model"
shape = "thread"
life = "archived"
updated_at = "2026-08-17T21:06:00+08:00"
owners = ["codex:/root"]
depends_on = []
conversation_ids = []
coordination = []

[[lane]]
repo = "beagle"
worktree = "~/code/beagle/worktrees/w5-spike-syntax"
branch = "w5-spike-syntax"
owner = "codex:/root"
state = "findings extracted; worktree and branch reaped"
+++

## Outcome

Record the standalone W5 syntax-object membrane experiment, its focused test
result, and the implementation constraints it exposes for the real wave. The
result is a new-file-only Racket module and test pair in
`beagle:experiments/`; no compiler seam is claimed implemented.

## Current state

`beagle:experiments/w5-syntax-object.rkt` defines an immutable syntax ADT:
Atom, Ident, List, Vector, Quote, and Unquote. Every value has a source span,
scope-set slot, optional expansion origin, and immutable properties. Ident
carries `(qualifier, leaf, provider-id)` as a structural name; `syntax->datum`
is explicit and lossy. `fill-unquotes` preserves a caller child by object
identity when it fills a generated template.

The pinned focused command `nice -n 19 "$RACO" test
experiments/w5-syntax-object-test.rkt` passed 5 tests. The authoring loop was
revived and its deep doctor passed before the experiment.

## What fits W1--W4

- W1--W4's `qualified-ref` already has exactly the needed structural-name
  fields: authored qualifier, leaf, and resolver-attached provider identity.
  The spike carries that triplet without reconstructing a slash-bearing name.
- Reader distinction between code and quoted data maps cleanly: a quote keeps
  raw datum inert, while unquote owns a syntax child. The test proves that the
  antiquoted caller child and its original span survive unchanged.
- Existing expansion provenance has an obvious destination in a persistent
  `ExpansionOrigin { macro-id, call-span, parent }`; immutable properties are
  sufficient for reader and diagnostic tags in this first cut.

## What fights W1--W4

- The current macro evaluator and `macros.rkt` exchange raw datums, and
  `parse.rkt` rebuilds generated output with one call-site `datum->syntax`.
  That cannot preserve an antiquoted child's individual span or syntax identity.
- Existing mode-2 hygiene rewrites definition-site free references to aliases.
  It is not a scope-set resolver, so the real wave must replace that mechanism
  at the macro/binder seam rather than compose a second identity system beside
  it.
- The self-hosted compiler mirrors the raw datum contract. A native-only
  migration would immediately break the remint/fixpoint obligation; both
  implementations need the same syntax membrane before output checking.

## Cost for the real W5.1 wave

Estimate 7--10 engineer-days after W3--W4 are integrated: 2--3 for the native
reader/macro adapter and source/provenance threading, 2--3 for the self-host
mirror and remint repair, 2 for parser/checker boundary and focused fixtures,
and 1--2 for exact-span/origin regression coverage and integration. This spike
does not include scope allocation, maximal-subset resolution, syntax patterns,
or dependency recording; those remain W5.2--W5.4 and must not be hidden in the
membrane estimate.

## Next actions

The implementation was intentionally not integrated. The next real change
should adapt one macro boundary at a time while retaining whole-output checking
and adding a native/self-host parity case before advancing beyond W5.1.

## Verification

`source bin/_beagle-racket && nice -n 19 "$RACO" test
experiments/w5-syntax-object-test.rkt` passed: 5 tests.

## Recovery and cleanup

The lane contained only the two new `experiments/` files and was committed at
`635ca28727a0867095a1f4606889a617671ad24c`. Its worktree and branch are now
reaped. This finding remains as the requested handoff artifact; it has no live
owner or pending external coordination.
