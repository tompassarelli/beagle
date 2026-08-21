# Adversarial review 7 — fact-store retention

## Verdict: REAL OPEN — the gate fact store has no retention machinery

The operator challenge is valid for the shipped v0.24.0 substrate. The first
cut mints immutable, content-addressed gate envelopes and appends them to a
FRAMLOG, but it does not yet maintain a certified root set, measure its own
size, compact history, or reclaim facts. A generic branch-segment collector
exists in the same Store database, but the gate-fact route does not use that
format or call that collector.

The first cut is shadow-only. It is therefore not yet a correctness failure to
retain a rejected candidate, but it is a real operations failure if this route
becomes the normal fact maintainer without the retention seam.

## Scope and evidence state

This audit reads the facts-first-cut revision
`7c7522fe69270df71675947b5d3541b9c0514deb` in the detached read-only checkout
`~/code/beagle/worktrees/adv-retention`. The relevant implementation is:

- `beagle:store/src/store/gate_facts.bclj` — gate-fact adapter and FRAMLOG
  routing;
- `beagle:store/database.clj` — FRAMLOG encoding, replay, and the separate
  branch-segment retention collector;
- `beagle:store/src/store/store.bgl` — in-memory TermStore and query/index
  behavior;
- `beagle:beagle-lib/private/gate-fact-envelope-v1.rkt` and
  `beagle:beagle-lib/private/gate-fact-maintainer.rkt` — envelope identity,
  candidate roots, and shadow coverage;
- `beagle:bin/beagle-test-facts` and
  `beagle:bin/test/gate-fact-maintainer/run.sh` — actual route lifetime; and
- `greywrought:tools/content-addressed-store.mjs` — contrast CAS.

The existing relevant Store check was run once at `nice 19`:

```text
store/tests/gate_facts_test.clj: 12 / 12 PASS
```

That check proves durable append/reopen and miss ordering. It does not prove
retention, inventory, or a size budget.

## Finding 1 — eviction, compaction, orphan sweep, accounting, and free space

### Gate-fact route: none exists today

The gate adapter declares only six immutable envelope kinds and an
`AppendCounts` record containing `appended` and `retained` counts
(`beagle:store/src/store/gate_facts.bclj:39-60`). Its route creates or opens one
FRAMLOG (`beagle:store/src/store/gate_facts.bclj:208-230`), appends assertion
propositions (`beagle:store/src/store/gate_facts.bclj:232-271`), and exposes only
`import`, `record-miss`, `record-observation`, `finalize`, and `cold-query`
commands (`beagle:store/src/store/gate_facts.bclj:519-559`). There is no
inventory, eviction, compaction, orphan sweep, store-byte counter, or free-space
check in that route.

The underlying FRAMLOG writer confirms the omission. It appends frames and
forces the file (`beagle:store/database.clj:422-435`); it does not inspect
filesystem free bytes or impose a fact-count/byte quota. The source candidate
does carry a selected-source `file-count` and `byte-total`, but those describe
the input revision, not the fact store (`beagle:beagle-lib/private/gate-fact-maintainer.rkt:251-280`).

### A separate generic collector exists, but is not the answer

The Store database has real retention machinery for a different allocation
format. It defines branch-head, pin, checkpoint, and session roots
(`beagle:store/database.clj:1252-1298`), enumerates those root documents
(`beagle:store/database.clj:1300-1330`), verifies their referenced segments,
and deletes unreferenced 64-hex segment objects
(`beagle:store/database.clj:1332-1371`). That collector operates on sealed
branch segment objects and their `.roots` documents. The gate-fact adapter
creates a single ordinary FRAMLOG and never calls
`retain-branch-root!`, `release-branch-root!`, or
`collect-unreachable-segments!`. Applying the branch collector to the gate
FRAMLOG would therefore be a format error, not a hidden existing solution.

## Finding 2 — what anchors liveness

### The current key has a candidate grouping, not a live root set

The adapter's `FactRoute` contains a path, base commit, candidate-root string,
and derived SpaceId (`beagle:store/src/store/gate_facts.bclj:52-53`). Each
stored proposition is keyed structurally as:

```text
("store.gate-facts/subject-v1", candidate-root, fact-id)
```

(`beagle:store/src/store/gate_facts.bclj:121-127`). Reads filter live
propositions by that candidate-root (`beagle:store/src/store/gate_facts.bclj:163-181`).
This distinguishes facts belonging to candidate A from facts belonging to
candidate B. It does not distinguish a live candidate from a dead branch,
rejected candidate, or abandoned experiment. Any caller that still knows a
candidate-root can query it.

