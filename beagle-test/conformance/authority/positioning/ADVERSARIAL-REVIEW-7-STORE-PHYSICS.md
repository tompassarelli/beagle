# ADVERSARIAL REVIEW 7 — FACT STORE PHYSICS UNDER FLEET CONCURRENCY

## Scope and bottom line

This review audits Beagle commit
`7c7522fe69270df71675947b5d3541b9c0514deb`. The implementation is a sound
shadow verdict experiment, but it is not a fleet-concurrent fact service.

| Threat | Verdict | Deciding evidence |
| --- | --- | --- |
| Concurrent writes | **FAIL FOR FLEET CONCURRENCY** | Per-operation OS file locking prevents interleaved bytes, but lock acquisition is fail-fast and every small mutation is a new process, cold reopen, append, and `fsync`. Five of eight simultaneous maintainers failed before fallback in both live campaigns. |
| Conflicting facts and compiler trust | **FAIL FOR AUTHORITY** | Immutable content IDs prevent one fact ID from changing, but conflicting verdict facts coexist under one candidate root. The verifier identity is an operator-supplied string, not an attested compiler materialization. |
| Growth and I/O | **FAIL OPERATIONS BUDGET** | One real 102-claim shadow attempt grew an empty Store by 534,429 bytes. At 100 new candidates/day that is 50.967 MiB/day and 18.167 GiB/year before retries, longer history, indexes, or proof bodies. No Store-byte accounting or retention is present in this seam. |
| Miss telemetry | **PARTIAL** | The four planted classes were durable before fallback. An extra observed phase was silently ignored: final coverage was `FULL`, no `unexplained-claim` event was written, and the phase had no stored observation. |
| Shared-store experiment | **INTEGRITY PASS; AVAILABILITY FAIL** | Every completed frame cold-reopened with unique fact IDs and links; no torn or lost durable transaction was observed. Progress was lost to fail-fast locks, partial attempts accumulated, finalization could fail while the wrapper still returned the old gate's zero exit, and mixed identities made coverage order-dependent. |

The current global gate `flock` normally hides these defects by serializing
whole maintainers. Shadow mode therefore proves decision parity only while
ordinary fleet concurrency is excluded (`beagle:bin/beagle-test-facts:8-17`).

## Threat 1 — concurrent writers can corrupt, lose, or stall one Store

### Threat restated

Many workers may derive facts independently and target one Store. The required
physics are: complete transactions or a recoverable torn tail, no interleaved
writers, bounded acquisition, no silently lost accepted write, and no
minutes-long global serialization around derivation.

### Evidence

The gate adapter does have a real cross-process lock. `with-writer!` acquires
authority for the canonical Store path before create/open and releases it after
the operation (`beagle:store/src/store/gate_facts.bclj:208-222`). The authority
path is `<canonical-log>.writer-authority.lock`, opened with
`FileChannel`, and `.tryLock` is used (`beagle:store/writer_authority.clj:30-63`).
Acquisition does not wait or retry: failure throws `writer-authority-held`
immediately (`beagle:store/writer_authority.clj:73-83`).

Store creation and Store append have different atomicity:

- Header creation writes and forces a tempfile, then installs it with
  `ATOMIC_MOVE` (`beagle:store/database.clj:388-420`).
- Normal commits do **not** rewrite-and-rename the Store. One transaction frame
  is appended directly to the canonical log, flushed, and forced
  (`beagle:store/database.clj:422-435`). The gate adapter batches all
  propositions supplied to one adapter call into that single Store transaction
  (`beagle:store/src/store/gate_facts.bclj:232-244`).
- A frame has length and CRC. An incomplete final length/payload is reported as
  a torn tail; a bad complete-frame CRC is corruption
  (`beagle:store/database.clj:283-323`). A passive cold open replays only complete
  frames and retains the torn-tail marker; only an authority-holding explicit
  repair may truncate it (`beagle:store/database.clj:492-517`). A later write
  refuses a known torn tail (`beagle:store/database.clj:1903-1906`).

Thus the guarantee is: **OS-file-lock serialization plus one forced append-only
transaction frame per adapter mutation, with torn-tail detection**. It is not a
database WAL, and ordinary appends are not rename-atomic.

