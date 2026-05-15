# Program 2: Nullable Data Pipeline

You have employee records as vectors of 3 elements: [name score active?]
where name is a String, score is a Long or nil (some employees have no score),
and active? is a Boolean.

Write:

1. `active-only` — filter to only active records (where the 3rd element is true)
2. `fill-score` — replace nil scores with 0: for each record, if score is nil, set it to 0
3. `top-scorers` — given records (after fill), return names of employees with score > 80
4. `process-employees` — compose: active-only → fill-score → top-scorers

Define sample data:
```
(def employees [["Alice" 92 true] ["Bob" nil true] ["Carol" 85 false]
                ["Dave" nil false] ["Eve" 88 true] ["Frank" 45 true]])
```

Define `demo-result` as `(process-employees employees)`.

Expected: `demo-result` is `["Alice" "Eve"]` — only active employees with score > 80.
