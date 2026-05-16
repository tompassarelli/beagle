# E5f: Smaller Model Bug Detection

## Hypothesis

Beagle's compile-time checker advantage grows as model capability degrades.
Opus 4 can read ~3000 LOC and find most bugs by inspection — the type checker
adds proof but not detection power. A weaker model (Sonnet, Haiku) should miss
more bugs that inspection alone would catch, making the type checker's detection
power relatively more valuable.

## Design

Same 40 bugs, same prompts, same tools, same scoring — only the model changes.

| Variable | E5d/E5e (baseline) | E5f |
|----------|-------------------|-----|
| Bugs | 40 injected | Same 40 |
| Prompt | beagle-agent.md / clojure-agent.md | Same |
| Tools | beagle-check-all, beagle-sig, etc. | Same |
| Scoring | Behavioral (E5e) | Same |
| Model | Claude Opus 4 | Claude Sonnet 4, Claude Haiku 4.5 |

## Expected outcome

| Model | Beagle prediction | Clojure prediction | Gap prediction |
|-------|------------------|-------------------|---------------|
| Opus 4 (baseline) | 85% | 90% | -5pp |
| Sonnet 4 | 70-80% | 60-70% | +5-15pp (beagle leads) |
| Haiku 4.5 | 55-70% | 40-55% | +10-20pp (beagle leads) |

Rationale: The type checker catches ~25 of 40 bugs at compile time regardless
of model capability. A weaker model fixes fewer of the remaining 15
inspection-only bugs, but beagle's 25 are guaranteed. Clojure's score degrades
across all 40 bugs because all require inspection.

## Trials

3 runs per model × track = 12 new runs:
- `e5f-sonnet-beagle-run{1,2,3}`
- `e5f-sonnet-clojure-run{1,2,3}`
- `e5f-haiku-beagle-run{1,2,3}`
- `e5f-haiku-clojure-run{1,2,3}`

## Running

```bash
# Set up trial + run agent + score (all-in-one)
bin/run-model-trial sonnet beagle 1

# Or manually:
bin/run-trial beagle 1 e5f-sonnet
claude --model claude-sonnet-4-6 --print --dangerously-skip-permissions \
  --max-budget-usd 5 --system-prompt "$(cat prompts/beagle-agent-automated.md)" \
  "Fix all bugs in trials/e5f-sonnet-beagle-run1/. Run beagle-check-all first."
bin/score-behavioral beagle trials/e5f-sonnet-beagle-run1/
```

## Controls

1. Same buggy files (copied from buggy-clean/)
2. Same prompt text (no model-specific hints)
3. Same tool availability
4. Same budget cap per trial ($5 sonnet, $2 haiku)
5. Same behavioral scoring
6. 3 runs for statistical significance
