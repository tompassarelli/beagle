# FACT STORE EPOCH ROLL — DISPATCH DESIGN

## Ruling

Fact validity is not one undifferentiated `input hash × compiler identity`
key. It has two validity domains:

```text
STRUCTURAL currentness
  = exact structural inputs
  × structural extractor/schema identity

SEMANTIC currentness
  = exact semantic input closure
  × CompilerEpochId
  × verifier/policy identity where the claim has one
```

A compiler release rolls only `CompilerEpochId`. Exact source bytes, source
selection, source structure, and parse identity therefore remain current across
an ordinary compiler epoch roll. Type judgments, interfaces, effects, proofs,
semantic units, lowered artifacts, and compiler-backed verdicts require the new
epoch.

The new epoch does not require those semantic facts to be re-derived when the
release has proved the old and new compilers verdict-identical over the exact
admitted corpus. The release seal emits an immutable parity attestation over the
eligible prior fact set. That attestation makes the existing fact payloads
current in the new epoch without rewriting their bytes or pretending the new
compiler derived them.

“Wholesale” means one bounded, exact set proof over every eligible semantic fact
in the prior certified snapshot. It does not mean “trust every old fact.” A fact
outside the parity bundle's declared and mechanically proved coverage remains
invalid and is re-derived or logged as a miss before the release can seal.

The name `CompilerEpochV1` is deliberate. Store already uses “sealed epoch” for
physical FRAMLOG history ranges. Compiler epochs are certification namespaces;
they do not change Store segment, range, revision, or retention semantics.

## Evidence and current substrate

This is a design ruling, not a claim that epoch roll is implemented.

| Evidence | What it establishes for this design |
| --- | --- |
| `beagle:beagle-test/conformance/authority/positioning/CODE-AS-FACTS-OPERATING-MODEL.md` | Facts are immutable; candidate derivation occurs under a private root; `Derivation`, `DependencyEdge`, `ProofFact`, `VerdictAttestation`, `FactSnapshot`, and `MaintenanceReceipt` are the governing logical roles; publication is a cold-verified short CAS. |
| `beagle:beagle-test/conformance/authority/positioning/FACTS-SYNTHESIS.md` | V1 kinds are use-derived and versioned; stored bytes are never reinterpreted; unresolved, stale, unknown, or inadmissible reuse must emit `FactMissEventV1` before fallback; reads bind an exact Store/Space/root. |
| `beagle:beagle-test/conformance/authority/positioning/CONE-RECEIPT-SPIKE-FINDINGS.md` | Compiler-emitted semantic-unit and dependency receipts distinguish body-only from public-interface changes. A body edit invalidated one producer and retained its consumer; a signature edit invalidated both. |
| `todo:facts-first-cut.md` | The speculative first-cut fact maintainer at Beagle `7c7522fe69270df71675947b5d3541b9c0514deb` already has canonical fact IDs, exact candidate routing, durable miss-before-fallback, cold coverage query, observations, verdicts, and maintenance receipts. It remains shadow-only and unlanded. |
| `todo:selfhost-stage1.md` and `todo:selfhost-stage2.md` | The speculative self-host stages compare hosted build/check/AST, checked bundles, branch-corpus identities, downstream artifacts, statuses, and streams byte-for-byte against the pinned Racket path. The Stage 3 checkpoint is `51a4ab784f7f84130b98d00bdec116948c8540d0`; none is landed yet. |
| `beagle:store/src/store/types.bgl` at main `96e5d08bfe35d186a137d962d960648b21aba45f` | The durable semantic substrate is recursive `Term = Atom | Triple`. `SpaceId`, `CommitOperation`, `OperationOccurrence`, `TermStore`, and transaction/occurrence coordinates already provide append-only identity and history. |
| `beagle:store/src/store/branch.bclj` and `beagle:store/database.clj` at that commit | `BranchRevision` names exact logical history independently of physical resealing; branch refs have a distinct `ref-identity`; `compare-and-set-branch-ref!` is the existing short publication seam. |
| `beagle:beagle-lib/private/gate-fact-envelope-v1.rkt` and `beagle:store/src/store/gate_facts.bclj` at the first-cut checkpoint | `GateCandidateV1`, `GatePhaseClaimV1`, `GatePhaseObservationV1`, `GateCandidateVerdictV1`, `FactMissEventV1`, and `GateMaintenanceReceiptV1` are canonical EDN envelopes hashed as `sha256:` IDs and persisted as ordinary Triple propositions. `FactRoute`, `FactEntry`, `FallbackLink`, and `AppendCounts` are the current adapter types. |
| `beagle:self-host/verify-selfhost.sh`, `beagle:bin/test/branch-compile-corpus/run.sh`, and `beagle:contrib/downstream/runner.rkt` | Current producers already decide byte parity, accept/reject parity, exact branch identities/cones, and downstream byte-clean verdicts. `beagle-downstream/1` is a machine-readable receipt; branch-corpus identity/context files and self-host ladder outputs supply the other comparison inputs. |
| `todo:release-train-seal-task.md` | The current seal order is exact local gate commit → main/tag equality → version and notes preflights → annotated tag → `safe-push --tag`; the tag-triggered workflow publishes binaries afterward. Epoch sealing belongs between local preflight equality and annotated tag creation. |

