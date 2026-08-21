# Facts Store Pre-Flip Requirements

## Ruling

The facts store remains shadow-only until every direct gate below is green. A
green old gate is not evidence that the facts store is authoritative: the old
gate currently masks store contention, and the shadow wrapper can return the
old gate's zero exit after fact finalization failed.

The order below is dependency-first and then risk-first. “Lowest deterministic
layer” means the smallest check that can prove the requirement without relying
on a wall-clock, network, compiler process, or fleet outcome when a pure or
controlled Store check can prove it.

The six requirements marked **SP** are the six store-physics gaps from
`ADVERSARIAL-REVIEW-7-STORE-PHYSICS.md`. The retention and epoch requirements
are separate designs that consume those seams.

## Ordered authority gates

### 1. FACT-ID-V1 — canonical identity and hostile envelope vectors

**Threat closed:** A corrupt, ambiguous, cross-runtime, or version-confused
envelope could be accepted as a fact, making every later root and verdict
untrustworthy.

**Evidence:** The store-physics report proves that complete-envelope hashing
and rejection of a mismatched envelope under one fact ID work, but that is only
per-fact immutability (`ADVERSARIAL-REVIEW-7-STORE-PHYSICS.md`, Threat 2). The
operating model requires cross-runtime hostile vectors as `R0`. The seven
candidate/four-miss parity receipt is
`47ccae5860a2591b91b4a437a25661babe189ba5aecdbb5e37348ca9573622bc`, with
supervisor receipt
`1186d2ec9815d2866dcab436bb1fb4e81466899a7e540750496fea2b8f850a3e`.

**Owning design:** Operating-model `S0` / `R0`; no landed authority
implementation is banked.

**Acceptance at the lowest deterministic layer:** Pure canonical-vector tests
must produce identical bytes and IDs under the supported emitters; corrupt,
unknown-version, duplicate, reordered, and trailing-data envelopes must reject.
A cold Store round trip must recover the same envelope bytes and ID. A V1
meaning correction creates V2; it never rewrites V1.

**Rough size:** 3–5 engineer-days.

### 2. SP-1 — bounded writer admission and stable authority space

**Threat closed:** Concurrent maintainers can fail fast, lose accepted
progress, repeatedly cold-replay the log, or serialize derivation behind a
global lock. The Store also must not be stranded in a new space when compiler
epochs or releases change.

**Evidence:** The store-physics report shows real file locking and framed
append/torn-tail detection, but fail-fast acquisition; five of eight workers
failed in both shared campaigns. Same-identity status/integrity receipts are
`f5a56c7b2556532d2bda63e8dfb2bb6fe065e812e72cc00e0c7893cdd423b902` and
`fa24892b74ec94c6c85b76320c0519b4b12c2678b24ebd58f2eaa852ae5eeefd`.
`EPOCH-ROLL-DESIGN.md` requires one stable authority `SpaceId` across compiler
epochs. The current 12/12 Store test receipt in
`ADVERSARIAL-REVIEW-7-RETENTION.md` proves append/reopen only, not admission.

**Owning design:** Store-physics Gap 1; the epoch design's stable-SpaceId
rule. The banked writer-queue/append-broker plan is in Threat 1 of the
store-physics report.

**Acceptance at the lowest deterministic layer:** A controlled Store-adapter
test with concurrent processes must admit work through one bounded queue or
long-lived writer, expose queue/authority deadlines and progress, and preserve
every accepted batch through cold reopen. Derivation must happen outside the
short publication lock. A compiler-epoch fixture must reuse the same SpaceId.

**Rough size:** 5–8 engineer-days.

### 3. SP-2 — atomic maintainer batches, attempt isolation, and revision CAS

**Threat closed:** Candidate/claim/miss preparation and observation/verdict
finalization can be left half-live; one worker's partial history can be
mistaken for another's; a stale writer can overwrite a newer composition; an
ambiguous durability failure can be retried as if it were clean.

**Evidence:** Threat 1 of
`ADVERSARIAL-REVIEW-7-STORE-PHYSICS.md` records one process and one forced append
per miss/observation, permanent partial facts, and the missing
`MaintenanceAttemptId`, expected revision, and dual-status receipt. The mixed
campaign status/integrity receipts are
`881f96f820c5c4b0eb03459a548a14711d258c684f2415728e2da37b5b0e4da1` and
`435bafa2c04ac78d61eed4e2a26b79c4271bc16d8587ce08f0f4bada4aa91ee4`.

**Owning design:** Store-physics Gap 2; the report's batched preparation,
batched completion, attempt partition, expected-revision CAS, and dual-status
receipt plan.

**Acceptance at the lowest deterministic layer:** Pure transaction tests must
prove that one preparation batch and one completion batch are atomic, that
attempt IDs partition all misses/links/receipts, and that a stale expected
revision returns a typed conflict without changing the published route. An
ambiguous append failure must remain ambiguous and must not be retried into a
PASS. Cold verification must distinguish old-gate status from fact-maintenance
status.

**Rough size:** 4–7 engineer-days.

### 4. SP-3 — attested compiler materialization and conflict algebra

**Threat closed:** A caller-supplied verifier string can disguise different
compiler binaries, schemas, projections, or toolchains; PASS and FAIL facts
for one candidate can coexist with no deterministic answer; first-occurrence
claim lookup makes coverage order-dependent.

**Evidence:** Threat 2 of
`ADVERSARIAL-REVIEW-7-STORE-PHYSICS.md` proves immutable individual facts but
finds self-declared compiler identity, conflicting PASS/FAIL, and first-claim
lookup. The conflicting PASS/FAIL receipt is
`987f413a8e79f2879018a1b13d7fd2093a0634afc6a7d60966fc97d3b5c5a754`.
The `unsupported-entry` incident cited there demonstrates that compiler name
alone is insufficient. The cone receipt
`CONE-RECEIPT-SPIKE-FINDINGS.md` is partial semantic evidence, not compiler
attestation.

**Owning design:** Store-physics Gap 3; the report's
`VerifierMaterializationId`, artifact/schema admission, full-key claim index,
and explicit conflict algebra.

