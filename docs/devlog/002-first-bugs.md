# 002 — First blood: 5 bugs caught by structured errors

**Date:** 2026-05-15 morning  
**Commits:** `310b41b`–`2453b50`  
**Related:** `experiments/report.md`

## Discovery

Over 68 LLM-generated responses across increasingly complex tasks,
5 real bugs surfaced — not in the generated code, but in beagle itself:

1. Match arm fallthrough missing
2. Inline unsafe form not validated
3. Bare-form cond (Clojure-style) misparse
4. Variadic stdlib type missing for reduce
5. Arity miscounted for multi-clause defn

Each was caught because behavioral verification (running generated Clojure
against assertions) failed, then the structured error output pointed directly
at the cause.

## Method established

```
write task spec → LLM generates beagle → compile → verify against oracle
                                            ↓
                              structured error → fix → re-verify
```

This loop — spec, generate, verify, diagnose — became the standard
experimental methodology for all subsequent work.

## Insight

The behavioral oracle (assertion script) is the ground truth.
The type checker is an accelerator — it makes the fix loop cheaper,
but the oracle decides correctness. This distinction becomes critical
later (see entry 009).
