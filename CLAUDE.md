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
the Racket oracle front end, then lowers to a frozen Native World before
materialization:

The source-profile boundary is absolute: `.bgl` with bare `#lang beagle`
always selects Core and the native lowering pipeline. The source is not
target-neutral; the frozen Native World is backend-neutral. Hosted compiler
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
doesn't. Native World lowering is implemented in Beagle and runs from its
hosted Clojure projection; its separate contract is the frozen world plus the
seven native obligations.

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
3. **Each target renders the same surface idiomatically** (<!-- beagle:langs idioms -->Beagle Native Core frozen Native World, Clojure eager persistent maps, JavaScript plain objects and ES modules, Nix lazy attrsets<!-- /beagle:langs -->). Idiomatic-per-target is not divergence.

Run a form through these and one answer falls out. **Do not surface decisions the spec already determines** — fact-finds ("what does bare `{…}` mean?" → match Clojure), unfinished analysis ("N rows ambiguous" → run the load-bearing test: does the divergence buy type precision or a backend anything?), and invisible implementation choices (AST shape, helper placement) are not forks. Pick, execute, report.

**Default mode is apply-and-report, not present-and-ratify.** No "your call" sentences or option-A/B/C menus — that is the failure mode this rule prevents. Escalate only a genuine conflict between two clauses; the ordering pre-resolves most: **types > idiom-matching > aesthetic preference**. On a real conflict, name it "real conflict: X vs Y", propose the resolution, ask one specific question — don't reopen the board.

## Surface lock — typed Clojure + inference, postfix `:`/`->` inline

Typed Clojure plus inference. No type-fact form, no `claim`, no spec
registry, no `s/` namespace, no validation runtime. Type info rides ordinary
bindings via inline postfix annotations at boundaries; interiors and
`let`-locals are inferred. The annotation is annotation only (not
Schema/Spec) — never build a spec registry, `s/def`, conform/explain, or
validation runtime behind it.

`NAME: TYPE` is the canonical typed-binding marker; return types use
`[params] -> RET` after the param vector. Together these annotate the four
boundaries `def` / `defonce` / `defn` (params + return) / `defrecord`
(fields required). Parameter vectors may mix typed and inferred entries.

Parameter and typed-field vectors have one canonical physical layout. A vector
with zero, one, or two logical entries stays inline when the complete owner
signature through any `-> RET` fits within 80 columns. Three or more entries
always put the vector on the following line; an over-width zero-, one-, or
two-entry signature does the same. A vertical vector has its first entry beside
`[` and every later logical entry starting once per line at the same column.
The `[` is exactly two columns past the owning form's opening parenthesis; `]`
remains after the final entry and is followed by exactly one space before any
`-> RET`. Never partially wrap a vector. Binding names are left-aligned at that
shared entry-start column. A typed entry is parenthesized `(NAME : TYPE)` with
exactly one space on each side of `:`; never pad names, colons, or types into
columns:

```clojure
(defn add [(left : Int) (r : Int)] -> Int
  (+ left r))

(defrecord Point [(x : Int) (y : Int)])
```

Thus `[(abc : Int) (b : String) (bc : (Vec Int))]` lays out as:

```clojure
[(abc : Int)
 (b : String)
 (bc : (Vec Int))]
```

Do not pad the type column:

```clojure
[(abc : Int)
 (b   : String)
 (bc  : (Vec Int))]
```

Do not indent shorter names to align the colons:

```clojure
[(abc : Int)
   (b : String)
  (bc : (Vec Int))]
```

A typed `(name : Type)`, destructuring form, or `& rest` pair is one logical
entry. The same rule covers `defn`/`defn-`/`fn`, multi-arity clauses, `letfn`,
protocol and implementation methods, `defmacro`, and typed record/union/error
fields. It does not apply to data vectors or let-style value-binding vectors.
The reader accepts physical layout; `beagle fmt --check` owns canonical style
and `beagle fmt --write` applies the same token-aware source-range rewrite —
including rewriting a flat `name: Type` entry into `(name : Type)`. A `defmacro`
param vector has no typed-binding grammar, so it keeps layout rules and is never
wrapped. Comment-bearing ranges that cannot move safely are reported without a
lossy rewrite. Source-less macro-produced datums have no physical-layout
obligation.

**This is a DUAL-ACCEPT cut — write the canonical spelling, but know what the
parser actually does** (`postfix-annotation-parse.rkt` is the contract):
- `(x : Int)` in a binding vector / `-> Ret` — canonical, silent.
- `x: Int` in a binding vector — ACCEPTED (~20k live sites), but `fmt --check`
  reports it as drift and `fmt --write` rewrites it to `(x : Int)`. Acceptance
  is NOT deprecated; only the canonical spelling moved.
- `x: Int` outside a binding vector (`def`, `defonce`, `let`) — canonical.
- `x :- Int` / `:- Ret` — legacy, still PARSES with one
  `legacy-annotation-marker` warning per source. Not yet an error, and the
  formatter leaves it alone.