The transaction boundary is too small for the maintainer. Preparation imports
candidate plus claims once, then invokes a fresh adapter process separately for
every miss (`beagle:beagle-lib/private/gate-fact-maintainer.rkt:587-625`).
Finishing likewise invokes one adapter process per observation
(`beagle:beagle-lib/private/gate-fact-maintainer.rkt:813-842`). Each invocation
spawns and waits for a new `bb` process (`beagle:beagle-lib/private/gate-fact-maintainer.rkt:91-117`),
cold-opens the full log under the writer lock, and returns a response that scans
all live propositions (`beagle:store/src/store/gate_facts.bclj:163-181`,
`:282-305`).

The wrapper deliberately returns the old gate's exit even when fact
finalization fails (`beagle:bin/beagle-test-facts:90-109`). This is correct for
shadow authority, but it makes process exit zero an invalid receipt for fact
maintenance under contention.

### Measurements

Two eight-worker campaigns started on one barrier, used the repository's
hermetic full control path, bypassed only the outer gate lock with the same
`BEAGLE_TEST_LOCKED=1` marker used by the parity driver
(`beagle:bin/test/gate-fact-maintainer/run.sh:184-206`), and shared one Store.
Every worker and supervisor ran at nice 19.

**Same declared verifier identity:** five workers failed during durable
preparation with `writer authority` errors. Three wrapper processes exited zero,
but one of those had failed fact finalization after the old gate passed. Only
two reached fact `FINISHED`. Losers returned in 3.17–4.65 seconds rather than
waiting. The resulting 22,593-byte Store cold-opened with exactly 21 unique
facts—candidate 1, claims 6, misses 6, observations 6, verdict 1, receipt 1—and
six unique fallback links. No accepted transaction was missing.

**Two alternating declared verifier identities:** five workers failed during
preparation. Three wrapper processes exited zero; two of them reported
finalization unavailable, while the only finalized attempt reported
`coverage=INCOMPLETE`. The 39,721-byte Store cold-opened with 39 unique facts,
including six claims, misses, and observations for each identity, 12 unique
fallback links, and one PASS verdict. No frame corruption or duplicate fact ID
was observed, but partial attempt state remained permanently live.

There was no Store-lock stall: acquisition failed immediately. The ordinary
entry point instead stalls earlier on the whole-gate `flock`; a live full-gate
attempt printed `waiting for concurrent gate to finish` before any Store write.
That serialization is the reason ordinary shadow runs do not exercise shared
Store concurrency.

### Verdict

**Integrity passes at the transaction-frame level; availability and composition
fail.** The implementation prevents interleaved byte writes and rejects torn
tails, but it does not provide bounded contention handling, attempt isolation,
or an atomic maintainer admission batch. It trades corruption for high failure
rates and permanent partial facts.

### Banked fix plan

1. Give one long-lived Store writer or bounded append broker ownership of the
   file. Queue concurrent candidate batches with visible deadlines and progress;
   do not spawn/cold-replay one runtime per fact.
2. Batch preparation as candidate + claims + all misses in one transaction.
   Batch completion as observations + fallback links + verdict + receipt in one
   compare-and-swap transaction.
3. Add a `MaintenanceAttemptId`. Partition misses, links, and receipt accounting
   by attempt so one failed worker cannot make another worker account for its
   partial history.
4. Commit against an expected Store revision. Retry a clean revision conflict
   outside the file lock; never retry an ambiguous durability failure into
   success.
5. Make the shadow wrapper report two statuses: authoritative old-gate decision
   and fact-maintenance decision. Exit compatibility may remain old-gate-based,
   but a machine-readable receipt must not call finalization failure success.

## Threat 2 — compiler identities and conflicting verdicts share one key

### Threat restated

Two workers may evaluate the same source candidate with different compiler
binaries, projections, schemas, or policies. A reader must not serve a PASS
merely because both workers used the same cache/candidate key, and it must have a
defined answer when PASS and FAIL attestations coexist.

### Evidence

The physical fact key is effectively `(candidate-root, fact-id)`: the Store
subject contains both (`beagle:store/src/store/gate_facts.bclj:121-127`). The
fact ID is SHA-256 of the complete canonical envelope
(`beagle:beagle-lib/private/gate-fact-envelope-v1.rkt:438-463`). The adapter
recomputes that hash and rejects mismatched content
(`beagle:store/src/store/gate_facts.bclj:102-119`); it also rejects two different
envelopes presented under one identical fact ID
(`beagle:store/src/store/gate_facts.bclj:246-261`). This makes individual facts
immutable.

