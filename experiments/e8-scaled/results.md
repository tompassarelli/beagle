# E8 Scaled Experiment — Results

## Setup

- 13 modules, 8500 LOC (beagle), 4700 LOC (clojure)
- 35 injected bugs: 12 scalar confusion + 5 arity + 3 multi-candidate + 15 logic
- Beagle checker catches 20 type errors; beagle-fix auto-applies 6
- Agent: Opus (standard speed), bypassPermissions mode

## Run 1 — Partial oracle (291 assertions)

| Metric | Beagle | Clojure |
|--------|--------|---------|
| Result | 291/291 | 291/291 |
| Turns | 76 | 36 |
| Duration | 442s | 215s |
| Bugs fixed | 29 | 10 |
| Winner | — | **Clojure (2x faster)** |

**Finding:** Partial oracle lets clojure shortcut — only fix bugs that
affect tested assertions. Beagle forced to fix all 20 type errors before
compiling, including untested code. Repair obligations are a cost.

## Run 3 — Full oracle (484 assertions)

| Metric | Beagle | Clojure |
|--------|--------|---------|
| Result | 484/484 | 484/484 |
| Turns | 76 | 92 |
| Duration | 375s | 485s |
| Output tokens | 20,089 | 25,479 |
| Winner | **Beagle (23% faster)** | — |

**Finding:** With full coverage, clojure can't shortcut. Must find and fix
all 35 bugs via manual reasoning from assertion failures and stack traces.
Beagle's auto-fix + precise diagnostics make the first 20 bugs nearly
mechanical, leaving only 15 logic bugs for behavioral iteration.

## Key insight

Beagle's performance is ~constant regardless of oracle coverage (checker
drives a fixed workflow). Clojure's cost scales with oracle coverage
(more assertions = more bugs surfaced = more reasoning needed).

At full coverage, beagle's "type tax" flips into an advantage: front-loaded
mechanical repair is cheaper than deferred manual reasoning.

## Warn-mode run — non-blocking type errors (484 assertions)

| Metric | Beagle --warn | Beagle blocking | Clojure |
|--------|---------------|-----------------|---------|
| Result | 484/484 | 484/484 | 484/484 |
| Turns | 74 | 76 | 92 |
| Duration | 385s | 375s | 485s |
| Output tokens | 19,522 | 20,089 | 25,479 |

**Finding:** `--warn` mode (type errors non-blocking, diagnostics still printed)
produced nearly identical performance to blocking mode. The agent's strategy
didn't change — it still fixed all type warnings before running verify,
treating them as repair tasks regardless of whether compilation was gated.

**Interpretation:** At Opus intelligence with full oracle coverage, the agent
recognizes type warnings as high-value repair signals and fixes them eagerly.
The blocking vs non-blocking distinction doesn't matter when the agent would
fix them anyway. The value of `--warn` is insurance, not speedup — it
prevents pathological cases where an unfixable type error blocks all progress.

## Summary

| Variant | Turns | Duration | vs. Clojure |
|---------|-------|----------|-------------|
| Beagle blocking | 76 | 375s | 23% faster |
| Beagle --warn | 74 | 385s | 21% faster |
| Clojure | 92 | 485s | baseline |

Beagle consistently beats clojure by ~20% on full-oracle bug repair at
8.5K LOC scale. The advantage comes from mechanical repair of type/accessor
bugs (auto-fix + precise diagnostics) rather than from the blocking behavior.

## Python reference track

See [results-python.md](results-python.md) for full writeup.

| Track | Avg wall time | Turns | Bugs | Per-bug time |
|-------|--------------|-------|------|-------------|
| Beagle E10 | 310s | — | 35 | 8.9s |
| Python | 346s | 60 | 30 | 11.5s |
| Beagle E9 | 421s | 77 | 35 | 12.0s |
| Clojure E9 | 595s | 88 | 35 | 17.0s |

Python (typed dataclasses, 30 bugs) beats Clojure by 42% and beagle E9
by 18% in absolute wall time — but per-bug, Python and beagle E9 are
comparable. The agents never used mypy; Python's readability alone
accounts for the speed. Beagle E10 (`--emit-patch`) still beats Python
by 10%: the repair compiler, not the type system, is the differentiator.
