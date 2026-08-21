# Code-as-facts gap-closure synthesis

## Ruling

The seven-stage operating model is the correct forward architecture, but it is
not sufficient as written to justify re-enabling the old graph-authoring mode.
Of the eleven archaeology gaps, two already have a complete closure mechanism
in the model and nine require the amendments below. “Closed” and “amended” in
this document are design judgments, not claims that implementation has landed.

The first implementation remains `CAF-1
BEAGLE-GATE-PHASE-FACT-MAINTAINER`. It makes the current Beagle gate maintain
and query facts in shadow mode. It does not make facts the source-edit surface,
does not restore graph-upstream guards, and does not skip an existing gate
phase. The current gate remains the execution oracle and release authority
until dual-run parity earns a later authority change.

The first foreign bridge remains the separate next seam,
`GRAFIFY-V1 RACKET-ORACLE-BOUNDARY`. It must not be folded into the first-cut
lane. The fact maintainer first proves that it can account for the current
gate; the bridge then proves that one opaque foreign phase can be safely
reused.

## Operator design laws

### The agent derives the vocabulary from use

The vocabulary table in the operating model is a map of expected roles, not a
schema to impose in advance. The implementing agent owns the vocabulary and
must derive each fact kind from a concrete use in this order:

1. Observe an existing authoritative operation and preserve its unmodified
   input, output, failure, and fallback behavior.
2. Name the query or maintenance decision that a later cold process must make.
3. Add only the identity and dependency fields needed to answer that query and
   reject a planted stale reuse.
4. Record a real positive event and at least one negative substitution before
   registering the versioned fact kind.
5. Mint a new version when meaning changes; never reinterpret stored bytes.

This is the **Use-Derived Vocabulary Protocol**. A kind with no current
producer, consumer, query, or deciding negative test is speculative and does
not enter V1. A newly encountered need does not get coerced into the nearest
old kind: it emits a fact miss, after which the agent either derives the
smallest new kind from that use or leaves the operation conservative and
always-run.

For the first cut, the required roles are only: exact candidate/source
selection, gate phase claim, phase observation, admitted verdict, fact miss,
and maintenance receipt. The agent determines their final V1 field sets from
the current gate events. Later roles such as native type facts, structural
promotion, foreign boundaries, and garbage-collection summaries enter only
when their own seam is being built and its uses are in hand.

### Every fact miss is a first-class logged event

A fact lookup may yield a current admitted fact, or it must produce a durable
`FactMissEventV1` before fallback work begins. It may never turn an unresolved
route, unopened store, absent input, stale derivation, inadmissible issuer,
unknown fact kind, hidden dependency, or unexplained claim into an empty query
result or a PASS.

Each miss records the requested query or claim, candidate repository revision
and fact root if known, miss class, identities actually observed, verifier and
policy, chosen fallback, and the resulting observation or failure. Diagnostic
time and duration may be recorded but never participate in semantic identity.
The maintenance receipt includes miss counts by class and links every miss to
its fallback outcome. A miss is diagnostic evidence, never a certifying proof.

The day-one human summary must say which facts were retained, rechecked, or
missed and why. Unknown or unclassified misses make the fact path shadow-only.
This rule turns the old “empty graph,” “dead coordinator,” and “tools absent”
states into named evidence at the point of failure.

## Eleven-gap closure table

Status meaning: **CLOSED** means the operating model already names a sufficient
mechanism and deciding evidence. **AMENDED** means the original model did not;
the named amendment in this table is now part of the design and must pass its
acceptance evidence before any relevant mode is enabled.

