# Store performance acceptance

This is the development acceptance contract for a Store change presented as a
performance, capacity, or resource-use improvement. It is not a public latency
guarantee and it does not claim parity with another database.

The governing baseline is the published Beagle `main` revision at the start of
the experiment. Run that baseline and the candidate on the same machine with
the same corpus, workload, JVM, cgroup, storage, and client boundary. Alternate
their order for three runs and decide from the medians. A result from another
revision, machine, or workload is context only.

Ordinary correctness changes do not inherit this benchmark gate. A performance
claim does: an unmeasured required row below is `UNPROVEN`, never an inferred
pass.

## Current research gate

The absolute limits express Store's owner-selected operational envelope. The
relative limits prevent an optimization from buying one resource by silently
damaging another. They are local acceptance decisions, not facts about
competitors.

| Surface | Workload and measurement | Must pass |
| --- | --- | --- |
| Logical result | Every measured run | Exact expected count and digest; zero adapter errors, corrupt/torn accepted data, duplicate or missing acknowledged writes, OOM, cgroup OOM event, or swap use. |
| Idle CPU | Ready server, no clients issuing work, 60 seconds | At most 1% of one logical CPU and no worse than current `main`. Report process-tree CPU time, not a point sample. |
| Small steady memory | 30k live Triples after warmup and explicit full GC | Candidate steady RSS, PSS, and post-GC live heap are each no greater than current `main`; report mapped/file-backed memory separately. |
| Agent-shaped concurrency | 32 connected clients, at most 8 issuing requests concurrently, one bounded listener, 60 seconds | Zero errors; read p95 no more than 1.10 times current `main`; durable-write throughput at least 0.90 times current `main`; remain inside the CPU and memory limits for the corpus. |
| 500k capacity | Real 500,000-live-Triple corpus with recorded digest, `-Xmx2g`, process-tree cgroup | Finish load, checkpoint, cold restart, warm restart, and the agent-shaped workload; peak memory below 3 GiB; post-GC live heap at most 512 MiB; no steady-state full GC. Projections do not pass. |
| 5M capacity | Real 5,000,000-live-Triple corpus with recorded digest, `-Xmx2g`, process-tree cgroup | Finish the same phases; peak memory below 8 GiB; post-GC live heap at most 1 GiB; no steady-state full GC. Projections do not pass. |
| Read latency | Existing in-class operations at every claimed corpus size | Candidate p50, p95, and p99 medians are each no more than 1.10 times current `main`; all rows are consumed into the result digest. |
| Durable writes | Existing in-class individually acknowledged commits at every claimed corpus size | Candidate median throughput is at least 0.90 times current `main`. |
| Startup and replay | Cold and warm restart at every claimed corpus size | Candidate restart-to-serving median is no more than 1.10 times current `main`; report replayed bytes and whether a checkpoint was used. |
| GC | Load and steady workload phases | No full GC in the steady phase; candidate GC wall share and p99 pause are each no more than 1.10 times current `main`. |
| Physical size | Log and checkpoint after each real capacity corpus | Report allocated and logical bytes per live Triple. A packed-representation candidate must use no more bytes than current `main`; a modeled byte count is not evidence. |

The 1.10/0.90 band is the explicit research regression budget. If any metric's
three-run range is wide enough to cross that band, the result is `NOISY`, not a
pass; control the input or collect more paired samples. A candidate may pass the
capacity rows when current `main` cannot finish, but every phase still needs the
absolute result and resource measurements.

## Comparator boundary

No same-machine, same-workload result exists yet for RDF4J NativeStore, Jena
TDB2, or Oxigraph. Therefore none currently supplies a threshold, ratio, or
competitive claim. RDF4J NativeStore is the closest planned comparison because
it is JVM, mutable, disk-backed RDF; Jena TDB2 and Oxigraph are useful flanks.
Their versions, licenses, adapters, and common logical subset must be fixed
before measuring, and a comparative acceptance rule must be chosen from those
observations rather than retrofitted to a desired verdict.

SQLite remains a lower-bound transport and harness diagnostic. Its schema,
query engine, history model, and call boundary are not equivalent to Store, so
its result never gates Store acceptance.

## What the existing evidence proves

The following are single-run directional observations. They explain the next
experiment; they do not pass the gate above.