**Acceptance at the lowest deterministic layer:** A controlled fixture must
use two actual compiler materializations, two schema/decoder contracts, and
two policies. The reader must distinguish them by full semantic key, reject an
unsupported entry before observation/PASS, and return an explicit conflict or
inadmissible result for contradictory verdicts. No string alias or Store
occurrence order may change the answer.

**Rough size:** 5–8 engineer-days.

### Designed sub-gate — compiler materialization attestation

#### Invariant

For every fact that a consumer accepts as compiler-produced, an offline
consumer can recompute one exact tuple from the proof pack:

```text
(VerifierMaterializationId, CompilerEpochId, FactStoreSpaceId,
 InputSnapshotId, InputBranchRevisionId, InputClosureDigest, OutputDigest)
```

The tuple either matches an admitted compiler materialization manifest and the
exact input facts in the named snapshot, or the fact is inadmissible. A caller
supplied verifier string, a release name, or a Store occurrence position can
never make an unattested fact eligible for reuse.

#### Mechanism

The admitted compiler identity is a canonical `CompilerMaterializationV1`:

```text
CompilerMaterializationV1
  materializationId              # hash of canonical fields below
  compilerEpochId
  executableDigest               # exact invoked compiler bytes
  compilerSourceCommit
  compilerSourceClosureDigest
  runtimeToolchainClosureDigest
  projectionId
  adapterVersion
  factSchemaId
  decoderSchemaId
  targetAbiProfile
  verifierPolicyId
  admissionKeyId
```

The manifest is admitted by the release or authority registry before any
fact-bearing result can use it. `materializationId` is derived from the exact
canonical manifest, not from a human-readable compiler alias. The manifest
binds the executable or native artifact, its source and runtime closure, the
projection and adapter, the fact and decoder schemas, the target profile, and
the policy that interpreted the result. A changed byte in any of those inputs
produces a different materialization ID.

Each compiler run emits a canonical `CompilerMaterializationReceiptV1`:

```text
CompilerMaterializationReceiptV1
  receiptId
  materializationId
  compilerEpochId
  factStoreSpaceId
  inputSnapshotId
  inputBranchRevisionId
  inputRefIdentity
  inputManifestId
  inputFactSetDigest
  requestDigest
  outputFactSetDigest
  outputFactIds
  outputBatchRevisionId
  receiptStatus                 # COMPLETE | INCOMPLETE | REJECTED
  launcherSignature
```

`inputFactSetDigest` and `outputFactSetDigest` are canonical sorted-set
digests. Large sets use bounded digest-chain chunks in the same style as
`EpochReattestationChunkV1`; no unbounded list is accepted as one Store term.
The compiler emits the request, output facts, and an unsigned draft receipt.
The materialization launcher records the executable bytes actually started,
checks that digest against the admitted manifest, binds the exact
`FactStoreSpaceId`, `inputSnapshotId`, and `inputBranchRevisionId`, and signs
the canonical receipt. This prevents a compiler process from making a mere
self-declaration stand in for the binary that ran. The trust anchor is the
admitted launcher or release key, not an environment variable.

The publication protocol is:

1. Open the named Store and snapshot cold at the exact branch revision. Refuse
   a mutable ref, a missing snapshot, a different compiler epoch, an unknown
   materialization, a withdrawn manifest, or a schema and policy mismatch.
2. Run the admitted executable with that immutable input manifest. The
   compiler records every input fact ID and produces output envelopes whose
   producer field names the materialization ID and compiler epoch.
3. The launcher verifies the draft receipt and signs it. A Store writer then
   publishes the output facts, receipt, membership links, and commit marker in
   one atomic batch against the expected Store revision.
4. An offline consumer reads only the proof pack and the named Store/Space. It
   verifies canonical envelope bytes and IDs, the launcher signature, the
   executable and closure digests, the snapshot and branch revision, input
   membership, output membership, schema and policy admission, epoch
   currentness, and the complete batch commit. It then recomputes the tuple
   above without invoking the compiler, contacting a service, or consulting a
   wall clock.

Failure is fail-closed for reuse. An absent or unreachable Store, an expired
queue admission, a stale branch revision, an unknown or withdrawn
materialization, a bad signature, a missing input, a digest mismatch, an
incomplete batch, or a torn or corrupt Store frame yields a typed
`MATERIALIZATION-INADMISSIBLE` or `MATERIALIZATION-INCOMPLETE` result. It
cannot yield an observation or PASS. A partial publication is ignored until
its complete batch and commit marker are present; the compiler does not
repair or truncate a Store as part of verification.

#### Future deterministic gate: SP-3-MATERIALIZATION-OFFLINE

At the lowest deterministic layer, a controlled fixture will admit two actual
compiler materializations, two projection or decoder contracts, two policies,
and two fact-store snapshots. It will verify that each receipt resolves only
against its exact executable, epoch, schema, policy, snapshot, input set, and
output set. It will substitute one executable byte, closure byte, epoch,
schema, input fact, output fact, signature, and branch revision at a time;
each substitution must reject before observation or PASS. A proof pack must
reproduce the same answer after the compiler process and network are absent.
This is a future gate and is not run by this design task.

#### Explicit deferrals

This design does not prove semantic correctness of an admitted compiler. Epoch
parity and the release seal must still establish when old semantic facts may
remain current. It does not provide TPM or hardware attestation, remote
worker identity, distributed key management, or cross-machine determinism;
those require separate authority rules. It also does not migrate the meaning
of existing V1 envelopes or prove physical per-unit native cache reuse, which
the cone findings leave open.

### Designed sub-gate — deterministic conflict handling

#### Invariant

For every conflict key, the cold reader result is a pure function of the set of
valid canonical fact contents and explicit withdrawal or supersession facts.
Permuting writer arrival, process scheduling, append revision, or Store
occurrence order cannot change the result. A fact ID collision or a
contradictory admitted verdict is never converted into PASS by first occurrence
or last writer.

#### Mechanism

The full semantic conflict key is:

