# E5: Event-Sourced Order Pipeline

Production-shaped experiment proving beagle's compile-time safety at scale.

## Domain

Event-sourced e-commerce order processing: events → projections → commands →
handlers → queries. 8 modules, ~3000 LOC per track, 20+ record types with
nullable state fields, heavy cross-module contracts.

## Why this domain

1. **Nullable state is structural** — projections accumulate state from events;
   fields are nil until the relevant event arrives (shipped-at, delivered-at, etc.)
2. **Pattern matching is natural** — event dispatch in handlers
3. **Cross-module contracts are dense** — every handler imports events + projections
4. **Schema evolution is realistic** — adding/splitting events cascades everywhere
5. **Field confusion is easy** — similar records with overlapping field names

## Experiments

| ID | Task | Beagle advantage |
|----|------|-----------------|
| E5a | Fresh build from spec | Compile-time catches mistakes during development |
| E5b | Schema evolution (split OrderPlaced → OrderPlaced + OrderPriced) | Compiler finds all affected call sites |
| E5c | Bug detection (40 injected bugs) | 25 caught at compile time; verified repair loop |
| E5e | Behavioral scoring (40 per-bug tests) | Eliminates line-diff bias; clojure jumps to 90% |

## Module DAG

```
events (leaf)
├── projections (requires events)
├── commands (requires events, projections)
├── handlers (requires events, projections, commands)
├── queries (requires projections)
├── pipeline (requires events, projections, handlers)
├── notifications (requires events, projections)
└── analytics (requires events, projections, queries)
```

## Results (3 runs per track, unlabeled bugs)

### E5c → E5d → E5e progression

| Metric | Beagle (E5d) line | Clojure (E5d) line | Clojure (E5e) behavioral |
|--------|:---:|:---:|:---:|
| Mean accuracy | 66.0% | 70.3% | **90.0%** |
| Std deviation | 1.7% | 2.1% | **0.0%** |
| Checker errors | 0 | n/a | n/a |

**E5e finding:** Line-diff scoring was the primary confounding factor.
Behavioral tests show the agent actually fixes 36/40 bugs correctly — the
20pp gap between line-diff (70%) and behavioral (90%) was entirely
"correct but different" fix patterns being penalized.

The 4 unfixable bugs (BUG-09, 10, 11, 18) are missing match cases and
nil-handling issues that neither type checkers nor code inspection catches.

Beagle behavioral scoring is blocked until the emitter produces self-contained
.clj (match destructuring + qualified accessor emission needed).

See `results.md` for full analysis and per-bug breakdown.

## Running

```bash
# Build golden beagle reference
bin/beagle-build-all golden/beagle/

# Verify golden reference
clj verify/master.verify.clj

# Run experiment
bin/run-experiment e5a beagle 1
```

## Beagle version

Built against: v0.3.0 (commit b4c4427, with/defenum/exhaustive-match)