The local raw sources at audit time are
`~/code/north-data/store-artifacts/8d1d337eb28001af6315b328890ab5fe31dc06dec7efa467ae3e0b76fce9c267.json`,
`~/code/north-data/store-artifacts/05f5d6de506a77c399b27645d413296d5dcc5321-store-3000-run1.log`,
`~/code/north-data/store-artifacts/28d4d947e7de683970188941afa35f2f07574a63-store-3000-run1.log`,
and
`~/code/north-data/store-artifacts/f69ad80173bf5b6745aadc77fef88387f8af7f77-store-3000-run1.log`.
The content digests below make relocation detectable.

| Observation | Provenance | Verdict |
| --- | --- | --- |
| `471.531319 ms` mixed-read p50 at 3,000 Triples | Beagle `11db5dc955c75cbc28baa9c42490e40b554c143e`; observed-facts receipt SHA-256 `8d1d337eb28001af6315b328890ab5fe31dc06dec7efa467ae3e0b76fce9c267` | Historical baseline observation only. |
| `353.648 ms` | `471.531` rounded and multiplied by `0.75` | Retired. This was a 25% prototype-materiality cutoff, not a Store target or competitor-derived threshold. |
| `444.104489 ms` mixed-read p50 | Beagle `05f5d6de506a77c399b27645d413296d5dcc5321`; raw-log SHA-256 `eab25bc2f6fd3f99926c85b361303a8d78661981a28f5bc23e1b86a043096f7f` | Prototype did not clear its one-off materiality cutoff. |
| `265.595661 ms` and `265.240890 ms` mixed-read p50 | Beagle `28d4d947e7de683970188941afa35f2f07574a63` and `f69ad80173bf5b6745aadc77fef88387f8af7f77`; raw-result SHA-256 `72091911790e3add5e6b6224375a38d917c18b75fab66a1f3e865e98e0234f47` and `776e6f8631f8b3460f6676f2fdc09106b3c14ad225459f7b524b23fcd248a39b` | Repeated directional evidence that persistent RPC transport helped; not current-`main` or broad competitiveness proof. |
| About `0.8 KiB` retained heap per Triple in a 25k boxed-Store probe | `~/code/todo/beagle-jvm-store-representation-risk.md`, SHA-256 `b246c9c020cfd2cb6adadf8816e4267bb476cc69e3bbfd4b0893fa6f5c57e930` | Representation-risk signal only; the failed `/proc` read means there is no RSS receipt. |
| `144-276` modeled packed checkpoint bytes per live Triple, rounded historically to `300` | `~/code/todo/beagle-store-packed-storage.md`, SHA-256 `d228a5e854a7688941afa9f5448c4d69d0d96bace02dc84bf470191c17f1c767` | Sizing estimate only. The rejected packed candidate never passed package, 500k, resource, or cgroup gates. |
| `1.334759 ms` SQLite mixed-read p50 at 3,000 Triples | Same observed-facts receipt as the historical Store baseline | Harness diagnostic only; not a Store competitiveness ratio. |

The audit base, Beagle `6fcf9b92756b6213b792d5300cad004de9d10341`,
contains the persistent-transport work but has no exact performance receipt.
There is also no direct 500k, 5M, 60-second idle-CPU, or same-class comparator
result. Those are the next measurements that can change the architecture.

## Smallest existing reproducible run

From each exact baseline or candidate checkout, run one half of an alternating
pair with a unique result path:

```sh
bench_revision="$(git rev-parse --short=12 HEAD)"
BENCH_ADAPTERS=store BENCH_RUNS=1 BENCH_SIZES=3000,30000 \
  BENCH_OUTPUT="/tmp/store-${bench_revision}-pair-1.jsonl" \
  store/bench/in-class/run.sh
```

Run three baseline/candidate pairs, reversing their order each pair. The runner
records environment metadata beside each JSONL file and never touches live
Store state.

This is presently the smallest reproducible latency/write loop, but it emits
only the metrics in `store:bench/in-class/scenario-contract.edn`. The audit
base has no harness for process-tree idle CPU, RSS/PSS/post-GC heap, the
32-connected-client shape, or real 500k/5M capacity. Those rows remain
`UNPROVEN` until a bounded resource harness measures them directly; widening
the small in-class run cannot substitute for that artifact.