`route` rejects the published names `main` and `refs/heads/main`, requiring an
immutable-looking experimental candidate name
(`beagle:store/src/store/gate_facts.bclj:83-100`). That is a routing safeguard,
not a root-set protocol. There is no durable commit-to-current-fact-root
pointer, no release/pin/checkpoint document for gate candidates, and no
operation that releases a candidate root.

The envelope contains useful re-derivation inputs: the candidate and its base
commit, repository revision, importer, profile, selected source files, and
source byte total (`beagle:beagle-lib/private/gate-fact-envelope-v1.rkt:101-142`).
The candidate identity is content-addressed by canonical envelope bytes
(`beagle:beagle-lib/private/gate-fact-envelope-v1.rkt:442-453`). Those facts
make re-derivation possible in principle; they do not make the candidate live.

### Append-only occurrence history makes dead facts durable

Imports assert new propositions and do not retract prior candidate facts
(`beagle:store/src/store/gate_facts.bclj:232-271`, `307-324`). The Store's
`live-propositions` view only means “asserted and not later withdrawn.” Its
liveness algorithm scans operation history and checks whether each assertion
remains active (`beagle:store/src/store/store.bgl:931-971`). Since the gate
adapter never withdraws old candidate propositions, a rejected or abandoned
candidate remains live in that narrow Store sense forever.

The first-cut receipt links claims to observations and miss events, not to a
general derivation graph (`beagle:beagle-lib/private/gate-fact-envelope-v1.rkt:297-347`).
Consequently, no current key or envelope can answer “which live commit keeps
this fact?” without an external convention. The liveness anchor required by
the operating model is absent.

## Finding 3 — passive measurement on this box

### Current persistent store

At `2026-08-18T08:58:17+08:00`, a `nice 19` inventory probe checked the default
gate-fact path in `~/code/beagle/main`, the facts-first-cut lane, and this audit
lane. It found:

| Measure | Observation |
| --- | ---: |
| Persistent gate-fact FRAMLOG files | **0** |
| Persistent gate-fact bytes | **0 B present; default path absent** |
| Persistent gate-fact entries | **0 present** |
| Per-gate-run growth observable from existing runs | **No** |

This is not evidence that a production store would grow at zero bytes. It is
evidence that no production gate-fact store is currently persisted on this
machine, so a current-store latency or growth rate cannot honestly be reported.

### Why existing runs leave no passive growth sample

The parity driver creates `facts_root="$scratch/facts"`
(`beagle:bin/test/gate-fact-maintainer/run.sh:247-248`) and assigns one
FRAMLOG per candidate (`beagle:bin/test/gate-fact-maintainer/run.sh:250-285`).
It launches seven candidate workers and four miss substitutions
(`beagle:bin/test/gate-fact-maintainer/run.sh:387-408`). On success, its exit
cleanup removes the complete scratch directory
(`beagle:bin/test/gate-fact-maintainer/run.sh:17-35`). The persistent default
would be `repo/.beagle/gate-facts-shadow.framlog`
(`beagle:bin/beagle-test-facts:19-29`), but that file is absent in all three
checked Beagle trees.

The driver and current first cut emit no before/after store bytes, entry count,
or candidate-root count. Therefore “growth per gate run” is **not measured by
the existing runs**. The only defensible result is an instrumentation gap, not
a guessed bytes-per-commit number.

## Finding 4 — query cost and scaling

### Cold path: full-file read, full replay, full live scan

`cold-query!` opens the requested FRAMLOG and then calls `facts-for`
(`beagle:store/src/store/gate_facts.bclj:463-475`). Opening a database reads the
entire file into memory (`beagle:store/database.clj:338-348`), decodes every
frame, creates a new TermStore, and replays every frame
(`beagle:store/database.clj:492-517`). `facts-for` obtains all live
propositions and filters them by candidate root
(`beagle:store/src/store/gate_facts.bclj:163-181`). The implementation has no
on-disk fact index or random-access fact lookup.

The TermStore does have an in-memory open-addressed slot index. Its width
doubles when the indexed row load exceeds four, and the old slot generations
remain resident (`beagle:store/src/store/store.bgl:29-66`, `95-114`). That
helps term interning during replay; it does not remove the full log read or the
full `live-propositions` scan used by the gate adapter.

### Warm path: no measured or exposed warm gate query

