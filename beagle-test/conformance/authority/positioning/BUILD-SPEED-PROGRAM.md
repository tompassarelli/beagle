# Build Speed Is a Language Feature

Status: design authority for the Beagle build-speed program. This paper defines
outcomes, gates, and dispatch seams; it authorizes no compiler or builder
implementation.

## Intent

> build latency is EXISTENTIAL; the goal is the fastest build time and development loop in the world by a country mile; expressiveness beyond C and Rust with compiled performance in the Common Lisp tradition; incremental compilation; intelligent parallelization; and abusing every facet of the programming system — the Store, facts, canonical encodings — for a stupidly fast loop.

Build speed is therefore a product property, not cleanup work. Native-path
changes do not land merely because they preserve meaning: they must also
preserve the applicable latency and work-count budgets in this paper. Beagle's
standard is an expressive, statically checked language whose development loop
feels like a live Common Lisp image and whose artifacts retain compiled native
performance.

The current forcing fact is a Fram server native build in which C17 emission
took **36m38s (2,198 seconds)**: one single-threaded whole-program pass, with no
incremental compilation and no cache, including on a same-commit rebuild. The
north star is not a percentage improvement on that architecture. It is removal
of whole-program work from ordinary development.

## North-star loops

All limits below are p95 end-to-end latency on the pinned reference system. A
sample starts and stops at the boundaries stated here; moving work outside a
boundary does not make the loop faster. “Verified” means that the artifact or
patch has the expected content identity, complete dependency receipt, compiler
and target pins, and a passing load/behavior probe.

| Loop | Exact boundary | Required cache/process state | Hard gate | Reference and reason |
|---|---|---|---:|---|
| **COLD full artifact build** | Start when a fresh builder accepts the pinned source root; stop when the complete native artifact and manifest are verified and published. | Empty Beagle semantic/native caches and empty C cache namespace; toolchains already installed. | **≤30.0 s** | Go made dependency structure and compilation speed founding product values, compiles against exported package data rather than reopening transitive source, and later made its build cache content-aware. Thirty seconds makes a large clean native artifact interactive instead of ceremonial. |
| **WARM same-commit rebuild** | Start when a fresh build request for the identical source root is accepted; stop when the already-built artifact is re-verified and returned. | Previous successful build and all local content-addressed entries present; no resident coordinator required. | **≤250 ms** | Go's content-aware cache establishes that unchanged inputs should not rebuild. Beagle must go further: the Store already names the root and its proof closure, so warm work should be bounded by root lookup, manifest verification, and response publication—not project size. |
| **INCREMENTAL one-definition artifact rebuild** | Start when the canonical edit fixture for one definition is accepted; stop when the successor complete native artifact is verified and published. | Parent artifact and caches present; no running application is required. | **≤100 ms** | Unison shows that content-addressed definitions make unchanged work structurally unnecessary, while Zig's incremental compilation and in-place binary patching program demonstrates millisecond reanalysis and persistent compiler/linker state. Beagle's target includes the part those examples often omit: a verified runnable successor artifact. |
| **LIVE one-definition process patch** | Start when the same canonical definition edit is accepted; stop when a running Store-backed process acknowledges the new code and a round-trip probe observes the successor behavior. | Resident compiler/patch coordinator and eligible running process present. | **≤5 ms** | Function redefinition into a live Common Lisp image is the fastest existing development loop. Beagle must match its function granularity, beat its ordinary millisecond feel at p95, and retain static proof plus native code. |

### Arithmetic and activation law

The absolute limits are end-state gates, not estimates. Each becomes an
ordinary landing gate only after its named mechanism gates pass on the pinned
fixture. Until then the active stage gate remains binding and the end-state
number remains a reported program failure; staging does not lower or rename the
north star.

| Loop | Arithmetic that must close | Required mechanism and work budget | Active stage and promotion dependency |
|---|---|---|---|
| **COLD full artifact build** | The measured serial C17 emission alone is 2,198 s, so 30 s demands at least **73.3×** before any checking, compilation, linking, verification, or publication is counted. Sixteen workers can supply at most 16×, leaving at least **4.58×** more even if every other stage were free. With 20 s allocated to cold shard emission plus compilation, per-worker useful throughput must improve by **6.87×** over the old emitter. | Empty caches permit no reuse. T0.1 first removes the serial loop. The end state replaces monolithic whole-program C traversal with deterministic definition/SCC work, direct or bounded-fragment native production, no repeated graph walks or textual serialization, and parallel cold compilation. Component budgets are: source decode/check/freeze/facts ≤4 s; all native shard emission and compilation ≤20 s; assembly ≤2 s; verification and durable publication ≤4 s. | **`COLD-EMIT-T0`**: one empty-cache 16-worker emission sample ≤165 s and byte-identical to serial, a 13.3× intermediate demand within the 16× ceiling and the three-minute verification bound. Promote **`COLD-30`** only after T1.4–T1.5 and every component budget pass. The remaining 6.87× per-worker throughput requirement is an explicit dependency, not credit assigned to parallelism. |
| **WARM same-commit rebuild** | The active Tier 0 limit of 60 s to 250 ms is a further **240×** reduction. No faster compiler can supply that reliably; the compiler, emitter, linker, and artifact byte scan must execute zero work. | The exact source/compiler/target key resolves one immutable authenticated-storage root: the admitted artifact digest plus filesystem-verity root. Reverification reads a bounded Merkle manifest, verifies that root metadata and its prior load/behavior attestation for the same digest and pins, and relies on verity checking when artifact pages are later read; it does not rescan or reload the artifact. Budgets are: lookup/decode ≤50 ms; receipt and root verification ≤100 ms; response publication ≤50 ms; 50 ms headroom. Bytes read and facts visited are bounded independently of project size. | **`WARM-T0`** remains <60 s with zero emission misses. Promote **`WARM-250`** only after **`WARM-O1-VERIFY`** proves zero compiler phase work and the bounded lookup/receipt work counts. |
| **INCREMENTAL one-definition artifact rebuild** | The 100 ms envelope already spends 30 ms on assembly. It closes only if all other work is limited to the exact changed definition/SCC and its proved caller cone. | Exact admitted receipts avoid unchanged work; phase-addressed cache hits avoid unchanged phases; one native shard is rebuilt; persistent assembly changes only its reserved region; Merkle publication avoids whole-artifact hashing. Budgets are: delta and invalidation ≤10 ms; check/freeze/lower/shard production ≤35 ms; assembly ≤30 ms; durable verification/publication ≤20 ms; coordinator ≤5 ms. | **`INCREMENTAL-SHADOW-EQUALITY`** first proves work count, cold equality, and publication without authorizing reuse. Promote **`INCREMENTAL-100`** only after the ruled shadow gates, Store FLIP, exact bidirectional caller-cone and fact-family/consumer-edge cutover gates, and T1.1–T1.7 component budgets pass. |
| **LIVE one-definition process patch** | The 5 ms envelope has no room for the 10 ms coordinator allowance formerly used by the artifact path. Patch production at 2 ms and installation at 1 ms leave only 2 ms for semantic delta, eligibility, acknowledgement, and the observed round trip. | LIVE uses a separate resident in-memory fast path: predecoded exact receipts; semantic delta plus eligibility ≤1 ms; direct native patch production ≤2 ms; private canary plus atomic epoch publication/acknowledgement ≤1 ms; successor round-trip probe ≤1 ms. It may not invoke a C compiler, linker, filesystem, general artifact coordinator, or cold Store query. | **`LIVE-PILOT-CORRECTNESS`** first proves eligibility, epoch safety, rollback, and successor behavior with latency reported but not excused. Promote **`LIVE-5`** only after all four component budgets pass independently. The direct ≤2 ms native-code path is unproven until measured; Common Lisp and Zig are mechanism references, not arithmetic evidence. |