- `x : Int` (space before the colon, unwrapped) — indistinguishable from
  `x: Int` at the reader, so it is ACCEPTED in binding position; `fmt` folds it
  into the canonical `(x : Int)`.
- `: Ret` in RETURN position — REJECTED, pointing at `-> Ret`. This is the one
  structural difference between the two positions.
- `[x : Int]` in binding position — REJECTED, pointing at `(x : Int)`. `[...]`
  is sequential destructuring at every binding site, so a bracketed annotation
  is a collision, not a spelling; the wrapped form uses parens.
- `(PATTERN : Type)` in a PARAM slot — the pattern may be a name, `[a b]`, or
  `{:keys [...]}`; the declared type is what callers are checked against.
  `let`/`loop` still take a name only in the wrapped form.

The removal cut flips `legacy-annotation-marker-mode` to `'error` and drops
`LEGACY-MARKER` from the marker predicates in `parse.rkt`; it is blocked on the
vendored `bin/test/facts-roundtrip-selfhost/fram-resolve-corpus/` (~750 legacy
sites) and the self-host dual-accept tests.

**Locked decisions — do not reopen:**
- `(claim NAME TYPE)` is not a form; the parser hard-rejects it pointing at inline `NAME: TYPE`.
- Removed forms `unless` / `fmt` / `has` are rejected pointing at `when-not` / `str`,`format` / `contains?`.

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

Removals must reject with a **pointed error naming the replacement** (e.g. `(:use ...) is not supported — use (:require [lib :refer [sym ...]])`), not a cryptic downstream misparse. A removal with a confusing error is half the win.

Do **not** reach for deprecated-alias patterns reflexively: an alias is justified only by a real corpus migration (many live sites depending on the old spelling). For surfaces with zero corpus hits it's pure off-ramp plus a second canonical form. Recording `X → Y` in release notes is fine; an accepted-but-deprecated parser state is not.

### Gates have stated jurisdiction. When ambiguous, ASK Tom — don't defer.

Every rule in this doc that *blocks action* must carry a scope clause naming what it blocks and what it doesn't; flag any blocking rule added without one. The Phase 0 telemetry gate is the canonical case:

- **Demand-driven** features (value depends on corpus exercising them): the gate applies — wait for usage evidence before building.
- **Thesis-driven** features (founding reasons for the substrate, e.g. macros): the gate does NOT apply — the corpus can't exercise what isn't built, so gating it is a self-fulfilling deadlock.

Classify demand- vs thesis-driven *before* gating. When the classification is unclear, **ask Tom** — defaulting to "conservative + cite the gate" reads as caution but functions as a veto. Stalling under cover of a policy is failure, not safety.

### Macros

`defmacro` + quasiquote is active, supported work. `(define-macro ...)` is hard-rejected at parse time (`'legacy-macro-form` in `parse.rkt`) — write `(defmacro NAME [params] body)`. No `safe`/`unsafe` kind word, no alias. Unquote `~`, splice `~@` (Clojure syntax-quote), **uniform across ALL targets** — a metaprogramming operator never varies by emission target. nix `${}` string interpolation is the `(s …)`/`(ms …)` form; the old `~"…"`/`~''…''` tilde-string reader sugar (which squatted on `~` and made nix's reader the lone divergent one) is removed in favor of `(s …)`.

### Zero escape hatches

No `unsafe-*` (nix/js/clj), no `nix-ident`, no raw verbatim-string-to-target form — all rejected at parse time. When you hit a gap:
1. Missing stdlib function → add a one-line typed entry to `beagle-lib/private/stdlib-nix.rkt` (or `stdlib-portable.rkt`).
2. Missing surface form → add AST struct + parse case + emit case + infer case + lint traversal + test.
3. Genuinely untypable target snippet → write a sibling `.nix` file next to the `.bnix` and import it.

### Beagle is Clojure plus types, nothing else

Two sanctioned divergences from Clojure: the type layer (postfix
`NAME: TYPE` / `-> RET` annotations + checker — see "Surface lock") and multi-backend targeting
(`target-case` + per-language prefixes — see below). Every other surface
form is plain Clojure. (Why this matters → README "What it isn't" /
"Design discipline".)

**Operating rules:**

- **Never invent syntax.** No new operators, forms, or sigils — capabilities
  that don't fit Clojure-shaped surface live in the type or backend layer.
  The pipe family (`|>`, `|>>`, `pipe-to`, `pipe-from`) was hard-removed for
  this reason; use the Clojure threading family (`->`, `->>`, `as->`,
  `cond->`, `cond->>`, `some->`, `some->>`).
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

The canonical typed-binding surface is postfix `NAME: TYPE` / `[params] -> RET`. The one spelling HARD-REJECTED today is a `:`-marked RETURN (`(defn add [x: Int] : Int ...)`), which points at `-> Int`; legacy `:-` is still accepted with a warning during the dual-accept cut. See the "Surface lock" anchor for the full accept/reject matrix — it is the only place that describes it accurately. A second type-producing glyph is an ambiguity surface ML/Rust-trained models will wander into, which is why `:-` is on a removal path rather than a permanent alias.

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
