# Durable sole-writer benchmark methodology

This benchmark compares durable stores with one authoritative writer and
concurrent readers. `store:bench/in-class/scenario-contract.edn` defines the
workload. Corpus sizes are live Triple counts and must be positive multiples of
three; the defaults are 3,000 and 30,000.

The deterministic corpus has three Triples per subject:

1. `kind = thread`
2. `title = title-N`
3. `owner = @owner-(N mod 32)`

Both adapters execute the same two-relation join: subjects with `kind=thread`
joined to their `title`. A correct result contains one row per three input
Triples. A missing result field or nonzero `errors` stops the run.

## Scenarios

- boot-to-serving: durable corpus activation through the adapter-ready probe;
- cold-start query: the first kind/title join before warmup;
- sustained writes under concurrent reads: 1,200 individually durable commits
  while another reader repeats the join;
- mixed read/write: 40 cycles of one durable write followed by three joins.

The Beagle Store adapter seeds a scratch FRAMLOG through the current server engine,
then times replay plus the first successful `rpc/status` request over a loopback
FRAMRPC v2 socket. JVM startup and TCP bind stay outside
`boot-to-serving-ms`; steady reads and writes cross the socket. SQLite uses
Python's `sqlite3` binding with WAL, `synchronous=FULL`, one writer connection,
and independent reader connections. Its seed transaction is complete and
checkpointed before the boot timer begins.

Every measured write is an individually acknowledged durable commit. Corpus
generation and initial SQLite seeding stay outside the timers. Scratch state
lives below `/tmp`; the benchmark never reads Beagle Store's live log or connects to
its live port.

## Warmup and reporting

Boot and cold-query measurements happen first. Each adapter then runs 30
durable warmup writes and 10 warmup joins; those results are discarded. The
sustained and mixed phases follow in that order.

Each run executes every adapter/size pair twice in alternating adapter order.
The report records range variance as `(max - min) / mean`. It also records the
Beagle Store revision, UTC time, kernel, CPU, memory, load, Python and SQLite versions,
corpus sizes, and run count. The corpus has no random input, so
`corpus-triples` plus the contract version identifies its logical contents.

Run the current comparison from a clean Beagle Store checkout:

```sh
BENCH_RUNS=2 BENCH_SIZES=3000,30000 \
  ~/code/store/main/bench/in-class/run.sh
```

The runner writes raw JSONL and environment metadata below `/tmp` unless the
output variables override those paths, then prints a report for that run.
