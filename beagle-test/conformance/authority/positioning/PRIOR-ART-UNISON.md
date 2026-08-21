# Prior-art steal sheet: Unison

> License: the inspected source tree at `resources:unison`
> (`db60ce2faa4649f97746873f7d186a6d3ebd3bb8`) is MIT-licensed under the
> copyright notice in `resources/unison:LICENSE`. The tree also bundles
> `Data.Relation`, which has a separate 3-clause BSD notice. This note
> paraphrases implementation ideas; it does not copy source code.

## Bottom line

Unison validates the useful half of Beagle's store-as-heap thesis: immutable
definitions can be content identities, while human names and branch heads are
changeable routing metadata. Its codebase is a database of hashed objects,
causal namespace snapshots, and indexes, not a directory of authoritative
source files. Its rename path therefore changes bindings and branch history,
not definition bodies.

Beagle should steal that separation, but retain two things Unison's model does
not make primary: exact source bytes for provenance and checked bundles that
bind a program to a source revision. Beagle's typed-triple store remains the
durable heap; native engines remain validated materializations; live cutover
remains an expected-head CAS at a tick boundary.

## What Unison actually does

### Content addressing: definitions are hashes, names are not identity

The hashing implementation groups mutually recursive definitions into strongly
connected components, canonicalizes their order, hashes each definition using
hashes for already-resolved dependencies, and assigns a component hash plus a
position to each member. See `resources/unison:unison-hashing-v2/src/Unison/Hashing/V2/ABT.hs:73-126`
and `resources/unison:unison-hashing-v2/src/Unison/Hashing/V2/Reference.hs:16-51`.

For terms, the type is incorporated into the term before hashing, while source
annotations are not semantic hash input. See
`resources/unison:unison-hashing-v2/src/Unison/Hashing/V2/Term.hs:92-109` and
the annotation-ignoring hash path in
`resources/unison:unison-hashing-v2/src/Unison/Hashing/V2/ABT.hs:136-167`.
The stored v2 term/decl blobs are later re-hashed and checked against their
claimed component hash by
`resources/unison:codebase2/codebase-sqlite-hashing-v2/src/U/Codebase/Term/Hashing.hs:26-45`
and `resources/unison:codebase2/codebase-sqlite-hashing-v2/src/U/Codebase/Decl/Hashing.hs:26-45`.

The name-to-definition association lives in a branch/namespace object. The v2
branch representation maps name segments to referents and metadata sets, while
the branch itself is content-addressed; see
`resources/unison:unison-hashing-v2/src/Unison/Hashing/V2/Branch.hs:16-39` and
`resources/unison:docs/repoformats/v2.markdown:225-250`. Consequently:

* changing a definition changes its definition/component hash;
* changing its name changes the branch/causal hash that routes to it;
* the same definition can have multiple names;
* a definition can remain present after a name is removed.

Important version caveat: the checked-in V3 branch type is deliberately trimmed
down: no conflicts, metadata, or patches (`resources/unison:codebase2/codebase/U/Codebase/BranchV3.hs:16-30`).
The hash-identity lesson survives that representation change, but “names as
metadata” is most literally the V2 format, not an invariant of every current
branch encoding.

### The codebase is a SQLite database of objects, history, and indexes

The v2 format is explicitly SQLite plus binary blobs
(`resources/unison:docs/repoformats/v2.markdown:1-37`). The schema has:

* a deduplicated `hash` table and a deduplicated `text` table;
* an `object` table containing typed blobs for term components, decl
  components, namespaces, and patches;
* `hash_object`, allowing more than one hash to identify one object, including
  future hash-version changes;
* `causal` and `causal_parent`, separating branch values from their causal
  history; and
* `name_lookups` plus scoped term/type lookup tables for derived search indexes.

These are actual tables in
`resources/unison:codebase2/codebase-sqlite/sql/create.sql:8-119` and
`:235-328`. The storage format uses local integer IDs inside blobs and lookup
arrays so objects can move between databases without rewriting every reference;
only the lookup table is rebuilt on import. See
`resources/unison:docs/repoformats/v2.markdown:121-211`.

Unison also distinguishes a hash reference from an object reference: an object
ID proves that the referenced object is actually present, while a hash can
refer to an object that still needs to be fetched. That distinction is stated
in `resources/unison:docs/repoformats/v2.markdown:55-74` and is a useful guard
against treating a merely known hash as loaded durable state.

The distributed/share path is not blind import. `SyncV2` validates downloaded
entities against their expected hashes and does not commit the transaction if
validation fails; see
`resources/unison:unison-cli/src/Unison/Share/SyncV2.hs:196-231`. This is the
most concrete distributed lesson in the current implementation.

### Rename and refactor are namespace edits, then a causal step

