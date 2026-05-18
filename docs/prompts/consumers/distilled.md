---
agent prompt model: distilled
---

# Beagle — Clojure delta

You know Clojure. Beagle is Clojure with static types. Files are `.rkt`
with `#lang beagle`. Compiles to plain `.clj`.

## What's different

**Type annotations** — params and return:
```racket
(defn total [(qty : Int) (price : Int)] : Int (* qty price))
```

**Records** — typed constructors, accessors, keyword access:
```racket
(defrecord Product [(id : Int) (name : String) (price : Int)])
(->Product 1 "Widget" 500)   ;; [Int String Int -> Product]
(product-name p)              ;; [Product -> String]
(:name p)                     ;; also typed
(with p [:price 600])         ;; typed update (use this, not assoc)
```

**Scalars** — newtypes, must unwrap/rewrap for arithmetic:
```racket
(defscalar Amount Int)
(->Amount (+ (amount-value a) (amount-value b)))
```

**require** imports everything: `(require catalog :as cat)`.
No `declare-extern` needed for cross-module Beagle calls.

Types: `String`, `Int`, `Float`, `Bool`, `Keyword`, `Nil`, `Any`,
`(Vec T)`, `(Map K V)`, `(Set T)`, `(U A B)`, `String?`

## Reading checker errors

```
E002: expected Carrier, got DeliveryZone → wrong accessor, not wrong variable
E001: called with 0 args, expects 1    → missing argument
"did you mean X?"                      → yes, use X
```

## Workflow

```bash
beagle-daemon start --watch .           # reactive: re-checks on every file save
beagle-fix --apply .                    # auto-fix mechanical type errors
# edit files — daemon shows errors after each edit
beagle-syntax *.rkt                     # paren balance after edits
beagle-build-all *.rkt --out .build/    # compile
# run verify
```

## Diagnosis tools

```bash
beagle-verify-enriched .build/ VERIFY   # verify + auto-diagnose failures
beagle-trace .build/ VERIFY --focus fn  # arithmetic trace for one function
beagle-cascade . VERIFY --from-failures # root cause when 5+ failures
```

## Query tools

With the daemon watching, record fields are included in error output.
These are for ad-hoc lookups:

```bash
beagle-sig fn-name .        # signature
beagle-fields Record .      # fields + accessor types
beagle-callers fn-name .    # call sites
beagle-provides file.rkt    # module exports
beagle-impact fn-name .     # downstream effects
```

## Repair agent pool

After each edit, a repair agent may be dispatched from the pool (1-3
agents, autoscaling) to fix type errors. Messages:

- **`REPAIR_AGENT_SPAWNED`** — agent fixing errors. **Do not edit that
  file.** Continue on other files. `[pool: N/M]` shows utilization.
- **`REPAIR_AGENT_DONE`** — agent finished. Re-read the file if needed.
- **`REPAIR_AGENT_NEEDS_CONTEXT`** — agent stuck. Write 2-3 sentences
  to the `response.md` path explaining your intent.
- **`REPAIR_AGENT_ACTIVE`** — agent already on that file. Skip it.
- **`REPAIR_POOL_FULL`** — task queued. Will dispatch when agent frees up.

Never edit a file with an active repair agent. Pool config: `.beagle/pool.json`.