### Current limitations that the dispatch must preserve visibly

- The first-cut fact kinds and Store adapter are speculative and shadow-only.
  They are substrate evidence, not current release authority.
- The self-host evidence is split among canonical artifacts, JSON receipts,
  TSV identity/context files, and bounded textual ladder output. A todo summary
  is not a certifying parity receipt. The first epoch-roll seam must normalize
  the machine outputs into one canonical bundle without weakening any existing
  comparison.
- `GateMaintenanceReceiptV1` is permanently shadow-only by its schema. Epoch
  work mints new kinds; it never changes that meaning or reinterprets V1 bytes.
- The current experimental `FactRoute` derives `SpaceId` from `base-commit`.
  That is acceptable for an isolated first cut but wrong for epoch authority.
  A release must not create a new Store space and strand old facts.
- Current compiler parity covers only what its compared channels expose. A
  PASS line does not automatically cover type/proof payloads absent from the
  compared checked-program, bundle, facts, or artifact bytes.

## Existing-type mapping and the additive vocabulary

### Store representation

No Store kernel type changes are required for the first epoch-roll seam.
Every new logical envelope is canonical EDN text with a domain-separated kind
in slot zero. Its fact ID is `sha256:` of those exact UTF-8 bytes, matching the
first-cut `FactEntry` rule. The adapter persists it as an ordinary proposition:

```text
Triple(
  Triple("store.fact-validity/subject-v1", certified-snapshot-id, fact-id),
  envelope-kind,
  canonical-envelope-edn)
```

Fallback and membership links are ordinary Triples with versioned predicate
names. The enclosing Store uses one stable authority `SpaceId` for the lifetime
of the fact-store format. Compiler epoch, Git release, candidate commit, and
published route are facts inside that Space, never components of `SpaceId`.

`TermStore` remains append-only. Prior fact envelopes, observations, verdicts,
and attestations remain addressable through occurrence history. Publication
advances a branch ref by `compare-and-set-branch-ref!` from the exact expected
`ref-identity`. `BranchRevision.identity` is recorded in every seal receipt so
cold readers can prove which logical history they opened even if physical
segments were later resealed.

### New versioned envelopes

The implementing workers derive final field spellings from their real
producer/query uses, but V1 must provide these roles and no fewer:

```text
CompilerEpochV1
  epochId                       # hash of this canonical envelope without epochId
  predecessorEpochId | "GENESIS"
  releaseCommit                 # exact 40-hex Git commit
  semanticCompilerManifestId    # exact ordered semantic producer closure
  semanticAbiId                 # checked/type/proof/interface meaning version
  factSchemaId                  # native semantic fact schema consumed here
  stage0ArtifactId
  selfhostSeedArtifactId
  racketOracleMaterializationId

FactValidityBindingV1
  bindingId
  factId                        # existing immutable FactEntry/content fact
  factKind
  validityDomain                # STRUCTURAL | SEMANTIC
  structuralInputClosureId
  structuralExtractorId         # required for STRUCTURAL
  derivedCompilerEpochId        # required for SEMANTIC facts actually derived
  derivationId

ParityCaseReceiptV1
  caseId
  coverageClassIds
  requestBytesId
  inputClosureId
  priorCompilerMaterializationId
  candidateCompilerMaterializationId
  priorStatus
  candidateStatus
  comparedChannelIds            # AST, checked bundle, facts, emit, diagnostics...
  priorChannelDigestIds
  candidateChannelDigestIds
  equalityVerdict               # IDENTICAL only when every named channel equals

CompilerParityBundleV1
  bundleId
  fromEpochId
  toEpochId
  releaseCommit
  corpusManifestId
  gatePolicyId
  parityCaseReceiptIds
  sourceReceiptIds              # exact existing self-host/downstream receipts
  coveredFactKindIds
  coveredProfileTargetIds
  skippedCaseIds
  infrastructureFailureIds
  verdict                       # IDENTICAL | DIFFERENT | INCOMPLETE

EpochReattestationChunkV1
  chunkId
  priorSnapshotId
  fromEpochId
  toEpochId
  parityBundleId
  chunkOrdinal
  chunkCount
  orderedFactIds                # bounded canonical vector
  priorChunkId | "FIRST"

EpochRollReceiptV1
  receiptId
  priorSnapshotId
  priorBranchRevisionId
  priorRefIdentity
  fromEpochId
  toEpochId
  parityBundleId
  structuralRetainedSetId
  semanticReattestationChunkIds
  freshlyDerivedFactIds
  invalidatedFactIds
  missEventIds
  countsByDisposition
  candidateSnapshotId
  coldCoverageObservationId
  publishedBranchRevisionId
  publishedRefIdentity
  publicationStatus             # PREPARED | PUBLISHED | CONFLICT

ReleaseEpochSealV1
  sealId
  releaseName                   # e.g. v0.25.0; routing metadata, not epoch identity
  releaseCommit
  localGateReceiptId
  compilerEpochId
  parityBundleId
  epochRollReceiptId
  certifiedSnapshotId
  certifiedBranchRevisionId
  tagMessageDigestPreimageId
```