The gate test deliberately runs each adapter invocation in a fresh Babashka
process (`beagle:store/tests/gate_facts_test.clj:1-2`, `45-64`). Its cold-reopen
assertion invokes a separate process and compares the reopened response
(`beagle:store/tests/gate_facts_test.clj:124-131`). The first-cut adapter has no
long-lived query service or warm-cache metric. At the measured current size of
zero, both cold and warm fact lookup latency are therefore **not applicable**;
there is no stored fact and no warm query to time. The 12/12 check above is a
correctness result, not a latency result.

### Growth curve

The relevant curve is not directory fan-out. Gate facts are appended to one
FRAMLOG, so the number of directory entries stays effectively constant. The
cost curve is:

- cold open: approximately linear in log bytes to read/decode, plus linear in
  transaction/operation count to replay;
- candidate query after open: linear in operation count because
  `live-propositions` scans every operation (`beagle:store/src/store/store.bgl:958-971`);
- memory: grows with decoded atom/triple/transaction/operation vectors and
  slot tables; slot-table doubling adds logarithmic resize events but does not
  bound retained history.

Absent a compact index or packed snapshot, a tenfold store means roughly a
  tenfold cold-read/replay and live-scan workload. A hundredfold store means
  roughly a hundredfold workload and a corresponding risk of JVM allocation
  pressure. These are implementation-derived scaling consequences, not
  benchmark claims. A real benchmark is blocked until a persistent store exists
  and inventory can report its size.

## Contrast with Greywrought's content-addressed store

| Discipline | Greywrought CAS | v0.24 gate fact store |
| --- | --- | --- |
| Free-space guard | `minFreeBytes` is a configured default of 8 GiB and is checked against filesystem space before publication (`greywrought:tools/content-addressed-store.mjs:100-120`, `2168-2188`, `2215-2232`). | **Absent.** FRAMLOG append/fsync has no free-space reserve (`beagle:store/database.clj:422-435`). |
| Directory fan-out guard | `maxDirectoryEntries` defaults to 4,096; scan and publication capacity both enforce it (`greywrought:tools/content-addressed-store.mjs:113-120`, `1853-1894`, `1903-1931`). | **Absent.** The gate route uses one log file and has no directory inventory or entry limit. |
| Size/object accounting | `inventorySummary` reports object, quarantine, temporary counts and bytes, totals, and quota status (`greywrought:tools/content-addressed-store.mjs:1814-1850`). | **Absent.** `AppendCounts` reports only appended/retained logical entries, not bytes (`beagle:store/src/store/gate_facts.bclj:55-60`). |
| Inventory API | `inventory()` recovers temporary files, scans, and returns the summary (`greywrought:tools/content-addressed-store.mjs:3384-3392`). | **Absent.** The dispatch surface has no inventory command (`beagle:store/src/store/gate_facts.bclj:519-559`). |
| Rooted collection | `planCollection` accepts FRAM, backup, and active-pin references, applies grace/quarantine ages, and returns quarantine/sweep/orphan-temp plans (`greywrought:tools/content-addressed-store.mjs:3394-3536`). | **Absent.** Candidate-root grouping is not a live root set and no gate-fact sweep exists. |

The game CAS has the operational disciplines the fact store lacks. Its
directory guards are not directly needed by a single-file FRAMLOG, but its
free-space reserve, inventory, object quotas, rooted collection plan, and grace
period are exactly the missing class of store operations.

## Banked design — `FACT-GC-V1 ROOTED-RE-DERIVABLE-COMPACTION`

This is a design bank, not a landed capability.

### 1. Establish explicit roots

Add one durable root manifest for the fact route, grounded in the existing
candidate grouping:

```text
FactRootV1
  root-id
  git-repository
  git-commit
  fact-candidate-root
  root-kind = LIVE-COMMIT | PIN | CHECKPOINT | SESSION | RECENT
  created-at / expires-at
  maintenance-policy
```

The live root set is the union of:

1. current published commits/branch heads mapped to their certified
   `FactCandidateV1` roots;
2. explicit pins, checkpoints, and active sessions; and
3. a recency window containing the last seven days or the last 100 candidate
   roots, whichever is larger, including rejected candidates.

The recency window is a warmth policy, not a correctness authority. A root
outside it is collectible only if its facts pass the re-derivability rule below.
The exact window remains a policy input and must be recorded in each
maintenance receipt.

The existing `subject-v1` key lets a collector enumerate all facts for one
candidate-root, but it cannot discover live Git roots. Therefore the root
manifest is mandatory before enabling deletion. Do not infer liveness from
filesystem modification time, a current row, or whether a process happens to
know a candidate-root.

