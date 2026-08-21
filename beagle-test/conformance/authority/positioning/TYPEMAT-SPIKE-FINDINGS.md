# Type materialization spike findings

## Verdict

**The agent-driven round trip is not available today.** The checker can report
the deliberately omitted return annotation, but `bin/beagle check --agent`
emits only a human summary, with no derived type, exact source span, or
machine-applicable edit. The standalone consumer therefore refuses to rewrite
instead of guessing from prose; two consecutive runs leave the fixture byte
identical.

The spike is committed as new files only in the Beagle lane:

- `beagle:experiments/fixtures/type-materialization-hole.bclj` is the missing
  return-type hole.
- `beagle:experiments/type-materialization-spike.rkt` runs
  `nice -n 19 bin/beagle check --agent`, accepts only an exact structured
  materialization plan, and applies it by offsets.
- `beagle:experiments/fixtures/type-materialization-view.bclj` demonstrates
  the adjacent, already-working direct materializer.

## What round-trips today

`bin/beagle explain-type FILE materialize --write` already captures inferred
types, computes exact source offsets, and rewrites omitted symbol-named `let`
binders. On the view fixture it changed `doubled` to `(doubled Int)`, then
`bin/beagle check --agent` returned `0 errors`; a second materialization run
produced zero diff. The implementation is `beagle:beagle-lib/private/type-view.rkt:126`
through `type-view.rkt:214`.

That path is a direct checked projection, not a diagnostic handoff: it neither
consumes `--agent` output nor handles a malformed function boundary.

## What the agent output carries

For the hole fixture, the agent result is exactly one prose line:

```text
1 error
- type-materialization-hole.bclj malformed defn — expected ... ReturnType ...
```

`beagle:beagle-lib/private/check-all.rkt:440` reduces each exception to the
three-field `agent-error(file, line, message)`, and
`check-all.rkt:760` through `check-all.rkt:782` renders that summary. It drops
the original diagnostic details before output.

The separate JSON diagnostic mode does already preserve structured
`expected`, `actual`, `expected-type`, `actual-type`, file, line, column, and
source line for ordinary type mismatches; `error-format.rkt:97` through
`error-format.rkt:120` folds all diagnostic details into the JSON object. A
focused HVec mismatch confirmed those fields. But it is not `--agent` mode.

For this malformed return slot, even JSON mode has only `kind=bad-form`,
`phase=parse`, and the message: its line, column, source line, derived type,
and fix plan are null or absent. The immediate rejection is
`beagle:beagle-lib/private/parse.rkt:3337` through `parse.rkt:3340`, before a
checked body/type table exists.

## Smallest useful addition for the real wave

1. Preserve the original exception in the agent accumulator at
   `beagle:beagle-lib/private/check-all.rkt:443`, then emit its
   `diagnostic->json` JSONL record instead of the summary at
   `check-all.rkt:775`. This exposes already-available expected/actual type
   data to the agent protocol.
2. Represent a missing annotation as a recoverable parser hole rather than
   rejecting it at `beagle:beagle-lib/private/parse.rkt:3337`; type-check its
   body with capture enabled, as the existing projection does at
   `beagle:beagle-lib/private/type-view.rkt:178` through `type-view.rkt:189`.
3. Emit one machine-applicable payload on that diagnostic:

   ```text
   fix_plan = {
     category: "materialize-annotation",
     file: <fixture path>,
     span: {start: <codepoint offset>, end: <codepoint offset>},
     replacement: " String"
   }
   ```

The spike consumer already validates precisely that contract and rewrites only
that span. The first change alone improves ordinary type-mismatch automation;
the second and third are required for a hole-to-annotation round trip.

## Cost estimate

Estimate **2–3 engineer-days** for the real wave: roughly half a day to retain
and JSONL-emit agent diagnostics, 1–1.5 days to carry an omitted annotation
through parse/check and derive a type with precise positions, and 0.5–1 day
for fixture coverage, format/idempotency cases, and self-host parity. This is
a narrow protocol/parser/checker seam, not a new repair system.

## Verification

- `nice -n 19 bin/beagle check --agent experiments/fixtures/type-materialization-hole.bclj`
  reported the expected malformed-return diagnostic.
- `source bin/_beagle-racket && nice -n 19 "$RACKET" experiments/type-materialization-spike.rkt ...`
  returned the expected missing-payload status twice; the fixture checksum was
  unchanged.
- `nice -n 19 bin/beagle explain-type ... --write`, followed by
  `nice -n 19 bin/beagle check --agent ...`, materialized `(doubled Int)`,
  checked green, and was idempotent on its second run.
- `source bin/_beagle-racket && nice -n 19 "$RACO" make
  experiments/type-materialization-spike.rkt` passed.