The **Rust anti-goal** is architectural, not rhetorical: Beagle must never accept
double-digit-second local edits, crate/codegen-unit-sized invalidation, or an
incremental mode whose bookkeeping can cost nearly as much as the work it
avoids. Rust's red/green query system is serious prior art, but its own compiler
guide records persisted session graphs, fingerprinting cost, whole codegen-unit
fallback, and expensive opaque backend work. Beagle uses that as the negative
control: no coarse invalidation unit and no opaque native tail may dominate a
one-definition edit.

The four loop names are contractual vocabulary. A fast typecheck is not an
INCREMENTAL result; a cache lookup that does not return a verified artifact is
not WARM; compiling a patch without safely installing and probing it is not
LIVE.

## Measurements

This is the permanent results table. Tier 0 owners replace only the `PENDING`
cells and attach the measurement receipt; no section or metric is added after
results are known.

| Measurement | Fixed configuration | Observed wall time | Work/identity result | Receipt |
|---|---|---:|---|---|
| Serial C17 emission baseline | Fram server native build; 1 emitter worker; whole program | **36m38s** | No incremental reuse; no cache reuse | Commander-verified baseline |
| Parallel C17 emission | Same source/compiler pins; 4 workers | **PENDING** | Output SHA-256 versus serial: **PENDING** | **PENDING** |
| Parallel C17 emission | Same source/compiler pins; 8 workers | **PENDING** | Output SHA-256 versus serial: **PENDING** | **PENDING** |
| Parallel C17 emission | Same source/compiler pins; 16 workers | **PENDING** | Output SHA-256 versus serial: **PENDING** | **PENDING** |
| Builder cache, first population | Same source/compiler pins; cold emission cache and cold ccache namespace | **PENDING** | Emission misses/hits and C misses/hits: **PENDING** | **PENDING** |
| Builder cache, same-commit rebuild | Same source/compiler pins; populated emission cache and ccache | **PENDING**; Tier 0 gate **<60s** | Emission misses must be 0; unexplained fallback must be 0 | **PENDING** |
| Builder cache key perturbation | Change source digest, then compiler pin, one at a time | **PENDING** | Each change must cause its named miss and no false hit | **PENDING** |

Every receipt records source root, compiler object, target, flags, worker count,
machine profile, cache state, stage wall time, stage instructions, peak memory,
hit/miss counts, miss reasons, and final artifact digest. Parallel results are
invalid unless the 4-, 8-, and 16-worker emitted bytes are each identical to
the serial bytes.

### Wildcard referral latency discrimination — 2026-08-18

This controlled measurement did not confirm a wildcard-referral compiler cost.
The semantic source was the current Racket oracle emission for the native Core
closure; the timing probe loaded one emitted `native.body-slice` module and its
13-module dependency tree with Babashka, the available downstream Clojure
compiler/runtime. The post form was the current 204a96d0 output. The pre form
was made by the exact parent-commit normalization: `[native.core :as core
:refer :all]` plus the generated 251-record `(import '[native.core ...])`
line. Both forms compiled/loaded successfully with the same invocation.

Six alternating runs were `post, pre, pre, post, post, pre`. Post wall times
were 1.029, 0.984, and 0.969 seconds; pre wall times were 1.011, 1.044, and
1.036 seconds. Means were post **0.994 s** and pre **1.030 s**, a pre/post
ratio of **1.037×**. Every timing records load before and after; load was
5.10–5.20 / 5.11–5.13 / 5.83–5.84 (1/5/15-minute fields) on 24 CPUs, with
about 74–76 GiB MemAvailable. Receipt: `/tmp/beagle-refer-all-cost-20260818/control/ab-repeats.receipt`;
the exact pre/post trees are under `/tmp/beagle-refer-all-cost-20260818/`.

The result refutes the claimed >20× wildcard effect for this emitted module
and downstream compiler path; the competing contention explanation is also
not needed to explain this controlled result. No scaling experiment was run
because there was no A/B effect to characterize. Emission policy implication:
this measurement alone does not justify a wildcard-referral ban or a latency
discouragement rule, although the Beagle source parser continues to reject
`:refer :all` and the current native output emits zero wildcard referrals.

### Compiler concurrency cliff — 2026-08-18

This measurement used the calibrated `body_slice` oracle compilation, whose
quiet-machine reference is **203 s**, with distinct output files, all compiler
processes at `nice 19`, and a one-second sampler. The exact command shape is
the one in `/tmp/beagle-seam2-parity-tail-20260818/control/oracle-invocations-clean.receipt`.
Receipts for this run, including context snapshots, per-process timing, process
RSS/I/O samples, and safety-stop records, are under
`/tmp/beagle-concurrency-cliff-20260818/`.

| Concurrent compilations | Total wall | Per-process mean | Slowdown vs 203 s quiet baseline | Result and resource bounds |
|---:|---:|---:|---:|---|
| 1, first baseline | **208 s** | **208 s** | **1.02×** | Complete; peak compiler RSS 596,856 KiB; max load 11.32; minimum MemAvailable 66.7 GiB |
| 2 | **211 s** | **210.79 s** | **1.04×** | Complete; peak RSS 532,480/533,736 KiB; aggregate peak 1.02 GiB; max load 13.36; minimum MemAvailable 66.0 GiB |
| 4 | **≥269 s** | **≥269 s** | **≥1.33×** | Censored by the machine-law stop at load 36.04; all four processes were killed at status 143; aggregate peak compiler RSS 1.86 GiB; minimum MemAvailable 47.5 GiB |
| 8 | — | — | — | Stopped before a timing result because load was already 36.04 after the level-4 stop; safety receipt records load 37.98 |
| 16 | — | — | — | Stopped by the same load guard; safety receipt records load 37.98 at admission and 45.08 at cleanup |
| 1, required last baseline | — | — | — | Not launched: after the level-4 stop, a bounded 120 s recovery watch still saw load 38.50, so launching it would violate the load ceiling |