An envelope's own ID is calculated over the envelope without that ID field, or
the encoder uses the established envelope-ID convention that avoids a cycle.
The exact convention is frozen by hostile canonical vectors before a second
emitter is admitted.

`EpochReattestationChunkV1` is bounded by encoded bytes and fact count. The
first implementation should start with at most 4,096 fact IDs and at most
1 MiB canonical text per chunk, then use the lower observed limit. This avoids
one unbounded Term string while retaining exact membership. Chunks form an
ordered digest chain; omission, duplication, reordering, or splicing changes
the head receipt.

### Payload identity is not validity identity

An old semantic fact keeps its existing `factId`. Re-attestation adds a new
proof edge; it does not mint an identical payload under a misleading new
derivation.

```text
fact payload F
  <- actually derived by compiler epoch E0, derivation D0
  <- current in E1 because parity bundle P(E0,E1) covers F's kind/profile
     and EpochRollReceipt R includes F exactly once
```

Queries return all three identities: `factId`, original `derivationId`, and
the currentness proof (`derivedCompilerEpochId` or re-attestation chain). A
caller may ask “why current?” without trusting the process that created F.

No V1 envelope is mutated. If the first-cut envelope folds payload, verifier,
and candidate information into one ID, the binding points to that complete V1
fact. Native fact work should separate `FactContent` from `Derivation` and
`Attestation`, but epoch roll does not wait for a destructive V1 migration.

## Validity-domain inventory

Classification is explicit in `FactValidityBindingV1`; it is never inferred
from a kind-name prefix at query time. Unknown, missing, or multiply classified
facts fail as SEMANTIC and emit `FactMissEventV1(unknown-fact-kind)` before
fallback.

| Logical fact role | Domain | Inputs that can invalidate it |
| --- | --- | --- |
| Exact repository revision, selected logical file list, source byte digest, byte count, logical path, source span | **STRUCTURAL** | Source bytes/selection, importer profile, path/provenance schema. Not `CompilerEpochId`. |
| Lossless reader datum, syntax occurrence, source tree, parse identity | **STRUCTURAL** | Source bytes plus `structuralExtractorId` and parse/schema identity. A parser projection-format change rolls this identity separately; an ordinary semantic compiler release does not. |
| Stable semantic subject name/occurrence link whose equality is defined only by structural identity | **STRUCTURAL** | Its structural occurrence and naming schema. |
| Binding resolution, expansion, inferred/effective type, interface digest, effect/authority judgment, proof obligation/result | **SEMANTIC** | Consulted structural/semantic facts, `CompilerEpochId`, and applicable policy. |
| Semantic-unit content, direct-read/interface-context cone, lowering obligation, native unit, target artifact | **SEMANTIC** | Semantic closure, compiler/backend/toolchain/profile identities. A compiler parity bundle covers only the profiles and artifact channels it compared. |
| `GateCandidateV1` source-selection portion | **STRUCTURAL** | Existing V1 is retained as immutable evidence; a validity binding classifies its source-selection claim. |
| `GatePhaseClaimV1` stable claim label/scope | **STRUCTURAL** only as a claim definition; its command/input/verifier closure is a separate **SEMANTIC** coverage dependency | A V2 split or validity binding must expose both. The complete V1 envelope is conservatively SEMANTIC until split. |
| `GatePhaseObservationV1`, `GateCandidateVerdictV1`, `VerdictAttestation` | **SEMANTIC** | Claim inputs, verifier/compiler epoch, policy, harness, fixtures, and correctness-relevant environment. |
| `FactMissEventV1`, failed/infra observations, `MaintenanceReceipt`, epoch/release receipts | **AUDIT ONLY** | Immutable historical evidence. They are retained but never satisfy a current program claim by themselves. |
| Store transaction occurrence, `BranchRevision`, ref CAS receipt, retention/GC summary | **STORE CONTROL** | Store history and control policy, not compiler epoch. They remain outside program-fact currentness. |

