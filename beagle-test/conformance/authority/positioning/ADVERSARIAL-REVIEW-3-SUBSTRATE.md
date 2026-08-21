# ADVERSARIAL PANEL SEAT 1 — SUBSTRATE ATTACK

Final input re-read: `THE-TURTLES-THESIS.md` SHA-256
`c56fa27dca42983ce54dfcf66f87a4b3a0b8b169cfc26bbd49433188ec523088`.
`TURTLES-DONE` was present. Verdict: the thesis has the right separations, but
W7 is not yet a constitution. Several identities it relies on are either absent,
colliding, or joined only by ambient process state. The Smalltalk failure mode
is therefore still live: the authoritative world and its external projection can
diverge behind a bridge that only the running system understands.

## Findings

1. **FATAL — Occurrence identity collides exactly where provenance matters: after a fork.**

   **Evidence.** The thesis's five ossified identities omit Atom, proposition,
   transaction, and assertion-occurrence identity (`THE-TURTLES-THESIS.md:33-49`),
   although mechanism 5 later calls an assertion coordinate “occurrence identity”
   (`THE-TURTLES-THESIS.md:557-559`). The store defines that coordinate as
   `(SpaceId, tx-sequence, op-ordinal)` (`beagle:branch-core/src/fram/types.bgl:176-201`).
   Beagle's own fork gate proves two sibling branches can append different
   propositions with the same coordinate, while only their branch revisions
   differ (`beagle:branch-core/tests/framlog_fork_test.clj:135-157`). An annotation,
   withdrawal, provenance edge, or receipt that names the bare occurrence can
   therefore refer to two different events once histories are inspected, copied,
   or joined outside one branch-local view. `W7-G3` cannot truthfully promise that
   every occurrence keeps its identity across routing and history operations.

   **Smallest repair.** Make the durable event ID content-addressed by its exact
   parent-history/event ID and canonical transaction frame; define occurrence ID
   as `(event-id, ordinal)`. Keep `(SpaceId, sequence, ordinal)` only as a
   branch-local coordinate and ordering locator. Add a fork/join gate in which
   sibling first appends have equal local coordinates but unequal occurrence IDs,
   while shared-prefix occurrences retain one ID.

2. **FATAL — The identity bedrock, `Term`, is not in the constitution and is not presently stable across runtimes.**

   **Evidence.** W7 versions definition serialization, but never versions the
   equality/canonicalization law of the values from which definitions and domain
   facts are built. The current ontology says Atom identity is kind plus canonical
   payload, then immediately records that host Float identity disagrees with the
   wire for NaN and signed zero (`beagle:branch-core/docs/ontology.md:9-31`). It
   also says a new intrinsic scalar equality requires a kernel and codec extension
   (`beagle:branch-core/docs/ontology.md:90-99`). A definition hash over typed
   facts cannot outlive an unsettled recursive Term equality law.

   **Smallest repair.** Put a versioned, domain-separated `TermId` envelope ahead
   of W7: fixed kind IDs, canonical payload bytes, recursive encoding, comparison,
   and hostile cross-runtime golden vectors, including all Float edge cases and
   text encoding. New kinds and new equality rules create new versioned IDs plus
   explicit equivalence/migration facts; they never reinterpret old bytes.

3. **FATAL — “Branch/revision identity” collapses three identities the landed store deliberately separates.**

   **Evidence.** The thesis describes one immutable branch/revision identity as
   the object selected by CAS (`THE-TURTLES-THESIS.md:42-44`). The implementation
   has at least three things: a mutable branch name, a logical `BranchRevision`
   over SpaceId plus exact history bytes (`beagle:branch-core/src/fram/branch.bclj:24-32,133-164`),
   and a `ref-identity` over physical ref bytes used as the CAS token. The source
   explicitly says the ref token is not a durable branch revision and may change
   on reseal (`beagle:branch-core/src/fram/branch.bclj:182-187`); the CAS actually
   compares that token (`beagle:branch-core/database.clj:898-935`). Thus a
   compaction-only change can make a promotion “stale” without changing semantic
   history, or a receipt can say “expected head” without saying which head notion
   it means.

   **Smallest repair.** Name four fields separately: `RouteName`, immutable
   `HistoryRevisionId`, opaque `RefStateToken`, and `EngineHeadId`. Promotion
   evidence binds the logical old history and engine head; the atomic update uses
   the ref token. A token-only reseal either transparently refreshes the token
   after proving the same history ID or returns a distinct physical-contention
   result, never semantic staleness.

