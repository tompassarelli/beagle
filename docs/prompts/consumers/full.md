---
agent prompt model: full
---

# Beagle — full agent reference

Beagle is a statically typed language that compiles to Clojure. Files are
`.rkt` with `#lang beagle`. You probably know Clojure — Beagle is Clojure
with a type checker bolted on. Same data structures, same stdlib, same
runtime. The differences are all compile-time.

## What's different from Clojure

### Type annotations

```racket
(defn total [(qty : Int) (price : Int)] : Int
  (* qty price))
```

Params are wrapped: `(name : Type)`. Return type after the param vector.
Untyped params are allowed but the checker treats them as `Any`.

### Records

```racket
(defrecord Product [(id : Int) (name : String) (price : Int)])
```

This generates:
- Constructor: `(->Product 1 "Widget" 500)` typed `[Int String Int -> Product]`
- Accessors: `(product-id p)`, `(product-name p)`, `(product-price p)`
- Keyword access: `(:name p)` returns `String` when the checker knows `p` is `Product`
- Typed update: `(with p [:price 600])` — checks field existence AND field type

**Use `with`, not `assoc`.** `assoc` works at runtime but the checker can't
validate it. `with` catches wrong field names and wrong types at compile time.

**Use accessors, not `get`.** `(get product :name)` returns `Any`. `(product-name product)` returns `String`. Same for `(:name product)`.

### Nominal scalars (newtypes)

```racket
(defscalar Amount Int)
;; (->Amount 500)       — wrap an Int into an Amount
;; (amount-value a)     — unwrap Amount back to Int
```

Amount ≠ Int at compile time. You MUST unwrap before arithmetic and
rewrap after:

```racket
;; WRONG — checker rejects: expected Int, got Amount
(+ a b)

;; RIGHT
(->Amount (+ (amount-value a) (amount-value b)))
```

The error message `expected Int, got Amount` always means you forgot to unwrap.

### require imports everything

```racket
(require catalog :as cat)
;; cat/find-product, cat/Product, cat/->Product — all imported and typed
```

You do NOT need `declare-extern` for cross-module Beagle calls. Ever.
`declare-extern` is only for Java interop and non-Beagle namespaces.
Adding it for a Beagle function shadows the real imported type and causes
false type errors.

### cond accepts both styles

```racket
;; Bracketed
(cond [(> x 0) "pos"] [(< x 0) "neg"] [true "zero"])

;; Flat (Clojure-style)
(cond (> x 0) "pos" (< x 0) "neg" :else "zero")
```

Both are fully type-checked.

### for returns a Vec, doseq returns nil

```racket
(for [x coll] (process x))     ;; (Vec ResultType)
(doseq [x coll] (process x))   ;; Nil — side-effects only
```

### let bindings infer types

```racket
(let [x (find-product id)] ...)     ;; x : Product, inferred from RHS
(let [{:keys [name]} product] ...)  ;; name : String, from record fields
```

Don't annotate unless narrowing a union:
```racket
(let [(x : Product) (find-item id)] ...)  ;; only when find-item returns (U Product Service)
```

## Types

Primitives: `String`, `Int`, `Float`, `Bool`, `Keyword`, `Nil`, `Any`

```
[A B -> R]           function type
[A & T -> R]         variadic
(Vec T)              vector
(Map K V)            map
(Set T)              set
(U String Int)       union
String?              nullable (= (U String Nil))
```

## All expressions

```racket
(if cond then else)
(cond [test body] ... [true fallback])
(when cond body...)
(do body1 body2 ... bodyN)
(let [name val ...] body...)
(loop [name init ...] body...)
(recur arg1 arg2 ...)
(for [x coll :when pred] body...)
(doseq [x coll] body...)
(fn [params] body...)
(try body... (catch ExType e handler...) (finally cleanup...))
(case val k1 r1 k2 r2 default)
(match expr [pattern body...] ...)
(-> x (f) (g))
(->> x (f) (g))
(:key map)
[item1 item2 ...]
{k1 v1 k2 v2}
#{item1 item2}
(unsafe "raw clojure")
```

## Parameters

