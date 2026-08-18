# Beagle conformance corpus

This directory is the implementation-independent semantic contract for the
oracle-retirement program. It is versioned as `BeagleConformanceCorpusV1` and
is intentionally separate from compiler-specific output goldens and from
`beagle-test/tests/conformance.rkt`.

## Layout

```text
manifest.json                 corpus membership and coverage declaration
corpus/decided/*.json          immutable DECIDED case payloads
drafts/*.json                  harvested observations awaiting adjudication
inbox/*.jsonl                  selfhost-daily shadow-diff input records
tools/harvest-divergence.py   observation -> draft case converter
tools/run-corpus.py            one-binary case runner
```

The manifest and each payload are JSON. A decided case has these load-bearing
fields:

| Field | Meaning |
| --- | --- |
| `caseId`, `corpusVersion` | Stable case and schema identity. |
| `status` | Must be `DECIDED` for corpus authority. |
| `profile` | Semantic environment, such as `core` or `hosted-js`. |
| `input` | Exact source/request bytes, command, target, and closure. |
| `rule` | Plain-language semantic rule and owning rule reference. |
| `expected` | Canonical output or named diagnostic assertion. |
| `coverage` | Surface, ALARM-BELL, host-leakage, and parity labels. |
| `decision` | Contract owner, independent reviewer, reference, and date. |

Expected assertions are authored contract evidence. Native, seed, and Racket
outputs may be retained under `observations`, but they never become an
expected assertion merely because implementations agree.

## Shadow-diff inbox format

The selfhost-daily producer writes one JSON object per line:

```json
{
  "schema": "beagle/selfhost-shadow-divergence/v1",
  "inputHash": "sha256:...",
  "profile": "hosted-js",
  "input": {"source": "...", "target": "js", "command": ["check", "{input}"]},
  "outputs": {
    "native": {"status": "ok", "stdout": "...", "stderr": "..."},
    "racket": {"status": "error", "stdout": "", "stderr": "..."}
  }
}
```

`oracle` is accepted as an alias for `racket`. The harvester preserves both
outputs as observations and writes a `drafts/*.json` case with status
`IMPLEMENTATION-OBSERVED`; a human or commander must fill in the rule and
expected assertion before it can enter `corpus/decided/`.

## Running

After the build/test hold, run the narrow corpus check at nice 19, supplying
the one compiler binary to exercise:

```sh
nice -n 19 python3 beagle-test/conformance/tools/run-corpus.py \
  --compiler /path/to/beagle --manifest beagle-test/conformance/manifest.json
```

The runner validates manifest membership and case shape, materializes each
case's exact input in a private temporary directory, executes the declared
command, and prints `PASS` or `FAIL` for every case. It does not invoke a
second compiler or consult `/tmp/beagle-gate.lock`.
