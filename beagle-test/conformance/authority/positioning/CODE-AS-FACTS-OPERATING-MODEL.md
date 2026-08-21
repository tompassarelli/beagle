# CODE AS FACTS — THE OPERATING MODEL

## Commission and claim discipline

This document makes one architectural ruling:

> A repository is developed by maintaining a certified graph of program facts.
> Source text is the exact, reviewable, Git-mergeable projection by which humans
> author that graph. A gate is not a ritual that interprets all text again; it
> is the transaction that identifies facts invalidated by a candidate change,
> re-derives or rechecks only those facts, and publishes a new certified fact
> root.

This is the operating consequence of the Turtles Thesis, not a new thesis. The
thesis already says that definitions, expansions, interfaces, lowered units,
artifacts, and receipts are analysis facts with explicit inputs; demand derives
only an absent or stale fact [E1]. The type doctrine makes the same ruling at a
smaller scale: infer once, retain every final judgment, and make `type-of` a
query rather than a request to reconstruct compiler state [E2].

The failure being corrected is **failure by construction**. The fleet currently
authors text, treats the store as an output cache, and throws away the proof
graph at process and gate boundaries. With no certified relation from a diff to
the claims it invalidates, the only sound gate is to re-prove almost every
claim. Faster runners, checkpoints, fixtures, caches, and batching reduce the
cost of that design without changing it. The store-first model changes the unit
of correctness from “this command ran over this tree” to “every claim required
by this policy has a current derivation or verdict under this exact fact root.”

Evidence notation is mandatory throughout this document:

- `[E#]` cites evidence that exists now.
- `[DERIVED:E#,...]` is a conclusion mechanically implied by cited evidence,
  not a new measured result.
- `[NEEDS EVIDENCE: R#]` marks an architectural claim, estimate, or safety
  condition that must be decided by a named spike or gate before it can become
  an operating fact.

No forecast below is presented as measured fact. At the time of writing,
Beagle v0.24.0 is still in its integration train [E13]. “Post-v0.24.0” in this
document means the exact landed and locally preflighted release commit, not the
current candidate and not any commit-only lane.

Normative definitions and rules below are design rulings, not assertions of
current capability. Each such block is governed by the nearest named `R#`
gate; where more than one applies, the block names all of them. An unmarked
sentence is explanatory expansion of that ruling, not evidence that it already
works. No implementation or speed claim becomes operational without its `R#`
evidence.

## Evidence register

| ID | Existing evidence and the claim it supports |
| --- | --- |
| **E1** | `~/code/todo/beagle-program-handoff/positioning/THE-TURTLES-THESIS.md`, especially “Kill Compile/Run,” “Kill Program-as-Text,” and W7. The store already has recursive semantic terms, durable revisions, CAS, post-durable observation, verified-root GC, compiler semantic units, exact source projections, and a proposed derivation/attestation constitution. It explicitly requires dependency-complete facts and cold-process replay. |
| **E2** | `~/code/todo/beagle-program-handoff/positioning/TYPE-MATERIALIZATION.md`. Existing compiler seams already capture some inferred/effective types, exact checked projections, source facts, interface digests, structured repair plans, and semantic-unit cones. They do not yet provide stable per-occurrence identities, complete derivations, one canonical type identity, durable type batches, or certified caller-cone receipts. The doctrine sizes complete W5f at 12–18 engineer-days after W5e. |
| **E3** | `~/code/todo/beagle-program-handoff/positioning/TYPEQUERY-SPIKE-FINDINGS.md`. A real cold-reopened FRAMLOG answered `type-of` through the landed Datalog evaluator. Median first query was 0.534 ms; median warm query was 0.481 ms. Three tiny definitions cost 7.551 ms durable mint and 1,348 bytes each under deliberately expensive per-definition `fsync`. This proves mechanism and exposes batching/volume risks; it is not a throughput result. |
| **E4** | `~/code/todo/beagle-program-handoff/positioning/CONE-RECEIPT-SPIKE-FINDINGS.md`. A body-only edit invalidated `cone.a/value` and skipped its consumer; a signature edit invalidated both. The existing unit-reuse corpus reported exact 9/9, 8/9, and 7/9 reuse cases. The native program cache still hashes the whole program and therefore cannot consume the per-unit answer. |
| **E5** | `~/code/todo/beagle-program-handoff/positioning/EXPFACTS-SPIKE-FINDINGS.md`. Expansion definition/call/output facts were minted and a facts-only query recovered the two affected macro call sites without reading source. The production hook exists; stable macro-definition identity and complete recursive provenance remain missing. |
| **E6** | `~/code/todo/beagle-program-handoff/positioning/TYPEMAT-SPIKE-FINDINGS.md`. Direct `explain-type --write` can make one interior annotation edit, recheck green, and become idempotent; the agent diagnostic route cannot yet carry a derived type, exact span, or fix plan for a boundary hole. |
| **E7** | `~/code/todo/beagle-program-handoff/positioning/W5-SPIKE-SYNTAX-FINDINGS.md` and `W5-SPIKE-SCOPES-FINDINGS.md`. Immutable syntax/provenance and structural scope resolution work as standalone mechanisms, but current raw-datum and interned-symbol boundaries cannot carry occurrence identity. This constrains the subject identity of durable facts. |
| **E8** | `~/code/todo/agent-coord.md`, `EXEC-154`. A recurring compiler build fell from 180.039 s to 16.337 s (11×); first-cold completed in 134.4 s where it had timed out; 25/25 outputs were byte-identical. The prior best warm result was 48.3 s. |
| **E9** | `~/code/todo/agent-coord.md`, `EXEC-165`–`EXEC-166`. A 40–43 minute publication materialization that repeated the whole pipeline became 59.6 s cold, 6.387 s with stage reuse (reported 9.3× over cold), and 0.185 s with whole-result reuse (reported 322× over cold), with byte-identical SHA-256 output. |
| **E10** | `~/code/todo/agent-coord.md`, `EXEC-152`, `EXEC-158`, `EXEC-169`–`EXEC-175`, and `EXEC-181`. A provisioned 2,415-test active tier still reached the 420 s suite bound; the current gate later ran 2,797 tests. Naive sharding rebuilt the Wasm fixture in every shard, consuming 1,615 CPU-s and leaving a 403.75 s four-way floor. The native cold path took 93.1 s against a 90 s bound and produced one timeout plus two dependent failures. A checkpoint changed an oracle bundle from a 180 s timeout to 28.8 s green. Full output retention turned three anonymous failures into one named timeout and two named casualties. |
| **E11** | `~/code/todo/agent-coord.md`, `EXEC-173`, `EXEC-183`, and `EXEC-204`. Seed provisioning legitimately took about 245 s; repeated command-shape defects cost 27-minute lock cycles; a later healthy seed was terminated after 373 s while holding the gate lock. Dry validation was then made mandatory before acquiring the lock. |
| **E12** | `~/code/todo/agent-coord.md`, `EXEC-195`–`EXEC-196`. Batching three independently focused-verified lanes into one integration candidate reduced four-or-more planned full gates to one. This removed repeated proof work by workflow decision, but did not make the retained proofs queryable. |
| **E13** | `~/code/todo/agent-coord.md`, `EXEC-205`–`EXEC-207`. The operator named code-as-facts as the missing operating model while the v0.24.0 integration candidate and speculative campaign lanes were still live. |