The first baseline and level 2 are valid completed compiler results. The last
baseline is explicitly censored by live-work load; no value is substituted for
it. The host was not quiet: the context receipts show live Bun tests, `raco
make -j 24`, Babashka native jobs, and other Beagle/Greywrought workers. None
were killed or altered.

The dominant saturating resource was **CPU run-queue capacity**. A single
compiler used 99% of one CPU, and both level-2 compiler processes also used
99%; the compiler is not internally multi-threaded, so process concurrency
consumes roughly one CPU per worker. At level 4, each compiler accumulated
about 209–221 CPU seconds during the 269-second censored run while system load
crossed the 36-on-24-core bound. This is oversubscription against the live
worker population, not a lock that serializes the first two compilers.

Memory capacity was not the hard ceiling: a compiler peaked at only 0.52–0.60
GiB, the four-process observed peak was 1.86 GiB, and MemAvailable stayed at
least 47.5 GiB. I/O and page-cache pressure became a secondary symptom at
level 4: each compiler read about 288–333 MiB from storage and system swap-out
advanced by 2,195,283 pages while swap used rose by about 6.2 GiB. Levels 1
and 2 had no comparable physical-read delta. The receipts do not prove or
exclude a higher-concurrency shared lock because machine-law load stopped the
4-process run first; they do rule out memory capacity as the primary cause
and show CPU/run-queue contention as the first measured cliff.

Two immediate fleet rules follow. **SAFE CONCURRENCY for bounded verification
gates is 2**: the completed level-2 per-process mean is 1.04× the quiet
baseline. **The point of diminishing returns for parallel build work is 2**:
going from one to two workers changed total wall from 208 s to 211 s rather
than reducing it, and the next tested level did not finish before the load
guard. These are conservative rules for the observed live-worker regime and
should remain in force until an isolated quiet-host run earns a higher limit.

## Why Beagle can win by a country mile

### 1. Facts turn invalidation into a proof

The declared-interface and fact-publication design in
`~/code/todo/beagle-program-handoff/positioning/TYPES-AS-FACTS-DESIGN.md`
owns the semantic/interface identities, declared-contract refinement,
exact type-check read receipts, and caller-cone authority. Its ruled shadow
authority remains candidate-only until the strengthened parity, receipt, and
bidirectional-cone gates pass. This build program must consume those outputs
rather than implement a second encoder, interface publisher, or semantic
caller-cone planner.

Once those decisions and gates pass, a changed definition first invalidates
its implementation derivation. Its provider is re-frozen against the declared
interface. Consumers record exact reads of value, type, constructor, macro,
profile, obligation, representation, ABI, codec, and other facets. If the
provider's outward facet bytes are unchanged, propagation stops. If a facet
changes, only views whose receipts name that facet enter the caller cone; each
consumer again stops propagation when its own outward facets are unchanged.

This is the least fixed point of changed canonical facets over exact read
edges. With complete receipts it is the provably minimal sound rebuild set, not
a heuristic “probably affected” set. An unrecorded or dynamic read is never
guessed safe: missing declarations, facets, conformance, receipts, or validators
remain `UNCUT` and fail closed to a conservative rebuild. Exactness is earned,
not assumed.

Ruled type-system decision **3**, the declared-interface transition, is the
load-bearing cutoff: the existing
`beagle:beagle-lib/private/module-interface.rkt` publication path must consume
a Beagle-native declared contract with an exact public export set and a proof
of refinement before it can mint facets. It must not create a competing
interface authority or require inferred-type identity. Ruled decision **2**
owns the exact per-definition and SCC identities, envelopes, encoders, and
source facets. Tier 1 adds only separately typed native-phase reads for
lowering, specialization, emission, linking, and materialization. Before
shadow authority's ruled gates, Store FLIP, and exact per-family/consumer-edge
cutover pass, all resulting plans and cache-hit proposals are shadow evidence:
the cold compiler remains authority and every build still executes the cold
path.

### 2. Canonical encodings turn a cache hit into a proof

A timestamp cache asks whether inputs look unchanged. Beagle can ask whether
the computation has the same semantic identity. Every reusable result is keyed
by a canonical definition or recursive-SCC encoding whose dependency references
are themselves canonical identities, plus the exact interface-view root,
semantic profile and attestation epoch, compiler pin, target/ABI, backend and
optimization policy, and phase schema. Conceptually:

```text
PhaseKey = H(phase-schema,
             canonical-definition-or-SCC,
             exact-read-root,
             compiler-pin,
             semantic-profile-and-attestation-epoch,
             target-ABI,
             backend-and-options)
```

The value stored under that key contains its output digest and complete read
receipt. On lookup, equality of the key and receipt proves that the cached bytes
are the result for these exact inputs. There is no mutable “valid” bit, mtime
window, path identity, or best-effort dependency scan. Corrupt bytes fail their
digest; an unsupported schema or missing dependency is an explained miss.

The identity is phase-specific. Certified type facts do not silently authorize
lowering; lowered IR does not silently authorize codegen; codegen does not
silently authorize linking or runtime materialization. Each phase publishes
and reads its own fact class. Only successful certified results enter the
artifact cache. This preserves the fact-publication rule that a failed check
publishes no certified type facts and that every fallback has exactly one named
prior miss.

That proof is not authority by itself. A cache may be populated and checked in
shadow, but a hit derived from new semantic facts may skip work only for a fact
class and cohort activated under the types paper's FLIP law. Tier 0's
whole-source emission and C-object caches do not consume those proposed facts:
their keys conservatively include the complete source root, compiler, target,
flags, and phase schema, so any source change misses.

Unison's codebase demonstrates the structural prize: definitions identified by
hash can be parsed and checked once, unchanged dependencies are exact, and
cached pure results need not be rerun. Beagle adds declared semantic interfaces,
native artifacts, and Store admission to make the same argument through the
whole compiled pipeline.

### 3. The Store makes LIVE replacement safe

The two-regime doctrine is the decisive advantage over mainstream hot reload.
Durable semantic state belongs to the Store; native code is a replaceable
materialization. A patch therefore never needs to reinterpret an authoritative
object graph hidden inside the old process. Native memory may contain stacks,
scratch values, caches, and handles, but no state whose loss or reinterpretation
would change durable semantics.

LIVE is sound only while all of these falsifiable invariants hold:

1. **Store authority:** every durable mutation is an admitted Store transaction;
   process-local mutable state is explicitly transient, reconstructible, and
   absent from the patched definition's semantic result. A cache, request
   context, lease, or buffer that can change an admitted result is not
   discardable and rejects LIVE without an explicit handoff proof.
2. **Canonical boundary:** values crossing the boundary use a versioned
   canonical codec and nominal type/shape identity. Native code never persists
   raw pointers, object layouts, closures, or target-specific bytes as semantic
   state.
3. **Stable handles:** native references to durable values are Store IDs plus
   an epoch/version, never addresses into mutable Store or process storage.
4. **Patch eligibility:** the declared interface, calling convention, ABI,
   layout/opacity facets, codec, effects, capabilities, failure behavior,
   synchronization, and semantic profile read by live callers are byte-identical.
   Any changed facet rejects LIVE and selects INCREMENTAL restart or an explicit
   migration.
5. **Complete code closure:** the patch manifest names the new code digest,
   exact dependency/read closure, compiler pin, target, stack maps, unwind data,
   and runtime support identities; every item is present and verified before
   publication.
6. **Complete code-pointer census:** stack frames, return addresses, recursive
   calls, closures, callbacks, vtables, exception edges, GC stack maps, unwind
   records, foreign trampolines, and signal handlers are either enumerated by
   the runtime or make the patch ineligible. Unknown pointer provenance is
   restart, never LIVE.
7. **Epoch-pinned in-flight execution:** installation occurs at a proved
   quiescent safepoint, or every activation carries a code-root epoch and all
   nested/recursive/callback calls from an old activation continue through the
   old closure. Redirecting an old frame into new code is forbidden. Old code
   and metadata remain mapped until the last old activation and callback drain.
8. **Effect quiescence:** no in-flight external effect, foreign call, lock,
   continuation, or capability lease crosses the swap unless its unchanged
   interface facet explicitly defines safe handoff.
9. **Atomic epoch switch:** code-root publication and call-target redirection
   are one observable transition. Threads see the complete old closure or the
   complete new closure, never a mixture.
10. **Initialization discipline:** module and resource initialization is not
   rerun by a body patch. A requested initialization change is a migration or
   restart, not LIVE.
11. **Prepare-probe-publish:** the new closure is built and verified off-side;
    its successor probe runs through a private epoch against a read-only or
    aborting Store transaction; ordinary traffic cannot enter it. Only a passing
    probe permits one atomic publication. Failure before publication discards
    the closure and cannot leave a Store mutation, call target, or metadata
    change behind.
12. **Bounded rollback:** the previous verified code root remains addressable
    through acknowledgement. A failure after target publication but before
    acknowledgement blocks new entrants, restores the prior root atomically,
    and waits for any successor frames to drain. General rollback after
    successor code has committed durable effects is not claimed; such code
    requires an independently proved transactional handoff or is restart-only.

These constraints do not claim arbitrary hot swapping is safe. They define a
small proof-carrying eligibility envelope whose fast path is exceptionally
strong because durable state is already outside the native image. The first
envelope is pure body-only replacement with byte-identical interface, ABI,
layout, codec, effect, profile, stack-map, and initialization facets. Runtime
enumeration of every native/foreign code pointer, epoch-pinned recursive calls,
effectful handoff, failure atomicity under concurrency, and the ≤1 ms
install/rollback bound remain unproven until T2's falsifiers pass; the Store
doctrine alone does not prove them.

### 4. Whole-program emission is parallel work wearing a serial loop

Once definitions are normalized, the emitter partitions the reachable graph
into deterministic definition or recursive-SCC units. Each worker is a pure
mapping from a canonical unit plus pinned inputs to a C fragment and metadata.
Workers share no output stream and allocate no order-sensitive names. A single
merge sorts fragments, declarations, symbols, and metadata by canonical ID.
Paths, timestamps, hash-map iteration, scheduling order, and worker count cannot
enter emitted bytes.

That makes emission embarrassingly parallel and cacheable, but parallelism
alone cannot close COLD arithmetic: even perfect 16-way scaling leaves 137.4 s
of the measured emission. The serial remainder is graph finalization plus
deterministic merge; its measured fraction becomes the next explicit
bottleneck, while `COLD-30` also requires the per-worker throughput mechanism
and component budgets above. Byte identity between 1, 4, 8, and 16 workers is
the correctness gate, not “equivalent C.”

## Staged roadmap

The numbered types-paper decisions 1–5 are ruled dependencies, not an open
queue or an execution order. Their execution order is the adopted types DAG:
identity/encoding, canonical values, evidence hooks, and the internal
no-bypass commit boundary; then shadow candidate production and diagnostics;
then normalization of existing effects/allocation/failure/capability/profile
contracts; then declared module contracts, exact export sets, and refinement;
then fact-family and consumer-edge authority cutover; then deferred tails.
`Tn.m` refers to a build seam below.

The types program exclusively owns those semantic products: the identity split
and kind encoders, canonical values and layout split, evidence hooks and
commit boundary, strengthened shadow gates, diagnostics, existing-contract
normalization, and Beagle-native declared-contract refinement with exact
export sets. This program consumes those products and owns only native-phase
receipts, native work selection, artifact production, and runtime patching.
Native facts may populate and compare in shadow, but no hit may skip work
before the ruled shadow gates, Store FLIP, and fact-family/consumer-edge
authority cutover. Unknown effect, value, proof, admission, or native-read
evidence remains conservative. General Tier 2 eligibility consumes both the
ruled normalized effects slot and the ruled canonical value encoding/layout
split; the first pure, unchanged-codec pilot admits no unknown.

There are **14 roadmap seams**: three Tier 0 seams, seven Tier 1 seams, and four
Tier 2 seams. Splitting emission reuse from C-object reuse removes the former
two-cache owner. Removing duplicated types-owned canonical/interface machinery
from Tier 1 removes duplicated types-program machinery. Each row has one exclusive
component surface and one focused gate. A dispatch brief must enumerate its
exact files; concurrent seams may not share a file or gate. If implementation
layout violates that boundary, the affected rows merge before dispatch rather
than assigning two workers to one surface.

The former in-flight T0.2 is the source of both new cache seams. Its current
owner retains them serially until it explicitly hands one off; the split does
not silently create a second owner for live work.

### Tier 0 — stop paying the known whole-program bill

