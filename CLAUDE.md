# beagle — session anchor

**What beagle is + the live target list → `README.md`, or `bin/beagle langs`
(rendered from `beagle-lib/private/targets.rkt`).** Don't restate here —
that duplication is what rots. Pipeline: `parse → check → emit`, at Racket
expand-time inside our `#%module-begin`.

**No static reference docs** for forms/types/stdlib — the surface churns and
docs go stale within a day. The compiler is the source of truth: query it
(`bin/beagle sig|fields|syntax`, or `bin/beagle` for the command list).

## Architecture — read this before touching the front end

There are **exactly two hosted front-end compilers**, both ordinary
ahead-of-time `parse → check → emit`, held byte-identical by gates. Core uses
the Racket oracle front end, then lowers through source → typed → native stages
to a frozen native program before materialization:

The source-profile boundary is absolute: `.bgl` with bare `#lang beagle`
always selects Core and the native lowering pipeline. The source is not
target-neutral; the frozen native program is backend-neutral. Hosted compiler
machinery may use explicit `.bclj` and `#lang beagle/clj` while bootstrapping
that pipeline, but `.bclj` itself remains hosted Clojure source.

1. **Racket (the oracle)** — `beagle-lib/*.rkt`, all <!-- beagle:langs count -->four<!-- /beagle:langs --> targets. Entry
   points: `beagle-lib/main.rkt` (Core `#lang beagle`),
   `beagle-lib/clj/main.rkt` (hosted `#lang beagle/clj`), and
   `beagle-lib/private/check-all.rkt` (`bin/beagle check/build`). Type checker
   is `check.rkt`. Verify any doubt against the require closure of
   `check-all.rkt` — nothing else runs there.
2. **Self-hosted (`clj` target)** — `self-host/src/selfhost/*.bclj`, written
   in beagle, running as its own emitted output (`self-host/seed/`) under
   babashka. `bin/beagle-remint` enforces the bootstrap byte-fixpoint in CI;
   `self-host/verify-selfhost.sh` holds it byte-identical to the Racket
   compiler. Read `self-host/README.md` before touching it.

The Racket compiler is the conformance oracle (`bin/beagle-certify`, shrink-only
divergence ledgers); the self-hosted compiler is the language's own hosted
compiler. A hosted behavior change on one side is incomplete until the gates
prove the other side agrees — or a ledger entry records why it deliberately
doesn't. Native Core lowering is implemented in Beagle and runs from its
hosted Clojure projection; its separate contract is the frozen native program
plus the seven native obligations.

Form dispatch is the **combiner registry** in `parse.rkt`
(`register-combiner!`). Built-in special forms register there; user macros are
still a separate registry (`macros.rkt`). Both lower to typed IR before any
backend runs.

**Do not build a runtime operative/fexpr evaluator.** It's impossible — we emit
Nix, which has no runtime `eval`/reified environments.

## Standing operating mode — apply the spec, don't ratify it

The spec is **generative** — three statements determine every surface question:

1. **Beagle is Clojure plus types.** Clojure surface, types threaded through.
2. **Divergence from Clojure must be load-bearing for the type system or a backend, or it dies.** (See "Rules with teeth".)
3. **Each target renders the same surface idiomatically** (<!-- beagle:langs idioms -->Beagle Native Core frozen native program, Clojure eager persistent maps, JavaScript plain objects and ES modules, Nix lazy attrsets<!-- /beagle:langs -->). Idiomatic-per-target is not divergence.

Run a form through these and one answer falls out. **Do not surface decisions the spec already determines** — fact-finds ("what does bare `{…}` mean?" → match Clojure), unfinished analysis ("N rows ambiguous" → run the load-bearing test: does the divergence buy type precision or a backend anything?), and invisible implementation choices (AST shape, helper placement) are not forks. Pick, execute, report.

**Default mode is apply-and-report, not present-and-ratify.** No "your call" sentences or option-A/B/C menus — that is the failure mode this rule prevents. Escalate only a genuine conflict between two clauses; the ordering pre-resolves most: **types > idiom-matching > aesthetic preference**. On a real conflict, name it "real conflict: X vs Y", propose the resolution, ask one specific question — don't reopen the board.