4. **FATAL — An ordinary assertion can counterfeit a promotion fact.**

   **Evidence.** W7 sketches `promotes(receipt-id, ..., parity, cas-result)` as a
   fact (`THE-TURTLES-THESIS.md:491-505`) and W6 allows “explicit receipt facts”
   into store codecs (`THE-TURTLES-THESIS.md:474`). But Fram explicitly does not
   certify assertion truth, makes asserter metadata optional, and treats fact
   status as a view decision (`beagle:branch-core/docs/ontology.md:7-16,33-41`).
   The current product also states that it has no engine access control and only
   single-machine, single-writer receipts (`beagle:branch-core/docs/guarantees.md:152-157`).
   Canonical bytes prove only that somebody made a well-formed claim. They do not
   prove that the admission kernel performed parity, held authority, or won CAS.

   **Smallest repair.** Separate freely assertable claims from sealed system
   attestations. Only the admission transaction may mint the latter; its canonical
   envelope names issuer/verifier identity, verifier and policy versions,
   authority/lease epoch, and the verified objects, and is authenticated against
   an explicit trust root. Ordinary triples may cite or dispute an attestation but
   can never enter the certified `promotion` relation by shape alone.

5. **FATAL — The parity receipt is not bound to the candidate it allegedly proves.**

   **Evidence.** The thesis requires the promotion receipt to bind source,
   definitions, and previous/next materializations (`THE-TURTLES-THESIS.md:47-54`).
   The current Stage 4 shadow receipt binds journal head/range, state/output/result
   digests, and equality, but contains no candidate materialization, source,
   program, compiler, ABI, or artifact identity
   (`greywrought:tools/shadow-engine.mjs:377-394` in the `stage-5-demo` lane).
   Promotion trusts that the same in-memory `ShadowEngine` last emitted the digest,
   then invokes an arbitrary callback carrying only `expectedHead` and the parity
   receipt (`greywrought:tools/shadow-engine.mjs:414-437`). After restart or export,
   the receipt cannot prove which engine was replayed. This is ambient image
   identity in miniature.

   **Smallest repair.** Put the exact candidate `MaterializationId` and its full
   source/program/compiler/ABI closure in the parity receipt preimage. The
   admission kernel must consume a candidate handle cryptographically or
   structurally attested to that same ID. Add a cold-process gate that validates
   the receipt and admits only that artifact without access to the originating
   `ShadowEngine` object.

6. **FATAL — CAS success, state position, engine publication, and receipt durability have no single commit point.**

   **Evidence.** The receipt sketch includes `cas-result` in the receipt identity
   (`THE-TURTLES-THESIS.md:47-49`, `491-502`), but success is only knowable after
   CAS, creating either a circular preimage or a post-CAS receipt. W7 says
   promotion “records” forward/reverse CAS but does not say that the receipt and
   visible engine head become durable atomically (`THE-TURTLES-THESIS.md:514`).
   The landed branch CAS durably replaces one ref and returns a process-local map
   afterward (`beagle:branch-core/database.clj:925-935`). The shadow engine first
   rechecks a journal head and then calls separate promotion code
   (`greywrought:tools/shadow-engine.mjs:429-437`). A crash can therefore expose a
   new head with no success receipt, and state/journal/tick can race a separate
   engine-head CAS.

   **Smallest repair.** Prepare an immutable `PromotionCommit` before publication;
   its ID binds old engine head, candidate materialization, exact state revision,
   journal cursor, tick, lease epoch, parity receipt, and policy. Perform one
   fenced compare-and-set over that whole expected tuple and make the visible head
   point to the commit. Success is derived from durable reachability of the commit,
   not stored inside its own preimage. Failed attempts use a separate attempt ID
   and rejection receipt.

7. **FATAL — “Reverse promotion” repeats the exact downgrade hole the OTP autopsy attacks.**

   **Evidence.** The thesis correctly says OTP cannot prove that a downgrade
   inverted migration (`THE-TURTLES-THESIS.md:265-269`), then asks the world to
   advance state and reverse-promote the previous engine (`THE-TURTLES-THESIS.md:310-317`).
   The remaining-work clause requires only that the receipt name the prior engine
   and current head (`THE-TURTLES-THESIS.md:300-306`). Naming does not prove that
   old code can decode, preserve, or advance state written by new code, nor that
   external effects are compatible.

   **Smallest repair.** Treat the old materialization as a new candidate against
   the *current* state. Require current-state hydration, declared schema/profile
   compatibility or an explicit reverse migration, replay parity through the
   cutover suffix, and the same effect fence and atomic promotion commit. If that
   proof is absent, call the operation roll-forward recovery, not reverse
   promotion.

8. **DEFECT — Source provenance is a bag of fields, not a derivation graph.**

   **Evidence.** `source-revision(exact-bytes, ordered-paths, spans, source-hash)`
   and a stored source-to-facts projection do not identify the reader,
   interpretation, transformation, authority, or exact input-to-output edges
   (`THE-TURTLES-THESIS.md:493-503,510-511`). The gate is named
   `SOURCE-SEMANTIC-BIJECTION` while the mechanism explicitly permits multiple
   source revisions to denote one definition; the relation is intentionally
   many-to-one. The Smalltalk autopsy's central warning is that source and live
   authority become split-brain unless the bridge is a permanent, checked
   protocol (`PRIOR-ART-SMALLTALK.md:216-222`).

   **Smallest repair.** Define a first-class `Derivation` object whose canonical
   preimage lists ordered input object IDs, transformer/materialization ID,
   interpretation/profile ID, authority, output IDs, and byte-range/origin map.
   Every admissible semantic object needs a verified derivation path back to an
   exact source revision or an explicitly non-source origin. Rename the gate to
   `SOURCE-SEMANTIC-PROJECTION` and test the intended many-to-one relation.