## I. Diagnosis: every latency is a forgotten fact

### 1. The common abstraction behind today’s wins

Every effective optimization today has the same logical shape:

```text
stable input identity
  + previously observed derivation/verdict
  + proof that no dependency changed
  = do not perform the derivation again
```

The whole-result cache remembers “this complete input closure produced these
bytes.” A stage checkpoint remembers “this prefix under these inputs produced
this intermediate.” A shared fixture remembers “these shards consume the same
prepared object.” A useful shard plan remembers “these claims are independent
and need no duplicate setup.” Batching remembers socially that focused proofs
already happened and therefore only one integrated candidate needs the broad
gate. These are all local, differently encoded instances of retained facts and
dependency-qualified reuse [DERIVED:E8,E9,E10,E12].

Sharding by itself is not fact retention. Today’s first sharding attempt is the
counterexample: it multiplied the forgotten fixture and did not materially
lower the floor [E10]. Sharding becomes part of the same model only when shard
inputs, fixtures, and verdicts are content-addressed facts that can be shared or
reused. The operating model therefore does not canonize “parallel” as a proof
mechanism; it canonizes stable identity, dependency completeness, and retained
verdicts.

### 2. Cost ledger

| Observed cost today | Specific fact that was forgotten | Evidence-backed consequence | Store-first correction |
| --- | --- | --- | --- |
| The warm active tier reached 420 s after 2,415/2,415 provisioning tests; the integration gate later contained 2,797 tests. | The gate retains no certified mapping from the candidate diff to the subset of test claims whose inputs changed. A pass is terminal text, not a reusable verdict with a dependency closure. | Every repaired candidate invokes the broad gate even when focused evidence and unchanged regions already exist [E10]. | Persist each gate claim, its complete subject/dependency closure, harness/profile, verdict, and verifier policy. Query current coverage; execute only missing or invalid verdicts. `[NEEDS EVIDENCE: R3]` |
| Naive four-way tier sharding consumed 1,615 CPU-s rebuilding the same Wasm fixture and had a 403.75 s floor. | The fixture was an implicit setup action rather than one immutable fixture fact referenced by all shard derivations. | Parallelism reproduced work four times and preserved nearly the full wall-clock floor [E10]. | Mint the fixture once under a content ID; shard verdicts depend on that ID. A changed fixture invalidates all consumers; an unchanged fixture is neither rebuilt nor copied semantically. `[NEEDS EVIDENCE: R2]` |
| The native C17 cold path took 93.1 s against a 90 s bound; its timeout caused two downstream classpath failures, yielding 2,794/2,797. | The cold native artifact and its readiness contract were reconstructed inside the test instead of admitted once as a checkpoint/artifact fact. | One forgotten prerequisite appeared as three gate failures [E10]. | Make native artifact readiness a prerequisite fact. Tests depend on its admitted artifact ID and never rebuild it independently. `[NEEDS EVIDENCE: R2]` |
| The oracle bundle first hit 180 s; with the checkpoint it completed in 28.8 s, a 6.25× change in that phase. | The oracle bundle was repeatedly derived from unchanged compiler/input closure. | A retained checkpoint removed more than 151 s from the phase [DERIVED:E10]. | Promote the checkpoint from a path convention to a content-addressed materialization fact with compiler/toolchain/input closure and an admitted decode contract. `[NEEDS EVIDENCE: R4]` |
| Recurring compiler work was 180.039 s and became 16.337 s; first-cold became 134.4 s; outputs stayed identical in 25/25 cases. | Intermediate decode/checkpoint results were discarded between invocations. | Remembering them delivered the reported 11× recurring improvement [E8]. | Emit each retained intermediate and its derivation into the fact graph. The cache lookup becomes an ordinary “is the required fact present and admissible?” query. `[NEEDS EVIDENCE: R2]` |
| Publication materialization cost 40–43 minutes, repeated three times that day; after caching it cost 59.6 s cold, 6.387 s from stage facts, and 0.185 s from the whole-result fact. | Refusal/retry and the native/Wasm roots forgot completed pipeline prefixes and identical full results. | Stage reuse delivered a reported 9.3× over the new cold path; whole-result reuse delivered a reported 322× over cold, byte-identically [E9]. | Use the same derivation identity at every materializer boundary. “Cold,” “stage hit,” and “whole hit” become three demand outcomes over one fact graph, not special scripts. `[NEEDS EVIDENCE: R2]` |
| Four-or-more integration gates were planned for separately focused-verified lanes; batching collapsed them to one. At the observed >420 s broad-gate floor, avoiding three runs avoids more than 21 minutes of repeated broad execution, though no completed end-to-end timing was recorded. | Focused verdicts and candidate ancestry lived in coordination prose; the gate could not consume them. | A human/orchestrator performed manual common-subexpression elimination [DERIVED:E10,E12]. | Focused verdicts become facts attached to exact subjects. The integration gate may reuse them when its policy says they cover the same claim and all derivation inputs are unchanged. `[NEEDS EVIDENCE: R3]` |
| Three product failures were anonymous because only a five-line tail survived; the next retained run identified one timeout and two consequences. | The failure verdict omitted case identity, phase, causal prerequisite, and full output digest. | Missing evidence forced another candidate cycle and initially obscured that all three reds shared one cause [E10]. | A verdict fact is structured even on failure. Failure is never a certifying pass, but its identity and causal inputs remain queryable diagnostics. `[NEEDS EVIDENCE: R1]` |
| Seed creation took about 245 s; command/path defects repeatedly entered 27-minute lock cycles; a healthy 373 s run was later killed while holding the global gate lock. | Command-shape validation, resolved input identity, and completed provisioning were ephemeral process knowledge. The global lock protected a mutable workspace rather than a short publication CAS. | Cheap errors repeatedly paid expensive setup and serialized unrelated work [E11]. | Validate command and manifest facts before expensive derivation; derive in immutable private fact space; hold serialization only for certified root publication. `[NEEDS EVIDENCE: R1,R6]` |