It does **not** make a candidate have one verdict. `GateCandidateVerdictV1`
includes candidate root, admission/status, verifier, policy, and claim links
(`beagle:beagle-lib/private/gate-fact-envelope-v1.rkt:220-255`). Changing status
or verifier changes the content hash, so multiple verdict facts coexist under
the same candidate root. Cold query returns all of them; there is no last-write
winner (`beagle:store/src/store/gate_facts.bclj:282-305`).

The claimed compiler/verifier identity is not attested. The entry point takes
`BEAGLE_GATE_FACT_VERIFIER`, defaulting to the literal
`bin/beagle-test-v1` (`beagle:bin/beagle-test-facts:24-29`). Candidate identity
hashes the Git-tracked source selection, base/repository revisions, importer,
and profile, but no executing compiler binary, compiler projection, runtime, or
toolchain closure (`beagle:beagle-lib/private/gate-fact-maintainer.rkt:233-271`).
The string is copied into claim/verdict identity and the reader merely compares
it for equality (`beagle:beagle-lib/private/gate-fact-maintainer.rkt:307-325`,
`:426-434`, `:858-866`). Two different binaries can therefore declare the same
string and become indistinguishable.

Different declared identities have a second bug. Claim lookup is `findf` over
the first stored claim with the same `(scope,label)`, excluding verifier and
policy from the lookup key (`beagle:beagle-lib/private/gate-fact-maintainer.rkt:404-405`,
`:480-505`). If the earlier claim belongs to another verifier, the later exact
claim can exist but the reader classifies the request stale before reaching it.
Storage occurrence order, not a declared resolution algebra, selects the
comparison candidate.

### Measurements

After the mixed-identity campaign, a second attempt under declared verifier
`fixture-compiler-0-v1` recorded one FAIL while the existing
`fixture-compiler-1-v1` PASS remained. Cold query returned both under candidate
root `sha256:bb709652…`; both envelopes said `ADMITTED`. The Store held 53
unique facts. The PASS identity's earlier finish had nevertheless returned
`coverage=INCOMPLETE` because the first `(scope,label)` claim belonged to the
other verifier. The reader is therefore neither last-write-wins nor a clean
per-compiler view: raw readers see both, while coverage can become
order-dependent `INCOMPLETE`.

The recorded Fram artifact build correctly bypassed its result cache as
`untrusted-compiler` because the compiler was not attested
(`todo:code-as-facts.md:40-45`). The first-cut fact Store would not make that
decision: it accepts an arbitrary verifier string and never challenges the
compiler materialization.

The game cutover is an even stronger counterexample. The clean pinned compiler
rejected shared result-cache key `4d0ee58f…` as `unsupported-entry` despite
byte-identical native inputs (`todo:greywrought-native-only-cutover.md:70-80`).
Later forensics found that the cache manifest itself named the same pinned
compiler commit and matching source digest; the evidence did **not** establish
a cross-version writer (`todo:greywrought-native-only-cutover.md:83-96`). Thus
compiler identity alone is insufficient: entry format/schema, materializer
projection, decoder contract, and artifact closure also require admission.

Current shadow execution would not itself serve the bad result because it never
skips the old gate (`beagle:bin/beagle-test-facts:73-94`). But if its stored PASS
logic were made authoritative unchanged, it would not prevent the
`unsupported-entry` class. The attestation path checks a caller-supplied name,
not the compiler and artifact contract that actually consumed the entry.

### Verdict

**Fact immutability passes; attestation and conflict resolution fail.** A hash
prevents mutation of one fact, not contradictory facts about one candidate.

### Banked fix plan

1. Derive `VerifierMaterializationId` from the exact executable/projection,
   compiler commit and source digest, runtime/toolchain closure, adapter, and
   verifier policy. Admission must challenge those bytes; environment text is
   not evidence.
2. Bind artifact format version, decoder/schema ID, target/ABI profile, and
   materialization derivation. Reject an unsupported entry before it can become
   an observation or PASS.
3. Index claims by the full semantic key `(candidate-root, claim-id,
   verifier-materialization-id, policy-id)`. Remove first-occurrence lookup by
   `(scope,label)`.
4. Specify conflict algebra. Distinct admitted verifier identities receive
   distinct coverage views. PASS and FAIL under one full admission key produce
   an explicit conflict/inadmissible result until withdrawn or superseded; no
   occurrence order or last writer decides.
5. Add negative tests using two actual compiler artifacts, not two strings, plus
   the `unsupported-entry` schema substitution that today's incident exposed.

## Threat 3 — append-only growth and I/O erase the speedup

### Threat restated