`AUDIT ONLY` and `STORE CONTROL` are not third currentness domains. They are
explicit exclusions from claim coverage. The two program-fact domains remain
STRUCTURAL and SEMANTIC.

## Re-attestation algorithm

### Inputs

The roll operates from one cold-opened prior certified route and receives:

1. exact prior `FactSnapshotId`, `BranchRevision.identity`, and ref identity;
2. exact candidate release commit and `CompilerEpochV1`;
3. one `CompilerParityBundleV1` produced on that exact commit;
4. current `GatePolicy` and fact-kind coverage registry;
5. every fact body or proof-pack body required to enumerate the prior snapshot.

The operation refuses a mutable Git ref, a bare version string, a warm-process
“current compiler,” an unresolved Store/Space route, or a receipt that names a
different commit/root/epoch.

### Admission preconditions

The parity bundle is admissible only when all are true:

- `fromEpochId` is the epoch that currently certifies the prior snapshot;
- `toEpochId` is the epoch derived from the exact release commit's compiler
  materialization manifest, not merely its SemVer or Git tag;
- the corpus manifest is the exact manifest selected by release `GatePolicy`;
- every selected case has a `ParityCaseReceiptV1`; there are no skips,
  `NOT-RUN`, `FLAKY`, infrastructure failures, missing output channels, or
  unclassified cases;
- each case compares old and new compiler status plus every channel required by
  its coverage classes; accept/reject equality alone cannot cover emitted
  facts, and emitted-byte equality alone cannot cover rejection semantics;
- source receipt IDs resolve to the exact self-host Stage 1 build/check receipts,
  Stage 2 checked-program/AST receipts, Stage 3 checked-bundle/branch/downstream
  receipts, and the release gate observation used to make the decision;
- the fact schema and semantic ABI claimed by a covered kind are unchanged, or
  a separate byte-exact equivalence receipt explicitly covers that transition;
- the issuer, verifier, policy, target, environment, and corpus identities are
  admitted and not withdrawn.

Any failed precondition makes the bundle `INCOMPLETE` or `DIFFERENT`; it cannot
be retried into `IDENTICAL`. The release may repair the candidate and produce a
new bundle for that new exact commit.

### Eligibility partition

For every fact reachable from the prior certified snapshot:

```text
if audit/control evidence:
  retain historically; do not count as current program coverage

else if validityDomain == STRUCTURAL:
  retain when structuralInputClosureId and structuralExtractorId are current

else if validityDomain == SEMANTIC:
  re-attest when all of:
    prior fact is currently admitted and not withdrawn
    complete dependency closure is available and unchanged
    fact kind/profile/target is covered by the parity bundle
    fact envelope/schema meaning is unchanged
    verifier/policy remains admitted
  otherwise invalidate and emit a named miss before fallback derivation

else:
  emit unknown-fact-kind miss and invalidate
```

The partition is total: every reachable fact appears exactly once in
`structuralRetained`, `semanticReattested`, `freshlyDerived`,
`invalidated/missed`, or the audit/control exclusion count. Overlap or an
unaccounted fact refuses the roll.

### Wholesale re-attestation

Eligible semantic fact IDs are sorted canonically, deduplicated, partitioned
into bounded chunks, and bound to the prior snapshot, both epochs, and parity
bundle. No compiler command runs per fact. The proof is:

```text
prior snapshot certified F under E0
and direct release parity bundle proves E0 == E1 for F's admitted coverage class
and F's non-compiler dependency closure is unchanged
and F is a member of the exact re-attestation set
therefore F is current under E1 by attestation, not by fresh derivation
```

The direct bundle is always between the currently published epoch and the
candidate epoch. A fact originally derived several releases ago may have an
attestation chain, but every release adds only one direct hop from the current
snapshot. V1 does not compact or silently shorten that chain.

### Candidate snapshot and publication

The roll builds a private candidate snapshot containing:

- the same current structural facts;
- prior semantic fact payloads plus the new epoch re-attestation chunks;
- freshly derived replacements for uncovered/changed facts;
- invalidation and miss evidence for every rejected reuse;
- a total coverage result under the release `GatePolicy`;
- the complete `EpochRollReceiptV1` in `PREPARED` state.