```racket
[(x : Int) (y : String)]            typed
[x y z]                              untyped
[{:keys [name age]}]                 map destructuring
[{:keys [x y] :as point}]           destructure + bind whole
[[a b & rest]]                       sequential destructuring
```

## Reading checker errors

This is where Beagle pays for itself. The checker output is precise enough
to fix most errors without reading the source.

### E002 — type mismatch

```
── E002 ── shipping.rkt:45 ──
  (carrier-base-rate zone)
  arg 1: expected Carrier, got DeliveryZone
  help: did you mean `zone-surcharge-pct`?
```

**"did you mean X?" is almost always correct. Use X.** Don't second-guess
the suggestion. `beagle-fix` auto-applies single-suggestion errors.

Type mismatch on an accessor call means **you called the wrong accessor**,
not that you passed the wrong variable. The variable is fine — the accessor
is for a different record type.

### E001 — arity

```
── E001 ── billing.rkt:61 ──
  (order-customer-id)
  called with 0 args, expects 1
  sig: order-customer-id : [Order -> Int]
```

Missing argument. The `sig:` line tells you exactly what to pass.

### General patterns

- E002 type mismatch → wrong accessor. Query: `beagle-fields Record .`
- E001 arity → missing/extra arg. Query: `beagle-sig fn .`
- Single suggestion → high confidence, auto-fixable
- Multiple suggestions → you choose from alternatives
- `expected Int, got Amount` → forgot to unwrap scalar
- `expected Amount, got Int` → forgot to rewrap scalar

## Tool reference

All tools are at the project's `bin/` directory.

### Reactive daemon — automatic checking after every edit

| Tool | What it does | When to use |
|------|-------------|-------------|
| `beagle-daemon start --watch .` | Start daemon + inotify watcher on all .rkt files | **Step 0.** Start this before anything else. Re-checks every file within ~100ms of a save. |
| `beagle-daemon query check-enriched .` | Synchronous: full type check + enriched context (JSON) | When you need a fresh check without the watcher. |
| `beagle-daemon query check-result FILE` | Return cached check result for one file (instant) | When you want to peek at the latest result without triggering a new check. |
| `beagle-verify-enriched .build/ VERIFY` | Run verify + auto-diagnose failures with trace/cascade | After `beagle-build-all`, instead of running the raw verify script. |

When the daemon is watching and a PostToolUse hook is configured, you
get enriched diagnostics injected automatically after every file edit.
The output includes error count, fix hints, and record field context —
eliminating the need for separate `beagle-check-all`, `beagle-fields`,
and `beagle-sig` calls during the edit loop.

### Phase 1 tools — auto-fix and batch check

| Tool | What it does | When to use |
|------|-------------|-------------|
| `beagle-fix --apply .` | Auto-fix high-confidence type errors | **Always first.** Handles accessor swaps, single-candidate fixes. 6-8 mechanical fixes in zero reasoning. |
| `beagle-check-all .` | Type-check all files, show remaining errors | After fix, if the daemon isn't watching. The daemon makes this redundant during the edit loop. |
| `beagle-syntax *.rkt` | Fast paren/bracket balance check (<200ms) | **After every edit session.** Catches unmatched delimiters before you waste a compile cycle. |

### Phase 2 tools — compile and verify

| Tool | What it does |
|------|-------------|
| `beagle-build-all *.rkt --out .build/` | Compile all files to Clojure |
| `beagle-verify-enriched .build/ VERIFY` | Run verify + auto-diagnose with trace and cascade |

### Phase 3 tools — diagnose verify failures

These tools analyze behavioral failures (assertions that fail after the
code compiles and runs). `beagle-verify-enriched` calls them
automatically, but you can use them directly for targeted analysis.

| Tool | What it does | When to use |
|------|-------------|-------------|
| `beagle-repair . VERIFY` | Unified pipeline: type check + blame + specfix → ranked repair queue | When you have both type errors AND verify failures. Produces AUTO (apply blindly) and SUGGEST (needs judgment) items. |
| `beagle-repair . VERIFY --emit-patch` | Same but outputs a unified diff to stdout | Pipe to `git apply`. Eliminates ~6 mechanical fixes in one command before you start reasoning. |
| `beagle-trace .build/ VERIFY` | Per-assertion arithmetic trace showing exact divergence | When a verify assertion fails and you can't see why. Shows the full computation chain and where the value first went wrong. |
| `beagle-trace .build/ VERIFY --focus fn-name` | Trace filtered to one function | When you know which function is wrong but not which operation. |
| `beagle-cascade . VERIFY --from-failures` | Root cause analysis across call graph | When 5+ assertions fail. Often one upstream bug causes 3-5 downstream failures. Fix the root, not the symptoms. |
| `beagle-blame .build/ VERIFY` | Ratio analysis (sign error, wrong operator) | Quick triage. Usually subsumed by `beagle-repair`. |