| Seam | Outcome | Named gate | Dependencies | Exclusive owner surface |
|---|---|---|---|---|
| **T0.1 Deterministic parallel emission** *(in flight)* | Whole-program C17 emission uses all useful cores without changing output. | **`T0-PARALLEL-BYTE-IDENTITY`**: record 4/8/16-worker stage times; every emitted byte equals serial; **`COLD-EMIT-T0`** requires one empty-cache 16-worker sample ≤165 s. | Current native emitter. | Emitter unit partition, worker execution, and canonical ordered merge; one owner because byte identity is their shared invariant. |
| **T0.2 Content-addressed emission reuse** *(in flight)* | An identical complete source/compiler/target key executes zero emission. | **`T0-EMISSION-CACHE`**: zero emission misses on same-commit rebuild; each source/compiler/target/schema perturbation yields its named miss; hit bytes equal cold emission. | T0.1 byte identity. | Builder emission-cache key, entry, lookup, and miss ledger only; no C-object cache or semantic-fact reuse. |
| **T0.3 C-object reuse** *(serialized continuation of former in-flight T0.2)* | Identical emitted fragments execute zero C compilation through the existing C cache namespace. | **`T0-C-OBJECT-CACHE`**: zero unexplained C misses, named miss on fragment/toolchain/flag perturbation, and final artifact equals cold; combined T0.2–T0.3 **`WARM-T0`** is <60 s. | T0.1 emitted bytes; current C toolchain pin. | Builder C-cache namespace and compiler invocation only; no emission-cache keying. |

### Tier 1 — exact one-definition native artifacts

| Seam | Outcome | Named gate | Dependencies | Exclusive owner surface |
|---|---|---|---|---|
| **T1.1 Native-phase read receipts** | Lowering, specialization, emission, linking, and materialization record domain-separated reads against types-owned identities. | **`NATIVE-READ-RECEIPTS-SHADOW`**: one mutation per native facet changes exactly the reading receipt; missing or dynamic reads are `UNCUT`; the cold build still runs and agrees. | Types identity/encoding, canonical values, evidence hooks, and commit boundary; then shadow/diagnostic gates, existing-contract normalization, and declared-contract refinement/export set. | Native compiler/build instrumentation and native receipt schemas only; no semantic encoder, interface conformance, planner, or cache. |
| **T1.2 Exact native rebuild plan** | A build plan combines the types-owned caller cone with native-phase reads and names one reason for every selected unit. | **`NATIVE-CONE-ORACLE`**: cold-oracle fixtures have zero false negatives, zero false positives for fully cut graphs, exact direct/transitive cones, and one `UNCUT` cause for every conservative expansion. | T1.1; types-owned bidirectionally exact cone and fact-family/consumer-edge cutover; Store FLIP only for authority. | Native work-plan query and explanation receipt only; no graph identity or execution scheduling. |
| **T1.3 Phase-addressed native cache** | Check/freeze outputs already authorized by their owner, plus lower, specialize, emit, and compile results, are independently addressable. | **`NATIVE-PHASE-CACHE`**: every hit re-verifies digest and receipt; one perturbation per key dimension yields one named miss; shadow mode compares but skips no work. | T1.1–T1.2; ruled shadow gates and fact-family/consumer-edge authority cutover for authoritative hits. | Native phase cache schemas, lookup, and miss protocol only; no shard production or artifact assembly. |
| **T1.4 Definition/SCC native shards** | Selected units emit and compile independently into deterministic object/code shards; cold work uses the same units without reuse. | **`NATIVE-SHARD-EQUIVALENCE`**: a body edit rebuilds exactly the selected SCC set; clean shard union exposes identical symbols, code, stack maps, and metadata; cold shard production fits its 20 s budget. | T0.1, T1.2–T1.3. | Shard ABI, stable symbols, and per-shard native/C production only. |
| **T1.5 Deterministic artifact assembly** | A successor executable is assembled without a whole-program relink, while cold assembly uses the same canonical layout. | **`INCREMENTAL-ASSEMBLY-30`**: one-definition assembly ≤30 ms p95; successor bytes equal cold, or canonical digest-covered padding explains the only reserved difference; cold assembly ≤2 s. | T1.4; target linker/materializer. | Persistent link state, replacement layout, canonical finalization, and artifact digest only. |
| **T1.6 Resident artifact coordinator** | One state machine accepts a root delta, asks T1.2 for work, invokes eligible workers, and commits one complete artifact publication. | **`RESIDENT-ARTIFACT-COORDINATOR-5`**: coordinator overhead ≤5 ms p95; ready work never waits behind an idle eligible worker; cancellation publishes nothing and reaps every worker. | T1.2–T1.5. | Artifact request/scheduling/publication state machine only; it treats planner, cache, shards, and assembler as stable interfaces. |
| **T1.7 Incremental equivalence and authority** | Shadow dual builds prove equality before one admitted cohort may use native reuse. | **`INCREMENTAL-SHADOW-EQUALITY`**: work counts, artifact/manifest, and behavior equal cold with no unexplained fallback. After the ruled shadow gates, Store FLIP, fact-family/consumer-edge cutover, and all budgets pass, **`INCREMENTAL-100`** is ≤100 ms p95 and rollback disables reads without deleting evidence. | Types per-family/consumer-edge authority cutover; Store FLIP; T1.1–T1.6. | Comparison receipts, cohort switch, and fail-closed reuse rollback only; no compiler or cache implementation. |

### Tier 2 — verified code replacement in a running Store-backed process

| Seam | Outcome | Named gate | Dependencies | Exclusive owner surface |
|---|---|---|---|---|
| **T2.1 LIVE eligibility proof** | A patch manifest proves all twelve Store/native invariants and classifies the edit as LIVE, restart, or migration. | **`LIVE-ELIGIBILITY`**: the pure body fixture is admitted; one mutation falsifies each invariant with its exact facet/reason; unknown is never LIVE. | T1.1–T1.4; ruled effects-slot normalization and canonical value encoding/layout split, both consumed at this LIVE boundary; invariants above. | Eligibility schema and proof checker only; one falsifier per invariant is the shared gate corpus. |
| **T2.2 Patchable code and metadata** | Eligible definitions compile directly to replaceable code with stable epoch-aware indirection and complete GC/unwind metadata. | **`LIVE-PATCH-2`**: patch production ≤2 ms p95 after predecoded semantic facts; old/new targets pass direct, recursive, callback, exception, GC, foreign-trampoline, and code-pointer census fixtures. | T1.4, T2.1; target runtime. | Direct patch codegen, slots, stack maps, unwind records, and target execution fixtures only. |
| **T2.3 Atomic epoch installation** | Runtime prepares a private epoch, probes it without durable effects, publishes one code root, drains old/new frames correctly, and rolls back before acknowledgement. | **`LIVE-INSTALL-1`**: private probe plus install or rollback ≤1 ms p95 at the fixture safepoint; stress sees no mixed epoch, old-to-new recursive edge, lost Store transaction, or retired live metadata. | T2.1–T2.2; runtime scheduler and Store transaction boundary. | Safepoint/quiescence, epoch switch, retirement, and rollback transaction only; no editor protocol or codegen. |
| **T2.4 LIVE loop service and gate** | A resident edit request, eligibility proof, patch, acknowledgement, and successor round trip form one supervised in-memory loop. | **`LIVE-PILOT-CORRECTNESS`** first requires successor behavior and old-process validity on every injected failure. **`LIVE-5`** then requires ≤5 ms p95 and each 1/2/1/1 ms component budget. | T1.1 native receipts, T2.1–T2.3; not T1.6's artifact coordinator. | Resident request/probe protocol, end-to-end fixture, stage telemetry, and gate integration only. |

