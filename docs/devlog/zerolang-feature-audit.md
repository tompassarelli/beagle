# Zerolang Feature Audit — Ideas Worth Stealing

Audit date: 2026-05-20
Source: zerolang (Apache 2.0), head-to-head comparison.

---

## Tier 1 — High Impact (changes how agents write beagle)

### 1. Named Error Sets on Function Signatures

**What zero does:**
```zero
fun parse(ok: Bool) -> i32 raises { InvalidInput, MalformedData } {
    if !ok { raise InvalidInput }
    return 42
}
```
The compiler validates that callers either `check` (propagate) or `rescue` (handle)
every error, and that explicit error sets are closed — you can't raise an error you
didn't declare. Callers with their own explicit sets must list every error their
callees might produce. This is checked transitively at compile time.

**What beagle has today:**
`(Result T E)` defunion + exhaustive match. This catches forgotten `Err` branches,
but doesn't enforce *what* errors a function can produce at the signature level.
Nothing stops you from returning `(Err "whatever")` with an unstructured string.

**The gap:**
Beagle has no way to say "this function can fail with exactly these named errors
and no others." The caller has no compile-time guarantee about the error domain.

**Proposed design:**
```racket
;; Declare named error sets on defn
(defn parse [(ok : Bool)] : (Result Int) :raises #{InvalidInput MalformedData}
  (if ok
    (Ok 42)
    (Err InvalidInput)))

;; Caller must handle or propagate all declared errors
(defn run [] : (Result Int) :raises #{InvalidInput MalformedData}
  (check (parse true)))   ;; propagates error set to caller

;; Local recovery (doesn't need :raises)
(defn safe-run [] : Int
  (rescue (parse true) 0))  ;; fallback on any error
```

The checker validates:
- `:raises` set is closed — function body can only produce listed errors
- `check` propagates: caller's `:raises` must be a superset of callee's
- `rescue` handles: caller doesn't need `:raises`
- Omitting `:raises` on a function that calls `check` is a compile error

**Why this matters for agents:**
Agents currently have to grep call chains to understand what can go wrong.
Named error sets make the error domain machine-readable at the signature.

---

### 2. Capability / Effect Tracking

**What zero does:**
The `World` parameter gates all I/O. Functions that do I/O must accept `World`.
`zero graph --json` reports per-function effects: `{args, env, fs, net, proc,
time, rand, web}`. An agent can inspect the call graph and know exactly which
functions touch the filesystem vs the network vs nothing.

**What beagle has today:**
No effect tracking at all. `println`, file I/O, HTTP calls, atom mutations — all
invisible to the type system. The agent must read every function body to know if
it's pure.

**The gap:**
Beagle can't answer "which functions in this module do I/O?" without reading
every line. This matters for: refactoring (can I move this to a pure module?),
testing (do I need mocks?), and cross-target porting (does this use JS-only APIs?).

**Proposed design:**
```racket
;; Effect annotations on defn (inferred or explicit)
(defn fetch-user [(id : Int)] : (Result User) :effects #{net}
  (let [resp (http-get (str "/users/" id))]
    (parse-user resp)))

(defn pure-transform [(u : User)] : String  ;; no :effects = pure
  (str (user-name u) " (" (user-email u) ")"))

;; Checker infers effects from call graph when not annotated
;; beagle-check --json reports effects per function
;; beagle-graph --json includes effect edges
```

Start with 6 effects: `#{io print fs net time rand}`.
Inference-first: checker walks the call graph and infers effects bottom-up.
Explicit annotations are optional but validated against inferred set.
Pure functions (no effects) are the default — no annotation needed.

**Why this matters for agents:**
Agents can use `beagle-graph` to partition code into pure/effectful without
reading bodies. Test generation knows which functions need mocks. Cross-target
migration knows which functions use target-specific capabilities.

---

### 3. `check` / `rescue` Forms for Result Handling

**What zero does:**
```zero
let value = check parse(true)       // propagate error, unwrap Ok
let safe = parse(false) rescue err { 0 }  // handle locally, provide fallback
```
`check` is mandatory at every fallible call site — you can't silently ignore a
Result. `rescue` is the local-recovery escape hatch.