The table identifies two classes of forgetting:

1. **Computational forgetting** discards a result or intermediate and repeats
   work. Checkpoints and caches address it.
2. **Epistemic forgetting** discards why a result remains valid: subject
   identity, complete dependencies, toolchain/profile, verifier, and policy.
   Current caches largely leave this unsolved. A fast cache without the proof
   graph is only a faster way to guess.

The remaining 420-second gate is predominantly epistemic forgetting: it knows
that previous commands passed, but not which of their roughly 2,800 claims the
new fact root invalidated [E10]. That is why another round of runner tuning
cannot finish the job.

## II. The operating model

### 1. Source is the authoring projection; facts are the maintained program

“Store-first” does not require humans to edit triples or abandon Git. The
authoring transaction is:

```text
edit exact source projection
  -> import exact SourceRevision fact into a private candidate root
  -> derive syntax/binding/type/interface/expansion/unit/artifact facts
  -> compute invalidated reverse dependency cone
  -> retain current certified facts outside that cone
  -> derive/check missing facts inside that cone
  -> prove gate-policy claim coverage
  -> publish the new certified fact root by short CAS
  -> export/reconcile exact text projections for Git
```

This preserves the thesis’s many-source-to-one-semantic relation and exact
source recovery [E1,E2]. A whitespace edit may change the source revision and
span occurrence facts while retaining semantic definition, interface, type,
and materialization identities. A signature-preserving body edit changes its
implementation facts but retains the caller type-check cone, exactly as the
cone spike demonstrated [E4]. A signature edit changes the interface fact and
invalidates callers.

During migration, Git commits remain the published routing authority and every
fact snapshot records the exact repository commit(s) from which it was
imported. The store becomes authoritative for derivation and gate validity one
claim class at a time. Making the store the sole namespace or collaboration
surface is explicitly outside this migration. `[NEEDS EVIDENCE: R8]`

### 2. The immutable fact vocabulary

The existing `Atom | Triple` store, durable transaction/reopen path, and query
engine are enough to host the model [E1,E3]. They are not yet a complete
identity or certification constitution [E1,E2]. The first implementation must
therefore use versioned, domain-separated envelopes and must never present a
raw SHA-256 string, a store-private integer, a path, a pretty name, or a current
row as semantic identity.

The minimum logical vocabulary is:

| Fact | Meaning and reuse rule |
| --- | --- |
| **SourceRevision** | Exact ordered authored bytes, repository/commit provenance, logical paths, spans, and importer profile. Changes on any byte change. It never doubles as definition identity. |
| **SemanticSubject** | A versioned definition, syntax occurrence, binding, type/interface, expansion, analysis unit, fixture, foreign unit, or artifact identity. Its equality law is domain-specific and versioned. |
| **Derivation** | Ordered input fact IDs, transformer/compiler materialization ID, interpretation and target profiles, authority, outputs, and origin map. An output does not embed its own derivation ID; the derivation names outputs, avoiding an identity cycle [E2]. |
| **DependencyEdge** | `consumer -> consulted fact` plus use kind: syntax, binding, macro, type interface, body, reflection query, fixture, toolchain, environment, foreign boundary, materialization, or gate policy. A disappearing read remains a dependency until the consumer is re-derived. |
| **ProofFact** | A checker-owned proposition such as typed occurrence, binding resolution, effect/authority satisfaction, interface compatibility, lowering obligation, artifact byte identity, or deterministic fixpoint. |
| **TestClaim** | The stable proposition that a test case or property is intended to decide. Test source bytes are not sufficient identity; claim schema, subject, fixtures, harness, and policy participate. |
| **VerdictAttestation** | PASS/FAIL/FLAKY/NOT-RUN over one exact claim and dependency closure, bound to verifier implementation, policy, environment profile, output/log digest, duration metadata, and issuer/authority. Only an admitted PASS can cover a gate claim. FAIL remains diagnostic; retry cannot transmute it into PASS. |
| **ArtifactFact** | Exact output bytes plus the materialization derivation that binds source/definition closure, compiler/backend/linker/runtime/toolchain/profile, policy, and obligations. |
| **GatePolicy** | A versioned set or query of claims required for publication, with admissible verifier/policy versions. Changing the policy invalidates coverage without pretending the program changed. |
| **FactSnapshot** | Immutable root joining repository revisions, certified semantic facts, derivations, verdicts, and policy. A mutable route such as `beagle/main-certified` points to it through the store’s existing durable CAS mechanism. |
| **MaintenanceReceipt** | Previous snapshot, candidate source revisions, changed fact IDs, invalidated cone, retained facts, re-derived facts, rechecked claims, reused verdicts, rejected reuse reasons, final coverage, verifier policy, and new root. This is the replacement for a gate transcript. |