## Repository build-latency gate

The required local gate is named **`native-build-latency`**. It gates every
change on the native compiler, checker/freeze path consumed by native builds,
emitter, native builder, cache schema, Store build facts, runtime materializer,
or native linker at the highest stage whose dependencies have passed. It is
named before release and is part of the ordinary native landing gate, not a
post-merge dashboard. The gate runs once for the exact candidate commit; a
valid red result is never rerun into green.

The manifest records one active stage per loop. Promotion is an enumerated
manifest change that may land only with the predecessor receipt:

| Loop | Active pre-promotion gate | End-state promotion |
|---|---|---|
| **COLD full artifact build** | **`COLD-EMIT-T0`**: one empty-cache 16-worker emission sample ≤165 s plus `T0-PARALLEL-BYTE-IDENTITY`. | **`COLD-30`** after T1.4–T1.5 and the 4/20/2/4 s component budgets pass. |
| **WARM same-commit rebuild** | **`WARM-T0`**: <60 s, zero emission misses, zero unexplained C misses, artifact equals cold. | **`WARM-250`** after `WARM-O1-VERIFY` proves bounded manifest work and zero compiler/link/load-probe work. |
| **INCREMENTAL one-definition artifact rebuild** | **`INCREMENTAL-SHADOW-EQUALITY`**: exact work counts, durable successor publication, cold equality, no skipped work. | **`INCREMENTAL-100`** after the ruled shadow gates, Store FLIP, exact bidirectional cone and fact-family/consumer-edge cutover gates, and T1.1–T1.7 budgets pass. |
| **LIVE one-definition process patch** | **`LIVE-PILOT-CORRECTNESS`**: all eligibility/concurrency falsifiers and successor behavior, with latency always reported. | **`LIVE-5`** after `LIVE-PATCH-2`, `LIVE-INSTALL-1`, and the two remaining 1 ms component budgets pass. |

An inactive end-state gate remains a required program exit criterion and is
reported as not yet qualifying. It does not masquerade as a landing failure
before its mechanism exists, and an active stage cannot be relaxed to absorb a
miss.

### Pinned workload and stimuli

One checked manifest defines `fram-server-native-v1`: exact source object,
compiler object, dependency closure, target triple and ABI, C toolchain pin,
optimization/profile flags, canonical environment, expected clean artifact
digest, and machine class. It also contains four immutable stimuli:

- COLD: distinct empty named Beagle semantic/native and C cache roots for every
  sample. The only prior inputs are the pinned source/compiler/toolchain; no
  generated interface, shard, manifest, or verification receipt for that source
  may be imported;
- WARM: the exact successful COLD roots and unchanged source identity;
- INCREMENTAL: a one-definition body edit whose declared outward facets remain
  unchanged, plus its expected successor root and behavior;
- LIVE: the same definition and successor behavior in a pinned Store snapshot
  and running process scenario.

Artifact publication means write to the dedicated local filesystem, file
`fsync`, atomic rename into the CAS namespace, and directory `fsync`; all four
steps are inside COLD and INCREMENTAL, and admission records the artifact's
filesystem-verity root. WARM verifies that immutable root, the bounded Merkle
manifest, and the prior probe attestation without rescanning artifact bytes.
LIVE uses a pre-opened local transport between a probe task and process task
pinned to different reserved physical cores; its acknowledgement and second
request/response behavior probe are both inside the boundary.

No public network, semantic wall clock, random seed, user directory, ambient
daemon, or unversioned system library may affect correctness or work count.
Latency uses `CLOCK_MONOTONIC_RAW` only.

### Measurement isolation and variance law

Instruction count is the primary regression measure for deterministic compiler
work. End-to-end wall time remains a hard product limit. The supervisor reserves
the exact physical CPU IDs and their SMT siblings recorded by the machine-class
manifest, places every gate task in that exclusive cpuset/cgroup, fixes the
performance governor, and reserves a preallocated benchmark filesystem. LIVE's
process and probe each have a distinct recorded physical core. No unrelated
task may enter the cpuset and no other build or benchmark may use the benchmark
filesystem during a sample set.

The preflight and continuously checked run bounds are fixed here: one-minute
load ≤0.75 × online logical CPUs, `MemAvailable` ≥16 GiB, CPU steal delta =
0, thermal-throttle delta = 0, benchmark-cgroup throttle delta = 0, benchmark
task CPU migrations = 0, and storage reset/timeout/thermal-warning delta = 0.
For WARM, INCREMENTAL, and LIVE timed regions, major faults and involuntary
context switches on the timed critical tasks must also be 0. The benchmark
filesystem monitor must observe no writer outside the gate cgroup. A violation
invalidates the complete sample set visibly; no individual sample is dropped or
replaced. High wall time alone never invalidates a run: when counters and work
counts are valid, it is an attributable product failure.

After `COLD-30` promotion, the exact order is preflight, five independent COLD
samples, two uncounted correctness/fixture-validation iterations for each fast
loop in disposable successor state, forty WARM samples against the last
verified COLD root, forty INCREMENTAL samples each reset to the identical parent
artifact, and two hundred LIVE samples each reset to the identical parent
process/Store snapshot. The reported nearest-rank p95 is sample 5 of 5 for
COLD, 38 of 40 for WARM and INCREMENTAL, and 190 of 200 for LIVE. Validation
iterations can fail correctness but can never replace a measured sample or warm
state forbidden by that loop's definition. Before promotion,
`COLD-EMIT-T0` runs exactly one measured sample under its 165 s deadline.

A valid lane must have per-stage instruction-count spread
`(max-min)/median ≤1%`. The gate fails when any loop exceeds its active
absolute p95 limit, any stage exceeds its checked instruction budget by more
than **2%**, or the total instruction count exceeds its checked budget by more
than **1%**. For INCREMENTAL, publication byte count, `fsync` count, and selected
definition/SCC count are fixed manifest work counters; for LIVE, transport
wakeups, epoch switches, patched definitions, and probe round trips are fixed.
Budget changes require an enumerated manifest edit and an explanation tied to
changed legitimate work; a baseline refresh cannot accompany an unexplained
regression.

