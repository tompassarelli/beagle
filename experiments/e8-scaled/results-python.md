# E8 Python Reference Track — Results

## Setup

Same E8 system: 13 modules, ~7200 LOC Python (vs 8500 beagle / 4700 Clojure),
30 injected bugs (vs 35 in beagle/Clojure — 5 Clojure-specific patterns don't
have clean Python equivalents), 484 assertions.

Agent: Claude Code (Opus 4.6) with `--dangerously-skip-permissions`.
Tools available: mypy + `python3 verify.py` + grep.

**Key finding:** None of the 3 agents used mypy. All went straight to
`python3 verify.py` and iterated from behavioral feedback. The speed
advantage is from Python's readability, not from static type checking.

## Raw data

| Run | Result | Turns | Wall (s) | Output tokens | Cost |
|-----|--------|-------|----------|---------------|------|
| 1 | 484/484 | 54 | 324 | 18,174 | $4.40 |
| 2 | 484/484 | 64 | 353 | 20,624 | $4.86 |
| 3 | 484/484 | 61 | 360 | 19,334 | $4.73 |
| **Avg** | **3/3** | **60** | **346** | **19,377** | **$4.66** |

## Comparison

| Track | Avg wall time | vs Clojure E9 | Bugs | Per-bug time |
|-------|--------------|---------------|------|-------------|
| Beagle E10 | 310s | 48% faster | 35 | 8.9s |
| **Python** | **346s** | **42% faster** | **30** | **11.5s** |
| Beagle E9 | 421s | 29% faster | 35 | 12.0s |
| Clojure E9 | 595s | baseline | 35 | 17.0s |

## Interpretation

Python is faster than both Clojure and beagle-without-patches in absolute
wall time (346s vs 421s/595s). Two factors explain this:

1. **Fewer bugs.** Python has 30 bugs vs 35. On a per-bug basis, Python
   (11.5s/bug) is comparable to beagle E9 (12.0s/bug) and faster than
   Clojure (17.0s/bug).

2. **Language readability.** Python's clear error messages (TypeError,
   AttributeError with field names), explicit type annotations in source,
   and familiarity from training data all help the agent reason faster.
   The agents never ran mypy — they didn't need a type checker to debug
   Python code efficiently.

Beagle E10 (310s, 8.9s/bug) still beats Python by 10%. The gap comes
from `--emit-patch` — mechanical fixes applied in zero turns. Python
has no equivalent of a repair compiler.

## What this means for beagle

The beagle advantage over Python comes from the repair toolchain, not
the type system alone. Python's type annotations are good enough that
Opus can read them and reason about bugs without a checker. The
differentiator is:

- **Beagle E10 vs Python:** 10% faster, because `--emit-patch` eliminates
  6 mechanical fixes entirely. The agent never sees them.
- **Beagle E9 vs Python:** 18% slower in absolute terms, comparable
  per-bug. Without `--emit-patch`, beagle's checker advantage is offset
  by Python's readability advantage.

The thesis holds: **mechanical bugs should compile into patches.** The
type system alone doesn't win — the repair compiler does.
