# 001 — Genesis: can types help LLMs write Clojure?

**Date:** 2026-05-15 morning  
**Commits:** `a514aee`–`f8b1a70`

## Premise

Clojure is an excellent AI authoring target — small syntax, uniform data,
minimal ceremony. But LLMs make shape errors: wrong arity, wrong field
access, wrong argument order. These produce runtime explosions (Java stack
traces) that are expensive to diagnose.

Hypothesis: a typed authoring layer that compiles to Clojure can catch
these errors at compile time, producing structured diagnostics the agent
can act on mechanically rather than reasoning through stack traces.

## Design choices (committed early)

- S-expressions, AST-based (non-negotiable foundation)
- Custom `#lang` reader preserving `[]` vs `()`
- Wrapped params only: `(x : Type)` — unambiguous, no lookahead
- Strict mode default — dynamic as escape hatch
- Stdlib extern catalog (~607 Clojure functions pre-typed)
- Compile to plain Clojure source — zero runtime dependency

## First validation

17 benchmark tasks, 3 LLM-written responses each. 100% behavioral
correctness after fixes. The pipeline works: parse → check → emit.

## Key insight

The leverage isn't in catching errors per se — it's in catching them
with enough structure that the fix is mechanical. An error message that
says "line 37: expected Order, got Int, did you mean order-total?"
eliminates a 5-call reasoning loop.