The gate does not retry a valid product failure. One bounded diagnostic rerun
may classify an invalid environment, and both results remain in the receipt; a
valid red diagnostic still cannot qualify the commit. Sample counts are capped
so the complete end-state gate fits the machine's 2–3 minute verification law:
at the limits, measured samples consume 165 s. Before `COLD-30`, Tier 0 runs the
active `COLD-EMIT-T0` benchmark in its separately bounded lane rather than
silently extending the ordinary landing gate.

### Mandatory stage report

Every run prints, in order, wall time, instructions, cache hits/misses, miss
reasons, scheduled definition/SCC count, and critical-path worker occupancy for:

1. source-root discovery and canonical decode;
2. parse/expand;
3. typecheck and FREEZE;
4. fact publication and interface conformance;
5. invalidation planning;
6. lowering and specialization;
7. native/C emission;
8. C/object compilation;
9. link or incremental assembly;
10. artifact verification and publication;
11. LIVE eligibility, safepoint, installation, retirement, and probe when
    applicable.

Failure names the first exceeded stage, its absolute and relative budgets, the
largest changed work counters, and every prior miss edge. “Fallback” is not a
stage and “cache miss” is not an explanation. An unclassified miss, silent
phase, orphaned worker, artifact mismatch, or stage deadline is itself a loud
gate failure.

## Resolved operator decisions

All five decisions below are ruled on 2026-08-18. The first four are
dependencies on the authoritative types paper, not duplicate decisions minted
here; their sequencing is governed by that paper's adopted dependency DAG.

1. **Shadow authority — RULED: APPROVED WITH STRENGTHENED GATES.** Shadow
   facts remain candidate claims without authoritative attestations. Promotion
   requires a clean build with identical canonical fact graph, diagnostics,
   and artifacts; incremental parity with a fresh cold build after edit,
   delete, rename, dependency, and profile sequences; complete receipts for
   every consumer read, including negative lookups, candidate sets, module
   enumeration, ordering dependencies, selected profile, target, and
   compiler-semantic inputs; and bidirectionally exact invalidation cones with
   no missed or unrelated consumers. Promotion is per fact-family and
   consumer edge, never per vague subsystem.
2. **Identity, encoding, and invalidation — RULED: IDENTITY SPLIT APPROVED.**
   Semantic identity excludes compiler epoch: it is kind, schema version,
   semantic profile, subject, and canonical payload. Attestation identity
   carries checker/compiler epoch, semantic fact identity, and result/evidence.
   One canonical fact envelope has kind-specific payload encoders; source has
   exact author-text and normalized semantic facets; and mutually recursive
   definitions use canonical SCC group identity with explicit internal
   references.
3. **Declared-interface transition — RULED: CONCEPT APPROVED, NAME AND
   CONFORMANCE OVERRIDDEN.** The form is not named after Clojure's JVM
   interface-definition form: reusing that name for a diverged semantic would
   violate the divergence doctrine. The Beagle-native name is decided
   separately. The public export set is exact, while implementation
   conformance must prove
   refinement of the declared contract, not inferred-type identity. The
   build program consumes this contract and its exact outward cutoff.
4. **LIVE semantic compatibility facts — RULED: EFFECTS SLOT NOW, FEATURES
   LATER; CANONICAL VALUES APPROVED.** The function-signature and interface
   identity includes the effects slot from first mint by normalizing existing
   synchronization, allocation, failure, capability, and profile contracts;
   user-defined effect labels, open rows, row-polymorphic syntax/inference,
   and handlers remain deferred. Canonical values use one semantic
   encoding/layout contract for identity, equality, hashing, and attestations,
   while physical Store layout may vary independently. The LIVE eligibility
   boundary consumes both the normalized effects slot and the canonical-value
   encoding/layout split.
5. **Development artifact optimization policy — RULED 2026-08-18: ADOPTED AS
   RECOMMENDED.** Use a pinned fast-native development artifact kind that is
   first-class and statically verified; keep release-native optimization as a
   separate COLD gate. INCREMENTAL and LIVE never inherit whole-program
   release optimization. This preserves fast development artifacts while
   keeping release optimization independently explicit and verified.

Three apparent choices were removed. The first LIVE envelope is settled as
pure body-only by the Store invariants above and the types paper's Release and
rollback law: unknown or changed ABI, layout, codec, effect, profile, stack-map,
initializer, foreign-call, or capability evidence fails closed to restart or
migration. Cache sharing is settled by this paper's canonical-cache proof and
the types paper's fact-publication authority: local Store/CAS validation is the
only validity authority; any future remote cache is transport for fully
revalidated entries and cannot change a build verdict. The old separate effect
and value questions were merged because this program consumes them at one LIVE
eligibility boundary; they remain distinct decisions 4 and 5 in the types
paper.

Everything else here is settled by recorded doctrine: build latency is
existential; the four loops and their absolute targets are gates; Store state is
durable and native code replaceable; unexplained fallback fails closed;
deterministic parallel output must be byte-identical; and the two original Tier
0 owners remain in flight while the former cache seam is serially recut.

## World references

- Go's founding dependency/compilation argument and package export discipline:
  <https://go.dev/talks/2009/go_talk-20091030.pdf>; current content-aware build
  cache contract: <https://pkg.go.dev/cmd/go>; reproducible-build account:
  <https://go.dev/blog/rebuild>.
- Common Lisp's `compile` installs the resulting compiled function as the named
  function definition: <https://www.lispworks.com/documentation/HyperSpec/Body/f_cmp.htm>;
  SBCL's compiler and image behavior: <https://www.sbcl.org/manual/>.
- Unison's content-addressed definitions and “perfect compilation cache”
  argument: <https://www.unison-lang.org/docs/the-big-idea/>; canonical term/type
  hashes: <https://www.unison-lang.org/docs/language-reference/hashes/>.
- Zig's incremental compiler and linker program, including millisecond updates
  and persistent watch mode: <https://ziglang.org/download/0.16.0/release-notes.html>;
  the earlier 63 ms half-million-line reanalysis datum:
  <https://ziglang.org/download/0.14.0/release-notes.html>.
- Rust's current red/green dependency graph, persisted cache, fingerprint cost,
  and codegen-unit boundary: <https://rustc-dev-guide.rust-lang.org/queries/incremental-compilation-in-detail.html>.

These sources supply mechanisms and failure lessons, not copied design text.
The absolute Beagle gates above—not a moving external benchmark—decide whether
the program has succeeded.

## Appendix A. Adversarial Review Record (2026-08-18)

This review attacked each program commitment against the commander-verified
empty-cache emission baseline, machine gate law, the types-as-facts authority
boundary, two-regime runtime failure cases, fleet seam law, and the existing
operator queue. The Measurements table was not changed.

