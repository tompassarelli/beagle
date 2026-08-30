# JVM Store resource harness

This scratch-only harness fills the process/resource rows in
`store:bench/PERFORMANCE_ACCEPTANCE.md`. It starts an explicitly supplied JVM
Store checkout or artifact on a free loopback port, under a new delegated
cgroup v2. It never reads the live Store port, data, service, or system closure.

The corpus is deterministic and real: three normalized triples per complete
`@resource-N` subject (`kind`, `title`, and one of 32 owners), plus the leading
part of the next subject when the requested count is not divisible by three.
The driver validates every scanned triple against its unique corpus index,
rejects duplicates or extras, checks Store validation, and emits a SHA-256 over
the proven index-ordered logical corpus.

## Run

Supply the exact Java and classpath belonging to the checkout or unpacked
artifact under test. A packaged artifact can carry `server.classpath`; a
checkout may instead replace the artifact classpath's first `store/out` entry
with that checkout's generated `store/out`.

```sh
STORE_RESOURCE_HOME=~/code/beagle/worktrees/CANDIDATE/store \
STORE_RESOURCE_JAVA=/path/to/jdk/bin/java \
STORE_RESOURCE_CLASSPATH_FILE=/path/to/server.classpath \
  store/bench/resource/run.sh --size 500000 \
  --output /tmp/store-candidate-500k.jsonl
```

The accepted capacity sizes are `30000`, `500000`, and `5000000`. The sole
development check is the same path shortened to 3,000 triples and two-second
idle/agent phases:

```sh
store/bench/resource/run.sh --smoke \
  --store-home ~/code/beagle/worktrees/CANDIDATE/store \
  --java /path/to/jdk/bin/java \
  --classpath '.../CANDIDATE/store/out:...dependency jars...'
```

The JSONL receipt records source and artifact digests, JVM and host identity,
cgroup inputs, process-tree CPU, RSS/PSS/peak RSS, post-explicit-GC heap,
file-backed mapped memory, cgroup peak and swap/OOM events, log/checkpoint disk
bytes, cold replay without a checkpoint, warm restart with a checkpoint, GC
pause/share/full-GC facts, exact logical count/digest, and the 32-connected / at
most eight-active client shape. Raw GC, server, workload, JVM, and identity
inputs are copied beside the receipt under `*.evidence/`.
Source revision and dirty status come from the Git checkout containing the
supplied Store home. For an unpacked artifact outside a Git checkout, those
fields are explicitly `null` and `source.status` records that provenance is
unknown; artifact and classpath content digests remain authoritative.

The harness fails on request errors, a count/digest/validation mismatch,
unexpected process exit, OOM kill, swap use, or a client-shape violation. It
does not compare revisions and does not declare a competitive verdict; run the
same command for baseline and candidate, then apply the acceptance contract to
paired receipts.