## Surface lock — typed Clojure + inference, structural bindings

Typed Clojure plus inference. No type-fact form, no `claim`, no spec registry,
and no `s/` namespace. Type annotations are compile-time information, not
Schema/Spec. The optional constraint in a binding declaration is an explicitly
authored predicate value and emits one local runtime guard; it is not permission
to build `s/def`, conform/explain, or a general validation runtime behind it.

### Canonical spelling

The outer `[...]` is only a collection of bindings. Each entry has exactly one
of these shapes:

```text
binding := symbol
         | (binding-form Type)
         | (binding-form Type constraint)
```

A symbol is the only bare binding and requests inference. Inside a typed
declaration, `binding-form` may be a symbol or an ordinary Clojure sequential or
associative destructuring form:

```clojure
(x Int)
(x Int positive?)
([x y] (HVec Float Float))
([x y] (HVec Float Float) valid-point?)
({:keys [host port]} Config)
```

The type and optional constraint annotate the complete binding operation, not
merely an identifier:

```clojure
[a]                                    ; one inferred binding
[(a Point)]                            ; one typed binding
[a b]                                  ; two inferred bindings
[(a Point) (b Point)]                  ; two typed bindings
[a (b Point)]                          ; mixed: a inferred, b typed
[([x y] (HVec Float Float)) options]   ; typed destructure + inferred symbol
```

Bare symbols request real inference; they do not insert `Any`. A bare
destructuring form in a strict typed signature is rejected because no aggregate
type is available to project; wrap the pattern and aggregate type in one
declaration. Explicit `(value Any)` is retained for a deliberate dynamic or
unchecked boundary, and typed and bare bindings may mix. The nesting is
semantic structure, not typography. The same declaration spelling is used in
parameter and binding vectors: `fn`/`defn`/`defn-`, multi-arity clauses,
`letfn`, protocol and implementation methods, `let`, `loop`, and
record/union/error fields. Fields remain required to carry types. A typed rest
parameter is `& (more (Vec Int))`; a constrained rest parameter is
`& (more (Vec Int) nonempty?)`. Top-level `def` and `defonce` are already
structural owner forms, so their type is the positional slot after the name.

Each outer parameter-vector entry is an independent binding. `[a (b Point)]`
contains a bare binding and a typed binding; `([x y] Point)` is one typed
destructuring binding. Never reinterpret an adjacent outer entry as the type,
constraint, or metadata of the preceding binding.

### Binding constraints

The optional third element is a statically known synchronous unary predicate
`[T -> Bool]`, where `T` is the declared binding type. Its signature must not
contain `Any`; it may not take extra/rest arguments, return a non-`Bool`, or
perform asynchronous work. Call-produced predicates are accepted only when the
callee publishes an explicit positive returned-callable synchronization proof;
executing the factory synchronously is not sufficient.

Emitters apply the predicate to the complete raw incoming value before the
binding target is installed or a destructuring pattern projects names. A false
result raises a target-idiomatic runtime error and the binding body does not
run. Thus `([x y] Point2 valid-point?)` calls `valid-point?` with the `Point2`,
not with `x` or `y`. Never move the guard after projection or let the predicate
refer implicitly to names introduced by its own binding.

```clojure
(defn positive? [(value Int)] Bool (> value 0))
(defn add-positive [(left Int positive?) (right Int positive?)] Int
  (+ left right))
```

Fields use the same standard optional constraint:

```clojure
(defrecord Character
  [(id String character-id-wire?)
   (name String character-name-wire?)])
```

Macro-owned declaration DSLs may give one declaration additional validators,
encoders, decoders, or other local metadata. Every outer entry must still
contain one complete declaration, such as
`(name Type value-validator wire-validator encoder decoder)` or
`(name encoder-expression validator)`. Iterate entries directly, reject
anything that is not a declaration form, validate the exact arity, and only
then destructure it locally. Never `partition`, pair, or reconstruct
declarations from adjacent tokens. Reject a flattened field form such as
`[(id String) character-id-wire?]` with a targeted diagnostic. This rejection
is contextual: in a parameter vector the same two entries are independently a
typed `id` and a bare `character-id-wire?` binding.

