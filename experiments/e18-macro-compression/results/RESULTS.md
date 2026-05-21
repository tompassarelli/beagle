# E18: Procedural macro compression — results

**Date:** 2026-05-21

## Method

Three patterns, each with hand-written baseline and proc macro version.
Both compile through full pipeline and run in Babashka with identical
output (verified). LOC = non-blank, non-comment, non-#lang lines.

## Pattern 1: CRUD scaffold

3 entities (User, Product, Order), each with 4 fields.
Each entity needs: defrecord + 4 typed getters + constructor alias.

| Variant | Macro def | Per entity | 3 entities | 10 entities | 20 entities |
|---------|:---------:|:----------:|:----------:|:-----------:|:-----------:|
| Baseline | — | 7 lines | 21 lines | 70 lines | 140 lines |
| Proc macro | 22 lines | 1 line | 25 lines | 32 lines | 42 lines |

**Crossover: 4 entities.** Below that, the macro definition cost dominates.
Above it, compression grows linearly: 3.3× at 20 entities.

Template macros **cannot** express this pattern — they can't iterate
over a field list to generate N accessor functions.

## Pattern 2: State machine

Order lifecycle with 5 transitions and 2 terminal states.
Needs: transition function + valid-event? predicate + terminal? predicate.

| Variant | Macro def | Per machine | 1 machine | 3 machines |
|---------|:---------:|:-----------:|:---------:|:----------:|
| Baseline | — | 25 lines | 25 lines | 75 lines |
| Proc macro | 24 lines | 5 lines | 29 lines | 39 lines |

**Crossover: 2 machines.** The proc macro's advantage is that the
transition table is data, not code — adding a state or transition is
one line in the table, not conditional-branch surgery across 3 functions.

Template macros **cannot** express this — the cond clause generation
requires iterating over the transition list and wrapping in brackets.

## Pattern 3: API client

3 resources (users, products, orders), each with list/get/create endpoints.

| Variant | Macro def | Per resource | 3 resources | 10 resources |
|---------|:---------:|:------------:|:-----------:|:------------:|
| Baseline | — | 7 lines | 21 lines | 70 lines |
| Proc macro | 16 lines | 2 lines | 22 lines | 36 lines |

**Crossover: 3 resources.** Barely breaks even at the test size.
Strong at scale (1.9× at 10 resources).

## Summary

| Pattern | Template possible? | Crossover | 10× compression | 20× compression |
|---------|:------------------:|:---------:|:---------------:|:---------------:|
| CRUD scaffold | No | 4 entities | 2.2× | 3.3× |
| State machine | No | 2 machines | 1.9× | — |
| API client | No | 3 resources | 1.9× | 2.7× |

### Key findings

1. **Template macros can't do any of these.** All three patterns
   require iterating over data to generate variable numbers of forms.
   This is the structural gap between template substitution and
   procedural macros.

2. **Compression scales linearly with repetition.** The macro
   definition is a fixed cost. Each additional entity/machine/resource
   costs 1-5 lines vs 7-25 lines by hand. The more entities, the
   bigger the win.

3. **Crossover is 2-4 instances.** Below that, the macro definition
   cost makes the proc macro version longer than hand-written. This
   is expected and fine — the macro is worth writing when you have
   enough instances to amortize it.

4. **The real win is structural, not just LOC.** Adding a field to
   the CRUD macro propagates to all entities automatically. Adding a
   transition to the state machine is one line in the table. Hand-
   written code requires finding and editing N sites.

### Comparison to HOF

Higher-order functions can compress some of these patterns at runtime
but can't generate typed top-level forms (defrecord, defn with
annotations). The proc macro operates at compile time, producing
forms that go through the type checker. HOF would need untyped maps
and lose the checker's coverage.

## Next: E19

E18 establishes the ceiling: proc macros compress 2-3× at realistic
scale, and template macros can't express the patterns at all. E19
asks: can an agent write these macros, given beagle-expand as
the feedback mechanism?
