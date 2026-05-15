# beagle behavior bench — scoreboard

Generated 2026-05-15 13:52:28.

Each response is compiled to Clojure, run against the task's
behavior verification script (`tasks/<task>.verify.clj`), and
timed end-to-end.

| response | variant | result | total ms |
|---|---|---|---|
| 01-greet-a-current | a-current | ✓ PASS | 966 |
| 01-greet-a-current-run-2 | a-current | ✓ PASS | 995 |
| 01-greet-a-current-run-3 | a-current | ✓ PASS | 1008 |
| 01-greet-b-required | b-required | ✓ PASS | 980 |
| 01-greet-c-minimal | c-minimal | ✓ PASS | 957 |
| 10-macro-inc-a-current | a-current | ✓ PASS | 1063 |
| 10-macro-inc-b-required | b-required | ✓ PASS | 949 |
| 16-factorial-a-current | a-current | ✓ PASS | 1025 |
| 16-factorial-a-current-run-2 | a-current | ✓ PASS | 999 |
| 16-factorial-a-current-run-3 | a-current | ✓ PASS | 943 |
| 16-factorial-a-current-run-4 | a-current | ✓ PASS | 993 |
| 16-factorial-a-current-run-5 | a-current | ✓ PASS | 1053 |
| 16-factorial-b-required | b-required | ✓ PASS | 1010 |
| 16-factorial-c-minimal | c-minimal | ✓ PASS | 1050 |
| 18-map-double-a-current | a-current | ✓ PASS | 981 |
| 18-map-double-b-required | b-required | ✓ PASS | 941 |
| 18-map-double-c-minimal | c-minimal | ✓ PASS | 994 |
| 19-nested-let-a-current | a-current | ✓ PASS | 997 |
| 19-nested-let-b-required | b-required | ✓ PASS | 1024 |
| 21-boolean-ops-a-current | a-current | ✓ PASS | 1053 |
| 21-boolean-ops-b-required | b-required | ✓ PASS | 975 |
| 21-boolean-ops-c-minimal | c-minimal | ✓ PASS | 1050 |
| 22-multi-arg-macro-a-current | a-current | ✓ PASS | 996 |
| 22-multi-arg-macro-b-required | b-required | ✓ PASS | 940 |
| 22-multi-arg-macro-c-minimal | c-minimal | ✓ PASS | 971 |
| 25-cond-many-a-current | a-current | ✓ PASS | 988 |
| 25-cond-many-b-required | b-required | ✓ PASS | 959 |
| 25-cond-many-c-minimal | c-minimal | ✓ PASS | 1011 |
| 26-compose-a-current | a-current | ✓ PASS | 1019 |
| 26-compose-b-required | b-required | ✓ PASS | 1008 |
| 26-compose-c-minimal | c-minimal | ✓ PASS | 1050 |
| 27-sum-of-squares-a-current | a-current | ✓ PASS | 1066 |
| 27-sum-of-squares-b-required | b-required | ✓ PASS | 1008 |
| 27-sum-of-squares-c-minimal | c-minimal | ✓ PASS | 1052 |
| 28-fizzbuzz-a-current | a-current | ✓ PASS | 988 |
| 28-fizzbuzz-b-required | b-required | ✓ PASS | 1082 |
| 28-fizzbuzz-c-minimal | c-minimal | ✓ PASS | 1054 |
| 29-gcd-a-current | a-current | ✓ PASS | 1016 |
| 29-gcd-b-required | b-required | ✓ PASS | 1062 |
| 29-gcd-c-minimal | c-minimal | ✓ PASS | 1010 |
| 30-count-evens-a-current | a-current | ✓ PASS | 1000 |
| 30-count-evens-b-required | b-required | ✓ PASS | 977 |
| 30-count-evens-c-minimal | c-minimal | ✓ PASS | 979 |
| 31-fib-a-current | a-current | ✓ PASS | 968 |
| 31-fib-b-required | b-required | ✓ PASS | 1036 |
| 31-fib-c-minimal | c-minimal | ✓ PASS | 1077 |
| 32-any-positive-a-current | a-current | ✓ PASS | 1012 |
| 32-any-positive-c-minimal | c-minimal | ✓ PASS | 1072 |
| 33-my-range-a-current | a-current | ✓ PASS | 983 |
| 33-my-range-b-required | b-required | ✓ PASS | 982 |
| 33-my-range-c-minimal | c-minimal | ✓ PASS | 1007 |

## Per-variant behavior pass rates

| variant | pass | total | rate |
|---|---|---|---|
| a-current | 22 | 22 | 100.0% |
| c-minimal | 14 | 14 | 100.0% |
| b-required | 15 | 15 | 100.0% |