The first encoder is `FactEnvelopeV1`, not an unversioned preview of the later
W7 constitution. Cross-runtime canonical vectors must freeze kind IDs, payload
order, strings, numbers, collections, and corruption rejection before a second
emitter is trusted. A later correction mints V2 and explicit equivalence or
migration facts; it never reinterprets V1 bytes [E1,E2]. `[NEEDS EVIDENCE: R0]`

### 3. Certified snapshots and candidate space

Facts are immutable. Candidate derivations happen under a private root and do
not contaminate the last certified snapshot. Successful derivation seals one
batch; a failed check can retain an explicitly uncertified attempt for
diagnostics but cannot add partial proofs to the candidate’s certified set,
matching the type doctrine [E2].

Publication is short:

1. Verify the candidate root’s closure and gate coverage from a cold process.
2. Compare the expected published fact root and exact repository heads.
3. Atomically route the certified name to the candidate root.
4. Export the maintenance receipt and exact text projections.

Expensive compilation, test execution, and fixture construction happen before
the publication CAS. This removes the architectural need for a minutes-long
global gate lock; the store’s existing durable CAS is the serialization seam
[DERIVED:E1,E11]. Whether the current implementation can support concurrent
private roots at the required throughput remains a deciding measurement.
`[NEEDS EVIDENCE: R6]`

### 4. Invalidation is a proof operation

For a candidate diff `D` and prior certified snapshot `S`:

```text
changed = import_and_compare(D, S)
invalid = reverse_transitive_closure(changed, observed_dependency_edges)
required = evaluate(gate_policy, candidate_root)
current = required verdicts whose complete derivation closure is unchanged
missing = required - current
run = schedule(missing, sharing identical fixture/artifact prerequisites)
publish only when every required claim has one admitted current PASS
```

There is no time-to-live validity. Wall-clock age does not invalidate a semantic
fact. A fact becomes non-current because an identity in its derivation closure
changed, its verifier/policy is no longer trusted, an explicit withdrawal or
successor fact superseded it, or required bodies are unavailable for the
policy’s replayability level.

The safety rule is asymmetric:

- A declared dependency may cause unnecessary rechecking; that is a
  performance defect.
- An undeclared dependency can cause false reuse; that is a correctness defect
  and blocks certification.

Until a producer can observe its complete reads, it receives a conservative
input closure. The first gate phase adapter may depend on the entire repository
tree, exact compiler/toolchain closure, environment profile, and policy. That
will reuse less but cannot claim more precision than exists. Precision is
earned by observed reads, compiler manifests, and substitution tests [E4,E5].
`[NEEDS EVIDENCE: R1,R2,R5]`

### 5. The gate becomes a fact maintainer

The gate’s public result changes from:

```text
2797 tests ran, 2797 passed
```

to:

```text
2797 claims required by GatePolicy P
  2734 retained under unchanged dependency closures
    63 rechecked on this candidate
  2797 current admitted PASS verdicts
     0 missing, flaky, failed, or policy-inadmissible
candidate FactSnapshot F certified
```

Those numbers are illustrative shape, not a prediction of actual invalidation
distribution. `[NEEDS EVIDENCE: R3]`

The fact maintainer must preserve the present gate as the execution oracle. It
does not rewrite test semantics in its first cut. It decides which existing
phase or case commands are required, supervises them with the current bounds,
and imports their structured verdicts. When it cannot prove a claim’s complete
inputs, it runs the conservative parent phase. When fact maintenance itself
fails, the old full gate remains the release fallback during migration.

Performance checks remain separate claims. Their verdicts include the exact
machine/load/toolchain profile and do not become reusable correctness passes.
Flaky checks are ineligible for certification until repaired or demoted under
the existing fleet law.

### 6. What exists after v0.24.0, and what must be built

The post-v0.24.0 baseline is contingent on the exact release train landing. The
table does not promote candidate work to fact before that event [E13]. Sizes
are one-owner engineering forecasts, not measured delivery commitments.

The baseline capability manifest must be generated from the exact v0.24.0
release commit before S0 starts. It may count only mechanisms reachable from
that commit and passing its local preflight. Evidence already supports the
durable Term/Triple store, revision/CAS/reopen/query machinery, exact source
projections, partial structural/type/interface facts, semantic units, and the
existing cache/checkpoint and gate infrastructure [E1,E2,E3,E4,E8,E9,E10]. It
must not count the constitutional general fact ID, complete derivation graph,
durable type batch, certified verdict admission, exact gate invalidation, or
Grafify bridge; those are the missing seams below. `[NEEDS EVIDENCE: R0,R1]`