A fact-maintained gate can become slower than the work it remembers if every
miss incurs process startup, full replay, and `fsync`, or if candidate manifests
and observations grow without size budgets and retention.

### Evidence

The write amplification follows directly from the maintained call graph:
preparation loops over misses and invokes the adapter once per miss
(`beagle:beagle-lib/private/gate-fact-maintainer.rkt:618-631`); finish loops
over claims and invokes it once per observation
(`beagle:beagle-lib/private/gate-fact-maintainer.rkt:813-842`); every resulting
commit appends, flushes, and forces one frame (`beagle:store/database.clj:422-435`).

### Measurements

The real `bin/beagle-test-facts --active-only` path ran at nice 19 against an
empty Store on the exact audit commit. An unrelated production gate held the
ordinary global lock, so this size experiment used an isolated `TMPDIR`. Its
wall time is contention-affected and is not a performance verdict. The
consumer-smoke phase hit its unchanged 100-second bound; finalization still
accounted for the complete predeclared 102-claim set as 3 PASS, 1 INFRA-ERROR,
and 98 NOT-RUN observations.

Cold integrity after finalization:

| Measure | Observed |
| --- | ---: |
| Store delta from absent | **534,429 bytes** (536,576 allocated bytes) |
| Unique facts | **309/309** |
| Candidate / claim / miss / observation / verdict / receipt | **1 / 102 / 102 / 102 / 1 / 1** |
| Unique fallback links | **102/102** |
| Selected tracked files / selected bytes | **1,621 / 16,911,565** |
| Candidate envelope alone | **201,999 bytes** |
| Contention-affected full wall / peak RSS | **4:36.19 / 1,325,700 KiB** |
| Warm-page-cache cold-process Store query | **0.61 s / 164,788 KiB peak RSS** |

At one new candidate per run, 100 commits/day projects to **53,442,900
bytes/day = 50.967 MiB/day**, or **19,506,658,500 bytes/year = 18.167
GiB/year**. This is a lower bound: it excludes retries, repeat shadow attempts,
future per-test facts, indexes/projections, native proof bodies, and archive
overhead.

A focused preparation benchmark reused the real 102-claim plan on a fresh
Store. It wrote candidate + claims + 102 absent misses, producing 375,855 bytes
in **43.79 seconds** with 172,240 KiB peak RSS. The code performs one import
transaction plus 102 individually spawned/reopened/forced miss transactions,
so the effective cost was about **425 ms per durable operation**. That number
includes candidate hashing, process launch, replay, response materialization,
and `fsync`; it is not claimed as raw device latency. Finish adds 102 more
per-observation transactions and one finalization transaction: **206 forced
append transactions** for the measured first run.

### Size-accounting gap

The adapter computes only appended/retained entry counts
(`beagle:store/src/store/gate_facts.bclj:59`, `:246-271`), and its call sites
discard even those counts (`beagle:store/src/store/gate_facts.bclj:307-324`,
`:459-461`). The durable maintenance receipt records status/miss counts and
retained/rechecked/missed counts, but no Store bytes before/after, bytes by kind,
append wall, `fsync` count, or retention root
(`beagle:beagle-lib/private/gate-fact-envelope-v1.rkt:297-347`). No gate-fact
path invokes retention, compaction, archive, or GC.

### Verdict

**Unbounded and operationally expensive.** The Store is small for one run but
already repeats a 202 KB whole-tree manifest per candidate, and first-miss
preparation alone consumes 43.79 seconds for 102 misses. This misses the stated
R6 operations question even before claim-level expansion.

### Banked fix plan

1. Persist source manifests and unchanged subtrees as content-addressed shared
   facts; a candidate references their IDs instead of embedding 1,621 path/size/
   hash rows again.
2. Pack one candidate's claims/misses/observations into transactional batches.
   One force per admitted batch, not one force and runtime startup per fact.
3. Add receipt fields for logical facts and physical bytes before/after, bytes
   by kind, replay/read bytes, transaction count, append wall, peak RSS, and
   authority-hold time.
4. Declare online roots, retry/diagnostic retention, proof-pack archive, and
   expiry/withdrawal policy before authority. Run retention and rehydration at
   the measured 100-commit/day shape.
5. Predeclare budgets. A first practical gate is preparation below the routine
   loop budget with one bounded writer queue, cold query below its consumer
   budget, and annual hot storage bounded independently of archive storage.

## Threat 4 — every miss must be durable; none may disappear as empty work

### Threat restated