The CLI rename handler computes the destination final segment and delegates to
the same move machinery used for branches, terms, and types. It combines the
updates and records one branch step through `updateAndStepAt`; see
`resources/unison:unison-cli/src/Unison/Codebase/Editor/HandleInput/Rename.hs:15-37`.

For a term or type, the move operation resolves the existing referent, checks
the destination for a conflict, and returns two branch transformations: delete
the old name and add the new name pointing at the same referent. See
`resources/unison:unison-cli/src/Unison/Codebase/Editor/HandleInput/MoveTerm.hs:17-36`
and `resources/unison:unison-cli/src/Unison/Codebase/Editor/HandleInput/MoveType.hs:17-36`. Moving a namespace copies the branch value from
the old path to the new path and empties the old path, without changing the
branch's history (`resources/unison:unison-cli/src/Unison/Codebase/Editor/HandleInput/MoveBranch.hs:13-36`).

This is refactor-by-metadata, not textual search-and-rewrite. The operational
effect is a new immutable branch/causal value selected by a mutable current
route. It is precise because references already point to content identities;
the rename need not parse or rewrite every dependent definition.

There is a real limitation worth retaining: Unison's own publishing notes ask
what should happen when one actor renames `foo` while another upgrades
`foo#a` to `foo#b` (`resources/unison:docs/publishing-library1.md:23-25`).
Content identity removes accidental textual breakage; it does not decide
collaborative intent.

### Abilities: typed algebraic effects, explicit handlers

An ability is an algebraic effect whose required set is carried in function
types. The typechecker checks a call against the ambient abilities available at
that expression, and a handler can add/eliminate an ability for its body; see
`resources/unison:docs/ability-typechecking.markdown:2-9,40-73`.

The core type representation has explicit `Effect` and `Effects` constructors
(`resources/unison:unison-core/src/Unison/Type.hs:39-57,145-163`). The runtime
compiles an ability request as a reference, constructor ID, arguments, and a
continuation, so a handler can interpret or resume it. See
`resources/unison:unison-runtime/src/Unison/Runtime/docs.markdown:24-31,65-83,126-142`.
The runtime deliberately normalizes code so ability requests are handled at a
small, explicit point rather than appearing as hidden behavior in every call.

### Distributed execution: explicit ability and content transport, with an RFC caveat

The checked-in distributed programming RFC proposes `Remote.transfer`,
`Remote.fork`, task supervision, node-local boxes/names, immutable `Durable`
values, explicit sync/load, and explicit failure handling. It says the runtime
should not contact another node unless the program explicitly requests it, and
that arbitrary values need hashes, serialization, and dependency discovery;
see `resources/unison:docs/distributed-programming-rfc.markdown:1-8,20-34,170-199`
and `resources/unison:unison-runtime/src/Unison/Runtime/docs.markdown:8-24`.

That RFC is a design surface, not evidence that the whole arbitrary remote
execution API is the current runtime contract. The shipped implementation
evidence in this checkout is stronger for content-validated Share sync than
for general remote execution. Treat the distributed story as a design lesson:
make placement, authority, serialization, dependency transfer, and failure
visible in typed program values; do not infer that a hash alone grants the
right to execute.

## STEAL for Beagle

### 1. Give durable definitions a semantic hash identity

Define a canonical hash for a typed-triple definition or definition component.
Its payload should include the normalized type, dependency identities, and
ability/authority requirements that affect execution. Exclude branch names,
aliases, current routing heads, operational timestamps, and presentation
annotations.

In Beagle this buys structural sharing across branches, exact dependency-cone
lookup, deduplicated durable heap objects, cheap snapshots, precise native
cache keys, and bundles that can prove “this engine was built from these
definitions.” It aligns naturally with live cutover: an engine candidate is
immutable content, and expected-head CAS chooses which candidate is serving.

Keep semantic identity separate from exact-source provenance. Two source files
may produce the same typed definition but must not erase their source-byte
records; conversely, a source-only edit can preserve the semantic definition
hash while producing a new checked source revision.

### 2. Make names, aliases, and branch heads first-class routing metadata

Model the durable heap as immutable content plus mutable/branch-local metadata:

```text
definition-hash -> typed triple / component
branch-head    -> name or route -> definition-hash
source-revision -> exact bytes + checked bundle + semantic hashes
engine-head    -> validated native materialization
```

The typed-triple store remains authoritative. Name indexes, occurrence indexes,
dependency indexes, and pretty names are derived views with rebuild/validation
paths. A name move should not copy or rewrite the definition payload.

### 3. Copy the rename wave's atomicity, not Unison's product surface

Unison's `rename` combines namespace, term, and type updates into one branch
step. Beagle's CLI rename wave should have the same semantic property: one
explicit migration changes the command tree, helper names, packaged entrypoints,
units, docs, tests, and consumer references coherently, then the expected-head
promotion observes the whole candidate.