**What beagle has today:**
Pattern matching on Result:
```racket
(match (parse true)
  [(Ok v) v]
  [(Err e) 0])
```
This works but is verbose for the common "just propagate" case, and nothing
forces you to actually match — you can bind a Result and forget about it.

**Proposed design:**
```racket
;; check — propagate error, unwrap Ok (requires :raises on enclosing defn)
(let [value (check (parse true))])

;; rescue — local fallback (no :raises needed)
(let [safe (rescue (parse false) 0)])

;; rescue with error binding
(let [safe (rescue (parse false) err (do (log err) 0))])

;; Calling a :raises function without check or rescue = compile error
(parse true)  ;; ERROR: unchecked fallible call — use (check ...) or (rescue ...)
```

**Why this matters for agents:**
- Eliminates the "forgot to handle the error" class of bugs entirely
- Reduces 4-line match blocks to 1-line `check` calls for the propagation case
- Makes error flow grep-able: search for `check` and `rescue` to find all error
  handling points

---

### 4. Target-Conditional Compilation (Meta Expressions)

**What zero does:**
```zero
const enabled: Bool = meta (target.os == "linux" && target.pointerWidth >= 32)
const fields: usize = meta fieldCount(Point)
```
Compile-time evaluation with access to target facts and type reflection.
Bounded execution (no infinite loops), sandboxed (no I/O).

**What beagle has today:**
Nothing. All 5 targets see the same code. Target-specific behavior requires
separate files (`.bclj` vs `.bjs` vs `.bnix`). No way to write a single
function that adapts to the target.

**The gap:**
Beagle already has 5 targets. A portable module that needs slightly different
behavior per target must currently be split into 5 files with duplicated logic.

**Proposed design:**
```racket
;; target-conditional expression
(defn sleep-ms [(ms : Int)] : Nil
  (target
    :clj  (Thread/sleep ms)
    :js   (await (js-promise-timeout ms))
    :nix  nil))  ;; nix is pure, no sleep

;; Compile-time type reflection
(meta (field-count Point))       ;; => Int literal
(meta (has-field? Point :name))  ;; => Bool literal
(meta (target))                  ;; => :clj, :js, :nix, :sql, :cljs
```

The `target` form is eliminated at emit time — only the matching branch
survives. Type checker validates all branches but only emits one.
`meta` expressions evaluate at check time with access to type metadata.

**Why this matters for agents:**
Agents writing portable beagle code can handle target differences inline
instead of maintaining parallel files. The type checker validates all branches
so cross-target correctness is checked even when building for one target.

---

### 5. Fix Safety Classification

**What zero does:**
Every repair suggestion carries a `fixSafety` label:
- `format-only` — whitespace/style, always safe to auto-apply
- `behavior-preserving` — semantically equivalent, safe to auto-apply
- `local-edit` — changes behavior but only locally, agent should apply
- `api-changing` — changes public API, needs human review
- `requires-human-review` — ambiguous intent, must not auto-apply

**What beagle has today:**
`beagle-fix` and `beagle-repair` report suggestions but with no safety
classification. `beagle-specfix` has confidence scores but they measure
"likely correct," not "safe to auto-apply."

**The gap:**
An agent using beagle-repair can't distinguish "rename this local variable"
from "change this public function's signature" without understanding the
fix semantics itself. Zero's labels let agents make automation decisions
without understanding the fix.

**Proposed design:**
Add `fix-safety` field to all repair/fix JSON output:
```json
{
  "diagnostic": "type-mismatch",
  "fix": "swap-accessor",
  "fix-safety": "local-edit",
  "confidence": 0.92,
  "summary": "Replace (user-name u) with (user-email u)"
}
```

Classification rules:
- `format-only`: indentation, parens, whitespace
- `behavior-preserving`: redundant cast removal, dead branch elimination
- `local-edit`: accessor swap, arg reorder, type annotation fix (private scope)
- `api-changing`: defn signature change, defrecord field change, export change
- `requires-human-review`: ambiguous alternatives, multiple valid fixes