Every route, schema, dependency, policy, admission, and claim mismatch must
become a durable `FactMissEventV1` before conservative fallback. A phase that
runs but has no predeclared claim is also a miss; ignoring it can make coverage
look complete.

### Evidence

The implemented positive path is strong:

- Coverage explicitly classifies unknown kind, stale policy/claim, omitted
  dependency, absent fact, and inadmissible observation
  (`beagle:beagle-lib/private/gate-fact-maintainer.rkt:436-521`).
- A failed cold route is converted into one `route-unresolved` plan per claim
  (`beagle:beagle-lib/private/gate-fact-maintainer.rkt:523-534`).
- The miss envelope includes query, candidate/observed roots, class, observed
  identities, verifier, policy, fallback, claim, and planned observation
  (`beagle:beagle-lib/private/gate-fact-envelope-v1.rkt:257-295`).
- Preparation waits for each Store append before returning
  (`beagle:beagle-lib/private/gate-fact-maintainer.rkt:618-631`), and only then
  does the wrapper start the old gate (`beagle:bin/beagle-test-facts:73-94`).
- Observation admission requires the prior durable miss and commits the
  observation plus fallback link in one frame
  (`beagle:store/src/store/gate_facts.bclj:326-379`). Finalization refuses any
  durable miss not represented by an exact durable fallback link
  (`beagle:store/src/store/gate_facts.bclj:416-461`).

### Measurements

The repository's full parity driver ran at nice 19 in 73.74 seconds. All seven
candidate decisions and claim/unit counts matched after cold reopen. The four
planted substitutions each reported `DURABLE-BEFORE-FALLBACK`:
`route-unresolved`, `unknown-fact-kind`, `stale`, and
`omitted-dependency` (`beagle:bin/test/gate-fact-maintainer/run.sh:304-332`,
`:396-411`). The real full run also durably emitted 102 `absent` misses.

The silent path is **unexplained phase observations**. The vocabulary declares
`unexplained-claim` (`beagle:beagle-lib/private/gate-fact-envelope-v1.rkt:25-32`),
but the coverage classifier never emits it
(`beagle:beagle-lib/private/gate-fact-maintainer.rkt:483-507`). Finalization
loads every phase observation into a table, then iterates only the prepared
claims; it never checks for keys left over in that table
(`beagle:beagle-lib/private/gate-fact-maintainer.rkt:749-771`, `:787-850`).

A live plant added one valid successful
`phase-unexplained.observation` after preparation. Finish returned status zero
and `coverage=FULL`. Cold query contained six expected observations, zero stored
observations for the planted phase, and only the six original `absent` misses;
there was no `unexplained-claim` event. This is a fact recomputation/observation
that disappears without telemetry.

One smaller diagnostic defect appeared under contention: writer authority
throws its code in `:code` (`beagle:store/writer_authority.clj:73-83`), while the
adapter's error serializer checks only `:fram/code` and `:type`, so all live lock
failures were reported as `unclassified`
(`beagle:store/src/store/gate_facts.bclj:561-577`).

### Verdict

**The four planted miss classes pass, but “every miss” fails.** The
miss-before-fallback ordering is real. Set equality between planned claims and
observed work is missing, and one defined class is dead vocabulary.

### Banked fix plan

1. Before constructing verdicts, compare the exact observed phase/unit label set
   with the prepared claim set. Persist `unexplained-claim` for every extra and
   mark coverage incomplete; missing observations remain NOT-RUN/inadmissible.
2. Add live negative cases for all seven V1 classes: absent, stale,
   unknown-kind, inadmissible, route-unresolved, omitted-dependency, and
   unexplained-claim. Assert Store order before fallback/coverage output.
3. Reject duplicate semantic observation IDs with different content unless a
   new attempt ID explicitly distinguishes them.
4. Preserve adapter error codes by reading `:code`; classify lock contention,
   route failure, corrupt frame, and durability ambiguity distinctly.

## Threat 5 — shadow parity hides the fleet-concurrency failure

### Threat restated

Shadow parity can be perfect while the infrastructure still fails when many
workers maintain one Store. The decisive test is simultaneous end-to-end
maintainers, followed by a cold integrity and accounting audit—not two serial
reads of one writer's result.

### Evidence