The mapping is deliberately not “add an alias forever.” A rename is metadata
and routing work, but the Beagle product migration is also a break-forward
consumer wave. The accepted `beagle store <verb>` surface and
`beagle-store-*` automation names should be the only live names after cutover.

### 4. Make abilities part of checked program identity and execution boundaries

Steal the discipline that an effect is visible in a type and interpreted by an
explicit handler. For branch-core, record effect/authority requirements in the
typed graph and in checked bundles. Native lowering must materialize those
requirements at an explicit boundary; it must not smuggle network, durable
mutation, or promotion authority through ambient process state.

For distributed execution, use an explicit `Remote`-like ability whose values
name the target, allowed effects, dependency bundle, and failure policy. Keep
the runtime dumb about discovery and placement. Beagle's tick-boundary cutover
and expected-head CAS are the corresponding handlers for live engine state:
they interpret a validated proposal without allowing an arbitrary execution to
rewrite the durable heap.

### 5. Validate bundles before insertion or promotion

Adopt the strongest shipped Unison practice: validate every claimed content
identity before saving it. A Beagle bundle should carry the root program hash,
transitive definition hashes, exact source-byte provenance, type/effect
requirements, engine/ABI context, and expected branch head. Reject missing,
mismatched, or unauthorized dependencies before the bundle becomes durable or
eligible for cutover.

## DO NOT COPY

* Do not make the database the only authoring surface. Unison's `.unison`
  branch/codebase workflow and UCM-centered editor are powerful but create
  tooling isolation. The repository documents a dedicated command-line editor
  architecture (`resources/unison:docs/commandline-editor-dev.md:1-11`) and a
  separate UCM MCP process per agent (`resources/unison:docs/mcp.md:1-13`).
  Beagle must preserve exact source bytes, ordinary file/editor access, and
  exportable checked bundles even when the store is the durable heap.

* Do not copy ecosystem lock-in. A bespoke language, runtime, codebase format,
  library namespace, publishing service, and effect vocabulary compound
  switching costs. Unison's own library-publishing notes describe the external
  branch merge as a multi-step workflow and warn that published namespaces need
  substantial tooling to stay immaculate (`resources/unison:docs/publishing-library1.md:3-21`).
  Beagle's typed triples and bundles need stable interchange and clear escape
  hatches, not an assumption that every useful tool or library will be native.

* Do not use a bare hash as the whole identity story. Version the hash
  algorithm, canonical serialization, type/effect interpretation, and engine
  ABI. Unison's `hash_object` indirection is evidence that hash evolution is a
  storage concern (`resources/unison:codebase2/codebase-sqlite/sql/create.sql:33-52`).
  Keep exact-source provenance and human intent alongside semantic identity.

* Do not assume content addressing solves concurrent refactor intent. The
  rename-versus-upgrade question in Unison's publishing notes is the warning:
  branch merge still needs an explicit policy for aliases, upgrades, conflicts,
  and deletions.

* Do not copy the distributed RFC as if it were a shipped guarantee. Start with
  content-validated transfer and explicit authority. Add remote execution only
  behind a typed ability, checked bundle, bounded failure model, and an
  observable promotion protocol.

* Do not copy Unison's runtime continuation machinery wholesale. The useful
  lesson is the boundary—typed requests and explicit handlers—not the exact
  evaluator, stack representation, or affine-handler optimization.

## Three first experiments

1. **Semantic definition identity.** Add a small branch-core fixture that
   canonicalizes a typed triple plus its dependency and ability requirements.
   Assert that two names and two branch snapshots yield one definition hash;
   renaming changes only routing metadata; changing a type, dependency, or
   authority requirement changes the semantic hash; exact source bytes remain
   separately addressable. Record the canonical bytes and hash in a checked
   bundle.

2. **Metadata-only rename with cutover CAS.** Build a fixture with aliases,
   dependent occurrences, an exact-source record, and one active engine. Run a
   rename wave that updates name/route triples only, prove the definition and
   source-byte hashes are unchanged, rebuild the derived indexes, and attempt a
   competing expected-head promotion. The stale-head writer must lose; the
   winning engine changes only at a tick boundary.

3. **Explicit remote/ability bundle.** Define the smallest checked bundle for a
   pure two-node execution: root program hash, dependency closure, source
   provenance, effect/authority set, target location, and expected branch head.
   Run it through a local verifier that rejects an unknown dependency, an
   altered source byte, an unauthorized ability, and a stale head. Then allow a
   single explicit remote operation and record the result as a typed receipt.
   This tests Unison's distributed discipline without making network discovery
   or ambient process state part of Beagle's semantics.

## Evidence

Inspected the MIT notice and the source files cited above at Unison commit
`db60ce2faa4649f97746873f7d186a6d3ebd3bb8`; the source checkout remained
clean and read-only. The requested license header, actual implementation
description, STEAL list, DO-NOT-COPY list, and three experiments are present.

PRIOR-UNISON-DONE