Top-level typed definitions use noun then type:

```clojure
(def port Int 7978)
(let [(acc Int nonnegative?) 0] ...)
(defrecord User [(name String nonblank?) (age Int nonnegative?)])
```

Executable signatures have one mandatory positional return slot after the
parameter vector. No arrow decorates that slot:

```clojure
(defn add [(x Int) (y Int)] Int
  (+ x y))
```

The mandatory slot prevents a type-shaped first body expression from becoming
ambiguous. Function types are data, so their type-level arrow remains:
`(Fn [Int String] Bool)`. `declare-extern` uses that type-level form too.

### Typed destructuring

The wrapper may contain any supported Clojure binding form. Use a positional
type for sequential destructuring and a record/map-shaped type for associative
destructuring:

```clojure
(defalias Point2 (HVec Float Float))
(defrecord Config [(host String) (port Int)])
(defrecord Point [(x Float) (y Float)])

(defn distance [([x1 y1] Point2) ([x2 y2] Point2)] Float
  ...)

(defn endpoint [({:keys [host port]} Config)] String
  ...)

(defn point-x [({:keys [x y]} Point)] Float
  x)
```

The parser preserves the nested binding structure; ask the checker for the
precise projection supported by a particular type instead of inferring it from
the spelling alone.

### Canonical physical layout

Width alone chooses among three shapes; parameter count never does:

```clojure
;; complete owner + signature fits
(defn distance [(a Point) (b Point)] Float
  ...)

;; owner causes overflow; move [params] Return as one unit
(defn horizontal-ring-distance
  [(anchor WorldCoordinate) (coord WorldCoordinate)] Float
  ...)

;; the indented unit also overflows; expand bindings, then return
(defn complicated-distance
  [(anchor Coordinate)
   (coord Coordinate)
   (world WorldState)
   (options DistanceOptions)]
  Float
  ...)

;; a single declaration that still exceeds the width expands internally
(defn validated-coordinate
  [(coordinate
    InternationalCoordinateReferenceSystem
    coordinate-inside-supported-world-boundaries?)]
  Float
  ...)
```

The boundary is inclusive at 80 columns. Expanded vectors contain one logical
binding form per line and are never partially packed. The mandatory return
owns the next line. A declaration that is itself too wide expands its binding
form, type, and constraint internally; alignment whitespace never simulates
grouping. `beagle fmt --check` owns canonical style and `beagle fmt --write`
applies the token-aware source-range rewrite. Comment-bearing ranges that cannot
move safely are reported without a lossy rewrite; source-less macro-produced
datums have no physical-layout obligation.

### Structural declarations are the only type surface

Bindings carry type and optional constraint in one structural form. Executable
returns occupy the mandatory positional slot after the parameter vector. Do not
add a second declaration surface.

A bare capitalized binding still raises the `capitalized-binding-name` warning:

```clojure
(defn f [x Int] Any ...)
;; `Int` is a second bare parameter; did you mean `(x Int)`?
```

**Locked decisions — do not reopen:**
- `(claim NAME TYPE)` is not a form; use the structural annotation at the real
  binding site.
- Removed forms `unless` / `fmt` / `has` are rejected pointing at `when-not` /
  `str`,`format` / `contains?`.
- Typed destructuring is not a special second annotation syntax:
  `(binding-form Type [constraint])` is the declaration, and a destructure is a
  binding form.

For exact grammar, nil-narrowing, qualified-call resolution, and stdlib
nullability: ask the compiler (`parse.rkt`/`check.rkt`), which reports
pointed errors — do not trust prose here. See README "Surface highlights".

## Tool-first reflexes

Query the compiler instead of guessing. The full tool table lives in
`AGENTS.md`; the canonical command list is `bin/beagle` (no args).