A separate cold process opens the exact Store/Space and candidate branch,
recomputes every set digest, verifies chunk chains and membership, rejects
withdrawals/corruption, evaluates release coverage, and confirms that the
candidate's exact release commit equals local main. Publication then performs
one `compare-and-set-branch-ref!` from the recorded prior ref identity. A moved
ref returns `CONFLICT`; the caller reopens and replans. It never overwrites the
newer route.

After CAS, the publisher records the new branch revision/ref identity and a
`PUBLISHED` receipt. The published route is current only when cold reopen
observes those exact identities and the new snapshot. Expensive corpus runs,
classification, re-attestation construction, and fallback derivations occur
before CAS.

## Self-host parity receipt integration

### Receipt source inventory

| Self-host seam | Existing deciding comparison | Epoch-roll coverage it may claim |
| --- | --- | --- |
| Stage 1 hosted build/check dispatch | Candidate stage0 versus pinned Racket status, stdout, stderr, success artifact bytes, failure atomicity, and fallback behavior | Hosted check verdicts and target emit facts for the exact source profiles/flags exercised. |
| Stage 2 AST dispatch | Checked-program v4 canonical bytes, provenance, inferred type, raises/doc fields, interface digest output, status and diagnostics | Structural parse projection only when the compared projection schema says so; semantic checked/type/interface facts only when those fields are present in the byte comparison. The recorded pre-existing non-parity fixture must be excluded from coverage or repaired before a bundle can be `IDENTICAL`. |
| Stage 3 checked bundle | Exact 5,062-byte branch response, module-interface hashes, entry projection, source closure, checked-bundle hash, repeated baseline, and body/interface mutation identities | Native compiler input bundle, module interface, semantic unit, and cone fact classes exercised by the branch corpus. |
| Stage 3 downstream compile | `beagle-downstream/1` candidate commit, consumer revisions/membership hashes, per-consumer status, diagnostics, and byte-clean result; Stage 3 additionally compared artifacts and complete success streams | Hosted downstream acceptance/artifact claims for the exact enumerated consumer/profile rows. Byte-clean consumer trees are a side-effect claim, not compiler semantic parity by themselves. |
| `verify-selfhost.sh` ladder | Stage-isolated emit bytes, AST parity, full-chain bytes, invalid accept/reject, checker-tail error-core, purity verdict/witness, and closed-module bundle parity | The precise compiler role/channel named by each rung. Its bounded completion receipt proves supervision only; it is not the semantic parity receipt. |
| Branch compile corpus | Deterministic identities, artifacts, source/interface boundary churn, semantic cones, and native receipt digests across baseline, repeat, comment, private-body, and public-interface cases | Exact source/interface/unit/cone coverage for the recorded profiles and mutations. It does not prove physical per-unit native cache reuse. |

### Normalization law

The parity worker consumes the existing artifacts without changing their
meaning:

1. discover the exact release corpus from the authoritative manifests;
2. run old and candidate compiler paths against identical canonical requests;
3. retain both raw outputs and producer receipts;
4. create one `ParityCaseReceiptV1` per case, naming every compared channel;
5. compare the selected-case set against the corpus manifest;
6. emit `CompilerParityBundleV1` only after total accounting.

Textual PASS summaries may be retained as logs but are never parsed as the sole
proof when a structured artifact exists. Timestamps, durations, temporary
paths, and job counts are observations and are excluded from semantic equality.
Request bytes, statuses, diagnostics where required, fact/projection/artifact
bytes, compiler materializations, profiles, policies, and corpus membership are
identity-bearing.

Coverage is positive and closed. A receipt lists exactly which fact kinds and
profile/target pairs its compared channels decide. A new semantic fact kind is
ineligible until a corpus case produces and compares its canonical bytes and a
negative substitution proves that a semantic drift rejects parity.

## Release-train seal integration

Epoch roll is a local pre-tag release gate. It never waits for GitHub and it
does not make a tag-triggered workflow the first proof.

### Revised seal order

```text
1. Build the exact release candidate, including version and authored notes.
2. Run the repository's local non-publishing release gate on that exact commit.
3. Produce the complete CompilerParityBundleV1 on the same commit.
4. Land the gated commit and prove local main == gated commit == prospective tag commit.
5. Rerun release-version and release-notes preflights.
6. Cold-open the current certified fact route and prepare the epoch roll.
7. Cold-verify the candidate snapshot and publish it by exact branch-ref CAS.
8. Emit ReleaseEpochSealV1 and cold-read the published root/epoch/receipt.
9. Create the annotated tag; its message names the gate receipt, CompilerEpochId,
   CompilerParityBundleId, EpochRollReceiptId, and certified FactSnapshotId.
10. Publish only with safe-push --tag VERSION.
11. The tag workflow may package binaries and attach the proof pack after its
    producing checks; that remote result is asynchronous and never repairs a
    missing local epoch seal.
```

