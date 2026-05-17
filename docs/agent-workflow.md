# beagle agent workflow — tool routing decision tree

When fixing bugs in a beagle project, use this decision tree to choose
the right tool at each step. The goal: minimize reasoning cycles by
letting the toolchain do mechanical work.

## First move: always run `beagle-repair`

```
beagle-repair src/ verify.clj
```

This runs the full pipeline (type check → specfix → blame) and gives you
a ranked queue. Items are tagged AUTO (apply directly) or SUGGEST (needs
judgment).

## Decision tree

```
Start
 │
 ├─ Got AUTO items in repair queue?
 │   YES → apply them (or use --auto), rebuild, rerun oracle
 │   NO  → skip to trace
 │
 ├─ Still have failures after AUTO fixes?
 │   YES → run beagle-trace to see divergence
 │   NO  → done ✓
 │
 ├─ Many failures (>5)?
 │   YES → run beagle-cascade --from-failures
 │         Fix highest cascade-score function FIRST
 │         (one fix may resolve 3-5 downstream failures)
 │   NO  → fix them individually using trace output
 │
 ├─ Trace shows wrong operator/operand?
 │   YES → swap the operator/operands at the traced source line
 │
 ├─ Trace shows wrong accessor (e.g., carrier-id where base-rate expected)?
 │   YES → check beagle-sig for the correct accessor type
 │
 ├─ Trace shows wrong argument to a function?
 │   YES → check beagle-provides for expected parameter types
 │
 └─ No clear fix from trace?
     → Read the source, reason about the domain, make judgment call
```

## Tool selection cheat sheet

| Situation | Tool | What it tells you |
|-----------|------|-------------------|
| Starting a repair session | `beagle-repair` | Full ranked queue with AUTO/SUGGEST |
| Type error with suggestion | (repair queue has it) | Which accessor/arg to use instead |
| Logic bug, assertion fails | `beagle-trace` | Exact operation + line that diverged |
| Many assertions failing | `beagle-cascade --from-failures` | Root cause(s) to fix first |
| Want to predict impact of a change | `beagle-cascade --modified fn1,fn2` | Which assertions will break |
| Need function signature | `beagle-sig fn-name src/` | Arg types and return type |
| Need record field types | `beagle-fields RecordName src/` | All fields with types + accessors |
| Need to know what module exports | `beagle-provides module.rkt` | Functions, records, types |
| Want oracle from golden code | `beagle-oracle golden/` | Auto-generated verify script |
| Comparing golden vs modified | `beagle-oracle golden/ --diff modified/` | Which functions diverge |

## Key principles

1. **Don't fix symptoms, fix roots.** If `beagle-cascade` shows a function
   with cascade score 5, fix that ONE function before touching the 5
   downstream failures it causes.

2. **Trust AUTO fixes.** They're oracle-verified (specfix) or mechanically
   determined (type checker with single suggestion). Apply them without
   reading the code.

3. **Use trace for logic bugs.** When the type system can't help (the code
   is type-correct but semantically wrong), `beagle-trace` shows the exact
   arithmetic chain. Look at the last operation in the trace — that's usually
   the bug.

4. **Rebuild after each fix batch.** Don't accumulate fixes without
   recompiling. The type checker might catch new issues exposed by earlier fixes.

5. **beagle-repair subsumes blame.** You rarely need to run `beagle-blame`
   directly — `beagle-repair` already includes blame evidence in the queue.
   Use blame standalone only for quick triage of a single failure.