```text
FactConflictKeyV1
  candidateRoot
  claimId
  verifierMaterializationId
  compilerEpochId
  policyId
  targetAbiProfile
  factSchemaId
```

The materialization and schema fields make the key stronger than the old
`(scope, label)` lookup. Distinct admitted compiler materializations receive
distinct views. A query that asks for an aggregate across materializations
must name an admitted policy for that aggregation; the default result for
more than one eligible materialization is `INADMISSIBLE`, not an arbitrary
winner.

Every writer recomputes `factId` from the exact canonical envelope bytes before
admission. For one fact ID:

- identical canonical bytes are one idempotent fact; the second writer returns
  `RETAINED-SAME-CONTENT`, regardless of arrival order;
- bytes whose recomputed hash is not the supplied fact ID are rejected as
  `FACT-ID-MISMATCH`, and the batch makes no partial publication;
- two distinct byte strings that both claim one valid fact ID produce a typed
  `FACT-ID-COLLISION` and leave the existing valid content unchanged. The
  resolver never chooses one by timing.

For a valid conflict key, the reader sorts canonical fact IDs and derives a
`ConflictSetDigest`. Resolution is then fixed:

```text
zero admitted decisions        -> MISSING
one distinct admitted decision -> that decision, such as PASS or FAIL
two or more decisions          -> CONFLICT
```

Different evidence for the same status is still `CONFLICT` unless it is
byte-identical. A `CONFLICT` result carries the sorted fact IDs, their status
and evidence digests, and the conflict-set digest. An explicit
`FactSupersessionV1` or withdrawal may remove a member only when it names the
exact prior conflict-set digest, the replacement fact, the same full key, and
an admitted reason and authority. The consumer verifies that content-addressed
statement before applying it. A late writer cannot silently supersede an
earlier fact, and a missing supersession leaves the conflict visible.

The writer may append both immutable conflicting facts for diagnosis, but no
candidate snapshot may publish an authoritative PASS while its conflict set is
`CONFLICT`, `INADMISSIBLE`, or `MISSING`. The derived conflict result is
recomputed from cold Store contents, so a conflict receipt is not made true by
the order in which a maintainer happened to observe the facts.

#### Future deterministic gate: SP-3-CONFLICT-ALGEBRA

At the lowest deterministic layer, a pure resolver fixture will feed one
fact, duplicate identical facts, PASS and FAIL facts, two same-status facts
with different evidence, two materialization IDs, a valid supersession, an
invalid supersession, and a same-ID different-content submission in every
permutation. It must produce the same `ConflictSetDigest` and result for every
permutation, deduplicate identical content, reject hash mismatches, preserve
both diagnostic facts for a real conflict, and never return PASS for an
unresolved set. A focused Store-adapter case will additionally prove that a
revision race returns typed conflict without changing the published route.
This is a future gate and is not run by this design task.

#### Explicit deferrals

This design defers operator and release governance for issuing a supersession
or withdrawal, including key rotation and revocation. Until that authority is
specified, unresolved sets remain `CONFLICT` or `INADMISSIBLE`. It does not
solve distributed Store replication, merge of two independent histories, or
cryptographic hash-collision recovery beyond rejecting the collision and
keeping the prior valid content. Those are separate availability and Store
authority concerns.

### 5. SP-4 — total miss accounting and unexplained-work rejection

**Threat closed:** A route, schema, dependency, policy, admission, or claim
mismatch can fall back without a durable miss; an observed phase with no
prepared claim can disappear while coverage says `FULL`.

**Evidence:** Threat 4 of
`ADVERSARIAL-REVIEW-7-STORE-PHYSICS.md` proves durable-before-fallback for
`route-unresolved`, `unknown-fact-kind`, `stale`, and `omitted-dependency`, and
the full run's 102 absent misses. Its silent unexplained-phase receipt is
`6bd23ebb32a686a1ee48f6ae8ec382388e3860482a505e61a9da68d4179882ac`; that
receipt observed `FULL` with no `unexplained-claim` event.

**Owning design:** Store-physics Gap 4; the report's exact observed-vs-planned
set comparison, seven miss classes, duplicate-observation rejection, and typed
error preservation.

**Acceptance at the lowest deterministic layer:** Given prepared claim keys
and observed phase/unit keys, a pure set-difference test must emit one durable
`unexplained-claim` miss for every extra observation, classify coverage
incomplete, and retain NOT-RUN/missing observations conservatively. A focused
Store-order test must show the miss frame before fallback and must preserve
lock, corruption, route, and durability error codes.

**Rough size:** 3–5 engineer-days.

### 6. SP-5 — shared-store fleet concurrency release case

**Threat closed:** Serial shadow parity can pass while simultaneous maintainers
against one Store lose most work, leave partial facts, or report a false zero
exit. Integrity alone is not availability or composition.

**Evidence:** Threat 5 of
`ADVERSARIAL-REVIEW-7-STORE-PHYSICS.md` reports two eight-worker barrier
campaigns: 2/8 fact completions for one identity and 1/8 for mixed identities,
despite 21/21 and 39/39 cold fact uniqueness and no torn frames. The campaign
status/integrity receipts are the same-identity pair
`f5a56c7b2556532d2bda63e8dfb2bb6fe065e812e72cc00e0c7893cdd423b902` /
`fa24892b74ec94c6c85b76320c0519b4b12c2678b24ebd58f2eaa852ae5eeefd` and the
mixed-identity pair
`881f96f820c5c4b0eb03459a548a14711d258c684f2415728e2da37b5b0e4da1` /
`435bafa2c04ac78d61eed4e2a26b79c4271bc16d8587ce08f0f4bada4aa91ee4`.

**Owning design:** Store-physics Gap 5; the permanent eight-maintainer shared
Store case specified in Threat 5, using SP-1 through SP-4.

**Acceptance at the lowest deterministic layer:** A supervised eight-worker
barrier test must have every accepted attempt finish or return a typed
revision conflict, within the declared queue/authority budgets. A cold audit
must account for every attempt, claim, miss, observation, link, verdict, and
receipt exactly once, with zero torn frames and no false-success wrapper
status. This is the only fleet-level gate here; all underlying frame and set
logic remains covered below it.

