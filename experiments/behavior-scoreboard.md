# beagle behavior bench — scoreboard

Generated 2026-05-15 13:31:47.

Each response is compiled to Clojure, run against the task's
behavior verification script (`tasks/<task>.verify.clj`), and
timed end-to-end.

| response | variant | result | total ms |
|---|---|---|---|
| 01-greet-a-current | a-current | ✓ PASS | 534 |
| 01-greet-a-current-run-2 | a-current | ✓ PASS | 555 |
| 01-greet-a-current-run-3 | a-current | ✓ PASS | 571 |
| 01-greet-b-required | b-required | ✓ PASS | 519 |
| 01-greet-c-minimal | c-minimal | ✓ PASS | 572 |
| 01-greet-d-inline | d-inline | ✓ PASS | 591 |
| 01-greet-f-schema-inline | f-schema-inline | ✓ PASS | 567 |
| 10-macro-inc-a-current | a-current | ✓ PASS | 578 |
| 10-macro-inc-b-required | b-required | ✓ PASS | 540 |
| 10-macro-inc-f-schema-inline | f-schema-inline | ✓ PASS | 511 |
| 16-factorial-a-current | a-current | ✓ PASS | 554 |
| 16-factorial-a-current-run-2 | a-current | ✓ PASS | 571 |
| 16-factorial-a-current-run-3 | a-current | ✓ PASS | 571 |
| 16-factorial-a-current-run-4 | a-current | ✓ PASS | 563 |
| 16-factorial-a-current-run-5 | a-current | ✓ PASS | 540 |
| 16-factorial-b-required | b-required | ✓ PASS | 565 |
| 16-factorial-c-minimal | c-minimal | ✓ PASS | 595 |
| 16-factorial-d-inline | d-inline | ✓ PASS | 555 |
| 16-factorial-f-schema-inline | f-schema-inline | ✓ PASS | 570 |
| 18-map-double-a-current | a-current | ✓ PASS | 564 |
| 18-map-double-b-required | b-required | ✓ PASS | 535 |
| 18-map-double-c-minimal | c-minimal | ✓ PASS | 536 |
| 18-map-double-d-inline | d-inline | ✓ PASS | 559 |
| 18-map-double-e-schema | e-schema | ✓ PASS | 576 |
| 18-map-double-f-schema-inline | f-schema-inline | ✓ PASS | 549 |
| 19-nested-let-a-current | a-current | ✓ PASS | 600 |
| 19-nested-let-b-required | b-required | ✓ PASS | 641 |
| 19-nested-let-f-schema-inline | f-schema-inline | ✓ PASS | 578 |
| 21-boolean-ops-a-current | a-current | ✓ PASS | 597 |
| 21-boolean-ops-b-required | b-required | ✓ PASS | 573 |
| 21-boolean-ops-c-minimal | c-minimal | ✓ PASS | 573 |
| 21-boolean-ops-d-inline | d-inline | ✓ PASS | 569 |
| 21-boolean-ops-f-schema-inline | f-schema-inline | ✓ PASS | 617 |
| 22-multi-arg-macro-a-current | a-current | ✓ PASS | 584 |
| 22-multi-arg-macro-b-required | b-required | ✓ PASS | 624 |
| 22-multi-arg-macro-c-minimal | c-minimal | ✓ PASS | 599 |
| 22-multi-arg-macro-d-inline | d-inline | ✓ PASS | 595 |
| 22-multi-arg-macro-e-schema | e-schema | ✓ PASS | 555 |
| 22-multi-arg-macro-f-schema-inline | f-schema-inline | ✓ PASS | 573 |
| 25-cond-many-a-current | a-current | ✓ PASS | 606 |
| 25-cond-many-b-required | b-required | ✓ PASS | 580 |
| 25-cond-many-c-minimal | c-minimal | ✓ PASS | 569 |
| 25-cond-many-d-inline | d-inline | ✓ PASS | 581 |
| 25-cond-many-e-schema | e-schema | ✓ PASS | 674 |
| 25-cond-many-f-schema-inline | f-schema-inline | ✓ PASS | 587 |
| 26-compose-a-current | a-current | ✓ PASS | 552 |
| 26-compose-c-minimal | c-minimal | ✓ PASS | 615 |
| 27-sum-of-squares-a-current | a-current | ✓ PASS | 594 |
| 27-sum-of-squares-c-minimal | c-minimal | ✓ PASS | 588 |
| 28-fizzbuzz-a-current | a-current | ✓ PASS | 545 |
| 28-fizzbuzz-c-minimal | c-minimal | ✓ PASS | 555 |
| 29-gcd-a-current | a-current | ✓ PASS | 588 |
| 29-gcd-b-required | b-required | ✓ PASS | 645 |
| 29-gcd-c-minimal | c-minimal | ✓ PASS | 623 |
| 30-count-evens-a-current | a-current | ✓ PASS | 624 |
| 30-count-evens-c-minimal | c-minimal | ✓ PASS | 596 |

## Per-variant behavior pass rates

| variant | pass | total | rate |
|---|---|---|---|
| d-inline | 6 | 6 | 100.0% |
| a-current | 19 | 19 | 100.0% |
| c-minimal | 11 | 11 | 100.0% |
| e-schema | 3 | 3 | 100.0% |
| f-schema-inline | 8 | 8 | 100.0% |
| b-required | 9 | 9 | 100.0% |
