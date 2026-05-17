# Beagle Experiment Report

## What is Beagle?

Beagle is an agent-native authoring layer for Clojure. It does not try
to make the type system maximally pure. It tries to make bugs maximally
repairable. The compiler emits structured diagnostics, repair traces,
and executable patches so LLM agents spend less time reasoning through
mechanical fixes.

**Thesis:** Mechanical bugs should not require cognition. They should
compile into patches.

## Summary

Across eleven experiments, Beagle's advantage shifted as the system matured:

1. At small scale, Beagle mostly improved speed.
2. At larger scale without an oracle, Beagle improved correctness.
3. With a full oracle, Beagle improved repair efficiency.
4. With `--emit-patch`, Beagle compressed mechanical fixes into executable patches.
5. Against Python, Beagle's advantage came from the repair compiler, not types alone.

Beagle wins when bugs can be converted from reasoning problems into
repair artifacts.

## Experiment design

All experiments use the same domain: an inventory & order management
system with typed records, cross-module dependencies, and a behavioral
verification oracle (assertions that define correct behavior).

An LLM agent (Claude Code, Opus 4.6 unless noted) receives buggy source
code and must fix all bugs until the oracle passes. We measure wall time,
turns, output tokens, and correctness (pass rate).

Three language tracks:
- **Beagle** — typed, with checker + repair toolchain (agent-native repair compiler)
- **Clojure** — untyped, same runtime, structural query tools only
- **Python** — typed (`@dataclass` + type annotations), mypy available

| System | Modules | LOC (beagle / clj / py) | Bugs | Assertions |
|--------|---------|------------------------|------|------------|
| v2-inventory | 5 | 1651 / 1235 / — | 12 | 444 |
| e8-scaled | 13 | 8500 / 4700 / 7200 | 35 (clj/bgl) / 30 (py) | 484 |

## Results at a glance

| Experiment | Beagle | Clojure | Python | Key finding |
|-----------|--------|---------|--------|-------------|
| E3b (1.2K, no oracle) | 219s, 3/3 | 344s, 3/3 | — | Beagle 36% faster |
| E4 (8.5K, no oracle) | 449s, **3/3** | 439s, **0/3** | — | First correctness divergence |
| E8 (8.5K, full oracle) | 375s, 3/3 | 485s, 3/3 | — | Beagle 23% faster |
| E9 (+ repair toolchain) | 421s, 3/3 | 595s, 3/3 | — | Beagle 29% faster, 36% fewer tokens |
| E10 (+ emit-patch) | 310s, 3/3 | 464s, 3/3 | — | Beagle 33% faster |
| E11 Opus | 310s | 464s | — | 33% beagle advantage |
| E11 Sonnet | 395s | 411s | — | 4% beagle advantage |
| E11 Haiku | 276s | 281s | — | 2% beagle advantage |
| E8 Python | — | — | 346s, 3/3 | Faster than clj+bgl E9; slower than bgl E10 |

---

## Detailed results

### E3b — Bug detection without oracle (5 modules, 1.2K LOC, 12 bugs)

No test suite provided. Beagle agents have `beagle-check`; Clojure
agents have only code reading and grep.

| Run | Beagle score | Beagle wall | Clojure score | Clojure wall |
|-----|-------------|-------------|---------------|-------------|
| 1 | 436/444 | 245s | 435/444 | 316s |
| 2 | 435/444 | 175s | 435/444 | 454s |
| 3 | 435/444 | 237s | 435/444 | 262s |
| **Avg** | | **219s** | | **344s** |

Both tracks found all 12 injected bugs every run (8-9 assertion
discrepancies are golden-code spec disagreements). **Beagle 36% faster.**
Beagle uses more tokens but less wall time — the checker provides dense
signal that drives faster iteration.

### E4 — Scaled bug detection without oracle (13 modules, 8.5K LOC, 35 bugs)

Same task at 5x scale. No test oracle. Beagle has checker + 5 query
tools. Clojure has 4 structural query tools (no type info).

| Run | Beagle | Wall | Clojure | Wall |
|-----|--------|------|---------|------|
| 1 | 484/484 | 436s | 484/484* | 307s |
| 2 | 484/484 | 468s | CRASH | 244s |
| 3 | 484/484 | 444s | 484/484* | 570s |
| **Avg** | **3/3 clean** | **449s** | **0/3 clean** | **439s** |