**Rough size:** 3–5 engineer-days after SP-1–SP-4; the release case itself is
not a substitute for those checks.

### Designed sub-gate — fleet availability and cold compilation fallback

#### Invariant

For every compiler invocation and every Store state in the declared failure
set, a Store failure cannot block compilation, alter the cold compiler input,
publish a partial fact, or produce a fact-backed PASS. The invocation returns
within a fixed Store probe deadline plus the ordinary cold compilation budget,
and its decision is byte and status equivalent to the same invocation with
fact reuse disabled. A healthy Store may enable a separately proven warm path;
an unavailable or uncertain Store always selects the cold path.

#### Mechanism

The compiler entry point treats Store access as an optional bounded read and
maintenance side channel. A `StoreAvailabilityReceiptV1` records the exact
route tuple and one of these modes:

```text
StoreAvailabilityReceiptV1
  receiptId
  factStoreSpaceId
  requestedSnapshotId
  requestedBranchRevisionId
  probeDeadlineClass
  mode                          # ONLINE | COLD | DEGRADED
  failureClass                  # NONE | UNREACHABLE | QUEUE-DEADLINE |
                                # CORRUPT | TORN-TAIL | PARTIAL-COMMIT |
                                # BUDGET | STALE-REVISION | DURABILITY-UNKNOWN
  fallbackMode                  # FACT-REUSE | COLD-COMPILATION
  maintenanceStatus             # PUBLISHED | DEFERRED | UNAVAILABLE
```

The protocol is:

1. The invocation asks a read-only Store adapter for the exact snapshot,
   branch revision, materialization, and policy. The adapter has a bounded
   probe deadline and never waits on the writer lock, a queue with no capacity,
   a network retry, or a Store repair operation.
2. If the exact route is readable and complete, the compiler may use only the
   attested facts returned by that route. If the path is absent, unreachable,
   permission denied, past its probe deadline, or missing its exact snapshot,
   the adapter returns `COLD` and the compiler immediately runs the ordinary
   source-driven compiler.
3. A degraded writer queue, free-space or byte budget breach, stale revision,
   unavailable materialization, or any typed Store authority error also returns
   `COLD`. No retry occurs inside the compiler invocation. A maintenance
   receipt may record `DEFERRED` or `UNAVAILABLE`, but it never claims that an
   uncommitted fact was accepted.
4. A torn tail, bad complete-frame checksum, incomplete transaction, or lost
   commit response makes the requested route `DEGRADED`. The compiler does not
   truncate, repair, or read through an uncertain route. The writer protocol
   exposes only complete CRC-checked transactions with a complete commit
   marker; a partial frame therefore cannot become a fact-backed observation.
5. If cold compilation succeeds while the Store is unavailable, the old gate
   result remains the authoritative compilation result and the maintenance
   status is separate. If compilation succeeds but fact publication fails, the
   output is not reclassified as a stored fact or PASS. An ambiguous durability
   result is recorded as `DURABILITY-UNKNOWN` and is not retried as success.
   Any later retry runs outside the compiler critical path from deterministic
   inputs and deduplicates by content ID.

There is no background Store recovery in the compiler process. Repair,
reopen, compaction, queue draining, and replication are separate bounded
maintenance operations. A Store outage therefore costs optional reuse and
fact recording, never the ability to compile from source.

#### Future deterministic gate: SP-5-COLD-FALLBACK-AVAILABILITY

At the lowest deterministic layer, a controlled adapter fixture will inject an
absent path, unreachable path, probe deadline, full writer queue, stale
revision, bad complete frame, torn tail, partial transaction, and ambiguous
commit response. For each case it will assert one bounded `COLD` transition,
one cold compiler call, no Store mutation by the compiler path, no fact-backed
PASS, and output equal to the Store-disabled baseline. A separate case will
prove that a complete healthy transaction is reusable and that a later
maintenance retry can publish only its exact content-addressed result. This is
a future gate and is not run by this design task.

#### Explicit deferrals

This design guarantees cold fallback, not Store uptime, replication, queue
capacity, or recovery time. It defers fleet-level capacity targets, active
replication, repair scheduling, retention and compaction, and the durability
policy for records whose append response is lost. The cold compiler itself
retains its existing correctness and performance gates. It also defers whether
an independently certified older snapshot may be used during a Store outage;
the default until that rule exists is cold compilation.

### 7. SP-6 — packed volume, accounting, and routine-loop budgets

**Threat closed:** Per-fact process startup, full replay, and `fsync`, repeated
whole-tree manifests, and unbounded append-only history can erase the speedup,
exhaust storage, or make authority unsafe.

**Evidence:** Threat 3 of
`ADVERSARIAL-REVIEW-7-STORE-PHYSICS.md` measured 534,429 bytes for 309 facts,
a 201,999-byte candidate envelope, 43.79 seconds for 102-miss preparation,
206 forced append transactions, and a lower-bound projection of 18.167 GiB per
year at 100 candidates/day. The full-run cold-integrity receipt is
`6c1ff61977b5f219379cc28cc4c889bf82947e9500daaae327178166a8ee9ea5` and the
102-miss preparation receipt is
`d60cc6d09c22eff753aa9bfb34b10656a3e56ab2334e3cc999507fb2c00cca25`.

**Owning design:** Store-physics Gap 6; the report's shared source manifests,
batched forces, byte/fact accounting, explicit budgets, and measured hot/archive
split.

**Acceptance at the lowest deterministic layer:** A representative packed
Store benchmark must emit bytes before/after, bytes by kind, logical facts,
replay/read bytes, transaction and `fsync` counts, append wall, peak RSS, and
authority-hold time. Preparation and cold query must meet predeclared routine
budgets at representative 1x/10x/100x sizes; a budget breach must fail closed
before append while retaining the old full-gate fallback.

**Rough size:** 5–8 engineer-days.

### 8. FACT-GC-V1 — rooted, re-derivable compaction and inventory