**Why this matters for agents:**
Agents can auto-apply `format-only` and `behavior-preserving` fixes in a
tight loop without human confirmation, dramatically speeding up the repair
cycle. `api-changing` and `requires-human-review` pause for confirmation.

---

## Tier 2 — Medium Impact (improves tooling quality)

### 6. `beagle-doctor` — Environment & Target Readiness

**What zero does:**
`zero doctor --json` checks host toolchain, target compilers, sysroots, and
reports a readiness matrix per target. Agents run it at session start to know
what's possible before attempting builds.

**What beagle has today:**
No equivalent. If Racket is missing, or a target runtime isn't installed, the
agent discovers this by watching a build fail.

**Proposed:**
```bash
beagle-doctor --json
# {
#   "status": "warning",
#   "host": "linux-x64",
#   "checks": [
#     {"name": "racket", "status": "ok", "version": "8.14"},
#     {"name": "clojure-cli", "status": "ok", "version": "1.12"},
#     {"name": "node", "status": "ok", "version": "22.1"},
#     {"name": "nix", "status": "ok", "version": "2.24"},
#     {"name": "daemon", "status": "warning", "message": "not running"}
#   ],
#   "targets": [
#     {"name": "clj", "status": "ok"},
#     {"name": "js", "status": "ok"},
#     {"name": "nix", "status": "ok"},
#     {"name": "sql", "status": "ok"},
#     {"name": "cljs", "status": "warning", "message": "shadow-cljs not found"}
#   ]
# }
```

### 7. `beagle-explain` — Per-Diagnostic Deep Help

**What zero does:**
`zero explain --json TYP009` returns structured metadata: title, summary, why,
repair suggestion with ID, and bad/good code examples. Agents load this on
demand instead of parsing prose error messages.

**What beagle has today:**
Error messages include "did you mean?" suggestions inline, but no dedicated
explain command with structured examples.

**Proposed:**
```bash
beagle-explain --json type-mismatch
# {
#   "code": "type-mismatch",
#   "title": "Type mismatch in function argument",
#   "summary": "Argument type doesn't match parameter annotation",
#   "why": "Beagle checks argument types against defn annotations...",
#   "examples": {
#     "bad": "(defn greet [(name : Int)] : String (str \"Hi \" name))\n(greet \"Tom\")",
#     "good": "(defn greet [(name : String)] : String (str \"Hi \" name))\n(greet \"Tom\")"
#   },
#   "repair": {"id": "fix-argument-type", "summary": "Change argument type or call site"}
# }
```

### 8. `schemaVersion` on All JSON Output

**What zero does:**
Every JSON command output starts with `"schemaVersion": 1`. This lets agents
detect breaking changes and adapt. Agents can assert `schemaVersion == 1` and
fail gracefully if the contract changes.

**What beagle has today:**
JSON error output has no version field. Format changes silently break agent
parsers.

**Proposed:**
Add `"schemaVersion": 1` to all `--json` / `BEAGLE_ERROR_FORMAT=json` output.
Bump when fields are removed or meanings change. Adding new fields doesn't bump.

### 9. `beagle-size` — Emitted Code Size Analysis (JS Target)

**What zero does:**
`zero size --json` breaks down artifact size by function, section, literal,
stdlib helper — with retention reasons explaining why each piece exists.

**What beagle has today:**
Nothing. For the JS target especially, emitted bundle size matters and agents
have no way to understand what's contributing to it.

**Proposed:**
```bash
beagle-size --json --target js src/app.bjs
# {
#   "totalBytes": 4280,
#   "functions": [
#     {"name": "fetch-users", "bytes": 320, "effects": ["net"]},
#     {"name": "render-list", "bytes": 180, "effects": ["io"]}
#   ],
#   "stdlib": [
#     {"name": "str", "bytes": 45, "retained-by": ["fetch-users", "render-list"]},
#     {"name": "map", "bytes": 120, "retained-by": ["render-list"]}
#   ],
#   "literals": {"count": 12, "bytes": 340}
# }
```

### 10. Version-Matched Skill Bundling

**What zero does:**
`zero skills list` / `zero skills get zero-agent` — every compiler binary
carries its own workflow documentation. Agents always get the right docs for
the installed version, not stale docs from training data.

