# beagle behavior bench — scoreboard

Generated 2026-05-15 14:52:19.

Each response is compiled to Clojure, run against the task's
behavior verification script (`tasks/<task>.verify.clj`), and
timed end-to-end.

| response | variant | result | total ms |
|---|---|---|---|
| 01-greet-a-current | a-current | ✓ PASS | 556 |
| 01-greet-a-current-run-2 | a-current | ✓ PASS | 533 |
| 01-greet-a-current-run-3 | a-current | ✓ PASS | 585 |
| 01-greet-b-required | b-required | ✓ PASS | 554 |
| 01-greet-c-minimal | c-minimal | ✓ PASS | 545 |
| 10-macro-inc-a-current | a-current | ✓ PASS | 574 |
| 10-macro-inc-b-required | b-required | ✓ PASS | 547 |
| 16-factorial-a-current | a-current | ✓ PASS | 564 |
| 16-factorial-a-current-run-2 | a-current | ✓ PASS | 569 |
| 16-factorial-a-current-run-3 | a-current | ✓ PASS | 595 |
| 16-factorial-a-current-run-4 | a-current | ✓ PASS | 578 |
| 16-factorial-a-current-run-5 | a-current | ✓ PASS | 604 |
| 16-factorial-b-required | b-required | ✓ PASS | 608 |
| 16-factorial-c-minimal | c-minimal | ✓ PASS | 552 |
| 18-map-double-a-current | a-current | ✓ PASS | 574 |
| 18-map-double-b-required | b-required | ✓ PASS | 588 |
| 18-map-double-c-minimal | c-minimal | ✓ PASS | 549 |
| 19-nested-let-a-current | a-current | ✓ PASS | 557 |
| 19-nested-let-b-required | b-required | ✓ PASS | 555 |
| 21-boolean-ops-a-current | a-current | ✓ PASS | 559 |
| 21-boolean-ops-b-required | b-required | ✓ PASS | 579 |
| 21-boolean-ops-c-minimal | c-minimal | ✓ PASS | 534 |
| 22-multi-arg-macro-a-current | a-current | ✓ PASS | 562 |
| 22-multi-arg-macro-b-required | b-required | ✓ PASS | 600 |
| 22-multi-arg-macro-c-minimal | c-minimal | ✓ PASS | 563 |
| 25-cond-many-a-current | a-current | ✓ PASS | 564 |
| 25-cond-many-b-required | b-required | ✓ PASS | 592 |
| 25-cond-many-c-minimal | c-minimal | ✓ PASS | 706 |
| 26-compose-a-current | a-current | ✓ PASS | 611 |
| 26-compose-b-required | b-required | ✓ PASS | 525 |
| 26-compose-c-minimal | c-minimal | ✓ PASS | 544 |
| 27-sum-of-squares-a-current | a-current | ✓ PASS | 529 |
| 27-sum-of-squares-b-required | b-required | ✓ PASS | 573 |
| 27-sum-of-squares-c-minimal | c-minimal | ✓ PASS | 562 |
| 28-fizzbuzz-a-current | a-current | ✓ PASS | 565 |
| 28-fizzbuzz-b-required | b-required | ✓ PASS | 590 |
| 28-fizzbuzz-c-minimal | c-minimal | ✓ PASS | 557 |
| 29-gcd-a-current | a-current | ✓ PASS | 576 |
| 29-gcd-b-required | b-required | ✓ PASS | 606 |
| 29-gcd-c-minimal | c-minimal | ✓ PASS | 579 |
| 30-count-evens-a-current | a-current | ✓ PASS | 572 |
| 30-count-evens-b-required | b-required | ✓ PASS | 573 |
| 30-count-evens-c-minimal | c-minimal | ✓ PASS | 617 |
| 31-fib-a-current | a-current | ✓ PASS | 632 |
| 31-fib-b-required | b-required | ✓ PASS | 544 |
| 31-fib-c-minimal | c-minimal | ✓ PASS | 578 |
| 32-any-positive-a-current | a-current | ✓ PASS | 568 |
| 32-any-positive-c-minimal | c-minimal | ✓ PASS | 561 |
| 33-my-range-a-current | a-current | ✓ PASS | 599 |
| 33-my-range-b-required | b-required | ✓ PASS | 557 |
| 33-my-range-c-minimal | c-minimal | ✓ PASS | 575 |
| 34-nullable-safe-a-current | a-current | ✓ PASS | 570 |
| 35-cond-tritype-a-current | a-current | ✓ PASS | 586 |
| 36-mapv-inc-a-current | a-current | ✓ PASS | 538 |
| 37-filterv-even-a-current | a-current | ✓ PASS | 564 |
| 38-macro-let-hygiene-a-current | a-current | ✓ PASS | 629 |
| 39-extern-typed-call-a-current | a-current | ✓ PASS | 563 |
| 40-pipeline-transform-a-current | a-current | ✓ PASS | 613 |

## Per-variant behavior pass rates

| variant | pass | total | rate |
|---|---|---|---|
| a-current | 29 | 29 | 100.0% |
| c-minimal | 14 | 14 | 100.0% |
| b-required | 15 | 15 | 100.0% |
