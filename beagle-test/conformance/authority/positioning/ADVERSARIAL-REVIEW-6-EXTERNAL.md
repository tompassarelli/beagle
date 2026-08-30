# ADVERSARIAL REVIEW 6 — EXTERNAL (Gemini): allocation substrate

## Scope and evidence state

This review adjudicates the three supplied findings against:

- `beagle:beagle-test/conformance/authority/positioning/ALLOCATION-THESIS.md`;
- `beagle:beagle-test/conformance/authority/positioning/THE-TURTLES-THESIS.md` v2;
- `beagle:beagle-test/conformance/authority/positioning/PRIOR-ART-KOKA.md`; and
- Beagle main `4f9c6f874157e3e7746e7e5f47c8748260511f25`.

Store Stage 2 aggregate `a6b42feb` is an ancestor of that main revision. The
landed train includes branch-ref CAS `5909e9e0`, post-durable watch
`a5390b70`, identity-preserving reseal `13f4af44`, hosted/native chain parity
`855da247`, and reachability GC `1c5b2d09`. Stage 3's focused
revision-generation slice is `7fa36f95`. The adjudication reads the landed
implementation and tests rather than relying on the allocation thesis's stale
pre-landing account.

| Finding | Verdict | Short reason |
| --- | --- | --- |
| 1. Fact-based GC cache/cost | **REAL-OPEN-COST** | Stage 2 has the correct explicit-root semantics and is outside ordinary request/promotion execution, but its full-log decode holds store/control authority and had no acknowledged cost model or budget. |
| 2. `bgl/promote` subset ergonomics | **NEEDS-DESIGN** | Current promotion copies one complete supported typed value. The author must construct a smaller survivor; neither Stage 2 nor Stage 3 shipped structural projection. |
| 3. Boundary-discovery failure mode | **NEEDS-DESIGN** | The design demanded inference from control flow and durability but did not specify what a developer sees when proof fails or how the explicit bounded fallback remains sound. |

## Finding 1 — fact-based GC cost

### Verdict: REAL-OPEN-COST

The semantic design answers *what retains durable state*: current branch heads
and durable pin/checkpoint/session documents. The landed collector enumerates
those documents, verifies every segment each document names, creates the
reachable segment-hash set, scans the segment namespace, and deletes only
unreferenced 64-hex objects
(`beagle:branch-core/database.clj:1143-1371`). Malformed roots abort before the
first deletion
(`beagle:branch-core/tests/branch_reachability_gc_test.clj:148-162`). CAS and
reseal likewise operate on durable ref/revision facts, not native addresses
(`beagle:branch-core/database.clj:898-937`,
`beagle:branch-core/database.clj:1373-1472`).

The external premise needs one correction. This GC does **not** traverse a
hydrated pointer graph or resolve private `TermStore` handles. Each named
segment is read as append-only bytes and fully decoded into transaction/Term
values so its chain facts and content identity can be verified. Access inside
one segment is sequential. The poor-cost risk is nevertheless real: the hosted
decoder allocates semantic values, validates structure and hashes, and repeats
the full decode when shared history appears in several root documents. The
current cost is:

`O(sum(root-referenced segment bytes and fact operations) + segment files)`.

It is not `O(unique live facts)` or `O(unique live segments)` in the presence
of shared roots.

The operation is off the request/promotion path only in a precise sense.
`collect-unreachable-segments!` is invoked explicitly; commit, CAS, arena close,
reseal, and engine promotion do not call it. It acquires the store-path writer
authority and branch-control authority for the whole operation
(`beagle:branch-core/database.clj:1241-1250`,
`beagle:branch-core/database.clj:1332-1371`). The cost is therefore paid in an
explicit maintenance epoch, not promotion-time. That blocks the default store
writer and ref/fork/retention topology changes; the landed code does not claim
to stop append-only writes to every independent child tail. Operations sharing
either authority wait until collection finishes. Without a declared
authority-hold budget, “off the hot path” was incomplete.

### Bounded benchmark

The benchmark ran once as a bounded campaign under `nice 19` on an AMD Ryzen AI
9 HX 370 (12 cores/24 threads, boost disabled), Babashka 1.12.218, warm page
cache, with 68 GiB available memory and starting one-minute load 14.91. Each
case created one default uncompressed store, committed one batch of unique
`(entity, :benchmark/value, integer)` facts, used the public fork path to seal
them, retained only the default current head, added one 4 KiB collectible
segment-namespace object, read the fact segment once as the raw anchor, then
called the landed collector once. GC timing excludes fixture construction and
process startup. Facts traversed/s is the known number of decoded fact
operations in the fixture; the collector does not yet expose a counter.

| Unique facts | Store size before GC | Fact-segment bytes | GC wall | Facts traversed/s | Effective decoded MiB/s | Warm raw read MiB/s | Raw/decode ratio |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10,000 | 513,207 B (0.49 MiB) | 508,944 B | 0.845929 s | 11,821 | 0.574 | 999 | 1,742× |
| 50,000 | 2,593,208 B (2.47 MiB) | 2,588,944 B | 3.913108 s | 12,778 | 0.631 | 1,608 | 2,549× |
| 100,000 | 5,193,211 B (4.95 MiB) | 5,188,945 B | 8.019951 s | 12,469 | 0.617 | 1,383 | 2,242× |

The raw anchor is intentionally not called a native-GC comparison. It measures
only same-byte cached sequential read/allocation and shows that storage
bandwidth is not the limiting factor in this fixture. No comparable local
production packed-pointer collector exists; inventing a linear array scan and
calling it GC would be dishonest. These numbers therefore establish a real
hosted decode/verification cost, approximately linear over 10k–100k facts, but
do not establish a hardware cache-miss ratio against a native tracer.