**What beagle has today:**
CLAUDE.md and docs/ are in the repo, loaded by convention. If docs drift from
tool behavior, agents use stale information.

**Proposed:**
```bash
beagle skills list
# beagle-agent      Agent editing workflow
# beagle-types      Type system reference
# beagle-repair     Repair tool routing
# beagle-targets    Multi-target guide
# beagle-stdlib     Stdlib catalog

beagle skills get beagle-agent
# (prints version-matched workflow doc)
```

Embed skill text in the Racket source (or a data directory read at runtime).
Version-stamp each skill. Agent sessions start with `beagle skills get beagle-agent`.

---

## Tier 3 — Nice to Have (polish and depth)

### 11. Structured `expected` / `actual` on All Type Errors

**What zero does:**
Every type mismatch diagnostic includes machine-readable `expected` and `actual`
fields, not just a prose message.

**What beagle has today:**
Some errors include this, but it's inconsistent.

**Proposed:**
Ensure all type-mismatch JSON errors include:
```json
{"expected": "String", "actual": "Int", "position": "argument 2 of greet"}
```

### 12. Deterministic Emit Verification

**What zero does:**
`releaseTargetContract` and repeat-build hash policy. Build the same input
twice, get the same output byte-for-byte.

**What beagle has today:**
No verification. Gensym counters, hash map ordering, and timestamp-dependent
output could produce non-deterministic emits.

**Proposed:**
`beagle-build --verify-deterministic` — build twice, compare output hashes,
report any differences. Fix sources of non-determinism (gensym seeding,
map iteration order in emitter).

### 13. Call Graph with Effect Annotations

**What zero does:**
`zero graph --json` includes per-symbol effects, allocation behavior, target
support, and ownership facts.

**What beagle has today:**
`beagle-callers` and `beagle-impact` show call relationships but no
effect or purity information.

**Proposed:**
If effect tracking (item 2) is implemented, propagate effect annotations
into `beagle-impact` and a new `beagle-graph --json` output.

### 14. General-Purpose `defer` / Cleanup Form

**What zero does:**
`defer` statements run at scope exit regardless of error path. Not tied to
specific resource types.

**What beagle has today:**
`(with-open ...)` for CLJ (Java Closeable). Nothing general for JS target.
No way to say "run this cleanup when this scope exits."

**Proposed:**
```racket
(with-cleanup [(cleanup-expr)]
  body ...)

;; Example:
(with-cleanup [(close-connection conn)]
  (let [data (query conn "SELECT ...")]
    (process data)))
```

Emits try/finally on CLJ, try/finally on JS. The cleanup expression runs
regardless of whether body succeeds or throws.

### 15. `beagle-abi` — Cross-Target Type Compatibility

**What zero does:**
`zero abi check --json` validates C ABI compatibility for exported types.

**Beagle equivalent:**
When writing code that crosses target boundaries (e.g., a beagle module used
from both CLJ and CLJS), validate that the emitted shapes are compatible.

```bash
beagle-abi check --targets clj,cljs src/shared.bclj
# Reports: which defrecords, defunions, defn signatures are compatible
# across the specified targets, and which diverge.
```

---

## Priority Order for Implementation

Recommended sequence based on effort/impact ratio:

1. **Fix safety classification** (#5) — small change, huge agent-loop improvement
2. **schemaVersion on JSON output** (#8) — trivial, prevents future breakage
3. **check/rescue forms** (#3) — moderate effort, big ergonomic win
4. **Named error sets** (#1) — builds on #3, completes the error story
5. **beagle-doctor** (#6) — small standalone tool, immediate agent value
6. **beagle-explain** (#7) — small standalone tool, pairs with existing diagnostics
7. **Target-conditional compilation** (#4) — moderate effort, unlocks portable modules
8. **Capability/effect tracking** (#2) — largest effort, largest long-term payoff
9. **beagle-size for JS** (#9) — moderate effort, JS-target-specific value
10. **Version-matched skills** (#10) — moderate effort, version-correctness guarantee
11–15: Lower priority, implement as opportunities arise.
