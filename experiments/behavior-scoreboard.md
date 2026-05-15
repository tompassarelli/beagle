# beagle behavior bench — scoreboard

Generated 2026-05-15 13:35:02.

Each response is compiled to Clojure, run against the task's
behavior verification script (`tasks/<task>.verify.clj`), and
timed end-to-end.

| response | variant | result | total ms |
|---|---|---|---|
| 01-greet-a-current | a-current | ✓ PASS | 537 |
| 01-greet-a-current-run-2 | a-current | ✓ PASS | 553 |
| 01-greet-a-current-run-3 | a-current | ✓ PASS | 532 |
| 01-greet-b-required | b-required | ✓ PASS | 532 |
| 01-greet-c-minimal | c-minimal | ✓ PASS | 592 |
| 01-greet-d-inline | d-inline | ✓ PASS | 601 |
| 01-greet-f-schema-inline | f-schema-inline | ✓ PASS | 556 |
| 10-macro-inc-a-current | a-current | ✓ PASS | 587 |
| 10-macro-inc-b-required | b-required | ✓ PASS | 533 |
| 10-macro-inc-f-schema-inline | f-schema-inline | ✓ PASS | 580 |
| 16-factorial-a-current | a-current | ✓ PASS | 557 |
| 16-factorial-a-current-run-2 | a-current | ✓ PASS | 593 |
| 16-factorial-a-current-run-3 | a-current | ✓ PASS | 554 |
| 16-factorial-a-current-run-4 | a-current | ✓ PASS | 586 |
| 16-factorial-a-current-run-5 | a-current | ✓ PASS | 587 |
| 16-factorial-b-required | b-required | ✓ PASS | 609 |
| 16-factorial-c-minimal | c-minimal | ✓ PASS | 607 |
| 16-factorial-d-inline | d-inline | ✓ PASS | 572 |
| 16-factorial-f-schema-inline | f-schema-inline | ✓ PASS | 542 |
| 18-map-double-a-current | a-current | ✓ PASS | 601 |
| 18-map-double-b-required | b-required | ✓ PASS | 693 |
| 18-map-double-c-minimal | c-minimal | ✓ PASS | 567 |
| 18-map-double-d-inline | d-inline | ✓ PASS | 568 |
| 18-map-double-e-schema | e-schema | ✓ PASS | 557 |
| 18-map-double-f-schema-inline | f-schema-inline | ✓ PASS | 582 |
| 19-nested-let-a-current | a-current | ✓ PASS | 592 |
| 19-nested-let-b-required | b-required | ✓ PASS | 581 |
| 19-nested-let-f-schema-inline | f-schema-inline | ✓ PASS | 544 |
| 21-boolean-ops-a-current | a-current | ✓ PASS | 577 |
| 21-boolean-ops-b-required | b-required | ✓ PASS | 572 |
| 21-boolean-ops-c-minimal | c-minimal | ✓ PASS | 572 |
| 21-boolean-ops-d-inline | d-inline | ✓ PASS | 566 |
| 21-boolean-ops-f-schema-inline | f-schema-inline | ✓ PASS | 568 |
| 22-multi-arg-macro-a-current | a-current | ✓ PASS | 559 |
| 22-multi-arg-macro-b-required | b-required | ✓ PASS | 628 |
| 22-multi-arg-macro-c-minimal | c-minimal | ✓ PASS | 561 |
| 22-multi-arg-macro-d-inline | d-inline | ✓ PASS | 542 |
| 22-multi-arg-macro-e-schema | e-schema | ✓ PASS | 565 |
| 22-multi-arg-macro-f-schema-inline | f-schema-inline | ✓ PASS | 582 |
| 25-cond-many-a-current | a-current | ✓ PASS | 608 |
| 25-cond-many-b-required | b-required | ✓ PASS | 587 |
| 25-cond-many-c-minimal | c-minimal | ✓ PASS | 576 |
| 25-cond-many-d-inline | d-inline | ✓ PASS | 604 |
| 25-cond-many-e-schema | e-schema | ✓ PASS | 663 |
| 25-cond-many-f-schema-inline | f-schema-inline | ✓ PASS | 571 |
| 26-compose-a-current | a-current | ✓ PASS | 565 |
| 26-compose-c-minimal | c-minimal | ✓ PASS | 567 |
| 27-sum-of-squares-a-current | a-current | ✓ PASS | 553 |
| 27-sum-of-squares-c-minimal | c-minimal | ✓ PASS | 568 |
| 28-fizzbuzz-a-current | a-current | ✓ PASS | 579 |
| 28-fizzbuzz-c-minimal | c-minimal | ✓ PASS | 533 |
| 29-gcd-a-current | a-current | ✓ PASS | 525 |
| 29-gcd-b-required | b-required | ✓ PASS | 533 |
| 29-gcd-c-minimal | c-minimal | ✓ PASS | 606 |
| 30-count-evens-a-current | a-current | ✓ PASS | 601 |
| 30-count-evens-c-minimal | c-minimal | ✓ PASS | 569 |
| 31-fib-a-current | a-current | ✓ PASS | 554 |
| 31-fib-c-minimal | c-minimal | ✓ PASS | 552 |
| 32-any-positive-a-current | a-current | ✓ PASS | 620 |
| 32-any-positive-c-minimal | c-minimal | ✓ PASS | 568 |
| 33-my-range-a-current | a-current | ✓ PASS | 552 |
| 33-my-range-c-minimal | c-minimal | ✓ PASS | 554 |

## Per-variant behavior pass rates

| variant | pass | total | rate |
|---|---|---|---|
| d-inline | 6 | 6 | 100.0% |
| a-current | 22 | 22 | 100.0% |
| c-minimal | 14 | 14 | 100.0% |
| e-schema | 3 | 3 | 100.0% |
| f-schema-inline | 8 | 8 | 100.0% |
| b-required | 9 | 9 | 100.0% |