When stuck after `syntax`/`check`: `bin/beagle repair DIR VERIFY --emit-patch`,
`bin/beagle-trace --focus FN`, `bin/beagle-cascade --from-failures`,
`bin/beagle-blame`, `bin/beagle-specfix`.

## Session start

Confirm the daemon up front to avoid cold-start delay:
`bin/beagle daemon status`, else `bin/beagle daemon start --watch .`
(the PostToolUse hook also auto-starts it on first edit).

## Agent loop

Trust hook output. **Never hand-count or hand-fix parens** — the PostToolUse
hook auto-balances deterministic delimiter imbalance (`beagle-syntax --repair
--write`, parinfer indent-mode, applied only when high-confidence + re-verified)
and re-reads cleanly; only genuinely-ambiguous cases (e.g. unclosed string)
surface for you. Prefer query tools over opening large files.

## Rules with teeth

The non-obvious ones an agent gets wrong otherwise.

### Zero users, zero backwards-compat

Beagle has zero external users (Tom is the only one). No deprecation, no transitional aliases, no soft hints. When a form/keyword/surface is wrong, **remove it** — make it unparseable, not discouraged. Accretion is the enemy, not breakage.

Removal means absence throughout the live tree: delete its reader/parser branch,
diagnostic kind, tests, fixtures, and authoring documentation. Generic current
reader/parser behavior owns text outside the language. Pointed errors remain
appropriate for malformed uses of current forms, not as tombstones for old ones.

Do **not** reach for deprecated-alias patterns reflexively: an alias is justified only by a real corpus migration (many live sites depending on the old spelling). For surfaces with zero corpus hits it's pure off-ramp plus a second canonical form. Recording `X → Y` in release notes is fine; an accepted-but-deprecated parser state is not.

### Gates have stated jurisdiction. When ambiguous, ASK Tom — don't defer.

Every rule in this doc that *blocks action* must carry a scope clause naming what it blocks and what it doesn't; flag any blocking rule added without one. The Phase 0 telemetry gate is the canonical case:

- **Demand-driven** features (value depends on corpus exercising them): the gate applies — wait for usage evidence before building.
- **Thesis-driven** features (founding reasons for the substrate, e.g. macros): the gate does NOT apply — the corpus can't exercise what isn't built, so gating it is a self-fulfilling deadlock.

Classify demand- vs thesis-driven *before* gating. When the classification is unclear, **ask Tom** — defaulting to "conservative + cite the gate" reads as caution but functions as a veto. Stalling under cover of a policy is failure, not safety.

### Macros

`defmacro` + quasiquote is active, supported work: `(defmacro NAME [params]
body)`. No macro-kind word or alias. Unquote `~`, splice `~@` (Clojure
syntax-quote), **uniform across ALL targets** — a metaprogramming operator never
varies by emission target. Nix `${}` string interpolation is the `(s …)`/`(ms
…)` form.

### Zero escape hatches

No `unsafe-*` (nix/js/clj), no `nix-ident`, no raw verbatim-string-to-target form — all rejected at parse time. When you hit a gap:
1. Missing stdlib function → add a one-line typed entry to `beagle-lib/private/stdlib-nix.rkt` (or `stdlib-portable.rkt`).
2. Missing surface form → add AST struct + parse case + emit case + infer case + lint traversal + test.
3. Genuinely untypable target snippet → write a sibling `.nix` file next to the `.bnix` and import it.

### Beagle is Clojure plus types, nothing else

Two sanctioned divergences from Clojure: the type layer (structural
`(binding-form Type [constraint])` declarations plus the mandatory positional
return slot and checker — see "Surface lock") and multi-backend targeting
(`target-case` + per-language prefixes — see below). Every other surface
form is plain Clojure. (Why this matters → README "What it isn't" /
"Design discipline".)

**Operating rules:**

- **Never invent syntax.** No new operators, forms, or sigils — capabilities
  that don't fit Clojure-shaped surface live in the type or backend layer.
  Use the Clojure threading family (`->`, `->>`, `as->`, `cond->`,
  `cond->>`, `some->`, `some->>`).