| # | Observed or open gap | Closure judgment and named mechanism | Required evidence before enablement | Status |
| ---: | --- | --- | --- | --- |
| 1 | Reads silently returned zero facts when `FRAM_CODE_LOG` was set but the read path required `FRAM_LOG`. | Add **A1 — Bound Snapshot Read**. Every read carries an explicit admitted `FactSnapshotId` and resolved Store/Space route. A valid zero-row answer includes a query observation proving that exact root was opened and evaluated. An absent, mismatched, or unhydrated route emits `FactMissEventV1(route-unresolved)` and falls back; it cannot produce rows or a verdict. This specializes the model’s exact snapshot and fail-closed laws at the read API. | Substitute the wrong log, SpaceId, root, and unopened store one at a time. Each produces a durable miss before fallback; none produces a plausible empty fold. Cold reopen of the correct root returns the same query result. | **AMENDED** |
| 2 | Whole-tree source discovery swallowed `docs/private/` and a recovery dump: 280 inputs instead of 51, more than one million facts, and an edit exceeding 20 minutes. | Add **A2 — Source Selection Admission**. The candidate importer first publishes the exact ordered source roots, selected logical files, importer/profile, file count, and byte total derived from the gate’s real source-discovery use. Every discovered file must belong to a named source class; unclassified input is a fact miss. Selection is admitted before projection, so private scratch and recovery dumps cannot silently become program input. | Replay the recorded real-module corpus, add a private recovery dump, move a real source file, and remove a selected file. The receipt exposes all counts and identities; the dump is excluded by an explicit source class, while move/removal changes the admitted selection and invalidates dependents. | **AMENDED** |
| 3 | A sealed graph-authoring capability could be granted while the agent received no usable tools; provider inventory rules also rejected a correct extra server. | Add **A3 — Capability Surface Admission**. After configuration, the agent discovers the actual provider-visible tool names, schemas, versions, and dispatchability, then compares them with the smallest capability set derived from current use. Advertised configuration is not evidence. A missing, extra-but-forbidden, schema-drifted, or undispatchable required verb emits a fact miss and refuses enablement. | Run discovery and one harmless dispatch through every supported provider route. Plant an advertised-but-undispatched verb and an allowed extra server. The first refuses with a named miss; the second is admitted when it does not violate the use-derived policy. | **AMENDED** |
| 4 | Managed lanes exposed tools while pointing them at an empty log, nonexistent worktree-local state, a dead hard-coded port, and missing runtime settings. | Add **A4 — Endpoint Binding Admission**. A capability is mounted only after an active challenge binds repository root, candidate fact root, Store/Space identity, service instance, protocol version, resolved endpoint, and correctness-relevant runtime profile. Endpoint values are discovered from the live service, not copied from a temporary checkout or hard-coded. Any mismatch emits a fact miss and leaves the capability unmounted. | Substitute root, fact root, SpaceId, port, protocol, and runtime profile independently. Each challenge fails with its exact mismatch; the correct lane challenge reads a known fact from the candidate root before tools become visible. | **AMENDED** |
| 5 | Moving repositories left 24 of 25 graph-upstream registry rows stale and silently disabled most source protection. | Add **A5 — Authority Coverage Admission**. Any future authority guard is generated from logical subjects plus the exact current Git commit and source projection; physical paths are routing data, never semantic identity. Before enablement, a receipt proves equality among claimed subjects, current projections, and observed guard decisions. A move invalidates that receipt and forces re-admission. Until equality is re-proved, source remains text-authoritative and no guard is enabled. | Move the checkout/container and rename one logical path in a scratch candidate. The old coverage receipt becomes stale, the new receipt accounts for every claimed subject exactly once, and a planted unmatched row blocks enablement visibly. | **AMENDED** |
| 6 | Daemon command and protocol drift made healthy graph lanes appear dead: a removed command was launched and an old EDN readiness probe spoke to binary FRAMRPC v1. | The model already closes this through **Grafify `BoundaryContractV1` + `BoundaryObservationV1` + `BoundaryVerdictV1`**, conservative foreign-unit identity, and R4/R5 substitution. Command, protocol, SpaceId, request/response schema, runtime, adapter, and readiness behavior are boundary inputs; a changed one invalidates the verdict and re-runs the challenge. Global fact-miss logging makes the failure visible but adds no gap-specific mechanism. | The boundary matrix substitutes command, protocol, schema, runtime, and adapter separately; every substitution rejects reuse. A cold correct observation gives the same readiness verdict. | **CLOSED** |
| 7 | Six advertised inspection tools were undispatched, and a successful edit did not advance the corpus read by the next request. | Combine **A3 — Capability Surface Admission** with the model’s **FactSnapshot publication CAS + MaintenanceReceipt**. Discovery proves every required read verb dispatches. An edit is not successful until its receipt names the newly published candidate root, and every subsequent read is bound to that root under A1. Thus surface completeness and post-edit freshness are separate, both explicit, claims. | Plant an unknown-tool route and a service that returns the prior root after a successful edit. The first fails capability admission; the second fails receipt/root equality. A committed edit followed by a cold read observes the new root and value. | **AMENDED** |
| 8 | Whole-corpus projections rebuilt the full EDB/index per page, stratum, and cold reader; concurrent readers reached a 9.15 GiB RSS crash. | The model already closes this through **S6 Shared Prerequisites**, **S10 Retention and Operations**, and **R6 Store Operations Budget**. Adopt the landed version-keyed single-flight projection cache as the first implementation: one immutable `ProjectionFact` per exact root/materialization is shared by pages, strata, and readers; cold reconstruction and memory remain budgeted evidence, not assumed properties. | One-build/many-consumer traces show one projection derivation per root under concurrent readers; output is byte-identical; corrupt projection rejection, cold replay, peak RSS, and authority-hold time pass the predeclared R6 budget. | **CLOSED** |
| 9 | `bgl/promote` copies one complete supported typed value; no structural projection or fused smaller-survivor copy plan exists. | Add **A6 — Structural Promotion Plan and Receipt**. From the first real partial-survivor use, the agent derives a plan fact naming the source revision/arena, destination revision/arena, selected structural paths, sharing/identity obligations, and required descendants. Promotion fuses selection and copy and publishes a receipt proving that only the reachable survivor crossed. Unsupported shape or ambiguous sharing emits a fact miss and retains the existing whole-value path only when policy admits it. | The W6-G7 corpus compares full-value and structural promotion for selected, shared, cyclic/refused, and omitted-child cases; restart preserves identity and bytes; a planted omitted reachable child refuses publication. | **AMENDED** |
| 10 | Stage 3 proves one authored hydration boundary, not automatic arena-boundary discovery from arbitrary control flow and durability. | Add **A7 — Arena Boundary Decision**. V1 does not claim general inference. The agent records actual allocation, durability, escape, and publication uses and proposes a boundary only where those observations decide it. Otherwise it emits `FactMissEventV1(ARENA-BOUNDARY-UNDECIDABLE)`, requires the bounded explicit boundary, and keeps automatic promotion disabled. The explicit decision and its evidence become queryable facts. | The W6-G8 corpus covers a decidable owned boundary, an escape across revisions, ambiguous control flow, and an explicit fallback. Ambiguity always yields the named miss and never a guessed boundary. | **AMENDED** |
| 11 | Segment GC is semantically correct but decodes every segment for every root, repeats shared-history work, and holds Store/control authority; no scalable budgeted maintenance path exists. | Add **A8 — Incremental Reachability Maintenance**. Derive immutable reachability summaries per segment/root from actual collector queries, memoize shared-history marks, plan outside authority, and hold authority only for a short compare-and-swap of the already proved deletion set. Each run publishes a resumable maintenance receipt with scanned/reused summaries, roots, bytes, pauses, and withdrawals. R6 supplies the measured budget and prevents enablement if it is missed. | Re-run the recorded 10k/50k/100k shapes plus shared-root and interrupted-run cases. Shared history is not decoded once per root, restart resumes without changing the deletion set, a moved root rejects the CAS, and authority-hold time stays inside the predeclared R6 budget. | **AMENDED** |