| Seam | Existing substrate to consume | Missing deliverable | Size | Required evidence |
| --- | --- | --- | ---: | --- |
| **S0 — Fact identity V1** | Recursive Terms, canonical binary wire, durable store, cold reopen/query [E1,E3]. | Domain-separated `FactEnvelopeV1`, fixed kind registry, canonical vectors, corruption rejection, and V1→future-version migration rule. | 3–5 days | **R0** cross-runtime hostile vectors and cold round trip. |
| **S1 — Source candidate importer** | Exact checked source bytes/provenance and source-fact routes [E1,E2]. | Import exact multi-repo candidate revisions into an isolated fact root; byte/path provenance remains separate from semantics. | 3–5 days | **R1** whitespace, move, stale-byte, missing-file, and clean-restart matrix. |
| **S2 — Beagle native fact batch** | Infer/check choke points, checked-program projection, effective types, interface digests, semantic units, source facts [E2]. | One transactional compiler sink for syntax/binding/type/interface/effect/proof/unit/materialization facts and complete derivations. Type completeness itself retains the doctrine’s 12–18 day W5f estimate after W5e. | 12–18 days for full type slice; 5–8 days for the narrower gate/unit batch | **R2** capture parity, volume, wall/peak memory, restart replay, and omitted-read failure. |
| **S3 — Reverse cone maintainer** | Body-vs-signature cone distinction and facts-only macro cone are proven in spikes [E4,E5]. | Persist dependency edges, reverse indexes/projections, changed-fact classification, retained/recomputed receipt, and missing-edge fail-closed behavior. | 4–6 days | **R2** mutation/substitution corpus across body, interface, macro, type, fixture, toolchain, and unconsulted edits. |
| **S4 — Gate claim registry** | Existing named gate phases, phase supervisor, shard runner, focused suites, and retained output machinery [E10]. | Stable claim IDs, phase/case input manifests, GatePolicy V1, structured verdict import, and cold coverage query. | 4–6 days | **R3** shadow parity against full gate on representative diffs. |
| **S5 — Verdict admission** | Store attestations and receipt constitution are designed; current store can hold facts [E1]. | Certified-vs-asserted separation, verifier/policy/profile IDs, PASS admission, FAIL/FLAKY semantics, log digests, and withdrawal/supersession. | 3–5 days | **R3** issuer/policy/toolchain/environment substitution rejection. |
| **S6 — Shared prerequisites** | Checkpoint and whole-result mechanisms have delivered 6.25×, 11×, 9.3×, and 322× local wins [E8,E9,E10]. | Promote fixtures, checkpoints, decoded bundles, and artifacts into ordinary derivation facts referenced by all consumers; eliminate per-shard rebuilding. | 4–7 days | **R2** one-build/many-consumer trace plus byte parity and corruption rejection. |
| **S7 — Grafify core** | Store can hold opaque recursive Terms and query them; receipt/attestation shape is designed [E1,E3]. | Foreign-unit, boundary-contract, observation, verdict, environment, and verifier facts; conservative manifest mode; adapter API. | 5–8 days | **R4,R5** first foreign adapter and hidden-input negative corpus. |
| **S8 — Beagle gate fact maintainer** | Everything above plus current full gate as fallback. | Query invalidation, reuse current verdicts, schedule missing claims with shared prerequisites, emit maintenance receipt, and publish candidate root. | 5–8 days | **R3** cold shadow parity, then authoritative narrow-diff pilot. |
| **S9 — Repository adapters** | Beagle-authored surfaces already exist across the four repositories [E1]. | North Clojure host adapter; Greywrought Bun/JS and asset/build adapters; Firn Nix evaluator/closure and shell adapters; cross-repo root pinning. | 3–6 days per adapter | **R5,R7,R8** per-boundary mutation matrices and loop measurements. |
| **S10 — Retention and operations** | Verified-root GC and proof-pack policy exist in the thesis/store design [E1]; type doctrine proposes packed interior facts [E2]. | Hot indexes vs packed fact bodies, roots/retention, archive/rehydration status, inspector, metrics, and emergency full-gate fallback. | 5–8 days | **R6** representative volume, GC authority-hold budget, query and admission latency. |

These are seams, not a serial project schedule. After S0 freezes the vocabulary,
S1/S4/S5/S7 can proceed independently; S2/S3/S6 can proceed on shared vectors;
S8 integrates them. Repository adapters share the Grafify contract, not files.

### 7. Repository-specific operating model

| Repository | Native facts | Foreign/opaque boundary | Gate-maintenance rule |
| --- | --- | --- | --- |
| **Beagle** | Exact source revisions; syntax/binding/expansion facts; types and interfaces; effects/authority proofs; semantic units and dependency cones; target artifacts; oracle/self-host parity; test claims and verdicts. Existing mechanisms cover parts of each class [E2,E4,E5,E7]. | Racket compiler/oracle internals and any Clojure/JVM helper not itself compiled from Beagle enter through Grafify. Their interiors are not promoted to typed Beagle facts. | First adopter. Recheck only claims whose semantic, fixture, harness, toolchain, policy, or foreign-boundary dependencies moved. The broad full gate remains fallback until R3 passes. |
| **North** | Beagle-authored orchestration/tools produce ordinary Beagle facts. North’s selected Beagle/store release, fact snapshot, prompts/policies, and dispatch outputs are explicit inputs. | Clojure/JVM host code and external CLI/process boundaries are opaque foreign units with observed request/response, file, exit, and side-effect contracts. The exact boundary inventory requires a repo-specific spike. `[NEEDS EVIDENCE: R7]` | A North claim reuses a Beagle verdict only when it pins the exact certified Beagle fact root. Clojure changes invalidate their boundary contracts and dependent North claims, not unrelated Beagle compiler facts. |
| **Greywrought** | Beagle game logic, checked effects/authority, durable schema/query facts, native/Wasm artifacts, journal/parity/admission receipts, and semantic test claims are native. The thesis records the present game/store/admission lineage without claiming unfinished Stage 4/5 work [E1]. | Bun/JavaScript browser tooling, asset processors, browser APIs, and any Clojure host remain opaque. Their inputs, emitted assets/bundles, public interfaces, and boundary tests are attested. Exact adapter boundaries require inventory. `[NEEDS EVIDENCE: R7]` | A gameplay body edit rechecks its exact semantic/test/materialization cone. An unchanged JS or asset boundary reuses its attestation. A boundary change invalidates only dependents. Live promotion still requires its separate parity/admission policy; a cached test pass cannot substitute for it. |
| **nixos-config / Firn** | `.bnix` exact source and Beagle semantic facts are authoritative authoring inputs; generated `.nix` is an ArtifactFact/projection with a derivation. Beagle-native repository tools emit ordinary facts. Existing Firn already treats `.nix` as generated and rebuilds commit snapshots [E1]. | Nix evaluation, derivation construction, system closure realization, shell adapters, and external package tools are opaque foreign units. A Nix store path is an output identity, not by itself a boundary-contract proof. | A `.bnix` edit invalidates its Beagle semantic cone and the exact Nix projection/evaluation claims that consume it. Unchanged Nix closures are reused; changed system closure realization still runs. `firn rebuild` publishes only a fact root whose Beagle and Nix-boundary claims both pass. `[NEEDS EVIDENCE: R7,R8]` |