| Commitment attacked | Break found | Repair made | Residual risk |
|---|---|---|---|
| **COLD full artifact build ≤30 s** | The paper assigned a 73.3× demand to parallel emission even though sixteen workers provide at most 16×; perfect scaling still leaves 137.4 s of emission and no time for the rest of the build. | Added the explicit 73.3×/16×/4.58× arithmetic, a 6.87× per-worker throughput dependency under a 20 s native-work budget, legal empty-cache mechanisms, a one-sample 165 s `COLD-EMIT-T0` stage inside the 16× arithmetic ceiling, a 4/20/2/4 s allocation, and dependency-gated `COLD-30` promotion. | Direct/bounded-fragment native production and the 6.87× per-worker gain are unmeasured; the 30 s gate remains unearned until their component receipts pass. |
| **WARM same-commit rebuild ≤250 ms** | A vague cache hit did not explain the 240× step from the active <60 s gate, and re-reading or re-probing the whole artifact would retain project-size work. | Required zero compiler/emitter/link work, bounded Merkle plus filesystem-verity root verification of an immutable prior load/probe attestation, explicit 50/100/50 ms budgets, `WARM-O1-VERIFY`, and staged `WARM-250` promotion. | Store/CAS lookup and durable receipt verification have no measured p95 yet. |
| **INCREMENTAL one-definition artifact rebuild ≤100 ms** | The paper budgeted 30 ms assembly and 10 ms coordination but gave no arithmetic for checking, native work, verification, or durable publication; caller-cone authority was also assumed. | Allocated 10/35/30/20/5 ms, bounded work to the changed SCC and proved cone, required Merkle publication, staged shadow equality before authority, and named the ruled shadow, identity, effects-normalization, declared-contract, and per-family cutover dependencies plus T1 work. | A large recursive SCC or target linker that cannot meet the fixture budgets will block promotion rather than redefine the loop. |
| **LIVE one-definition process patch ≤5 ms** | T2.4 depended on a coordinator allowed 10 ms, already twice the whole gate; references to Lisp/Zig supplied no 5 ms mechanism. | Removed the artifact coordinator from LIVE, required a resident in-memory 1/2/1/1 ms path with no C compiler/linker/filesystem/cold query, and staged correctness before `LIVE-5`. | The direct ≤2 ms native-code path and two ≤1 ms control/probe paths are explicitly unproven. |
| **Exact facts yield a minimal sound rebuild** | The text described the types paper's pre-authority candidate graph as already available and risked building a second identity/caller-cone authority. | Recorded the ruled candidate-only shadow gates, identity split, declared-contract refinement, and bidirectionally exact cone ownership; limited this program to native-phase receipts and work plans. | The exact cone gate remains the highest-risk dependency because a false cutoff can reuse a wrong program. |
| **Canonical keys make cache hits proofs** | Key equality was conflated with permission to skip work; phase facts could become build authority before their owning cohort flipped. | Added shadow-only population/comparison, per-fact-class activation, cold execution before FLIP, and a conservative whole-source-key explanation for Tier 0 caches. | Cross-version schemas and retained corrupt entries still rely on the Store's admission and digest implementation. |
| **Store-held durable state makes LIVE safe** | Durable Store authority did not refute old frames calling new code, semantically relevant transient state, hidden code pointers, ABI drift, probe mutations, or failure midway through publication. | Expanded the contract to twelve falsifiable invariants: transient-state exclusion, complete code-pointer census, epoch-pinned calls, byte-identical ABI/facets, prepare-probe-publish, and bounded pre-ack rollback; named what remains unproven. | General effectful handoff, foreign/runtime pointer completeness, concurrent failure atomicity, and post-effect rollback are not claimed. |
| **Whole-program emission is parallel work** | “Embarrassingly parallel” obscured the serial fraction and treated byte identity as if it closed the latency target. | Kept byte identity as the correctness gate, made graph finalization/merge the measured serial remainder, and tied COLD promotion to separate per-worker throughput and full-pipeline budgets. | Tier 0 measurements may expose a larger serial fraction; that blocks the stage gate without changing the target. |
| **Consistency with types-as-facts authority** | Tier 1 duplicated canonical graph/interface machinery and did not enforce the types paper's shadow-first rule for facts consumed by builds. | Replaced those rows with native read receipts and a consuming native planner; every proposed semantic/native hit stays observational until the ruled shadow gates, Store FLIP, and per-family/consumer-edge cutover. | Exact file-level boundaries must still be fixed in dispatch briefs once the ruled prerequisites authorize implementation. |
| **Fourteen independently dispatchable seams** | The old T0.2 hid two cache namespaces, T1.1/T1.2 duplicated another program, gates were unnamed, and coordinator ownership overlapped the LIVE path. | Recut the same total into 3 Tier 0, 7 Tier 1, and 4 Tier 2 seams; gave each one named gate, dependency set, and exclusive component surface; serialized the split of the already-live cache owner. | Repository co-location may force a pre-dispatch merge; concurrent briefs are forbidden to share files or gates. |
| **One repository latency gate** | Applying unearned 30 s/250 ms/100 ms/5 ms targets immediately would create permanent red, while leaving them aspirational would make them non-gates. | Added one manifest-selected active stage per loop, named predecessor receipts, exact-commit execution, and explicit promotion without relaxing any north star. | The manifest promotion change is safety-critical and needs review against the named receipt. |
| **Loop boundaries measure real products** | COLD did not exclude imported generated artifacts, WARM verification could hide a full scan/probe, INCREMENTAL publication durability was unstated, and LIVE round-trip topology was unspecified. | Defined forbidden COLD prior products, Merkle/attestation WARM work, file+directory `fsync` publication, and a pre-opened local two-core LIVE probe/process transport inside the boundary. | The pinned filesystem and transport implementation must prove these work counters without boundary-moving. |
| **Deterministic, isolated, no-retry latency verdict** | Twenty LIVE samples and broad “isolated headroom” language could not distinguish scheduler/I/O noise at 5 ms; sample timing, invalidation, and retry handling were underpinned. | Fixed 5/40/40/200 samples and nearest-rank indices, exact run order/reset state, cpuset/core/storage ownership, load/memory/counter thresholds, no sample replacement, and one visible diagnostic rerun only for an invalid environment. | Zero-context-switch/major-fault conditions may invalidate a noisy host; repeated invalidity is an infrastructure defect, never a green product result. |
| **Five operator decisions** | The queue repeated the already-settled pure body-only LIVE envelope and local validity authority, while effect and value policy were separate entries with one build consequence. | Recorded all five decisions as ruled: strengthened shadow gates, identity split, Beagle-native declared-contract refinement, effects-slot normalization plus canonical values, and the pinned fast-native development artifact policy. | Dependent roadmap rows remain gated by their named prerequisites and cannot skip work before their cutovers pass. |