The amendments are additive to the operating model. They do not revive the old
configuration chain. A1–A5 are the admission constitution needed before any
agent-facing fact mode; A6–A8 close the three later allocation/design gaps at
their own stages.

## Prior-component reuse rulings

| Prior built component | Ruling | Reason |
| --- | --- | --- |
| 1. Lossless program-to-facts projection and rendering | **ADOPT** | Keep the shipped source/fact/source round trip and its Store/compiler identity tests as the exact import/export parity and clean-text escape hatch. Adoption does not make the old fact form an authoring UI or semantic identity. |
| 2. Real Term/Triple fact store and structural code graph | **ADOPT** | Reuse the durable recursive Term/Triple store, cold reopen/query, revisions, and CAS. New gate facts use versioned, domain-separated envelopes; the old codegraph predicates are not presumed to be the new vocabulary. |
| 3. Structured fact-level authoring verbs | **ABANDON** | Do not restore upsert, replace-body, rename, insertion, or multi-module graph transactions as the normal authoring surface. The new model authors exact source text and maintains facts from it. The old verb tests remain archaeological cases only where they supply projection or transaction evidence. |
| 4. One-command `fram-code-on/off/status`, warm coordinator, and reasoning corpus | **ABANDON** | A global flip recreated the fragile multi-process chain and coupled ordinary editing to coordinator health. Authority now advances one admitted seam at a time; there is no repository-wide “on” switch in the migration. |
| 5. Graph-upstream registry, sentinels, and source-edit guard | **ABANDON** | Source remains text-authoritative throughout migration. No old marker or path registry is re-enabled. Any later authority guard must be regenerated and admitted through A5, with the old full gate and text projection still available. |
| 6. Managed sealed agent capability composition | **ADAPT** | Keep sealed least-authority grants and managed-lane composition, but require A3 capability discovery and A4 endpoint challenge through every provider before exposure. Configuration alone no longer proves a usable capability. |
| 7. Commit-time sealed verifier and materialized program views | **ADAPT** | Keep the verifier boundary and next-request visibility goal. Replace mutable “current corpus” state with an exact candidate `FactSnapshot`, verdict admission, a maintenance receipt, A1 root-bound reads, and first-class miss logging. |
| 8. Durable allocation substrate: branch CAS/watch/reseal, reachability GC, and revision generation | **ADAPT** | Keep the landed immutable allocation and CAS mechanisms. Add A6 structural promotion, A7 explicit/decidable arena-boundary facts, and A8 incremental budgeted reachability before treating the substrate as the fleet fact authority. |