Steps 6–8 are inserted into the current `release-train-seal-task` after its
exact gated/main/tag equality and metadata preflights, and before annotated tag
creation. If the parity bundle is incomplete, required facts remain missing,
the cold verifier disagrees, or the ref CAS conflicts, no tag is created.

The first fact-authoritative release is `GENESIS`: it has no prior epoch to
re-attest and must create its certified baseline by derivation. Every later
compiler release must either publish a complete re-attestation/fresh-derivation
roll or stop before tagging. The current shadow-only first cut is not an
authoritative prior root and cannot be presented as a genesis seal.

Publication is idempotent for the same exact inputs. If the fact route already
names the candidate snapshot and its cold receipt matches, rerunning seal
returns the same IDs. If another snapshot advanced the route, seal returns a
visible conflict and replans from the new root. A failed tag push does not
change epoch evidence; the same unpublished annotated tag may be retried. No
published tag is moved or recreated.

## Dispatch inventory

The work is four independently verifiable seams. File boundaries below are
proposed ownership boundaries; the implementing agent must re-ground them on
the landed post-release tree before creating a lane.

### ER-1 — Canonical compiler parity bundle

**Preconditions**

- The self-host Stage 1–3 lane and the first-cut fact lane have either landed or
  are rebased into one exact integration base. Speculative receipts are not
  called release evidence.
- The exact authoritative self-host, branch-corpus, downstream, and gate
  manifests are inventoried from that base.

**Owned files**

- new `beagle:beagle-lib/private/compiler-parity-envelope-v1.rkt`;
- new `beagle:bin/test/compiler-epoch-parity/run.sh` and its bounded fixtures;
- minimal structured-receipt output additions only where an existing producer
  lacks a durable machine output: `beagle:self-host/verify-selfhost.sh`,
  `beagle:bin/test/branch-compile-corpus/run.sh`, and
  `beagle:contrib/downstream/runner.rkt`;
- focused tests for canonical vectors and corpus-total accounting.

It does not edit compiler semantics, Store code, release scripts, gate
scheduling, timeouts, cache eligibility, or consumer registries.

**Stages and verification**

1. Freeze hostile canonical vectors for all parity envelopes. Verify identical
   bytes/IDs under Racket and one independent decoder; corrupt, reordered,
   unknown-version, duplicate-case, and trailing-data inputs reject.
2. Normalize each existing receipt source. Verify the unmodified current
   compiler compared with itself yields exact case receipts and a total
   `IDENTICAL` bundle.
3. Compare the prior released compiler with the candidate over the exact
   manifest. Plant independently: one accept/reject drift, one emitted byte
   drift, one checked-program/type field drift, one diagnostic drift, one
   omitted corpus case, one skipped case, one wrong compiler identity, and one
   wrong release commit. Each prevents `IDENTICAL` in the relevant coverage
   class.
4. Cold-read the final bundle and its raw-source receipt digests. The selected
   case set, compared-channel set, and coverage-class set must reproduce
   exactly without ambient files.

**ER-1 landing bar**

- Every release corpus case is represented exactly once.
- `IDENTICAL` is impossible with a skip, infra result, missing channel,
  duplicate, unclassified case, or commit/compiler mismatch.
- Each claimed fact-kind/profile coverage has a real compared byte or verdict
  channel and a deciding negative test.
- Existing producer verdicts and default command behavior are unchanged when
  receipt output is not requested.

### ER-2 — Structural/semantic validity split

**Preconditions**

- The first-cut envelope/adapter behavior is landed and its V1 bytes are frozen.
- Native fact kinds being classified exist from real producer/query uses.

**Owned files**

- new `beagle:beagle-lib/private/fact-validity-envelope-v1.rkt`;
- new `beagle:store/src/store/fact_validity.bclj` and generated-only
  `beagle:store/out/store/fact_validity.clj`;
- new Store and Racket focused tests/fixtures;
- the smallest additive calls from the gate fact maintainer needed to write and
  query validity bindings.

It does not change `store.types`, the TermStore kernel, transaction encoding,
FRAMLOG segment/reseal formats, GC, or existing V1 envelope meanings.

**Stages and verification**

1. Register `CompilerEpochV1` and `FactValidityBindingV1` from real query uses.
   Cross-runtime hostile vectors and cold Store round trips must agree.