*Clojure runs required manual correction (extra closing paren in
`target-achievement-pct` — all 3 agents made this error independently).
Run 2 also missed a bug causing runtime crash.

**First correctness divergence — the most important result in this
report.** Wall time roughly equal (~2%), but Beagle produces 3/3 clean
runs while Clojure produces 0/3. When the oracle is absent, Clojure can
appear to pass but still produce dirty output requiring manual
correction. Beagle's checker prevents this class of failure entirely. At
scale, the value shifts from speed to correctness.

### E8 — Full oracle baseline (13 modules, 8.5K LOC, 35 bugs, 484 assertions)

Behavioral oracle provided (484 assertions). Single runs.

| Metric | Beagle | Clojure |
|--------|--------|---------|
| Result | 484/484 | 484/484 |
| Turns | 76 | 92 |
| Duration | 375s | 485s |
| Output tokens | 20,089 | 25,479 |

**Beagle 23% faster.** With full oracle coverage, Clojure can't
shortcut. Beagle's auto-fix makes the first 20 type errors mechanical,
leaving only 15 logic bugs for behavioral iteration.

Notable: with a *partial* oracle (291 assertions), Clojure was 2x
faster — it only had to fix bugs that affected tested code. Beagle
was forced to fix all 20 type errors regardless. Beagle's advantage
requires sufficient test coverage.

### E9 — Repair toolchain (3 runs each)

Beagle gets the full repair toolchain (`beagle-repair`, `beagle-trace`,
`beagle-cascade`, `beagle-specfix`, `beagle-blame`). Clojure gets
oracle + structural query tools.

| Run | Beagle turns | wall | tokens | Clojure turns | wall | tokens |
|-----|-------------|------|--------|---------------|------|--------|
| 1 | 83 | 437s | 23,257 | 77 | 534s | 30,486 |
| 2 | 82 | 441s | 22,255 | 90 | 588s | 32,195 |
| 3 | 67 | 386s | 19,297 | 96 | 663s | 39,152 |
| **Avg** | **77** | **421s** | **21,603** | **88** | **595s** | **33,944** |

Correctness: 3/3 both tracks.

| Metric | Delta |
|--------|-------|
| Turns | -12% |
| Wall time | **-29%** |
| Output tokens | **-36%** |

Clojure variance is higher (534–663s vs 386–441s). The repair toolchain
gives Beagle more targeted information per turn, producing less
exploratory output.

### E10 — Workflow compression (`--emit-patch`)

Beagle's `--emit-patch` emits a unified diff that auto-applies 6
mechanical fixes via `git apply` before the agent starts reasoning.

| Run | Beagle | Clojure | Notes |
|-----|--------|---------|-------|
| 1 | ~~659s~~ | 494s | Invalid — 3 `--emit-patch` toolchain bugs |
| 2 | 285s | 404s | |
| 3 | 334s | 494s | |
| **Avg** | **310s** | **464s** | Beagle: valid runs only |

Correctness: 3/3 both tracks.

**Beagle 33% faster.** The 6 patched fixes eliminate 15 of 33 baseline
failures (45%). The remaining 18 are semantic bugs requiring judgment.

| Metric | E9 → E10 beagle | E9 → E10 clojure |
|--------|-----------------|------------------|
| Wall time | 421s → 310s (-26%) | 595s → 464s (-22%) |
| Gap vs clojure | 29% → **33%** | — |

### E11 — Model tier

Same E8 system tested across Opus, Sonnet, and Haiku.

| Config | Wall time | Beagle advantage |
|--------|----------|-----------------|
| Opus + Beagle | 310s | 33% faster |
| Opus + Clojure | 464s | baseline |
| Sonnet + Beagle | 395s | 4% faster |
| Sonnet + Clojure | 411s | |
| Haiku + Beagle | 276s | 2% faster |
| Haiku + Clojure | 281s | |

Correctness: all configurations 484/484.

**Beagle's advantage scales with model capability.** Opus extracts 33%
from the structured repair tools. Sonnet and Haiku fall back to
sequential "read-find-fix" regardless of tooling.

Directionally, Beagle appears to enable model-tier arbitrage: Sonnet +
Beagle (395s) beats Opus + Clojure (464s) at ~5x lower token cost.
Sample sizes are small (2 runs each at Sonnet, 1 at Haiku) — treat as
promising, not settled.

### Python reference track (13 modules, 7.2K LOC, 30 bugs)

