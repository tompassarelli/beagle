# Program 1: Score Statistics

Given a vector of test scores (integers), write functions that compute:

1. `score-avg` — takes a vector of scores, returns the integer average (use `quot` for integer division)
2. `score-min` — returns the minimum score (or nil if empty)
3. `score-max` — returns the maximum score (or nil if empty)
4. `count-passing` — count of scores >= 60
5. `letter-grade` — given a single score: >=90 "A", >=80 "B", >=70 "C", >=60 "D", else "F"
6. `summarize` — takes a vector of scores, returns a vector: [avg min max passing-count grade-of-avg]

All functions should handle edge cases (empty vectors where applicable).

Define `demo-result` as `(summarize [95 82 67 44 91 73])`.
