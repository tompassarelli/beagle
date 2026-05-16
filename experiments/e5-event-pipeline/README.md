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

## E5c Results

**Status:** multi-trial experiment in progress (3 runs per track, unlabeled bugs).

The type checker catches 25 of 40 injected bugs at compile time. Both tracks
receive the same buggy code with no bug-location hints.

**Scoring:** line-level diff against golden reference. Automated via `bin/score-trial`.

**Prompts:** exact agent prompts published in `prompts/`.

See `results.md` for completed trial data.

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

Built against: v0.2.0 (commit f91b70a)