2. Classify the existing first-cut roles and the first native fact batch. A
   registry completeness test fails on every unclassified kind. Unknown kinds
   durably miss before conservative fallback.
3. Build a two-release fixture with unchanged source bytes and a changed
   semantic epoch. Cold query must retain source selection, source bytes,
   syntax tree, and parse identity while rejecting type/proof/verdict facts
   lacking new-epoch derivation or attestation.
4. Change only `structuralExtractorId`; structural parse facts and their
   semantic dependents invalidate, while unrelated exact source-byte facts
   remain. This proves that “semantics-independent” is not “identity-free.”
5. Substitute Store path, SpaceId, root, epoch, schema, verifier, and policy.
   Every mismatch produces a named miss, never an empty result or PASS.

**ER-2 landing bar**

- An ordinary compiler epoch change invalidates zero current STRUCTURAL facts.
- A structural extractor/schema change invalidates the exact structural cone.
- Every SEMANTIC currentness answer names either its actual derivation epoch or
  an admitted re-attestation path.
- Audit/control receipts cannot satisfy a program claim.
- The stable authority SpaceId is unchanged across compiler epochs.

### ER-3 — Epoch re-attestation and snapshot CAS

**Preconditions**

- ER-1 and ER-2 are landed.
- One certified shadow snapshot exists with enough semantic facts to exercise
  covered and uncovered classes.

**Owned files**

- new `beagle:beagle-lib/private/epoch-roll-maintainer.rkt`;
- new `beagle:store/src/store/epoch_roll.bclj` and generated-only
  `beagle:store/out/store/epoch_roll.clj`;
- new bounded focused Store/Racket tests and a supervised end-to-end driver;
- no release workflow or compiler producer files.

**Stages and verification**

1. Implement the total eligibility partition and bounded chunk encoder. Pure
   tests cover empty sets, one chunk, multiple chunks, duplicates, overlap,
   missing IDs, reordered chunks, corrupt envelope bytes, and withdrawal.
2. Execute an identical-compiler epoch roll. The candidate must retain all
   STRUCTURAL facts, re-attest every covered SEMANTIC fact, run zero per-fact
   compiler derivations, and preserve every old fact ID.
3. Execute a partial-coverage roll. Covered semantic facts re-attest; uncovered
   kinds emit durable misses and are freshly derived through the existing
   conservative oracle. Publication remains impossible until every required
   claim is current.
4. Plant body-only and public-interface mutations from the cone spike. Body
   change re-derives the producer and retains the caller cone where its
   interface remains equal; interface change invalidates the exact consumers.
   Epoch re-attestation must not erase source-driven invalidation.
5. Cold-open and verify the candidate from only Store history and proof packs.
   Then race the expected ref: one publisher succeeds, the stale one receives
   `CONFLICT`, and no partial route is visible.
6. Reseal physical Store segments and repeat cold verification. The logical
   `BranchRevision.identity`, fact IDs, and epoch verdict remain unchanged even
   though ref/segment routing may change.

The supervised driver owns phase deadlines, child process groups, visible
progress, cleanup, and failure artifacts. No routine case exceeds the fleet's
2–3 minute verification window; corpus cases are sharded by independent
fixture without duplicating shared prerequisites.

**ER-3 landing bar**

- A fully covered parity release re-attests the complete eligible semantic set
  with zero payload rewrites and zero per-fact compiler runs.
- Cold verification accounts for every reachable fact exactly once and every
  required claim is current.
- An omitted dependency, fact, chunk, receipt, or coverage class rejects
  publication.
- CAS conflict is visible and leaves the published route untouched.
- Old snapshot and fact history remain queryable after publication and physical
  reseal.

### ER-4 — Release seal gate

**Preconditions**

- ER-3 is authoritative for one narrow claim class after its shadow parity
  observation window; other classes may remain conservative and freshly
  derived.
- The repository's exact local non-publishing release gate is identified on the
  landed base.

**Owned files**

- new `beagle:scripts/check-release-epoch.sh`;
- new `beagle:scripts/seal-release-epoch`;
- additive release-preflight registration and focused scratch Git/Store tests;
- release workflow changes only if needed to attach, not create or validate,
  the already local `ReleaseEpochSealV1` proof pack.

It does not change compiler semantics, fact classification, Store kernel, or
remote CI into a landing/release preflight oracle.

**Stages and verification**

1. Add a dry preflight that proves gated commit, local main, candidate epoch,
   parity bundle, and prospective tag commit equality without publishing.
2. Add the cold epoch prepare/verify/CAS operation and emit
   `ReleaseEpochSealV1` only after published-root cold reopen.