The ordinary entry point holds one global `flock` across preparation, old-gate
execution, and finalization (`beagle:bin/beagle-test-facts:8-17`). The shipped
parity driver explicitly sets `BEAGLE_TEST_LOCKED=1`, so its concurrent
candidates use separate Stores and do not test one shared Store
(`beagle:bin/test/gate-fact-maintainer/run.sh:184-206`, `:247-285`). At the Store
layer, every adapter call independently takes the fail-fast file lock
(`beagle:store/src/store/gate_facts.bclj:216-222`,
`beagle:store/writer_authority.clj:73-83`).

### Measurements

The two barrier campaigns supplied the missing shared-Store experiment:

| Campaign | Wrapper exits | Fact completion | Cold Store result |
| --- | --- | --- | --- |
| 8 workers, same declared identity | 3 zero / 5 status 2 | 2 finished; 1 zero-exit wrapper lost finalization | 21/21 unique facts, 6/6 links, `FULL`, 22,593 bytes |
| 8 workers, two declared identities | 3 zero / 5 status 2 | 1 finished `INCOMPLETE`; 2 zero-exit wrappers lost finalization | 39/39 unique facts, 12/12 links, 2 claim sets, one PASS, 39,721 bytes |

All 16 supervisors wrote subtree-reaped receipts. No supervisor timed out and no
cold open found a torn frame. The failure was not hidden lock waiting: Store
losers failed in seconds. The failures were lost maintainer progress, partial
facts, and a wrapper status that cannot distinguish old-gate PASS from fact
maintenance failure.

### Verdict

**The concurrency experiment fails the fleet acceptance criterion.** Transaction
integrity survived, but a shared Store admitted at most a minority of workers,
and even successful old-gate exits did not imply a complete fact receipt.

### Banked fix plan

Adopt the batched writer queue, attempt isolation, full-key claim index,
compare-and-swap finalization, and dual-status receipt specified in Threats 1
and 2. Keep one permanent release-gate case that starts at least eight
maintainers on one barrier, requires every accepted attempt to finish or return
a typed revision conflict, then cold-proves exact facts, links, verdicts,
attempt receipts, zero torn frames, and bounded lock/queue wall.

## Run receipts

All experiment artifacts remain under
`/tmp/beagle-adv-physics.M5fd2I/`. The decisive receipt digests are:

| Receipt | SHA-256 |
| --- | --- |
| Seven candidates + four planted misses log | `47ccae5860a2591b91b4a437a25661babe189ba5aecdbb5e37348ca9573622bc` |
| Its supervisor receipt (`subtree-reaped-v0 exit status=0`) | `1186d2ec9815d2866dcab436bb1fb4e81466899a7e540750496fea2b8f850a3e` |
| Real full shadow log | `b6c42faf95406f09549b23759f72ee1c2c6f1c0b5e495f4faf6be1685a9982ce` |
| Real full supervisor receipt (`subtree-reaped-v0 exit status=1`) | `1d5ef80d30b82fe4ee0884074796e46ae9c03c2df018cf80950fdc023b0493f9` |
| Real full cold-integrity summary | `6c1ff61977b5f219379cc28cc4c889bf82947e9500daaae327178166a8ee9ea5` |
| 102-miss preparation log | `d60cc6d09c22eff753aa9bfb34b10656a3e56ab2334e3cc999507fb2c00cca25` |
| Same-identity status / integrity summaries | `f5a56c7b2556532d2bda63e8dfb2bb6fe065e812e72cc00e0c7893cdd423b902` / `fa24892b74ec94c6c85b76320c0519b4b12c2678b24ebd58f2eaa852ae5eeefd` |
| Mixed-identity status / integrity summaries | `881f96f820c5c4b0eb03459a548a14711d258c684f2415728e2da37b5b0e4da1` / `435bafa2c04ac78d61eed4e2a26b79c4271bc16d8587ce08f0f4bada4aa91ee4` |
| Silent unexplained-phase summary | `6bd23ebb32a686a1ee48f6ae8ec382388e3860482a505e61a9da68d4179882ac` |
| Conflicting PASS/FAIL summary | `987f413a8e79f2879018a1b13d7fd2093a0634afc6a7d60966fc97d3b5c5a754` |

## Final ruling

Keep this implementation shadow-only. It has useful immutable envelopes,
durable miss-before-fallback ordering for known classes, framed crash recovery,
and cold queryability. It does not yet satisfy the operating model's R6 store
operations budget: the global gate lock masks concurrency, the Store lock fails
instead of composing writers, compiler trust is self-declared, conflicting
verdicts have no stable resolution law, whole-tree manifests and per-fact
`fsync` grow linearly, and unexplained observed work can disappear while
coverage says `FULL`.

FACTS-ADV-B-DONE