9. **DEFECT — Explicit `become:` has no resolution law and already differs by query surface.**

   **Evidence.** W7 says a successor/alias fact is queryable and reversible, but
   leaves cycles, chains, conflicting successors, branch merges, type
   compatibility, and whether history APIs follow aliases unspecified
   (`THE-TURTLES-THESIS.md:512`). The current `:kernel/supersedes` behavior is only
   an effective-view rule in the retained JVM facade; it does not change
   `TermStore` liveness and is not honored by native scan or Datalog triple
   (`beagle:branch-core/docs/architecture.md:98-102`). That is already the
   Smalltalk/Iceberg split-brain pattern: identity means different things inside
   different tools.

   **Smallest repair.** Specify one snapshot-relative successor algebra: admission
   rule, cycle rejection, conflict value for multiple live successors, chain
   resolution, type/profile compatibility, and explicit “raw history never
   follows” versus “current semantic view follows.” Run one conformance matrix
   across hosted, native, Datalog, scan, reflection, export, and inspector paths.

10. **DEFECT — Receipt validity and GC retention form an unresolved permanence paradox.**

    **Evidence.** The thesis says no receipt is valid until every referenced
    object is present and verified (`THE-TURTLES-THESIS.md:51-54`), makes retained
    receipts GC roots (`THE-TURTLES-THESIS.md:515`), and demands independent
    replay of the linked receipt graph (`THE-TURTLES-THESIS.md:517-522`). Retaining
    a century of valid promotion receipts therefore retains every source,
    compiler, artifact, state, and journal closure forever. Releasing those
    objects makes old receipts invalid under the stated rule; releasing the
    receipts destroys the audit chain. “All and only reachable” does not choose a
    preservation policy.

    **Smallest repair.** Separate three statuses: byte-integrity-valid,
    admissible-at-the-recorded-policy, and locally replayable-now. Let a receipt
    commit to a closure manifest/Merkle root and durable archival disposition.
    Online GC may evict bodies only after the proof pack is archived or explicitly
    expired by a new auditable policy fact; replayability is restored by fetching
    and revalidating that pack.

11. **DEFECT — “Hash SCCs deterministically” is not a definition-identity algorithm.**

    **Evidence.** W7.1 does not decide alpha-equivalence, binder and scope-ID
    normalization, automorphic recursive components, nominal versus structural
    types, exported nominal seals, capability identity, or ordering of otherwise
    symmetric members (`THE-TURTLES-THESIS.md:510`). Those choices determine
    whether rename preserves identity and whether two distinct recursive APIs
    collapse. Versioning an unspecified serializer only versions ambiguity.

    **Smallest repair.** Publish a normative canonical graph algorithm with
    domain-separated node kinds, de Bruijn or equivalent binder normalization,
    explicit nominal seals, deterministic treatment of graph automorphisms, and
    component-member IDs. Gate it with adversarial alpha-renames, symmetric SCCs,
    reordered declarations, nominal twins, and cross-runtime/machine vectors.

12. **DEFECT — Materialization identity names output, but not the reconstructible execution closure.**

    **Evidence.** The materialization list names compiler, interface, target, ABI,
    obligations, and artifact hashes (`THE-TURTLES-THESIS.md:45-46`), but does not
    require the exact compiler artifact, linker/backend/sysroot/runtime closure,
    build options, host-feature contract, or admissibility policy to be content
    identities. An artifact hash identifies bytes, but not why those bytes are
    trusted or where they are valid. The Smalltalk autopsy predicts this directly:
    once the VM, image format, plugins, platform, and external files are implicit,
    the supposedly portable artifact becomes an opaque closure
    (`PRIOR-ART-SMALLTALK.md:184-198`).

    **Smallest repair.** Split `ArtifactId` from `MaterializationDerivationId` and
    `RuntimeCompatibilityProfileId`. Bind the exact transitive toolchain/build
    inputs and policy in the derivation; bind CPU/OS/ABI/host capabilities in the
    compatibility profile. Promotion verifies all three rather than trusting a
    compiler name and output digest.

## Panel verdict

The thesis should survive, but its W7 identity list should not ossify in this
form. Findings 1, 3, 5, and 6 are the load-bearing blockers: assertions collide
after forks; logical revisions and CAS tokens are conflated; parity is not bound
to the candidate; and publication has no single durable commit point. Findings 2,
4, and 7 make those failures semantic and adversarial rather than merely
representational. Until repaired, Beagle can reproduce Smalltalk's decisive
failure with better hashes: the live world knows which object, engine, and
transition it meant, while an external reviewer sees projections and receipts
that cannot independently recover that identity.

PANEL-SUBSTRATE-DONE