Cross-repository edges always name an immutable certified fact root and exact
interface/contract IDs. “Use current Beagle” is not a dependency. Advancing a
consumer creates a new candidate edge and rechecks only claims reachable from
the changed interface, policy, or artifact. `[NEEDS EVIDENCE: R8]`

## III. The Grafify bridge

### 1. Purpose and trust boundary

Racket internals, Nix, Bun/JavaScript tools, Clojure hosts, shell programs, and
platform tools cannot emit native Beagle type/proof/dependency facts. Pretending
otherwise would make the graph unsound. Grafify lets their seams participate
without claiming proof of their interiors.

Grafify’s assertion is deliberately narrow:

> For this exact foreign content, toolchain/runtime/environment profile, input
> manifest, invocation, and boundary contract, this admitted verifier observed
> these outputs and this verdict.

It does **not** assert that the foreign implementation is internally typed,
pure, deterministic, dependency-complete, memory-safe, or semantically
equivalent to a Beagle implementation. Those require separate evidence. The
opaque unit may be replaced by native facts later without changing its
consumers if the boundary contract identity stays equal. `[NEEDS EVIDENCE: R4]`

### 2. Boundary-attestation facts

```text
ForeignUnitV1
  contentManifestId       # exact ordered files/bytes, lockfiles, generated inputs
  runtimeToolchainId      # Racket/JVM/Bun/Nix/shell and owned dependency closure
  environmentProfileId    # OS/arch/ABI plus only correctness-relevant capabilities
  adapterVersionId

BoundaryContractV1
  contractSchemaVersion
  inputTypeAndEncodingIds
  outputTypeAndEncodingIds
  exitAndErrorAlgebra
  declaredReadsWritesEffects
  determinismClass
  compatibilityPolicyId

BoundaryObservationV1
  foreignUnitId
  boundaryContractId
  canonicalInputIds
  observedOutputArtifactIds
  observedReadWriteEffectManifest
  stdoutStderrDigest
  exitOrResult

BoundaryVerdictV1
  observationId
  boundaryClaimId
  fixtureAndHarnessIds
  verifierMaterializationId
  verifierPolicyId
  issuerAuthorityId
  status = PASS | FAIL | FLAKY | NOT_RUN

BoundaryAttestationV1
  admittedBoundaryVerdictIds
  closureManifestId
  replayabilityStatus
  attestationPolicyId
```

All identities are versioned and domain-separated through S0. The observation
records what happened; the verdict says what claim the observation decides;
the attestation says which verifier/policy is trusted to certify it. Conflating
those three would allow arbitrary foreign output to masquerade as proof.

### 3. Conservative dependency law

Grafify V1 has two manifest modes:

1. **Conservative manifest.** Hash the entire owned foreign subtree, lockfiles,
   runtime/toolchain closure, boundary fixtures, invocation adapter, and
   correctness-relevant environment profile. This is safe but coarse.
2. **Observed manifest.** A tracer or owned host reports actual file/module/env/
   subprocess reads. An undeclared observed read fails certification. The
   conservative manifest remains the fallback for unobservable surfaces.

Network state, wall-clock time, randomness, shared mutable caches, and external
services are not silently added as identities. Correctness tests must control
or deny them. If a boundary genuinely requires one, the claim becomes an
explicit observation under a named non-hermetic profile and is ineligible for
ordinary reusable correctness certification until its policy says otherwise.
`[NEEDS EVIDENCE: R5]`

Reuse is exact:

```text
same ForeignUnitId
and same BoundaryContractId
and same canonical input IDs
and same fixture/harness/verifier/policy/environment IDs
and admitted PASS
=> boundary claim remains current
```

Any changed element invalidates the verdict and all native facts that depend on
it. A foreign interior edit that leaves bytes changed still changes
`ForeignUnitId`; Grafify never attempts semantic equivalence inside an opaque
unit.

### 4. Minimal first cut: `GRAFIFY-V1 RACKET-ORACLE-BOUNDARY`

The first foreign adapter wraps the Racket oracle bundle boundary already
observed in today’s gate:

- subject: the complete owned Racket oracle/bundle source subtree, pinned
  Racket runtime, package lock/closure, bundle-builder adapter, and schema;
- contract: canonical bundle bytes decode under the named Beagle consumer and
  satisfy the existing oracle/fixpoint boundary tests;
- outputs: exact bundle artifact digest, decoder/schema ID, structured test
  verdicts, and retained output digest;
- reuse: if all subject and contract inputs are unchanged, use the attested
  bundle fact instead of rebuilding it;
- invalidation: any Racket source, runtime/package, schema/decoder, fixture,
  adapter, or verifier-policy change rebuilds and re-attests the boundary.

The phase has already moved from a 180 s timeout to 28.8 s under an ad hoc
checkpoint [E10]. Grafify V1 does not claim another 6.25×. Its first measurable
benefit is avoiding even that 28.8 s on candidates outside the boundary cone;
its architectural benefit is making the reuse reason cold-queryable and safe.
`[NEEDS EVIDENCE: R4]`

The deciding negative test changes, one at a time, a Racket source byte, pinned
runtime, decoder schema, fixture, adapter, and policy. Every substitution must
reject reuse before the consumer runs. A hidden file/env/subprocess read must
fail observed-manifest mode. Cold restart must produce the same decision.

## IV. Migration without halting the fleet

The fleet never waits for a flag day. Each stage shadows the existing path,
compares decisions, and earns a narrower authority. The old full gate remains
callable until the new fact maintainer has passed its substitution matrix and
cold shadow parity. New facts are additive; old source projections and Git
workflows continue throughout.

Speed estimates are expected ranges for narrow recurring changes, not promises
and not multiplicative across stages. A broad compiler/toolchain/policy change
may invalidate the whole graph and remains approximately 1.0× until the new
facts it creates can be reused later.

### Stage 1 — Beagle gate phase facts in shadow mode