## Amended first-cut work order

### Identity and precondition

Work order: **`CAF-1 BEAGLE-GATE-PHASE-FACT-MAINTAINER`**.

Dispatch only after the Beagle v0.24.0 release train has landed and its exact
commit has passed the repository’s local non-publishing preflight. Record that
commit as `BASE_COMMIT` and generate the baseline capability manifest from
mechanisms reachable and green at that commit. Candidate or lane-only work is
not baseline capability.

The worker must implement the Use-Derived Vocabulary Protocol and
`FactMissEventV1` in the first checkpoint, before importing a PASS. The lane is
shadow-only: it may observe and persist old-gate results, but it may not skip a
phase or publish the certified `main` fact route.

### Lane

Create branch `caf-1-gate-phase-facts` in
`~/code/beagle/worktrees/caf-1-gate-phase-facts` from the clean, current
`~/code/beagle/main` after the release landing. Never edit
`~/code/beagle/main`.

### File boundary

The worker may add or edit only:

- `beagle:bin/beagle-test` — additive, opt-in phase observation only. With no
  fact-mode setting, preserve the present lock, command order, execution,
  supervision, output, and exit behavior.
- new `beagle:bin/beagle-test-facts` — the shadow/dual-run entry point; it
  invokes the same existing gate oracle and never substitutes its own test
  semantics.
- `beagle:beagle-lib/private/tier-runner.rkt` — additive machine-readable unit
  observations only; do not change scheduling, sharding, cache eligibility,
  child commands, bounds, or pass/fail classification.
- new `beagle:beagle-lib/private/gate-fact-envelope-v1.rkt` — only fact kinds
  justified by first-cut gate uses, canonical vectors, and miss encoding.
- new `beagle:beagle-lib/private/gate-fact-maintainer.rkt` — exact candidate
  import, phase claim query, observation/verdict admission, cold coverage
  query, and maintenance receipt.
- new `beagle:store/src/store/gate_facts.bclj` and generated-only
  `beagle:store/out/store/gate_facts.clj` — the narrow durable Store adapter;
  do not change the Store kernel, rotation, schema, allocation, GC, or existing
  claim semantics.
- new `beagle:store/tests/gate_facts_test.clj`.
- new `beagle:beagle-test/tests/gate-fact-maintainer.rkt` and
  `beagle:beagle-test/tests/fixtures/gate-facts/**`.
- new `beagle:bin/test/gate-fact-maintainer/run.sh` — the supervised dual-run
  parity and substitution driver.
- `beagle:beagle-test/tiers.rktd` only to register the focused hermetic Racket
  regression.

No other file is in scope. In particular, do not edit graph-authoring verbs,
code-as-facts guards or skills, `bin/_gate-cache-run`, Racket-oracle bundle
construction, compiler inference, native facts, Grafify, repository adapters,
retention/GC, release workflows, North, Greywrought, or Firn. The existing gate
cache may supply observed input-closure evidence, but a cached-green marker is
not itself an admitted verdict and the cache is not modified in this lane.

### Required behavior

1. Observe the current top-level gate phases and tier units at their existing
   execution boundaries. Derive the smallest V1 vocabulary that can identify
   the exact candidate, claim, inputs, verifier/policy, observation, verdict,
   miss, and receipt used by this seam.