Same E8 domain ported to Python with `@dataclass` and type annotations.
30 bugs (vs 35 for Beagle/Clojure — 5 Clojure-specific patterns don't
translate). Agent has mypy + behavioral verify.

| Run | Result | Turns | Wall | Output tokens | Cost |
|-----|--------|-------|------|---------------|------|
| 1 | 484/484 | 54 | 324s | 18,174 | $4.40 |
| 2 | 484/484 | 64 | 353s | 20,624 | $4.86 |
| 3 | 484/484 | 61 | 360s | 19,334 | $4.73 |
| **Avg** | **3/3** | **60** | **346s** | **19,377** | **$4.66** |

**None of the agents used mypy.** All went straight to `python3 verify.py`
and iterated from behavioral feedback.

| Track | Avg wall time | Per-bug time | Bugs |
|-------|-------------|-------------|------|
| Beagle E10 | 310s | 8.9s | 35 |
| **Python** | **346s** | **11.5s** | **30** |
| Beagle E9 | 421s | 12.0s | 35 |
| Clojure E9 | 595s | 17.0s | 35 |

Python beats Clojure by 42% and Beagle E9 by 18% in absolute wall
time. Per-bug, Python (11.5s) is comparable to Beagle E9 (12.0s).
**Beagle E10 still beats Python by 10%** — the repair compiler, not
the type system, is the differentiator.

---

## Progression narrative

```
E3b  (1.2K LOC)  → beagle 36% faster, both correct
E4   (8.5K LOC)  → wall time equal, beagle 3/3 vs clojure 0/3
E8   (full oracle) → beagle 23% faster, both correct
E9   (+ repair tools) → beagle 29% faster, 36% fewer tokens
E10  (+ emit-patch) → beagle 33% faster
E11  (model tier) → advantage scales: 33% Opus, 4% Sonnet, 2% Haiku
Python reference  → type system alone ≈ beagle E9; repair compiler wins
```

## Key takeaways

1. **Correctness divergence at scale.** At 8.5K LOC without a test
   oracle (E4), Beagle produces 3/3 clean runs vs Clojure 0/3. This
   is the strongest result — types prevent bugs that behavioral testing
   misses.

2. **The repair compiler is the differentiator, not the type system.**
   Python with type annotations (346s) is comparable to Beagle-without-
   patches (421s) on a per-bug basis. Beagle E10 with `--emit-patch`
   (310s) is 10% faster than Python. The value is in compiling mechanical
   fixes into patches, not in having types.

3. **Beagle amplifies capable models.** Opus gains 33% from Beagle's
   tooling; Sonnet gains 4%; Haiku gains 2%. The structured repair
   output is only useful if the model can act on it.

4. **Beagle may enable model-tier arbitrage.** Sonnet + Beagle (395s,
   ~$1) outperforms Opus + Clojure (464s, ~$5) directionally. Small
   sample sizes — promising, not conclusive. More runs needed.

5. **Caveat: Beagle's speed advantage needs behavioral coverage.**
   E4 showed value *without* oracle coverage (correctness, not speed).
   But for the *speed* advantage, coverage matters: with a partial oracle
   (E8 run 1, 291 assertions), Clojure was 2x faster because it could
   ignore untested broken code. Beagle's type checker forces the agent
   to fix all type errors regardless. Beagle's speed advantage requires
   enough behavioral coverage for Clojure to be forced through the same
   bug surface. With partial coverage, Clojure can appear faster by
   ignoring untested broken code.

## Appendix: confounds and limitations

- **Python has fewer bugs.** 30 vs 35 — 5 Clojure-specific patterns
  don't translate. Per-bug normalization partially accounts for this.
- **No mypy usage.** The agents had mypy available but never used it.
  Python's advantage comes from readability and error messages, not from
  the type checker. A stricter experiment could force mypy usage.
- **E11 sample sizes are small.** Sonnet: 2 runs each. Haiku: 1 run
  each. Treat the sub-Opus numbers as directional, not conclusive.
- **E10 run 1 invalid.** Three `--emit-patch` toolchain bugs discovered
  during run 1; fixed before runs 2–3. Results use valid runs only.
- **Same model judges all tracks.** The agent (Claude) may have stronger
  Python priors from training data, biasing the Python track favorably.
- **LOC differs across tracks.** Beagle 8500 LOC, Clojure 4700 LOC,
  Python 7200 LOC. More code means more context to read, though bug
  density (bugs per LOC) is roughly comparable.