**Threat closed:** Rejected, abandoned, and dead-branch facts remain live
forever; a single FRAMLOG grows without inventory, free-space guard, root
semantics, compaction, archive, or rehydration.

**Evidence:** `ADVERSARIAL-REVIEW-7-RETENTION.md` is explicit that no gate-fact
inventory, eviction, compaction, orphan sweep, byte counter, or free-space
check exists. Its `store/tests/gate_facts_test.clj` receipt is 12/12 PASS, but
that proves only append/reopen and miss ordering. The report's passive
inventory receipt found 0 persistent bytes and therefore no honest production
growth sample. The store-physics report independently found the 18.167 GiB/year
lower bound above.

**Owning design:** Banked design
`FACT-GC-V1 ROOTED-RE-DERIVABLE-COMPACTION` in
`ADVERSARIAL-REVIEW-7-RETENTION.md`.

**Acceptance at the lowest deterministic layer:** Pure mark/partition tests
must classify live commit, pin, checkpoint, session, recent, dead, and
rejected roots; a fact may be deleted only when its exact producer and source
commit re-mint the same ID. Controlled compaction must cold-verify every live
root, preserve the old log on interruption, refuse stale-root/CAS replacement,
and report bytes, entries, roots, free space, retained/evicted facts, and
rehydration. Run the 1x/10x/100x query and authority-hold cases before deletion
is enabled.

**Rough size:** 5–8 engineer-days, plus the 14-run measurement window required
to publish the initial cadence (`g95`/`e95`).

### 9. EPOCH-1 — validity domains and a certified GENESIS snapshot

**Threat closed:** A compiler release can invalidate semantic facts while
structural facts remain current, or a reader can mistake an old payload ID for
current validity without an admitted derivation or attestation.

**Evidence:** `EPOCH-ROLL-DESIGN.md` explicitly says epoch roll is designed, not
implemented. It defines STRUCTURAL versus SEMANTIC currentness, immutable
validity bindings, bounded attestation chunks, and a GENESIS baseline. Its
source evidence includes the self-host and downstream parity artifacts named in
the design. The semantic-unit receipt
`CONE-RECEIPT-SPIKE-FINDINGS.md` proves body/signature invalidation behavior at
the compiler seam but is not an epoch receipt.

**Owning design:** `EPOCH-ROLL-DESIGN.md`, especially ER-2 and the
`CompilerEpochV1`/`FactValidityBindingV1` vocabulary.

**Acceptance at the lowest deterministic layer:** Cross-runtime vectors and
cold Store round trips must classify every current program fact exactly once as
STRUCTURAL or SEMANTIC, with audit/control exclusions explicit. An unchanged
source/compiler-epoch fixture retains all structural facts; a changed
structural extractor invalidates exactly its cone; every semantic currentness
answer names its derivation epoch or admitted re-attestation. The first
authoritative route must be a cold-derived GENESIS snapshot, not the current
shadow root.

**Rough size:** 5–8 engineer-days; no implementation estimate is stated in the
design, so this is a planning estimate rather than banked evidence.

### 10. EPOCH-2 — wholesale re-attestation, cold verification, and snapshot CAS

**Threat closed:** A release can silently reuse uncovered or stale semantic
facts, omit a fact from the parity proof, publish a partially prepared route,
or overwrite a newer certified root.

**Evidence:** `EPOCH-ROLL-DESIGN.md` defines the exact preconditions, total
eligibility partition, bounded digest-chain chunks, zero per-fact compiler runs
for covered facts, cold candidate verification, and expected-ref CAS. There is
no green implementation receipt today. The cone receipt proves the known
body-vs-signature semantic distinction; it also records that the native program
cache remains whole-program-keyed.

**Owning design:** `EPOCH-ROLL-DESIGN.md`, ER-1 through ER-4; re-attestation is
the banked design, not current capability.

**Acceptance at the lowest deterministic layer:** Pure chunk tests must reject
duplicates, overlap, reordering, omission, corrupt bodies, and withdrawals.
On an identical-compiler roll, cold verification must retain every structural
fact, re-attest every covered semantic fact with zero payload rewrites and zero
per-fact compiler runs, and account for every reachable fact once. A partial
coverage roll must emit misses and derive uncovered facts before publication.
Two publishers racing one expected ref must yield one publish and one visible
`CONFLICT`, with the stale route untouched; the body/interface corpus must
retain the caller on a body-only change and invalidate it on a signature change.

**Rough size:** 8–12 engineer-days; no green implementation receipt exists.

### 11. BLAST-RADIUS-7 — consume the pending review before authority

**Threat closed:** The pre-flip list could omit a dependency or cache boundary
found by the still-running blast-radius review.

**Evidence:** `ADVERSARIAL-REVIEW-7-BLAST-RADIUS.md` is still being written by
another worker and is therefore pending, not a completed authority receipt.
The known partial finding from `CONE-RECEIPT-SPIKE-FINDINGS.md` is: per-unit
semantic hashing and the body-vs-signature early cutoff are proven, while the
native program cache is still whole-program-keyed. The direct receipt says the
whole-program `program_closure_hash` changes for either unit edit, so physical
skip of the caller is not proven.

**Owning design:** Pending blast-radius report; its final findings must be
folded into the six SP gates and epoch/cone acceptance cases. No banked design
may be treated as closing this gate.

**Acceptance at the lowest deterministic layer:** After the report lands,
enumerate every new threat and map it to one numbered gate. The known native
cache seam must either pass a unit-cache/whole-program-assembly negative matrix
or remain conservative and always rebuild. No authority decision may rely on
the pending report's unknown conclusions.

**Rough size:** 0.5–1 engineer-day after the report lands; the report's own
remaining size is unknown.

### 12. FLIP — cold shadow parity, certified root publication, and dual receipt

**Threat closed:** The system can have individually valid facts while the
candidate snapshot is incomplete, the policy is not covered, or the published
root differs from what the cold verifier checked.