Build S0, the conservative portion of S1, S4, S5, and the phase-level slice of
S8. Each existing named gate phase becomes one claim with an initially
conservative whole-repository/toolchain input manifest. Run the current gate
unchanged; import structured phase verdicts; cold-query whether a second
identical candidate would be covered. Do not skip execution yet.

- **Speed estimate:** 1.0× by design in shadow mode. After authority is earned,
  1.2–3× for diffs that leave most phase manifests unchanged; 1.0× for broad
  changes. `[NEEDS EVIDENCE: R1,R3]`
- **Risk:** coarse manifests may reuse little; incomplete manifests may reuse
  unsafely. Start coarse, and fail closed on ambiguity.
- **Exit:** at least one representative body edit, interface edit, test-only
  edit, toolchain change, and no-op candidate has the same final decision as
  the full gate after cold restart; every forced substitution rejects reuse.

This is the **first-cut seam**: `CAF-1 BEAGLE-GATE-PHASE-FACT-MAINTAINER`.

### Stage 2 — Compiler-native facts, exact cones, and shared prerequisites

Build S2, S3, and S6. The Beagle compiler emits transactional type/interface/
proof/unit/dependency batches. Existing fixture, oracle bundle, native
checkpoint, semantic unit, and materialization caches become derivation facts.
Use the body-versus-signature and macro-cone spike cases as the first exact
invalidation corpus [E4,E5].

- **Speed estimate:** 1.5–5× for the compiler/materializer portion of narrow
  diffs; 1.0× on a cold broad change. This range is extrapolation from the
  already observed 6.25×, 11×, 9.3×, and 322× local reuse wins, not a measured
  integrated result [E8,E9,E10]. `[NEEDS EVIDENCE: R2]`
- **Risk:** fact volume or per-fact durability could erase the gain. E3’s 7.551
  ms per-definition mint is dominated by per-definition `fsync`; production
  emission must batch once per analysis unit and measure packed storage [E3].
- **Exit:** cold restart reproduces exact changed/retained cones; one fixture is
  built once and referenced by all shards; omitted-read and corrupt-fact tests
  fail before reuse.

### Stage 3 — Claim-level incremental Beagle gate

Refine phase claims into stable test/property/obligation claims. Test verdicts
depend on semantic subjects, fixtures, harness, toolchain/profile, and policy,
not merely test-file bytes. The maintainer schedules only missing claims and
publishes the maintenance receipt. Keep one periodic diagnostic full-gate
comparison outside the correctness gate until the observation window closes;
it may reveal missing dependencies but does not block every landing unless it
finds a reproducible product mismatch.

- **Speed estimate:** 5–20× on routine narrow Beagle changes, with an initial
  target of moving the observed >420 s loop below 60–120 s; 1.0× for a change
  that genuinely invalidates all claims. The invalidation distribution is not
  yet measured. `[NEEDS EVIDENCE: R3]`
- **Risk:** tests often have hidden fixtures, environment reads, order
  dependence, or shared mutation. Such cases stay at conservative phase scope
  or are marked non-reusable; they are not guessed into per-case reuse.
- **Exit:** shadow decisions match the broad gate across the predeclared diff
  corpus; the cold verifier accounts for every required claim as retained or
  rechecked; a deliberately omitted dependency is detected.

### Stage 4 — Grafify V1 and the Beagle foreign phases

Build S7 and `GRAFIFY-V1 RACKET-ORACLE-BOUNDARY`, then adapt other Racket,
Clojure/JVM, shell, and external-tool phases one boundary at a time. Foreign
interiors remain opaque; native dependents consume only admitted contract facts.

- **Speed estimate:** the first adapter can avoid up to the measured 28.8 s
  cached oracle build on an out-of-cone candidate—about 1.07× against a 420 s
  gate if that phase is additive. The exact integrated saving and overlap are
  unmeasured. Additional adapters receive no forecast until inventoried.
  `[NEEDS EVIDENCE: R4,R5]`
- **Risk:** an incomplete foreign manifest creates the most dangerous false
  pass in the model. Whole-subtree conservative identity is mandatory when
  observed reads are unavailable.
- **Exit:** the Racket substitution matrix and hidden-read negative pass; cold
  reuse avoids the build; changed boundary inputs re-run and invalidate native
  consumers exactly.

### Stage 5 — North and Greywrought adopt certified dependency roots

Run two parallel repository seams. North pins exact certified Beagle/store
roots and Grafifies its Clojure/process boundaries. Greywrought imports Beagle
game facts natively and Grafifies Bun/JavaScript/assets/browser boundaries.
Neither repository waits for the other. Existing gates remain fallbacks.

- **Speed estimate:** 2–10× for narrow local loops whose Beagle and foreign
  contracts remain mostly unchanged; 1.0× on broad interface/toolchain changes.
  No current per-repository invalidation distribution supports a tighter
  estimate. `[NEEDS EVIDENCE: R7]`
- **Risk:** cross-repo “current” pointers and unrecorded process effects can
  break reproducibility. Every consumed root and effectful boundary must be
  exact and immutable.
- **Exit:** one North-only edit retains Beagle claims; one Beagle interface edit
  invalidates exact North consumers; one Grey gameplay edit retains unrelated
  JS/assets; one boundary edit invalidates its exact native dependents.

### Stage 6 — Firn makes Nix a projection and attested boundary

Treat `.bnix` as native source facts, `.nix` as a generated artifact, Nix
evaluation as a foreign boundary, and the realized system closure as an exact
artifact/contract result. `firn rebuild` still builds a committed snapshot and
remains the sanctioned publication operation; it now consumes the fact
maintenance receipt before switching.

- **Speed estimate:** 1–5× for Firn authoring/validation loops that do not alter
  most Beagle or Nix boundary facts; 1.0× when a changed closure genuinely must
  realize. No Nix phase timing or cone distribution has been measured for this
  model. `[NEEDS EVIDENCE: R7]`
- **Risk:** Nix’s own derivation/store identities are not automatically Beagle
  boundary attestations, and generated `.nix` must never become a second
  authoring authority.