- **Accept-and-canonicalize is for real Clojure forms only** (`when`, `if-let`,
  `cond` flat-pair, quoted containers, list-wrapped multi-arity). Never accept
  a Beagle-specific spelling beside the Clojure one.
- **If a form is real Clojure and types fine, keep it and steer via guidance —
  don't hard-remove on taste.** Hard removal (with a pointed error naming the
  replacement) is for inventions and untypeable forms only; never silently
  translate one idiom into another.

### Prefix where meaning diverges from Clojure

Namespace any form whose behavior diverges from its Clojure namesake under a
target prefix (`nix/`, `js/`, …); bare names are reserved for Clojure-equivalent
behavior. Bare `assert` / `with` / `with-cfg` are HARD-REJECTED — only
`nix/assert` / `nix/with` / `nix/with-cfg` are accepted.

**The bare top-level namespace is for idiomatic Clojure ONLY — a hallucination
firewall (existential, per the surface-coherence policy above).** This extends
the rule from "where behavior *diverges*" to **any target-specific concept at
all**: a form that's a concept from another target (e.g. JS `async`) with NO
core-Clojure meaning still goes under its target prefix (`js/async`), never as a
bare top-level form — even though there is no Clojure namesake to "diverge" from.
Why: **bare ⇒ the model's Clojure priors are ALWAYS correct (zero hallucination);
the prefixed set is the enumerable, learnable boundary where target-specific
behavior lives** (and it compresses to a self-policing agent prompt). Polluting
the bare namespace with target-specific forms teaches agents to hallucinate
arbitrary bare forms — a dumpster fire. Keep the firewall: **bare ⇒ Clojure,
prefix ⇒ target.**

### Surface stewardship — governed divergence + periodic audit

Beagle MAY diverge from Clojure at the stdlib/form level — but ONLY through
Clojure's own extension mechanism, and governed:

- **A divergent form carries a FIXED prefix that is part of its name and shows at
  EVERY use site** (`js/await`, `nix/…`; a canonical `bgl/…` for an earned
  cross-target original) — and is **NEVER `:refer`'d into bare usage.** This is the
  load-bearing rule: the model learns from the *use site*, and `:refer`'d names get
  hallucinated as universal core forms (it already happens with Clojure's own
  refer'd names — a model sees bare `split` and assumes it's core, drops the
  require, uses it where it isn't defined). So `js/await`, never an imported bare
  `await`. **The firewall is the use site:** bare-at-use = idiomatic Clojure only;
  anything divergent is prefix-qualified at use. A divergent form must lower
  soundly to **every** emission target (it is sugar over typed IR).
- **Agents SELF-APPLY this policy — it is not a gate routed through one steward.**
  The steward (currently beagle-4) owns the *policy*, the periodic *audit*, and the
  *strategic per-target-surface design* (e.g. "does the `js/` surface make sense").
  Individual surface decisions agents make themselves against these rules; escalate
  only a genuine new-surface-area fork, not every form.
- **Escalation hierarchy:** target-specific behavior → target prefix
  (`js/`, `nix/`); a cross-target Beagle-original form → a canonical `bgl/`
  prefix (`bgl/foo` — fixed, qualified at every use, never `:refer`'d),
  promoted *from* a per-target prefix only when it earns it. **The bare
  top-level namespace stays Clojure-only, forever — nothing is ever promoted to a
  bare global form** (that breaches the hallucination firewall above).
- **Admission bar — high + DEMAND-DRIVEN.** Default REJECT. A form earns a
  `bgl/` home only after the *corpus* proves the pattern recurs AND has no
  clean existing Clojure expression. "Nice in language X" is not enough — keep it
  a local macro. Every admitted form is a small permanent cost outside the model's
  priors.
- **Periodic surface audit (the stewardship cadence).** Review across targets and
  their bespoke surfaces: enumerate the per-target surfaces, flag/fix any
  bare-namespace pollution, promote earned forms to `beagle.*`, **REMOVE** unearned
  ones (zero-users → delete, per zero-backwards-compat), and confirm every
  divergent form is queryable (`bin/beagle sig`) and reversible. The audit removes
  as much as it adds — accretion is the enemy.

### Hallucination log — data-driven surface pruning

Every hallucination gets LOGGED. A "hallucination" = Beagle code that failed (or a
"gap" an agent believed) because of a wrong Clojure/prior assumption about the
surface — a rejected/misparsed/miscompiled form, a name assumed to exist, an
inherited false gap. **Every agent, the moment it hits one, appends ONE structured
record to `hallucinations.jsonl` (repo root) — before or as it fixes it. No
hallucination goes unlogged.**

The log is the dataset we mine — cluster by `category`, rank by frequency, prune
the highest-rate divergences at the root, and watch records-per-period trend
DOWN over time. The periodic surface audit reads this to prioritize root-fixes
mathematically.

Record schema (one JSON object per line):
`{ts, agent, category, target, wrote, expected, reality, severity, resolution, fix}`
- `category`: reader | stdlib | form | dynamics | interop | prefix | roundtrip | false-gap | …
- `severity`: silent-misparse | silent-miscompile | build-reject | runtime-throw | false-gap | surface-fragmentation
- `resolution`: fixed-at-root | worked-around | form-added | fix-queued | non-gap
- `wrote` = what the agent wrote; `expected` = the wrong prior; `reality` = why it was wrong; `fix` = the ref.

Analysis: JSONL → mechanically aggregable. `bin/beagle-halluc` reports counts by
category / severity / resolution / date (the reduction-rate trend); or parse it with
any JSON tool (`bb` + `cheshire`). Reduction rate = records-per-period falling as
roots are fixed. (Future: each record is already a set of propositions
and migrates cleanly to Fram Triples — hallucination-reduction inside the one graph.)

### Test tiering during surface iteration

`bin/beagle test` runs the **active tier only**; opt into the demoted/gated
suites with per-suite env (`BEAGLE_ORACLE=1`, `BEAGLE_NIX_EVAL_CHECK=1`). Authoritative tier assignment lives in
`beagle-test/tiers.rktd` — read it, don't trust a hand-maintained list.

Fixture migrations are test **inputs**, not demoted test code: when a
surface change breaks them you **must** migrate them, not leave them alone.

### Type-system gating policies

The canonical binding grammar is `symbol | (binding-form Type [constraint])`.
Bare symbols request inference, explicit `Any` marks a dynamic boundary, and a
constraint must check as a synchronous unary `[Type -> Bool]` predicate.
Executable signatures use `[params] RET` with a mandatory positional return.
Function-type arrows remain inside type vectors. See the "Surface lock" anchor
for the complete grammar.

Deferred type-system work (refinement annotations, bidirectional Layer 2 synthesis, sourcemap fidelity, types-as-view delaborator) is tracked in contrast-doc thread `20260530180000` and `20260614120025` — not here.

## Conventions

Phase-stable surface rules, easy to get wrong:

- Params can be `param`, `map-destructure`, or `seq-destructure` structs (`ast.rkt`) — always check the predicate before calling `(param-name p)`.
- `emit-form`/`check-form` handle top-level forms; `emit-expr`/`infer-expr` handle expressions. Edit the matching level.
- **Maps/vectors/sets evaluate. Keys are keywords. `{:enable true}`.** (Closed. Do not reopen.)
- Bare vectors are structural slots: `[x y]` for params/fields/binding-zones (no `(params …)` wrapper). `'` is the inert marker for lists only (`'(a b c)` for paths/code-as-data); containers `[…]`/`{…}`/`#{…}` are never quote-prefixed.
- Combiner dispatch is the `register-combiner!` registry in `parse.rkt`.

## What changed recently — read the git log, not this file

Anything beyond the rules with teeth is in `git log` and the life-os threads.
If the surface looks different from what you expect,
`git log --since="1 week" CLAUDE.md beagle-lib/private/parse.rkt` will tell
you why.
