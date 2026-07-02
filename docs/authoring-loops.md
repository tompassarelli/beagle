# Authoring loops — the vocabulary

One principle decides every name here: **loops repair; components don't.**
Name a loop by what it converges; name a component by what it emits. The term
"repair compiler" violated this — the compiler never repaired anything, it
diagnosed. The model repaired. The loop converged. This page fixes the
vocabulary and shows how the loops compose.

## Terms

**oracle** — anything that returns a mechanical verdict + diagnostics for a
proposed change. The beagle compiler is the primary oracle; witness checks,
roundtrip checks, and build gates are oracles too. No judgment inside.
*(Prior art: test oracle, software-testing literature.)*

**diagnostics** — an oracle's structured failure output, written to be acted
on. *Agent-grade diagnostics* is the property people meant by "repair
compiler": errors that state what broke, where, and what would satisfy the
oracle (`beagle check --agent`). The compiler diagnoses; it never repairs.
*(Prior art: Elm/rustc diagnostics tradition.)*

**oracle ladder** — the ordered verification tiers a change climbs:
parse → apply/graph-gate → compile → build → witness. A change is *green*
when it tops the ladder; a failure names its rung.
*(Exapts the existing "graceful ladder" flip-level vocabulary.)*

**repair loop** — the convergence protocol around ONE change:
propose → oracle verdict → if red, diagnostics feed back → repropose.
Retries resume from the lowest failing rung. This is the term that survives
from "repair-compiler loop" — the loop is the repairer; the compiler is its
oracle. *(Prior art: APR generate-and-validate; TDD red→green.)*

**edit channel** — HOW a change lands: text re-emit (whole-file, def-level)
or graph edit (claim changeset). Channels differ in cost and blast; they
share one oracle ladder. *(Already house vocabulary: "edit-channel".)*

**blast zone** — what a change can reach: transitive callers/dependents,
derived from the codegraph. This is *edit* diagnostics, not *error*
diagnostics — consulted before proposing, not after failing.
*(Prior art: change-impact analysis; "blast radius" from ops.)*

**reasoning loop** — the agent's cycle around one task: gather context
(blast zone, claims, docs) → form intent → drive repair loops → verify
intent against witnesses → record the outcome as claims. The only loop with
judgment in it. *(Prior art: OODA; the agentic loop.)*

**task loop** — session scale: many reasoning loops under one goal,
coordinated through threads and concerns. Above it sits the program.

## Composition

```
program
  ⊃ task loop            (threads/concerns coordinate)
    ⊃ reasoning loop     (judgment: what should change)
      ⊃ repair loop      (convergence: make it green)
        ⊃ oracle ladder  (mechanical: is it green)
```

- the **blast zone** feeds the reasoning loop *before* an edit
- **diagnostics** feed the repair loop *after* a check
- **witnesses** close the reasoning loop *after* green

## Deprecated

- **"repair compiler" / "repair-compiler loop"** — wrong subject; the
  compiler diagnoses, the loop repairs. Say *the compiler* (component),
  *agent-grade diagnostics* (its property), *repair loop* (the protocol).
- **"chartroom"** for the code graph — use *codegraph* (rename thread
  019f2037-dfda).