### 2. Add the missing dependency/re-derivation manifest

The current receipt links claims to observations, but not every fact to all
inputs needed to rebuild it. Add a minimal `FactDerivationV1`/dependency
manifest containing:

- exact source commit and selected source-file digests;
- candidate-root and fact IDs produced;
- verifier, policy, importer, compiler/toolchain profile;
- predecessor fact IDs or the conservative whole-candidate input closure; and
- a deterministic producer command/version or an explicit “not re-derivable.”

A fact is collectible only when its producer, exact input commits, policy, and
required foreign inputs are available. If any input is missing or the producer
is not deterministic/replayable, retain the fact or archive it; never delete it
on age alone. This makes eviction a warmth loss only: correctness can rerun the
producer from the immutable commit and mint the same envelope ID.

### 3. Mark and sweep outside the hot write path

Each maintenance run should:

1. snapshot the root manifest and current FRAMLOG revision under the writer
   authority;
2. mark all fact IDs grouped under live roots, then follow explicit
   derivation/dependency edges and the recency roots;
3. classify unmarked facts as `re-derivable`, `archive-only`, or `unsafe`; and
4. compact only `re-derivable` facts that are outside the recency window.

The current single-file format cannot delete individual frames. Compaction
must therefore write a new temporary FRAMLOG containing the retained fact
propositions, fsync and cold-reopen it, verify every live root and envelope ID,
then atomically publish it only if the original log revision is unchanged.
Acquire the writer lock for the final compare-and-swap, not for the expensive
mark/replay phase. If the root or log revision moved, discard the unpublished
compaction result and retry from a new snapshot. Preserve the current log until
the replacement is durably validated.

Every run emits a `RetentionReceiptV1` with root IDs, candidate roots, facts and
bytes scanned, facts retained/evicted, re-derivability decisions, compaction
bytes, elapsed time, and the compare-and-swap result. An interrupted run must
leave the old log valid and resumable.

### 4. Inventory and admission guards

Before the first production GC, add an inventory call that reports:

- FRAMLOG bytes and filesystem allocated bytes;
- total operation occurrences and live fact entries;
- candidate-root count, root age range, and dead/recent/re-derivable counts;
- bytes since the last compaction and last successful sweep; and
- current free bytes.

For this single-file format, the important guards are `maxLogBytes`,
`maxFactEntries`, and `minFreeBytes`; a directory-entry guard is not the right
primary bound. The guard must fail closed before append when a write would
cross the configured byte/fact/free-space budget, with the existing full-gate
fallback remaining available.

### 5. Cadence sizing from the evidence actually available

The measured current persistent growth rate is **not available** because the
box has no persistent gate-fact store and the successful parity runs delete
their scratch stores. Therefore no numeric bytes-per-gate-run rate should be
pretended in this review.

The production cadence should be sized from the first inventory-enabled runs:

```text
g95 = 95th-percentile new FRAMLOG bytes per completed gate run
e95 = 95th-percentile new fact entries per completed gate run

run GC when either:
  bytes_since_last_sweep >= 10 * g95
  entries_since_last_sweep >= 10 * e95
  elapsed_since_last_sweep >= 24 hours
```

The initial operating policy is therefore “daily plus the measured ten-run
growth threshold,” not a fabricated absolute size. After 14 real persisted
runs, publish `g95`, `e95`, the resulting cadence, and the largest root/segment
authority hold in the retention receipt. If a configured maximum log or free
space reserve is reached first, maintenance runs immediately and append fails
closed until it succeeds or the old full gate is used. This is the smallest
cadence claim supported by today's evidence.

## Acceptance bar for the banked design

Do not make retention authoritative until a local R6-style check proves:

- live commit, pin, checkpoint, session, recent, dead-branch, and rejected-
  candidate root cases;
- a fact outside roots is deleted only when its exact producer and source
  commit re-mint the same ID;
- a missing producer/input keeps the fact;
- stale-root and concurrent-write CAS attempts refuse replacement;
- interrupted compaction leaves the old store readable;
- cold reopen of the compacted store returns every live root's facts;
- inventory reports bytes, entries, roots, and free space; and
- 1x, 10x, and 100x representative store sizes stay inside the predeclared
  maintenance authority-hold and query budgets.

Until that bar passes, the honest operating mode is shadow-only fact
maintenance plus the unchanged full gate. The fact store currently remembers;
it does not yet know what it is allowed to forget.

FACTS-RETENTION-OPEN — no live fact-store inventory or GC exists; the rooted re-derivable compaction design is banked above.
