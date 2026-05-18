# 003 — One idiom per concept

**Date:** 2026-05-15 afternoon  
**Commit:** `1ea7cb4`

## Decision

Ran a 6-variant benchmark comparing annotation styles:
- `:-` vs `:` as type marker
- Inline `x:Type` vs wrapped `(x : Type)` params
- Type aliases (`Long` = `Int`) vs bare primitives

Result: no measurable difference in LLM output quality for any variant.
When alternatives are equally good, fewer is better. Removed:

- `:-` annotation syntax
- Inline parameter annotations
- Type aliases
- Variants D, E, F from benchmarks

## Principle

> For every semantic concept, beagle has exactly one syntactic form.

This is the opposite of Clojure's "many ways to express the same thing"
philosophy. LLMs perform better when the syntax space is small and
unambiguous — they never have to guess which idiom is correct.

Corollary: never add a shorthand form unless it measurably improves
agent performance on benchmarks. Convenience for human aesthetics
is not a valid reason.
