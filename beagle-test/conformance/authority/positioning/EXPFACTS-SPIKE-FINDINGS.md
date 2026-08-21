# Expansion facts spike findings

## Verdict

Expansion facts are viable now. The committed standalone probe observes the
compiler's macro trace, writes source-facts-style tab-separated records, and
answers the invalidation question from that facts file alone. For the fixture's
`make-const` definition at `fixtures/expfacts/macro-sites.bclj` position 19,
span 86, the cone is its calls at line 6 and line 7.

The committed files are all new:

- `beagle:fixtures/expfacts/macro-sites.bclj` defines one surface `defmacro`
  and invokes it twice.
- `beagle:experiments/expfacts/mint-expansion-facts.rkt` observes expansion,
  records definition/call spans, and emits expanded syntax trees.
- `beagle:experiments/expfacts/macro-sites.expansion.facts` is the checked
  facts oracle. Its rows use the existing `subject<TAB>predicate<TAB>kind<TAB>object`
  source-facts shape, including `t` text and `n` node edges.
- `beagle:experiments/expfacts/invalidation-cone.rkt` reads only those facts.
  Given definition source-id, position, and span, it prints the affected sites.
- `beagle:experiments/expfacts/run.sh` regenerates the facts and checks both
  facts and query output against committed oracles.

## Evidence carried by each expansion

Each `macro-expansion` node records the macro name, macro-definition source
location, call source location, expansion depth, and an `output` edge. Every
reachable `expanded-syntax` node records its syntax kind, literal/symbol value
or child edges, and its synthetic call-site span. The two outputs are:

```text
(def alpha Int 10)
(def beta Int 20)
```

The stored query result is:

```text
make-const fixtures/expfacts/macro-sites.bclj:6:0 span=21 -> syntax-1
make-const fixtures/expfacts/macro-sites.bclj:7:0 span=20 -> syntax-6
```

No source file is consulted by `invalidation-cone.rkt`; it selects only rows
whose `macro-definition-source-id`, `macro-definition-pos`, and
`macro-definition-span` match the changed definition identity.

## Existing seam and production-sized tap

The expansion hook already exists at `beagle:beagle-lib/private/macros.rkt:224`
through `macros.rkt:336`: `current-trace-handler` receives before/after events
with macro name, raw input/output datum, and depth. The parser has both the
call-site syntax object and its span at `beagle:beagle-lib/private/parse.rkt:2066`
through `parse.rkt:2096`; generated output deliberately inherits that span.
The checked AST also preserves macro name/depth and synthetic source provenance
at `beagle:beagle-lib/private/ast-json.rkt:373` through `ast-json.rkt:425`.

The gap is definition identity: `macro-def` at
`beagle:beagle-lib/private/macros.rkt:21` has no definition location, and the
registration loop at `beagle:beagle-lib/private/parse.rkt:1910` through
`parse.rkt:1960` iterates only datums, discarding the parallel syntax object.
The spike obtains that span by a read-only fixture pre-scan.

The smallest production tap is to carry the parallel definition syntax object
through that registration loop into `macro-def`, then emit one structured event
at the existing trace call around `macros.rkt:332` through `macros.rkt:336`.
That event needs the retained macro-definition location plus the call syntax
location already available in `expand-fully/at-source` at `parse.rkt:180` through
`parse.rkt:185`. It should use the same synthetic call-site span for every
generated syntax child, matching the current parser policy. Nested calls need
the same source association threaded through recursive expansion; the present
datum-only recursion intentionally has no inner syntax objects.

## Verification

- `nice -n 19 bash experiments/expfacts/run.sh` passed: regenerated facts and
  facts-only cone exactly matched both committed oracles.
- `nice -n 19 bin/beagle syntax fixtures/expfacts/macro-sites.bclj` passed.
- `nice -n 19 bin/beagle check fixtures/expfacts/macro-sites.bclj` passed with
  zero errors.