**Evidence:** The operating model's `R3` requires broad-gate parity over a
predeclared corpus, substitutions, omitted-dependency detection, and a cold
coverage receipt. The store-physics parity receipt is
`47ccae5860a2591b91b4a437a25661babe189ba5aecdbb5e37348ca9573622bc`; it
matched seven candidate decisions and four planted miss classes but did not
exercise shared-store concurrency. The full-run supervisor receipt is
`1d5ef80d30b82fe4ee0884074796e46ae9c03c2df018cf80950fdc023b0493f9`, and its
cold-integrity summary is
`6c1ff61977b5f219379cc28cc4c889bf82947e9500daaae327178166a8ee9ea5`.

**Owning design:** Operating-model `S8`/`R3` and `R6`, plus the epoch design's
candidate snapshot and short CAS. Flip is not authorized by the existing
shadow receipts; it is authorized only by a new receipt satisfying all prior
gates.

**Acceptance at the lowest deterministic layer:** A separate cold verifier,
given only the exact Store/Space, candidate root, source commit, GatePolicy,
parity/epoch receipts, and proof packs, must reproduce total claim coverage:
every required claim is an admitted PASS or an explicitly conservative
recheck, with no unexplained observation, unresolved conflict, unsupported
entry, missing dependency, stale identity, budget breach, or pending report.
The old full gate and fact maintainer decisions must match across the
predeclared no-op, whitespace, body, interface, test-only, toolchain, missing,
and negative-substitution corpus. Publication must be one short expected-ref
CAS, followed by cold reopen of the exact published root. The dual receipt must
show old-gate status and fact-maintenance status separately.

**Rough size:** 5–8 engineer-days after the prerequisite seams land.

## Release-cadence requirements for bootstrap continuity

These requirements are deliberately separate from the fact-store flip. They
gate Racket-removal and self-host stages, not the facts store's first
authority publication. They must nevertheless be release-cadence obligations
for any stage that removes or weakens the pinned Racket recovery route.

### B-1. Two independent recovery pins and current-HEAD canaries

**Gap closed:** Pin advancement is manual, no rule retains two known-working
recovery pins, and current seed checks do not prove that a retained pin can
compile today's HEAD.

**Evidence:** `ADVERSARIAL-REVIEW-7-BOOTSTRAP.md` Finding C lists all three
gaps. Its live drill receipt proves one current recovery path only: pinned
Racket compiled all 12 modules in 30.731 seconds; the pinned Babashka seed
emitted all 12; generation one and two matched at
`06548fbe3f0cf3a8d94fdb29e7332045551cb63affb606f6b5f7d8297bf12186`.
Finding A/B are PROVEN; continuity is REAL-OPEN-GAP.

**Acceptance:** Before each Racket-removal stage and before pin advancement,
retain two distinct immutable pins. A bounded canary must run each retained
pin's seed and pinned-Racket route against the exact current HEAD closed
self-host bundle, record pin object, commit, route, status, and elapsed time,
and refuse to advertise a failed pin as recovery.

**Rough size:** 3–5 engineer-days plus a canary on every main change.

### B-2. Pin advancement and recovery-payload release records

**Gap closed:** Pin sidecars declare consumers but do not constitute a recovery
registry; native stage0 is not present in the enumerated pins, so “the pin” does
not by itself imply a runnable native recovery binary.

**Evidence:** `ADVERSARIAL-REVIEW-7-BOOTSTRAP.md` Finding A enumerates the five
immutable pins and states that their useful payload is seed/Racket source, not
`self-host/native/beagle-selfhost`. Finding C says no pre-Racket-removal rule
requires a pin canary or recovery receipt.

**Acceptance:** The release record must name the two surviving pin object IDs,
their successful current-HEAD canary receipts, consumer sidecars, and the
supported payload (Babashka seed plus pinned Racket route, or a published
native stage0). A pin cannot be retired until the replacement and remaining
pin both pass the canary.

**Rough size:** 2–4 engineer-days.

### B-3. Discoverable incident recovery runbook

**Gap closed:** A broken current compiler cannot be recovered by an operator
who does not know how to select an immutable pin, compile a closed bundle,
remint the seed, use the Racket fallback, and preserve pin immutability.

**Evidence:** `ADVERSARIAL-REVIEW-7-BOOTSTRAP.md` provides an exact runbook but
Finding C says it is not discoverable from the self-hosting documentation.
The live drill's Racket-free path measured about 32 seconds for the 12-module
seed remint plus 21 seconds for generation two; the pinned Racket route was
about 31 seconds.

**Acceptance:** A clean detached recovery checkout must follow the linked
runbook using only a retained pin and current HEAD, pass the seed compiler
check and generation-two identity check, and never write the pin or shared main
checkout. The runbook must state the supported recovery payload and be linked
from the self-hosting summary before the stage advances.

**Rough size:** 1–2 engineer-days.

### B-4. Frozen v0.24.0 oracle pin and decaying authority

**Gap closed:** A Racket implementation can remain an accidental second
production authority, or a mutable/ambient copy can be mistaken for the final
reference.

**Owning design:** `beagle:beagle-test/conformance/authority/positioning/ORACLE-RETIREMENT-DESIGN.md`
sections “The last Racket compiler is a frozen reference oracle” and “Authority
decays and never backports”.

**Acceptance:** Record the exact v0.24.0 sealed commit as a clean detached
hash-named pin with a sidecar naming every real `consumer-main`, and record its
hermetic Nix oracle closure and materialization digest. The pin is authoritative
only for its sealed semantic surface, is silent on later semantics, and is not
backported or maintained. A release record that lacks the exact object ID,
sidecar consumers, or Nix closure fails.

**Status:** DESIGNED; future check not run.

### B-5. Implementation-independent conformance corpus authority

**Gap closed:** Seed/native/Racket agreement can preserve a common semantic
mistake without a living contract that is independent of all three.

**Owning design:** `beagle:beagle-test/conformance/authority/positioning/ORACLE-RETIREMENT-DESIGN.md`
section “Conformance corpus”.