3. Make annotated tag construction consume the seal receipt IDs. Refuse a tag
   on missing/incomplete parity, missing fact coverage, wrong commit, stale
   root, CAS conflict, malformed tag metadata, or genesis claimed over an
   existing authoritative epoch.
4. In a scratch bare remote, run: genesis; fully re-attested second release;
   partial coverage with successful fallback derivation; parity drift; stale
   CAS; tag-push failure and same-tag retry. Only the first three produce an
   eligible final tag, and retry never moves a published tag.
5. Run the repository's existing local non-publishing release gate once on the
   exact ER-4 commit after focused checks pass. Remote workflows are async.

**ER-4 landing bar**

- No non-genesis compiler release can be tagged without a cold-verified
  published epoch roll for the same exact commit.
- The annotated tag binds the exact local gate, compiler epoch, parity bundle,
  epoch roll, and certified fact snapshot IDs.
- A tag-triggered workflow cannot manufacture missing local seal evidence.
- Re-running the same successful seal is idempotent; a moved Store route or
  different commit refuses.
- Existing version/notes checks, annotated-tag rule, `safe-push --tag`, and
  producing-workflow binary rule remain intact.

## Dependency and dispatch order

```text
land/rebase first-cut fact maintainer ─┐
                                      ├─> ER-2 validity split ─┐
land/rebase self-host stages 1–3 ─> ER-1 parity bundle ────────┤
                                                               └─> ER-3 roll/CAS
                                                                      │
                                                                      └─> ER-4 seal
```

ER-1 and ER-2 have disjoint primary files and may run in parallel after their
respective bases land. ER-3 integrates their frozen envelopes. ER-4 owns only
the release seam after ER-3's authority pilot. No worker edits another seam's
files; integration conflicts return to the owning seam.

Each worker creates one Beagle lane from clean current main, records the exact
worktree/branch/owner mapping in a flat todo record before mutation, stages only
its enumerated files, runs the named focused checks and one exact-commit local
gate, lands with `safe-push --to main`, fast-forwards main, and reaps the lane.
Those are future execution instructions; this design performs no lane, code,
gate, commit, or landing.

## Program-level landing bar

Epoch roll becomes part of release authority only when all of the following are
true:

- canonical epoch, parity, validity, re-attestation, roll, and seal envelopes
  pass hostile cross-runtime vectors and are never reinterpreted;
- the authority Store keeps one stable SpaceId across at least two compiler
  releases and cold-reopens the same prior facts;
- the fact-kind registry totally classifies all current program facts as
  STRUCTURAL or SEMANTIC, with audit/control exclusions explicit;
- a fully parity-covered release keeps all eligible semantic fact IDs and makes
  them current through one exact wholesale re-attestation set rather than
  re-derivation;
- a structural-only fact remains current across that roll, while a structural
  extractor change invalidates its exact cone;
- uncovered semantic kinds, skipped/infra corpus cases, wrong compiler or
  commit identity, omitted dependencies, corrupt chunks, withdrawals, and
  stale policies all reject reuse before fallback or seal;
- the cone spike's body/interface distinction remains exact through a roll;
- cold coverage accounts for every required claim and reproduces the candidate
  snapshot without the compiler process that produced the prior facts;
- short publication CAS is the only serialized Store mutation and a conflict
  never overwrites a newer root;
- the exact locally gated release commit, `CompilerEpochId`, parity bundle,
  epoch roll receipt, certified snapshot, annotated tag, and published tag all
  agree;
- genesis is used exactly once, and every later compiler release seals by
  re-attestation plus bounded fresh derivation for genuine uncovered changes;
- the old full gate remains the conservative fallback until the relevant fact
  classes earn authority, but a fallback PASS is imported as new evidence and
  never relabeled as parity re-attestation.

## Rollback and recovery

Before authority, disable the epoch path and run the unchanged full gate; the
experimental facts remain immutable diagnostic data under unpublished roots.

After authority, rollback never deletes facts or moves a published tag. Route
the certified fact name by a new, cold-verified CAS to a previously certified
snapshot whose compiler release is the one actually selected by the repository
and consumers. Emit a new rollback maintenance receipt explaining the route
change. If program/compiler main has advanced, reverting it is a separate
ordinary repository landing and must agree with the selected fact snapshot.

Corrupt or unavailable re-attestation bodies make affected semantic facts
unavailable, not silently stale-current. Recover from the archived proof pack,
or re-derive through the conservative gate and publish a new snapshot. Store
history and old receipts are retained until retention policy proves no
certified route, release proof pack, or consumer needs them.

EPOCH-ROLL-DONE