The predeclared 200,000-fact case hit its 120-second case deadline while
constructing the synthetic one-batch fixture (`user=115.63 s`) and never
entered GC. It is excluded from collector throughput. One bounded 100,000-fact
replacement case, unchanged except for size and a 90-second supervisor,
provided the upper datapoint above. The construction failure is visible because
retrying it into success or mislabeling it as GC evidence would overstate the
result.

### Repair and kill-condition

`ALLOCATION-THESIS.md:340-410` now records the landed algorithm, repeated-root
cost, benchmark, store/control-authority timing, and
**`FACT-GC-MAINTENANCE-BUDGET`**. `THE-TURTLES-THESIS.md:602` extends
`W7-G6 SEMANTIC-REACHABILITY`; bet 4 and mechanism 9 carry the same cost
contract (`THE-TURTLES-THESIS.md:629`, `:664-668`). A consumer must predeclare
its largest representative root/segment topology and store/control-authority
hold budget,
then record roots, unique/repeated references, bytes/facts decoded, wall, and
deletions. Missing the budget kills or narrows the off-hot-path claim unless a
verified segment cache/summary or incremental mark phase preserves the same
abort-before-delete law. Moving full GC into promotion or revising the budget
after a miss is not a pass.

## Finding 2 — `bgl/promote` subset ergonomics

### Verdict: NEEDS-DESIGN

The current surface and IR make one complete lifetime crossing explicit.
Lowering turns handle-free values into copies, collapses already-old promotion,
and otherwise emits one `PromoteInstructionV0`
(`beagle:native-core/src/native/lower.bclj:15393-15432`,
`beagle:native-core/src/native/lower.bclj:23253-23300`). The runtime descriptor
walk recursively copies every reachable supported field/element, does not
preserve aliasing, and has no partial-field plan
(`beagle:native-core/shim/native_shim.h:583-593`,
`beagle:native-core/shim/native_shim.c:5953-6110`). The compiler rejects maps,
recursive types, callables, atom cells, and other unsupported domains before
runtime (`beagle:native-core/src/native/lower.bclj:5527-5591`).

Stage 2 shipped CAS, watch, reseal, parity, and segment GC; none is a native
survivor projection. Stage 3's focused slice constructs a complete
`RevisionGeneration` and explicitly promotes it on revision match
(`beagle:branch-core/src/fram/revision_generation.bgl:19-31`). Therefore, for
an intertwined transient graph where only part survives, the developer today
constructs the smaller typed result and promotes that result. They do not
manually copy bytes or free nodes, but they do manually state the structural
subset.

Perceus is relevant only after that semantic choice. Its backwards liveness can
identify dead intermediates and its reuse pass can recycle a uniquely dead,
same-layout block. The prior-art note already limits both to bounded transient
representations and forbids reuse across epoch/store boundaries
(`PRIOR-ART-KOKA.md:145-172`, `:178-202`, `:220-231`). Reference counting or
reuse cannot soundly decide that a field is semantically dispensable, and must
not become a second durable reachability graph.

The smallest sound answer is now registered in
`ALLOCATION-THESIS.md:253-289` and `THE-TURTLES-THESIS.md:541` as **`W6.7
Structural promotion`**. Source continues to state the survivor using ordinary
typed record/union/vector construction. A compiler-owned post-liveness pass may
fuse that construction plus `bgl/promote` into one field-path copy plan, avoiding
the discarded intermediate and full-graph copy. Dynamic/recursive/alias-
sensitive cases remain explicit and receive a source-pointed reason.

**`W6-G7 STRUCTURAL-PROMOTION`** requires semantic and artifact identity with
explicit construct-then-promote, no full-graph promotion in generated code, no
younger handle after close, and copied bytes bounded by projected value plus
declared layout overhead. Kill the optimization if the named authority workload
shows no material promotion-byte/time reduction or if it requires a general
source ownership language.

## Finding 3 — Phase 3 boundary-discovery failure mode

### Verdict: NEEDS-DESIGN

The prior allocation thesis said Phase 3 must discover store-generation
boundaries from control flow and durability, prove no use-after-close, and
measure reclamation, but specified no developer-facing failure contract. No
current Store slice proves general boundary inference. The current Greywrought
evidence remains the honest manual model: a driver-owned request boundary and
fixed 80 MiB scratch policy
(`ALLOCATION-THESIS.md:410-428`).

The smallest sound contract is now in `ALLOCATION-THESIS.md:430-459` and
`THE-TURTLES-THESIS.md:542` as **`W6.8 Boundary inference failure contract`**:

- successful inference produces the ordinary region/close/promotion and memory
  receipt;
- an unproved site emits **`ARENA-BOUNDARY-UNDECIDABLE`** at the allocation or
  escape, naming the value/type, blocking control-flow join or durability edge,
  and nearest explicit boundary;
- the fallback declares a driver-owned request/transaction epoch, fixed or
  bounded capacity such as the 80 MiB scratch arena, and explicit typed
  projection/promotion; and
- fallback never disables old-to-young, use-after-close, or capacity checking.

**`W6-G8 BOUNDARY-DIAGNOSTIC-FALLBACK`** requires one nontrivial inferred
fixture and one deliberately undecidable fixture that names its blocker,
succeeds under the bounded fallback with identical semantics and complete
counters, and still rejects a lifetime-invalid fallback. If the representative
authority infers no nontrivial boundary, or any failure lacks an actionable
fallback, the automatic-boundary claim dies and the thesis must describe the
model as driver-managed arenas.

EXT-REVIEW-DONE
FINDING 1 — REAL-OPEN-COST
FINDING 2 — NEEDS-DESIGN
FINDING 3 — NEEDS-DESIGN