### Query tools — replace file reads

These are faster and more reliable than reading source files. With the
reactive daemon, record field context is already included in error
output. Use these for ad-hoc lookups.

| Tool | What it does | Example |
|------|-------------|---------|
| `beagle-sig fn-name .` | Function signature | `order-total : [Order -> Amount]` |
| `beagle-fields Record .` | Record fields + accessor types | Shows all fields, their types, and accessor names |
| `beagle-callers fn-name .` | All call sites with arity | Find who calls a function and how |
| `beagle-provides file.rkt` | Module exports with types | Everything a module makes available |
| `beagle-impact fn-name .` | Downstream effects of a change | Before changing a signature, see what breaks |

**With the daemon watching, most query tool calls are unnecessary.**
The enriched error output already includes record fields for the types
mentioned in each error. Use query tools only for ad-hoc exploration
(e.g., "what does this module export?").

## Workflow — the proven sequence

This workflow comes from analyzing 7 experiment runs. Runs that follow
this pattern are consistently faster.

### Step 0: Start the reactive daemon

```bash
beagle-daemon start --watch .
```

This starts a persistent background process that watches all `.rkt` files
via inotify. **Every time you edit a file, the daemon re-checks it within
~100ms.** If a PostToolUse hook is configured, you'll see enriched type
errors automatically injected after each edit — no need to manually run
`beagle-check-all`.

The daemon also enriches errors with record field context, so you see
which accessors are available without running `beagle-fields`.

### Step 1: Mechanical fixes (zero reasoning)

```bash
beagle-fix --apply .
```

Auto-fixes 6-8 accessor swaps and single-candidate type errors. This is
free — it never introduces new bugs.

### Step 2: Remaining type errors

If the daemon is watching, you'll see errors after each edit. Otherwise:

```bash
beagle-check-all .
```

Read each error. Use the patterns above to fix them. For ambiguous errors,
query:

```bash
beagle-fields DeliveryZone .    # what accessors does this record have?
beagle-sig order-total .        # what does this function expect?
```

### Step 3: Confirm type-clean, then compile

```bash
beagle-check-all .              # should be clean
beagle-build-all *.rkt --out .build/
```

### Step 4: Run behavioral verification

Run whatever verify script exists. Read the failures.

### Step 5: Diagnose logic bugs

For each verify failure:

1. **Read the expected vs actual.** Often the pattern is obvious:
   - expected 700, got -700 → subtraction is backwards
   - expected 700, got 7 → missing `* 100` or dividing by wrong number
   - expected 700, got 0 → wrong accessor returning an ID where a value is needed

2. **If not obvious**, use trace:
   ```bash
   beagle-trace .build/ VERIFY --focus function-name
   ```

3. **If 5+ failures**, check for root causes first:
   ```bash
   beagle-cascade . VERIFY --from-failures
   ```
   Fix the highest cascade-score function first — one fix may resolve
   3-5 downstream failures.

### Step 6: Paren check after edits

```bash
beagle-syntax *.rkt
```

This catches corrupted paren balance in <200ms. Lisp-unfamiliar editing
(and Clojure-familiar editing under pressure) commonly breaks delimiter
balance. Run this after every batch of manual edits, before compiling.

### Step 7: Rebuild and re-verify

```bash
beagle-build-all *.rkt --out .build/
# run verify again
```

Repeat steps 4-7 until all assertions pass. Typical: 3-4 build-verify
cycles after the mechanical fixes are done.

## Common bug patterns

In the domain code you'll encounter:

- **Wrong operator**: `+` instead of `*`, `-` instead of `+` (especially in line-total, commission, surcharge computations)
- **Swapped operands**: `a - b` should be `b - a` (especially margin: price - cost, not cost - price)
- **Wrong accessor**: using `product-id` where `product-unit-cost` needed (the type checker catches these — trust it)
- **Wrong comparison direction**: `>` should be `<` (especially reorder-needed: stock is LOW, not HIGH)
- **Wrong divisor**: dividing by 10 instead of 100 for percentages
- **Missing arguments**: forgetting a collection parameter on lookup functions

## Repair agent pool — automatic error forking

After each file edit, a PostToolUse hook checks for type errors. If errors
are found, a **repair agent** from the pool is dispatched to fix them. The
pool autoscales from 1 to 3 agents based on demand. You will see messages
in this format:

### REPAIR_AGENT_SPAWNED

```
REPAIR_AGENT_SPAWNED: agent-a7f3 handling 3 errors in inventory.rkt (step:a7f3) [pool: 2/3]
```

**Action: do nothing.** Continue your current plan. Do NOT investigate the
errors yourself. Do NOT edit the file the repair agent is working on. The
`[pool: N/M]` shows current utilization.

### REPAIR_AGENT_DONE

```
REPAIR_AGENT_DONE: agent-a7f3 finished on inventory.rkt
  L45: swapped carrier-base-rate → zone-surcharge-pct
  L52: added missing argument `zones`
```

**Action: acknowledge and continue.** The file has been fixed. If you were
planning to work on that file next, re-read it first — it has changed.
When agents finish, queued tasks are automatically dispatched.

### REPAIR_AGENT_NEEDS_CONTEXT

```
REPAIR_AGENT_NEEDS_CONTEXT: agent-a7f3 (step:a7f3) fixing inventory.rkt
  Why was the reorder threshold changed? Is the comparison intentional?
  Write context to: .beagle/agents/agent-a7f3/response.md
```

**Action: write a brief response.** The repair agent is stuck — it needs
to understand your intent. Write 2-3 sentences to the response file
explaining what you're trying to accomplish:

```bash
cat > .beagle/agents/agent-a7f3/response.md << 'EOF'
The reorder-needed function should return true when stock is LOW (below
threshold), not high. The original code had > instead of <. The fix is
to flip the comparison operator.
EOF
```

Then continue your plan. The repair agent will pick up the response and
finish.

### REPAIR_AGENT_ACTIVE

```
REPAIR_AGENT_ACTIVE: agent-a7f3 already handling inventory.rkt
```

**Action: skip this file.** A repair agent is already working on it.
Move to a different file.

### REPAIR_POOL_FULL

```
REPAIR_POOL_FULL: shipping.rkt queued (2 in queue, 3 agents active)
```

**Action: continue working.** All agents are busy. The task is queued and
will be dispatched when an agent frees up.

### Key rules

- **Never edit a file with an active repair agent.** You'll create
  conflicts. Move to other files and come back after REPAIR_AGENT_DONE.
- **Don't duplicate the repair agent's work.** If you see SPAWNED for a
  file, trust the agent to handle it.
- **Context requests are fast.** Writing a 2-3 sentence response to
  `response.md` takes seconds and unblocks the repair agent.
- **Pool config** is at `.beagle/pool.json` — adjust `max_agents` (1-3)
  and `model` as needed.

## What NOT to do

These are mistakes observed in experiment runs that wasted time:

- **Don't skip `beagle-fix`.** It handles 6-8 fixes instantly. Doing them
  manually costs 5-10 minutes.
- **Don't read source files to understand signatures.** Use `beagle-sig`
  and `beagle-fields`. They're faster and authoritative.
- **Don't re-run a blocked command repeatedly.** If a tool fails, diagnose
  why — don't retry the same invocation.
- **Don't accumulate edits without checking.** Run `beagle-syntax` and
  `beagle-check-all` after each batch. Catching errors early is cheaper
  than debugging a cascade of type failures.
- **Don't second-guess "did you mean X?" suggestions.** They have >95%
  accuracy. Apply and move on.
- **Don't add `declare-extern` for cross-module Beagle functions.** This
  shadows the real import and causes false errors.
- **Don't use `assoc`/`get`/`update` on typed records.** Use `with`,
  accessors, and keyword access instead.
