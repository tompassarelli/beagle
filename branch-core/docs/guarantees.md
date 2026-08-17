# Guarantees

This document is the current source-head guarantee, concurrency, workload, and
client-obligation contract.

## Surface binding

Unless a guarantee explicitly names the retained JVM route or a storage regime,
it binds to the occurrence-native server, binary FRAMLOG, and exact
FRAMRPC v2 wire version 2.0 in this source tree. A mismatch in either the major
or minor wire version is rejected rather than negotiated.

## Durability

Durability is stated per **storage regime**, because what "the bytes are down"
means is the storage owner's answer, not the engine's:

- **POSIX storage** — the engine owns the file. `storage_sync` is `fsync` on
  the log descriptor, and the barrier completes inside the commit path before
  any acknowledgement leaves.
- **Host storage table** — an embedder supplies the storage hooks
  ([isolation and deployment](isolation-and-deployment.md#the-wasm-embed-contract)).
  `storage_sync` returning zero means only that the host accepted the bytes.
  Where the host's own commit is asynchronous — a Durable Object's storage is
  the case in hand — durability lands after the guest call unwinds, so **the
  embedder must await its store's commit before acknowledging the write**. An
  embedder that answers the caller first has moved the barrier, not removed it.

D1-D5 below are the POSIX regime. D6 states what the engine still guarantees
when the barrier belongs to a host.

| # | Guarantee |
|---|---|
| D1 | An acked commit is durable: its FRAMLOG frame is covered by a successful `force(true)` barrier before the cohort's immutable head is published |
| D2 | A torn trailing frame never corrupts state: authority boot truncates to `:valid-bytes`; exactly the longest committed prefix survives, at every possible cut offset |
| D3 | A passive recovery open (no writer authority) reports a torn tail and never rewrites the log |
| D4 | An append-path failure fences the writer (`:durability-ambiguous` / `:recovery-required` / `:database-corrupt` / `:database-state-invalid`); every waiter in a failed cohort is refused and writes stay fenced until restart |
| D5 | Damaged committed bytes are detected loudly on replay; replay never silently produces a divergent image |
| D6 | Under a host storage table the engine appends whole frames in commit order and never rewrites committed bytes. An isolate that dies before its host's commit lands therefore loses a suffix and never a prefix: the durable image is exactly what the last landed commit left, and a fresh instance opens it and serves |

D6 places two obligations on the host, and neither is checkable by the engine.
One commit must land **atomically** and commits must land **in order**: replay
reads from byte zero, so a host that applies half of one commit, or overtakes an
earlier one, damages the middle of the image rather than its tail — which is
detected loudly (D5) but is not repairable by truncation the way a torn tail is
(D2). Serialize commits, one in flight.

## Atomicity

| # | Guarantee |
|---|---|
| A1 | One RPC batch remains one transaction frame; a sequencer cohort prepares FIFO on a private root and publishes all covered frames together after one barrier, or publishes none |
| A2 | A write, batch, or successful lease acquire, renew, or release encodes its exact predicted success response before append. Any Term depth, node, or frame-size rejection appends nothing and leaves version and state unchanged |

## Isolation and concurrency

| # | Guarantee |
|---|---|
| I1 | One active writer per `SpaceId`; its singleton FIFO commit sequencer orders every mutation, while readers take only immutable published snapshots. Under POSIX storage the engine enforces this with a `flock` on the log and fails a second server closed; under a host storage table the exclusivity is the embedder's grant and the engine cannot check it |
| I2 | OCC: every one of the 13 data operations accepts and enforces `expected-version`; a stale or future value returns `:rpc/conflict` before operation-specific handling and without moving the version |
| I3 | K concurrent socket writers: every acked proposition is durable exactly once, per-writer issue order is preserved, tx-sequence strictly rises, each ack's version equals its frame's tx-seq, and the published root contains that transaction before its ack |
| I4 | **JVM route only:** reads do not convoy writes; validate is a non-convoying read, and during a 2 s slow query or validate a lone write acks ≤ 250 ms and ten concurrent writes ack ≤ 1 s. Native production makes no such guarantee: its `dispatch_mutex` serializes the dispatch of every complete request |

## Ordering and recovery

| # | Guarantee |
|---|---|
| O1 | `tx-sequence` + `op-ordinal` define exact logical order; mutation receipts return occurrence coordinates |
| R1 | Replay restores logical order and occurrence liveness; restart resumes at the next tx without duplication |
| R3 | A snapshot image is an accelerator that cannot change an answer: with a valid image the boot installs it and replays only the FRAMLOG tail past its watermark; an image that fails to install, or whose tail does not continue, degrades to the full fold and reports it instead of failing the boot. `rpc/checkpoint` appends nothing to the log, so history stays authoritative |
| R4 | A completed `fram-backup` is the exact authoritative FRAMLOG prefix through one native checkpoint watermark, bound to its SpaceId, served version, and native artifact READY receipt by canonical SHA-256 metadata. Restore starts from fresh storage, refuses a different SpaceId without mutation, reaches the recorded version before readiness, and accepts durable writes afterward |

## Wire

| # | Guarantee |
|---|---|
| N1 | Exact FRAMRPC wire 2.0 exposes 13 data operations plus the separate fixed native `rpc/checkpoint` operator; the data client cannot select that operator. A major or minor version mismatch, unknown tag or field, or trailing byte is rejected, and EDN is refused. The JVM codec models request, response, cancel, and event frames. A cancel retains the 26-byte header and request id and has a zero-byte body. The native decoder accepts request frames only and its encoder emits response frames only, so identical-host-codec guarantees do not extend beyond that directional surface |
| N2 | Limits: header = 26 B; body ≤ 1,048,576 B; frame ≤ 1,048,602 B; SpaceId ≤ 4,096 UTF-8 bytes; string ≤ 1 MiB; term nodes ≤ 65,536; depth ≤ 256 |
| N3 | Paging behavior is operation- and route-specific. On native, an unpaged query over 248 rows refuses typed `:term-depth-exceeded`; scan has a 200-row/page maximum, refuses a larger unpaged result with `:rpc/native-page-required`, and uses its own `:rpc/native-scan-cursor`; unpaged `rpc/occurrences` silently returns only the first 248 rows. Clients therefore paginate every nontrivial read and never treat an unpaged occurrence result as complete. Recursive list bounds still cap a request list at 250 values and a mutation batch at 247 actions. Before a write, batch, or successful lease acquire, renew, or release commits, the runtime encodes its exact predicted response; a depth or byte-budget failure refuses without advancing version or state |

## Query

| # | Guarantee |
|---|---|
| Q1 | Query semantics per [`query-reference.md`](query-reference.md), including stable natural-value ordering and global top-K with a canonical full-row tie breaker |
| Q2 | A page cursor pins its resolved upper sequence and lower-exclusive occurrence bound across intervening commits; eviction may recompute from the pinned immutable root without changing rows |
| Q3 | Five positive text relations read live String values through one shared index: `text-match` (unordered token conjunction), `text-phrase` (token order preserved), `text-substring` (case-folded, punctuation kept), `text-stem` (English stemming), and 4-arity `text-search` (ranked, exact before stem before substring). All are positive-only, need a bound String needle, and reject empty or punctuation-only needles. Plans whose text attributes are all constant build only those attribute rows; a variable attribute conservatively builds the full corpus. One index build is bounded at 64 MiB and fails typed `:query-text-index-limit`; the analyzers behind phrase, substring, stem, and search realize on first use, so a `text-match` query pays nothing for them |
| Q3a | The text index is exact-snapshot keyed, single-flight, and retained across requests for four versions — **JVM route only**. The native route builds the source per query, plan-gated so an unqueried text relation costs nothing, and leans on the ordered-result cache (Q5) for repeats |
| Q4 | Budgets: step budget 10,000,000; timeout `min(60000, requested else 5000)` ms |
| Q5 | Complete deterministically ordered results are reused by snapshot generation, SpaceId, resolved `{lower-exclusive, upper-inclusive}` view, operation, and canonical request digest; concurrent misses share one computation |
| Q6 | `current`, inclusive `as-of U`, and `since L upper` compose transaction-exact state plus occurrence and targeted-withdrawal history. Native applies the `(L,U]` lower bound to every base relation without materializing the full occurrence relation. The retained JVM route lower-bounds only `occurrence` and `withdrawal`, leaving `triple` and text at upper snapshot `U` |
| Q7 | A historical miss uses the newest valid prefix-bound checkpoint and replays its tail; corrupt derived state falls back to canonical history. Sealed ranges preserve rows, while unavailable and explicitly expired ranges remain distinct |

## Profiles

The EAV profile whose stored kind is currently named `"relational"` is advisory
at this slice. Its declared rules are R1: all positions are Atoms; R2: t1 is a
non-blank String or Keyword; R3: t2 is a non-blank String or Keyword; R4: t3 is
a non-nil Atom (the blank String is valid). Profile lint bootstrap-skips every
Triple whose t2 is exactly the Keyword `:kernel/profile`. Only a well-formed
anchor with the required header and rule propositions binds a profile; malformed
anchor-shaped Triples receive the broad lint exemption but bind nothing.

R5 — the declared-vocabulary rule — is listed separately because a profile
opts into it: a space that does not list `R5` beside R1-R4 keeps every
verdict it had. Where it is listed, a proposition whose t2 is a namespaced
Keyword violates R5 unless that Keyword's membership is asserted in the same
space as `(predicate, :member_of, anything)`. Closed `:kernel/*` protocol
vocabulary is exempt.

| # | Guarantee |
|---|---|
| P1 | A space without a complete profile declaration retains current freeform write behavior |
| P3 | The prospective admission verdict and advisory lint verdict agree for R1-R4 |
| P5 | Under R5 a declaring space rejects a namespaced non-`:kernel/` t2 whose membership is unasserted, and spaces that omit R5 are unaffected |

## Write semantics

One writer serializes accepted transactions while clients read immutable
published snapshots. All 13 data operations may carry `expected-version`;
stale or future values fail `:rpc/conflict` before operation-specific handling
and without advancing the version. Lease fencing is an additional resource
guard, not a replacement for transaction OCC or sole-writer authority.

Actions in a batch receive ordered occurrence coordinates and commit as one
frame or not at all. Every assertion creates a new occurrence even when equal
proposition content is live. A successful retraction carries structurally equal
content, follows its target in the same SpaceId, and withdraws exactly the
newest live equal assertion occurrence; one assertion occurrence can be
withdrawn at most once. The derived `withdrawal(retraction, assertion)` system
relation records that target. Retracting without a live match is an explicit
`stateChanged = false` receipt. It still records a retraction occurrence and
advances the version, but produces no withdrawal.
Cardinality, uniqueness, referential integrity, and replacement policy are
domain rules, never implied by `t1`, `t2`, or `t3`.

## Workload envelope and client obligations

Reference workload NW-1 is a coordination substrate: mostly single-proposition writes, occasional atomic batches, targeted reads, paged projection drains, at most eight concurrent bulk clients, one bounded listener poller, listener leases, and interactive traffic. Whole-corpus client filtering is excluded.

| Dimension | Contract |
|---|---|
| Request/response | header = 26 B; body ≤ 1,048,576 B; frame ≤ 1,048,602 B; SpaceId ≤ 4,096 UTF-8 bytes; bulk reads paginate; native scan pages use at most 200 rows, native query pages stay within the Term depth budget, and unpaged native occurrences are incomplete above 248 rows; mutation replies are exact-preflighted before commit under N3 |
| Latency | targeted read p95 at 500k Triples and ≤8 clients is TBD and may not be cited |
| Writes | sustained single-transaction throughput and restart cost per 100k Triples are TBD and may not be cited |
| Contention | `:rpc/conflict` is normal contract behavior; retry from a fresh base |
| Restart | replay is O(full log); probe `:rpc/status` before serving |
| Overload | unspecified until bounded admission exists |

Clients must retry transient transport errors with bounded backoff, paginate every nontrivial read, never substitute a differently scoped result after timeout, and probe readiness after restart. A fail-closed reaction to one missing read amplifies transient flicker and is outside the contract.

## Explicit non-guarantees

- No engine access control: isolate by process, network, `SpaceId`, and log
  ([`isolation-and-deployment.md`](isolation-and-deployment.md)).
- Single-machine, single-writer receipts — not distributed consensus.
- Equal propositions are not deduplicated: assertion always creates a new occurrence.