**Acceptance:** A content-addressed corpus manifest must map every retirement
surface, ALARM-BELL divergence, and host-leakage gate to a `DECIDED` case with
an explicit rule and expected assertion. The manifest verifier rejects
implementation-observed-only cases, unresolved cases, and missing coverage.
Matching implementation output or an old parity label never satisfies this
gate.

**Status:** DESIGNED; future check not run.

### B-6. Recovery-host runtime closure

**Gap closed:** A retained seed or oracle pin may be unusable on a recovery host
because its JVM, Babashka runtime, Racket environment, or other external
runtime is merely assumed to exist.

**Owning design:** `beagle:beagle-test/conformance/authority/positioning/ORACLE-RETIREMENT-DESIGN.md`
section “Recovery-host runtimes”.

**Acceptance:** Each retained recovery pin and the frozen oracle must name a
hermetic Nix recovery profile and realized closure containing every supported
runtime. From a clean host with only Nix and the declared closure/pin inputs,
the profile must materialize, pass runtime probes, and run the bounded recovery
canary. Ambient runtime discovery or network access is not evidence.

**Status:** DESIGNED; future check not run.

### B-7. Full-surface current-HEAD recovery canary

**Gap closed:** The B-1 canary covers only the closed self-host bundle while
Core compilation, native linking, and the Wasm materializer remain outside its
scope.

**Owning design:** `beagle:beagle-test/conformance/authority/positioning/ORACLE-RETIREMENT-DESIGN.md`
section “Canary scope”.

**Acceptance:** For each of the two retained pins and each supported route, the
bounded current-HEAD canary must cover the closed self-host bundle, Core
compilation, native executable linking, and Wasm materialization. It records
canonical Core and Wasm identities plus a platform-qualified native link
manifest. A closed-bundle-only receipt cannot advertise a pin as full recovery.

**Status:** DESIGNED; future check not run.

### B-8. `HL-NUMBER-SEMANTICS` conformance gate

**Gap closed:** Numeric behavior can leak from the host's domains, rounding,
overflow, non-finite values, or printer.

**Acceptance:** The corpus must contain a decided numeric rule and boundary
vector for every admitted numeric domain and operation; the future check must
match the canonical result, named error, and serialization. Host defaults are
not acceptable evidence.

**Status:** DESIGNED; future check not run.

### B-9. `HL-EQUALITY-HASHING` conformance gate

**Gap closed:** Host identity or accidental structural equality can become
Beagle equality or an inconsistent collection hash.

**Acceptance:** A decided corpus case must cover equal/unequal atoms, symbols,
collections, and cross-domain lookalikes. The future check must prove the
decided equality relation, equal-values-have-equal-hashes invariant, and key
lookup behavior.

**Status:** DESIGNED; future check not run.

### B-10. `HL-SYMBOL-BEHAVIOR` conformance gate

**Gap closed:** Symbol qualification, interning, identity, or print/read
behavior can be inherited from the host namespace model.

**Acceptance:** A decided corpus case must cover repeated, qualified,
unqualified, and lookalike symbols plus canonical round-trip representation.
The future check must match the declared identity and error behavior without
using host interning as the specification.

**Status:** DESIGNED; future check not run.

### B-11. `HL-TRUTHINESS` conformance gate

**Gap closed:** Conditional behavior can inherit host truthiness for empty,
zero-like, null-like, or collection values.

**Acceptance:** A decided truth table and corpus case must classify every
admitted value category as true, false, or a typed error. The future check must
compare branch results to that table; omitted categories fail closed.

**Status:** DESIGNED; future check not run.

### B-12. `HL-COLLECTION-ORDERING` conformance gate

**Gap closed:** Host hash-table or set iteration order can become observable
semantics, hashes, or artifact bytes.

**Acceptance:** A decided corpus case must exercise insertion permutations and
declare ordered, canonicalized, or explicitly unordered behavior. The future
check must compare iteration/render/hash/artifact results to that declaration.

**Status:** DESIGNED; future check not run.

### B-13. `HL-NATIVE-CORE-GC-OWNERSHIP` conformance gate

**Gap closed:** Native Core ownership reasoning can accidentally depend on host
GC timing, finalization, weak references, addresses, or reachability.

**Acceptance:** A decided ownership rule must keep transient Native Core values
owned until promotion and forbid transient pointers in durable Store values.
The future controlled check must force collection and allocation pressure at
the promotion boundary and reproduce the same canonical promoted result.

**Status:** DESIGNED; future check not run.

### B-14. `HL-HOST-MACRO-EXPANSION` conformance gate

**Gap closed:** Racket macro expansion, phase inheritance, syntax metadata,
capture, generated names, or evaluation order can silently define Beagle.

**Acceptance:** A decided corpus case must cover lexical capture/shadowing,
generated names, and phase visibility. The future check must compare Beagle's
canonical expansion or named error, not accept host expansion merely because
it matches.

**Status:** DESIGNED; future check not run.

### B-15. `HL-UNSPECIFIED-BEHAVIOR-AS-SPEC` conformance gate

**Gap closed:** “Unspecified” behavior can become an undocumented contract
because implementations happen to agree today.

**Acceptance:** Every such point must be canonicalized, rejected with a named
error, or assigned a finite explicit allowed-outcome set. A future controlled
perturbation case must prove the canonical result, named error, or declared set
under two legal allocation/order seeds. “Matches current implementations” is
not a pass.

**Status:** DESIGNED; future check not run.

## Additional pre-flip authority gates from completed trace reports

These rows extend the numbered authority gates with findings from the completed
profile-key, invalidation, and divergence reports. Registration records the
requirement and its future check; it does not make any row PROVEN.

### TRACE-1 — profile identity in every authoritative key

**Threat closed:** A hosted and Native Core value with identical source bytes
or rendered content can collide in an authoritative cache, index, fact, receipt,
or materialization key when the source profile is carried only as an ambient
field or a transitively remembered property.

**Evidence:** `reports/PROFILE-KEY-TRACE.md` identifies the semantic-index
`rootHash` as an authoritative defect candidate: its hash domain contains only
sorted paths and file digests, and `build-semantic-index` publishes that root
without hashing the target field. The report also lists profile-blind CNF,
native stage/unit, reuse, materialization, receipt, and build-manifest identity
candidates. This is a verified flip blocker, not a claim that every listed
candidate has already collided.

