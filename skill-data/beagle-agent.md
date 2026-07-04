# Agent editing workflow

## Session start

1. Run `bin/beagle daemon status` — start with `bin/beagle daemon start --watch .` if needed
2. Run `bin/beagle doctor` to verify environment readiness

## Edit loop

After every edit to a beagle file (.bgl, .bclj, .bjs, .bnix, .bsql):

1. Fix **syntax errors first** — `bin/beagle syntax FILE`
2. Then type-check — `bin/beagle daemon query check-enriched FILE`
3. Review diagnostics — each has an `error-code` (E001–E015) and `fix-safety` label
4. For unknown codes — `bin/beagle explain E002`
5. Auto-apply fixes with `fix-safety: type-directed` or `behavior-preserving`
6. Pause for human review on `fix-safety: requires-human-review` or `api-changing`

## Before opening large files — use query tools

- `bin/beagle sig NAME FILE...` — function signature
- `bin/beagle fields RECORD FILE...` — record fields and types
- `bin/beagle callers NAME FILE...` — find all call sites
- `bin/beagle provides FILE...` — module exports with types
- `bin/beagle impact NAME FILE...` — callers + change impact

## When stuck — escalate to repair tools

- `bin/beagle repair ... --emit-patch` — unified repair pipeline
- `bin/beagle-trace ... --focus FN` — execution trace
- `bin/beagle-cascade ... --from-failures` — root cause analysis
- `bin/beagle-blame ...` — error attribution
- `bin/beagle-specfix ...` — speculative fix with oracle verification

## Fix safety labels

Every fix suggestion includes a `fix-safety` label:

| Label | Meaning | Agent action |
|-------|---------|--------------|
| format-only | Whitespace/style only | Auto-apply |
| type-directed | Type-checker guided replacement | Auto-apply |
| behavior-preserving | Semantically equivalent | Auto-apply |
| local-behavior-change | Changes local behavior only | Apply with caution |
| api-changing | Changes public API | Human review required |
| requires-human-review | Ambiguous intent | Human review required |

## Diagnostic codes

Run `bin/beagle explain --list` for the full catalog. Key codes:

- E001: Arity mismatch
- E002: Type mismatch (most common)
- E003: Return type mismatch
- E004: Definition type mismatch
- E005: Let binding type mismatch
- E006: Non-exhaustive match (critical — missing cases crash at runtime)