- **Exit:** projection byte parity, Nix boundary substitution matrix, clean
  snapshot rebuild, and rollback-to-old-certified-root behavior pass without
  editing generated `.nix` as source.

### Stage 7 — Store-first becomes the default fleet contract

Publish cross-repository certified snapshot roots, require maintenance receipts
for normal landings, expose “why retained / why rechecked / why rebuilt”
queries, enforce retention/GC policy, and make the old unconditional full gates
explicit diagnostic/fallback commands rather than the normal unit of proof.
Text export and clean-clone reconstruction remain permanent gates.

- **Speed estimate:** no additional multiplier is credited. This stage makes
  the gains of Stages 1–6 the default and prevents regression to text-first
  proof. Expected migrated-loop speed is whatever the preceding measured gates
  earned; broad invalidations remain honest full work. `[NEEDS EVIDENCE: R8]`
- **Risk:** store loss, version migration, or projection drift could make the
  operating model an opaque codebase manager. Clean Git clone → import → derive
  → verify → exact export is the permanent escape hatch.
- **Exit:** every repository can reconstruct its certified current snapshot
  from exact Git commits and archived/available proof packs in a cold process;
  every published claim is explainable without the compiler process that
  originally produced it.

## V. Required evidence and kill conditions

| ID | Deciding spike/gate | Kill or narrowing condition |
| --- | --- | --- |
| **R0 — FACT-ID-V1-VECTORS** | Cross-runtime hostile vectors over every V1 kind; corrupt/unknown versions; cold store round trip; deterministic encoding on at least Racket, self-host/Beagle, and Clojure host. | Do not admit a second emitter if bytes or equality disagree. A correction creates V2; never rewrite V1 meaning. |
| **R1 — CANDIDATE-IMPORT-AND-PHASE-SHADOW** | Exact source import plus phase-fact shadow decisions for no-op, whitespace, body, interface, test, toolchain, and missing-file changes. | Keep the full gate authoritative if a changed input can retain a phase verdict or if clean restart changes the decision. |
| **R2 — NATIVE-FACT-CONE-AND-VOLUME** | Body/signature, macro/provider, type/interface, fixture, toolchain, and unconsulted changes; cold exact cones; once-built shared fixture; fact counts/bytes/write wall/peak memory/query latency. | Narrow granularity or use packed batches if fact emission materially worsens the routine loop. Kill exact reuse for any producer that cannot expose complete output-affecting reads. |
| **R3 — GATE-MAINTENANCE-PARITY** | Current broad gate versus fact maintainer on a predeclared representative diff corpus; policy/verifier/environment substitutions; one deliberately omitted dependency; cold coverage receipt. | The maintainer remains shadow-only on any false retain, unexplained claim, or decision mismatch. Performance misses narrow the speed forecast, not the correctness bar. |
| **R4 — GRAFIFY-RACKET-ORACLE** | Exact Racket oracle boundary, cold reuse, output byte/decode parity, and substitution of source/runtime/schema/fixture/adapter/verifier/policy one at a time. | Keep the phase opaque and always-run if any substitution retains PASS or if replay needs ambient state. |
| **R5 — GRAFIFY-HIDDEN-INPUT-CORPUS** | File/env/subprocess/network/time/random/shared-cache reads under conservative and observed modes. | A boundary with unobservable correctness-relevant inputs cannot receive reusable certification; include the whole enclosing closure or always run it. |
| **R6 — STORE-OPERATIONS-BUDGET** | Concurrent private candidates, short root CAS, batched admission, representative packed volume, cold query, retention/GC, archive/rehydration, and failure recovery. | Do not move the global lock boundary if candidate isolation is unsound. Narrow hot facts or retention if storage maintenance violates its predeclared authority-hold budget. |
| **R7 — REPOSITORY-BOUNDARY-MATRICES** | North, Greywrought, and Firn each inventory native/foreign boundaries and run one native-body, native-interface, foreign-interior, foreign-contract, toolchain, and unrelated edit. Measure invalidated claim percentages and wall time. | Retain conservative repository-wide invalidation for any boundary whose exact dependents cannot be named. Do not publish the 2–10× or 1–5× forecasts as achieved without measurements. |
| **R8 — CLEAN-CLONE-CROSS-REPO-RECONSTRUCTION** | From exact Git commits and proof packs, cold-import all four repositories, reproduce certified roots/projections, evaluate cross-repo edges, and explain one retained and one rechecked claim per repository. | The store-first default does not ship if an opaque live store is required, exact source cannot round-trip, or a mutable “current” dependency is needed. |

The model is killed—not merely optimized—if a whole-tree gate remains the only
sound correctness proof after dependency-complete native facts and conservative
Grafify boundaries exist. It is narrowed if only some claim classes earn exact
dependencies: those classes become fact-maintained and the rest remain
conservative phase claims. This is still coherent; pretending coarse facts are
exact is not.

## VI. The century-scale invariant

The lasting object is not a faster test cache. It is a program history in which
every current claim has an inspectable reason:

- why this source occurrence denotes this binding;
- why this expression has this type;
- why this interface retained identity across a body edit;
- why this expansion or materialization was rebuilt;
- why this test verdict still covers the current subject;
- why this foreign boundary is trusted only at its seam;
- why this repository did or did not invalidate a consumer in another;
- why this exact fact root was admitted for publication.

Today’s 0.481 ms warm `type-of` query and body-edit consumer skip prove that the
store and compiler can already answer two critical instances of that question
[E3,E4]. Today’s 11×, 9.3×, and 322× results prove the economic value of not
forgetting [E8,E9]. Today’s 420-second gate and duplicated 1,615 CPU-seconds
show the cost of remembering results without a general proof graph [E10]. The
remaining work is not to invent another cache. It is to make retained facts,
their derivations, their invalidation, and their attestations the normal way all
four repositories develop.

FACTS-MODEL-DONE — 7 stages; first-cut seam: `CAF-1 BEAGLE-GATE-PHASE-FACT-MAINTAINER` (first foreign adapter: `GRAFIFY-V1 RACKET-ORACLE-BOUNDARY`).