**Owning design:** `SEMANTIC-CONTRACTS-DESIGN.md`, especially its
`ProfileIdentityV1` rule that profile identity participates in every
authoritative identity and receipt.

**Acceptance at the lowest deterministic layer:** An authoritative-key schema
manifest must enumerate every cache and index key admitted to the flip. Each
key must carry the canonical `ProfileIdentityV1` (or a profile-qualified
component whose canonical derivation is specified), and a controlled hosted/Core
collision fixture must produce distinct identities for identical source bytes,
paths, and output terms. A target-blind semantic-index root or any unlisted
authoritative key fails closed; profile identity may not be supplied only by a
consumer-side recheck.

**Future deterministic gate: PROFILE-KEY-COVERAGE-V1:** A pure manifest and
key-construction verifier will check the complete authoritative-key inventory,
substitute `core`, `clj`, `js`, and `nix` identities over the same payload, and
reject every missing or non-distinguishing profile component. This is a future
gate and is not run by this design task.

**Status:** OPEN; the semantic-index `rootHash` defect candidate and the other
profile-blind identity candidates have no green authority receipt.

### TRACE-2 — selective invalidation with contract and derivation receipts

**Threat closed:** A semantic-rule change can be treated as reusable because
source and unit digests remain unchanged, while a compiler-wide identity can
invalidate every native result even when only one semantic cone changed.

**Evidence:** `reports/INVALIDATION-TRACE.md` finds that a native `let`
evaluation-order change leaves source-unit semantic digests, read sets,
dependency-context digests, and hosted receipts unchanged, so unit reuse can
under-invalidate. The whole-program native manifest instead changes through
`beagle_identity`, so it over-invalidates. Current `main` has no
`FactMissEventV1` or shadow-fact lineage; selective semantic re-attestation is
only a caller discipline in the experimental unit path.

**Owning design:** `SEMANTIC-CONTRACTS-DESIGN.md`, whose contract fingerprints
identify language rules and whose immutable per-node `DerivationReceiptV1`
records the exact profile, contracts, dependencies, rule epoch, and result.

**Acceptance at the lowest deterministic layer:** Before any reuse verdict is
authoritative, every derived result must have a profile-qualified contract
fingerprint set and a complete per-node derivation receipt for every contract
and dependency read. A changed `let` contract with unchanged AST bytes must
invalidate the directly affected receipts and their transitive dependency cone;
no old unit result may be accepted without the changed contract fingerprint.
An implementation may retain a conservative whole-program miss, but it may
not present that over-invalidation as selective proof or let the unchanged
unit digests authorize reuse.

**Future deterministic gate: SEM-CONTRACT-SELECTIVE-INVALIDATION:** A
controlled fact-store fixture will change one node hash, one contract hash, one
dependency fact, the compiler implementation with contracts unchanged, and the
profile in turn. It must report the exact direct receipt set and transitive
cone, preserve reuse only when all receipt inputs are unchanged, and fail closed
on any missing contract or dependency read. This is a future gate and is not
run by this design task.

**Status:** DESIGNED; the contract-fingerprint and per-node-receipt design is
written, but no implementation or green invalidation receipt exists.

### TRACE-3 — divergence decision coverage

**Threat closed:** An authoritative form can ship while one or more of its
cross-profile semantic dimensions remain undecided and the implementation's
current behavior is mistaken for the language contract.

**Evidence:** `reports/DIVERGENCE-INVENTORY.md` inventories 414 shared rows and
marks unsupported dimensions with `?` across evaluation order, strictness,
allocation/representation, effects, identity/equality, and failure behavior.
Its completeness note explicitly says that a `?` remains an unknown and that
stdlib declarations are not operational proof.

**Owning design:** `ORACLE-RETIREMENT-DESIGN.md`, especially its
implementation-independent `BeagleConformanceCorpusV1`: cases are `DECIDED`
only when a rule and expected assertion are present, and implementation
observations never replace that decision.

**Acceptance at the lowest deterministic layer:** The 414-row inventory must
be joined to the admitted semantic-contract and conformance-corpus manifests.
For counting, a row with one or more `?` dimensions is closed only when every
such dimension has both a decided contract and a conformance case with an
explicit expected assertion. A row is not closed by matching current native,
seed, Racket, or hosted behavior. The flip remains barred while any
authoritative form maps to an unresolved `?` dimension.

**Future deterministic gate: DIVERGENCE-DECIDED-COVERAGE-V1:** A pure manifest
verifier will reject missing or duplicate row coverage, unresolved `?`
dimensions, `IMPLEMENTATION-OBSERVED` cases, and cases without decided rules
or expected assertions; it will pass only when every `?` dimension in the
414-row inventory has both required artifacts. This is a future gate and is
not run by this design task.

**Status:** OPEN; the inventory still contains undecided `?` dimensions and no
registration of this row changes that fact.

## Honest status

PROVEN today: individual fact IDs are immutable; framed Store append/reopen and
torn-tail detection work; four planted miss classes are durable before
fallback; cold shadow parity and cold queryability work for their tested
single-writer cases; the shared-store campaigns found no torn frames; a pinned
Racket compiler and pinned Babashka seed can recover today's 12-module
self-host bundle; and the cone spike proves per-unit semantic hashing with the
body-versus-signature early cutoff. DESIGNED but not green: the six store
physics repairs, including fleet availability, compiler materialization
attestation, and deterministic conflict resolution; rooted re-derivable
compaction, validity split and epoch re-attestation, certified GENESIS
publication, and the final cold flip gate.
OPEN: unexplained-work accounting, storage/retention budgets, the pending
blast-radius review, and bootstrap continuity; the native program cache remains
whole-program-keyed, so physical per-unit caller reuse is not proven.

ADV7-CONSOLIDATED-DONE — definitive pre-flip requirements document written; the facts store remains blocked from authority until its listed gates are green.
