# beagle behavior bench — scoreboard

Generated 2026-05-15 13:29:58.

Each response is compiled to Clojure, run against the task's
behavior verification script (`tasks/<task>.verify.clj`), and
timed end-to-end.

| response | variant | result | total ms |
|---|---|---|---|
| 01-greet-a-current | a-current | ✓ PASS | 545 |
| 01-greet-a-current-run-2 | a-current | ✓ PASS | 578 |
| 01-greet-a-current-run-3 | a-current | ✓ PASS | 561 |
| 01-greet-b-required | b-required | ✓ PASS | 560 |
| 01-greet-c-minimal | c-minimal | ✓ PASS | 542 |
| 01-greet-d-inline | d-inline | ✓ PASS | 588 |
| 01-greet-f-schema-inline | f-schema-inline | ✓ PASS | 565 |
| 10-macro-inc-a-current | a-current | ✓ PASS | 544 |
| 10-macro-inc-b-required | b-required | ✓ PASS | 566 |
| 10-macro-inc-f-schema-inline | f-schema-inline | ✓ PASS | 594 |
| 16-factorial-a-current | a-current | ✓ PASS | 572 |
| 16-factorial-a-current-run-2 | a-current | ✓ PASS | 541 |
| 16-factorial-a-current-run-3 | a-current | ✓ PASS | 564 |
| 16-factorial-a-current-run-4 | a-current | ✓ PASS | 568 |
| 16-factorial-a-current-run-5 | a-current | ✓ PASS | 562 |
| 16-factorial-b-required | b-required | ✓ PASS | 553 |
| 16-factorial-c-minimal | c-minimal | ✓ PASS | 550 |
| 16-factorial-d-inline | d-inline | ✓ PASS | 539 |
| 16-factorial-f-schema-inline | f-schema-inline | ✓ PASS | 564 |
| 18-map-double-a-current | a-current | ✓ PASS | 560 |
| 18-map-double-b-required | b-required | ✓ PASS | 551 |
| 18-map-double-c-minimal | c-minimal | ✓ PASS | 556 |
| 18-map-double-d-inline | d-inline | ✓ PASS | 582 |
| 18-map-double-e-schema | e-schema | ✓ PASS | 595 |
| 18-map-double-f-schema-inline | f-schema-inline | ✓ PASS | 566 |
| 19-nested-let-a-current | a-current | ✓ PASS | 530 |
| 19-nested-let-b-required | b-required | ✓ PASS | 540 |
| 19-nested-let-f-schema-inline | f-schema-inline | ✓ PASS | 590 |
| 21-boolean-ops-a-current | a-current | ✓ PASS | 580 |
| 21-boolean-ops-b-required | b-required | ✓ PASS | 553 |
| 21-boolean-ops-c-minimal | c-minimal | ✓ PASS | 547 |
| 21-boolean-ops-d-inline | d-inline | ✓ PASS | 567 |
| 21-boolean-ops-f-schema-inline | f-schema-inline | ✓ PASS | 611 |
| 22-multi-arg-macro-a-current | a-current | ✓ PASS | 560 |
| 22-multi-arg-macro-b-required | b-required | ✓ PASS | 542 |
| 22-multi-arg-macro-c-minimal | c-minimal | ✓ PASS | 554 |
| 22-multi-arg-macro-d-inline | d-inline | ✓ PASS | 575 |
| 22-multi-arg-macro-e-schema | e-schema | ✓ PASS | 593 |
| 22-multi-arg-macro-f-schema-inline | f-schema-inline | ✓ PASS | 594 |
| 25-cond-many-a-current | a-current | ✓ PASS | 544 |
| 25-cond-many-b-required | b-required | ✓ PASS | 570 |
| 25-cond-many-c-minimal | c-minimal | ✓ PASS | 592 |
| 25-cond-many-d-inline | d-inline | ✓ PASS | 597 |
| 25-cond-many-e-schema | e-schema | ✓ PASS | 557 |
| 25-cond-many-f-schema-inline | f-schema-inline | ✓ PASS | 553 |
| 26-compose-a-current | a-current | ✓ PASS | 561 |
| 26-compose-c-minimal | c-minimal | ✓ PASS | 585 |
| 27-sum-of-squares-a-current | a-current | ✓ PASS | 605 |
| 27-sum-of-squares-c-minimal | c-minimal | ✓ PASS | 537 |
| 28-fizzbuzz-a-current | a-current | ✓ PASS | 526 |
| 28-fizzbuzz-c-minimal | c-minimal | ✓ PASS | 546 |

## Per-variant behavior pass rates

| variant | pass | total | rate |
|---|---|---|---|
| d-inline | 6 | 6 | 100.0% |
| a-current | 17 | 17 | 100.0% |
| c-minimal | 9 | 9 | 100.0% |
| e-schema | 3 | 3 | 100.0% |
| f-schema-inline | 8 | 8 | 100.0% |
| b-required | 8 | 8 | 100.0% |