2. Run every current gate phase exactly as the old gate would. Import its
   structured result. Shadow mode never skips a command, including on a fact
   hit.
3. Reopen the Store in a cold process and answer whether an identical second
   candidate is fully covered. This is a query demonstration, not authority to
   omit work.
4. On every absent, stale, unknown, inadmissible, or unresolved fact, persist a
   `FactMissEventV1` before running the conservative old phase. Include the miss
   and fallback result in the maintenance receipt and human summary.
5. Keep PASS, FAIL, FLAKY, NOT-RUN, and infrastructure/error observations
   distinct. Only an admitted current PASS can cover a claim; retry never
   rewrites a prior red into green.
6. Do not publish or advance the certified `main` fact route. All facts live in
   an experimental, exact-`BASE_COMMIT` candidate space until a later authority
   work order.

### Verification

Run the lowest deterministic checks first from
`~/code/beagle/worktrees/caf-1-gate-phase-facts`:

```bash
source bin/_beagle-racket
"$RACO" make beagle-lib/private/gate-fact-envelope-v1.rkt
"$RACO" make beagle-lib/private/gate-fact-maintainer.rkt
"$RACO" test beagle-test/tests/gate-fact-maintainer.rkt
bin/beagle check store/src/store/gate_facts.bclj
bin/beagle build store/src/store/gate_facts.bclj store/out/store/gate_facts.clj
store/tests/run_hosted_test.sh 120s env -u BEAGLE_STORE_TELEMETRY_LOG bb -cp store/out store/tests/gate_facts_test.clj
bin/test/gate-fact-maintainer/run.sh
```

The dual-run driver owns explicit per-case/phase deadlines, visible progress,
all child process groups, and cleanup. It runs the current old gate path and
the fact-shadow path against the same exact candidate with the existing gate
cache disabled as evidence for these predeclared cases:

- no-op candidate;
- whitespace-only source edit;
- implementation-body edit;
- public-interface edit;
- test-only edit;
- toolchain/policy substitution;
- selected-file removal.

For every case, compare final exit decision, required phase/unit set, per-unit
status, and aggregate test counts. Reopen the fact store cold before the
coverage query. Separately substitute an unresolved fact route, unknown fact
kind, stale policy, and omitted dependency; each must produce a durable named
miss, run the conservative old phase, and remain ineligible for certification.

Then run the repository’s existing local active gate once on the exact lane
commit:

```bash
bin/beagle-test --active-only
```

Do not lengthen a timeout. A phase or parity case exceeding the fleet’s routine
verification bound is a visible failure to fix or narrow, not a reason to wait
longer. Remote CI is asynchronous confirmation and does not gate this landing.

### Landing bar

Land only when all of the following are true:

- the old `bin/beagle-test --active-only` path remains the default and passes;
- all seven dual-run candidates have identical old-gate and fact-shadow final
  decisions and claim/unit accounting after cold reopen;
- every required claim is accounted for as observed, and shadow coverage has
  no unexplained claim;
- every planted miss is durably logged before fallback and none appears as an
  empty result, retained PASS, or skipped command;
- ordinary non-fact invocation preserves the existing gate’s command order,
  supervision, output contract, and exit classification;
- the fact path remains shadow-only, performs zero authoritative skips, and
  advances no published fact route;
- the focused checks and exact-commit local active gate above pass within their
  existing bounds.

Stage only the enumerated paths, commit a coherent checkpoint, land from the
lane with `safe-push --to main`, fast-forward `~/code/beagle/main`, verify it is
clean and exact, then remove the worktree and delete the local lane branch.

### Rollback

Rollback is immediate and does not depend on Store repair: stop invoking
`bin/beagle-test-facts` and run the unchanged-default `bin/beagle-test` path.
Any mismatch, unexplained claim, Store error, or missing miss event keeps the
fact path shadow-only and the old full gate authoritative.

If a landed defect affects the default path, revert only the enumerated
first-cut files in a new Beagle worktree, pass the old local active gate, and
land that revert through `safe-push`. Experimental facts are immutable
diagnostic data under an unpublished candidate root; rollback removes or stops
routing to that root and does not run destructive GC. Do not restore the old
graph guard, markers, authoring MCP surface, or global activation scripts as a
fallback.

FACTS-SYNTH-DONE closed=2 amended=9
