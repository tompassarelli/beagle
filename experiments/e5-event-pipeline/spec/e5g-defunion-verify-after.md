# E5g: defunion + verify-after workflow

## Hypothesis

With `defunion` enforcing exhaustive match (wildcards disallowed on union
types) and a verify-after workflow (inspect → fix → check ONCE), beagle
should catch category-F bugs (missing dispatch cases) that were previously
invisible to both tracks, while maintaining or improving on category A-E
detection.

## Changes from E5e baseline

| Dimension | E5e | E5g |
|-----------|-----|-----|
| Union types | none | `defunion PipelineEvent`, `CustomerProjectionInput`, `PaymentProjectionInput` |
| Match enforcement | wildcard allowed | wildcard on union type = compile error |
| Beagle prompt | checker-first iterative | verify-after (inspect first, checker as safety net) |
| Clojure prompt | same | same (unchanged) |
| Bugs | 40 | 40 (same set) |
| Expected wins | 15 type errors | 18 errors (15 original + 3 exhaustiveness) |

## What defunion catches

- **BUG-09** (handlers.rkt dispatch-event): missing `OrderDelivered`, `CustomerRegistered` cases
- **BUG-10** (projections.rkt apply-customer-event): missing `CustomerTierChanged` case  
- **BUG-23/24** (projections.rkt apply-payment-event): missing `RefundIssued` case

These are category F — "missing dispatch case" bugs that require domain
understanding to fix correctly. The checker now flags them, but the agent
still needs to add the correct implementation.

## Design

- 3 runs, Opus only
- Beagle track uses `prompts/beagle-agent-verify-after.md`
- Clojure track uses `prompts/clojure-agent-automated.md` (unchanged)
- Scoring uses same `bin/score-behavioral` as E5e

## Success criteria

- Beagle catches BUG-09, BUG-10, BUG-23, BUG-24 in all 3 runs
- Overall beagle behavioral score > clojure behavioral score
- No regression on categories A-E vs E5e baseline
