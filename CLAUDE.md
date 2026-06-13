# beagle — session anchor

A typed authoring IR. **Clj, CLJS, and Nix are live targets.** Zig, JS,
Py, Rkt, SQL emitters are parked under `beagle-lib/private/dormant/` and
reactivate with `BEAGLE_ALL_TARGETS=1`. Odin is the next native target. Pipeline:
`parse → check → emit`, all at Racket expand-time inside our custom
`#%module-begin`.

There is **no static reference documentation** for the form set, types,
or stdlib. The surface churns; static docs go stale within a day. The
compiler is the source of truth — query it.

## Standing operating mode — apply the spec, don't ratify it

The spec is **generative.** Three statements determine every surface
question:

1. **Beagle is Clojure plus types.** Clojure surface, types threaded
   through. Nothing else.
2. **Divergence from Clojure must be load-bearing for the type
   system or for a backend, or it dies.** See "Rules with teeth" for
   the codified detail.
3. **Each target renders the same surface idiomatically** (Nix as
   lazy attrsets, Clojure as eager maps, CLJS as Clojure-shaped JS).
   Idiomatic-per-target is not a divergence — it's the same form
   rendered faithfully per backend.

These three constraints **produce** answers, they don't ask for
them. Run a form through them and exactly one answer falls out.
There are no open surface decisions to ratify — only the spec to
apply.

**Do not surface "decisions" the spec already determines.** Three
failure modes that historically reach Tom and shouldn't:

- **Fact-finds disguised as choices.** *"What does bare `{…}`
  mean?"* — go read what Clojure does and match it. The authority
  is Clojure's semantics; the parser is interesting only as a
  conformance check (does it conform; if not, it's a bug), never
  as a fork.
- **Unfinished analysis disguised as ambiguity.** *"These N rows
  are ambiguous"* almost always means "the load-bearing test wasn't
  run to completion." Run the test — does this divergence buy type
  precision or a backend anything? — and the rows resolve
  themselves. "Ambiguous" without that pass is incomplete work,
  not a real fork.
- **Invisible implementation choices** with zero surface
  consequence. Internal AST shape, parse-rewrite vs native macro
  expansion, helper-function placement — these produce identical
  observable output and **never reach Tom**. The agent picks,
  executes, reports.

**Escalate only a genuine conflict between two clauses of the
rule** — e.g., a form where matching Clojure exactly would cost
type precision. Most such conflicts are pre-resolved in the
ordering: **load-bearing-for-types outranks idiom-matching** when
they collide; **idiom-matching outranks aesthetic preference**
always. When a real conflict appears: name it as "real conflict:
X vs Y", propose the resolution, ask one specific question, do
not reopen the rest of the board.

**Default mode is apply-and-report**, not present-and-ratify.
Report what was done and what was measured (test counts, type
errors surfaced, perf deltas, byte-identical-output proofs).
"Your call" sentences and option-A/B/C menus are the failure mode
this rule exists to prevent. If you find yourself drafting one,
check whether the spec resolves it. It almost always does.

## Surface lock — typed Clojure + inference, `:-` inline

The surface is **typed Clojure plus inference**. There is no
separate type-fact form, no `claim`, no spec registry, no `s/`
namespace, no validation runtime. Type information rides on
ordinary Clojure bindings via inline `:-` annotations at
boundaries; interiors are inferred.

**Annotation syntax (the only typed-binding surface):**
- `(def NAME :- TYPE VALUE)` — top-level binding with type.
- `(defn NAME [PARAM :- TYPE ...] :- RETURN-TYPE BODY)` — typed params and return.
- `(defonce NAME :- TYPE VALUE)` — same shape as def.
- `(defrecord NAME [field :- TYPE field2 :- TYPE2 ...])` — record
  fields use the same flat grammar as params; types required (records
  are typed boundaries).
- Mixed param vectors are legal: `[a :- Int b c :- String]` — `a`
  typed, `b` inferred, `c` typed.
- Docstrings are real Clojure surface and accepted everywhere Clojure
  accepts them: `(def N "doc" V)`, `(def N :- T "doc" V)`,
  `(defn N "doc" [params] ...)` — carried through to clj/cljs emit.
- Locals and `let`-bindings are inferred unless inference can't
  reach; if a local needs help, prefer refactoring the boundary
  annotation.

**Nil-narrowing (2026-06-12):** the checker flow-narrows nullable
locals through guards — `nil?`/`some?`/`not=`-nil leaves, bare
truthiness (so `if-let`/`when-let`/`when-some` narrow), `not`
inversion, `and`/`or` composition with De Morgan, sequential
narrowing across `and`/`or` arguments, and `cond` clauses seeing
prior tests' negations. Bindings only — field paths `(:k p)` don't
narrow; bind-then-guard (`if-let`) is the idiom. Bare truthiness
never falsy-narrows a Bool-containing union (could be `false`).
Nullable-honest stdlib returns (`parse-long` → `Int?`,
`System/getenv` → `String?`, …) live as clj-table overrides;
unguarded use in a non-nil position is a pointed compile error.

**Qualified-call resolution (clj/cljs, 2026-06-12):** an unresolved
namespace alias (`fs/x` with no `(require babashka.fs :as fs)`) is a
pointed compile error suggesting the require line; a missing member in
a catalog-known namespace gets a did-you-mean note; a required
namespace with no typed entries gets one "unchecked" note — the
demand-driven to-type queue for stdlib-bb.rkt. Sibling-module type
imports warn (never silently void) on failure.

**Clojure-surface guarantees (hardened 2026-06-12):** the full
`(ns name "doc"? (:require libspec...) (:import spec...))` form, quoted
`(require '[lib :as a])` libspecs, `#(... % %2 %&)` fn shorthand,
map-destructure `:or`/`:as`, and nested seq destructure `[[k v] m]` all
parse, type-check, and emit. Malformed meta forms and special forms
raise pointed errors — nothing falls through to the call-form
passthrough or drops silently. Variadic fns satisfy fixed-arity fn
positions (`(mapv str xs)` checks). `unless`/`fmt`/`has` are removed
(use `when-not` / `str`,`format` / `contains?`).

**Lowering:** `:-` annotations lower to Clojure-family `^Type`
metadata at clj/cljs emit. Nix emit consumes them through the
type checker but produces untyped Nix output (Nix doesn't carry
source-level type hints).

**`:-` is annotation only.** It is not Schema and not Spec. There
is no spec registry behind it, no `s/def`, no `s/fdef`, no
validation runtime, no conform/explain. The glyph carries the
Schema/core.typed prior because that prior reads correctly as
"has type"; the machinery those libraries put behind the glyph is
not part of Beagle.

**`(claim NAME TYPE)` is not a form.** The parser rejects it with
a pointed error naming the inline `:-` replacement. This decision
is locked at the anchor level — do not reopen.

## Tool-first reflexes

Use these before reading source or guessing. Each one is a dynamic
answer to a question a static doc would otherwise try to encode.

| question | tool |
|---|---|
| does this file parse? where? | `bin/beagle-syntax FILE` (`--ledger`, `--repair --emit-patch`) |
| does this file type-check? | `bin/beagle-check --agent FILE` (`beagle-op-*` is the quarantined operative pipeline — gated behind `BEAGLE_EXPERIMENTAL_OPERATIVE=1`, not the default) |
| what's the signature of X? | `bin/beagle-sig X FILE...` |
| what fields does record R have? | `bin/beagle-fields R FILE...` |
| who calls X? | `bin/beagle-callers X FILE...` |
| what does FILE export? | `bin/beagle-provides FILE` |
| change-impact for X? | `bin/beagle-impact X FILE...` |
| show macro expansion | `bin/beagle-expand FILE` |
| run tests | `bin/beagle-test` (active-tier default, includes Nix + Clj + CLJS) |
| compile this | `bin/beagle-build FILE [OUT]` |

When stuck after ordinary checks: `bin/beagle-repair --emit-patch`,
`bin/beagle-trace --focus FN`, `bin/beagle-cascade --from-failures`,
`bin/beagle-blame`, `bin/beagle-specfix`.

For the form set, read `beagle-lib/private/parse.rkt`. For the typed
externs, read `beagle-lib/private/stdlib-nix.rkt` and `stdlib-portable.rkt`.

## Session start

1. Confirm daemon: `bin/beagle-daemon status`. Start with
   `bin/beagle-daemon start --watch .` if absent — the PostToolUse
   hook auto-starts it on first edit but confirming up front avoids
   cold-start delay.

## Agent loop

1. Trust hook output. Fix syntax errors before type errors. Never
   count parens by hand — `bin/beagle-syntax` already counted them.
2. Use query tools above before opening large files.
3. Use `--emit-patch` tools before manual repair.

## Rules with teeth

These are the non-obvious ones an agent will get wrong otherwise.

### Zero users, zero backwards-compat reasoning

Beagle has **zero external users**. Tom is the only user. There is no
installed base, no downstream consumers, no migration to ease. **Stop
reasoning about backwards compatibility, deprecation paths,
transitional aliases, or "not breaking existing code."** None of that
exists here.

When a form, keyword, or surface is wrong, **REMOVE IT.** Do not
deprecate, do not alias, do not emit a soft hint and leave it
accepted. Hard removal. Make the wrong thing unparseable, not merely
discouraged.

The cost model is the inverse of a language with users: every
transitional courtesy is pure bloat with no offsetting benefit, and
it accumulates fast. **Accretion is the enemy, not breakage. There is
no one to break.**

When removing something, the parser must reject with a **pointed
error that names the replacement** — e.g. "`(def x : Int 42)` is
not supported — use `(def x :- Int 42)`" — not a cryptic
downstream error from the grammar misparsing the offending shape.
The repair loop's value is "wrong surface, here's the right one";
a removal that produces a confusing error is half the win.

The `assert` → `nix/assert` / `with` → `nix/with` work used a
transitional-alias pattern (bare form accepted as deprecated alias
during corpus migration). **That pattern was the wrong default** and
must not be applied reflexively. It made sense only because the
corpus had 98 sites depending on the bare spelling — a real
migration. For surfaces with **zero corpus hits**, an alias is an
off-ramp for a road nobody is on, plus a latent second surface that
violates the one-canonical-form property the rest of the rules are
trying to defend.

Release notes can record `X → Y` migrations after the fact. The
record is fine. The accepted-but-deprecated parser state isn't.

### Gates have stated jurisdiction. When ambiguous, ASK, don't defer.

A blocking rule with no jurisdiction metastasizes onto everything.
Every rule in this document that *blocks action* carries a **scope
clause** naming what it blocks and what it doesn't. Unscoped
blocking rules are how a tool trying to be disciplined turns into
a tool that won't let you move.

The Phase 0 telemetry gate is the canonical example of this
distinction:

- **Demand-driven features** — speculative capabilities whose
  value depends on the corpus actually exercising them. Refinement
  types (beyond the decidable floor), bidirectional inference
  Layer 2 (full synthesis), types-as-view rendering, schema-path
  expansion to non-NixOS domains. For these, **the gate applies**:
  wait for Phase 0 rejection histograms or comparable usage
  evidence before building.

- **Thesis-driven features** — work that exists because it's a
  founding reason for the substrate, independent of current corpus
  usage. Macros (`defmacro` + quasi-quote) are the canonical
  example; see next rule. For these, **the gate does NOT apply**.
  The corpus can't exercise what isn't built, so applying a
  demand-driven gate to a thesis-driven feature is a
  self-fulfilling deadlock.

**Classification comes before gating.** When a feature might be
gated on usage evidence, first decide demand-driven vs
thesis-driven. The classification is the test, not the
conclusion: a thesis-driven feature isn't exempt because it's
favored; it's exempt because the gate's measurement mechanism
doesn't and can't apply to it.

**Tiebreaker when classification is unclear: ASK Tom, do not
defer.** The implicit default of "when uncertain, fall back to the
conservative side and cite the gate" reads as caution but
functions as a veto. Flip it: when a gate's applicability is
unclear, surface the classification question — Tom deciding in
five seconds beats parking the work for 30 days under the cover
of a policy. **Stalling under the cover of a policy is failure,
not safety.**

This rule applies to every gate added to this document going
forward. A blocking rule that doesn't name its jurisdiction
violates this rule and should be flagged when added.

### Macros are thesis-driven, not demand-driven

`defmacro` + quasi-quote is **active work**, not deferred-pending-
telemetry. The earlier "30-day rejection histogram justifies macro
work" gate was wrong and is **lifted**: it's a self-fulfilling gate
(no `defmacro` → no macro attempts → no telemetry → never
activates), and the premise was wrong anyway. Macros aren't a
demand-driven feature here. Beagle is a Lisp *specifically to watch
what AI does with macros* — that's a founding reason for the
substrate, not a feature waiting for usage evidence. The corpus
can't reach for `defmacro` when `defmacro` doesn't exist.
§4.3 of the contrast doc (`20260530180000`) saying macro-form
rejections are unlikely in any normal agent workload is *true and
irrelevant*: this isn't a normal agent workload, it's the
experiment the substrate exists to run.

Concrete decisions (already locked in
`~/code/life-os/threads/20260530160300-...`, **don't re-litigate**):
- Unquote sigil: `,` (Clojure-canonical). Currently whitespace in
  beagle's reader, so no collision.
- Splice sigil: `,@`.
- `~` stays for tilde-strings (`~"…"` / `~''…''`). Beagle-native
  syntax, no Clojure prior to fight.
- `defmacro` is the canonical and only macro definition form;
  `define-macro` is HARD-REJECTED (`'legacy-macro-form` in
  `parse-kind-cause-table`). Authors write
  `(defmacro NAME [params] body)` — no `safe`/`unsafe` kind word, no
  transitional alias.

### Zero escape hatches

No `unsafe-*` anything (no `unsafe-nix`, `unsafe-js`, `unsafe-clj`,
`unsafe-py`, `unsafe-rkt`, no `(define-macro unsafe ...)`). No
`nix-ident` or any other verbatim-string-to-target form under any name.
No `''…''`-as-raw-passthrough on bnix.

When you hit a gap:
1. Missing stdlib function → add a one-line typed entry to
   `stdlib-nix.rkt` (or `stdlib-portable.rkt`).
2. Missing surface form → add AST struct + parse case + emit case +
   infer case + lint traversal + test, same as every other form.
3. Genuinely untypable target snippet → write a sibling `.nix` file
   next to the `.bnix` and import it. The filesystem boundary is
   auditable; an inline backdoor is not.

Every typed language that shipped an escape hatch regretted it
(TypeScript `any`, Java `Object`-cast, Python `Any`-as-bailout,
Rust `unsafe`). The discipline of "no escape" forces the stdlib to
mature and makes hallucinations show up as compile errors.

### Beagle is Clojure plus types, nothing else

**Sanctioned divergences from Clojure are exactly two:**

1. **The type layer** — inline `:-` annotations on `def` / `defn` /
   `defonce`, the checker, the repair/blame loop, diagnostic-kind
   taxonomy. The thesis (minimal truth + types as view,
   `~/code/life-os/threads/20260529020859-…`) lives here. See the
   "Surface lock" anchor above for the annotation grammar.
2. **Multi-backend targeting** — `target-case` + per-backend
   lowering. Per-language namespacing (`nix/…`, eventually
   `lua/…` / `bevy/…` / `sql/…`) marks the meaning-divergence;
   see "Prefix where meaning diverges from Clojure" below.

Every other surface form is Clojure. The thesis runs on the
Clojure prior — every gratuitous deviation taxes the one asset
the project depends on.

**The test for any divergence:** does it serve the type system or
the backend story? Yes → load-bearing, keep. No → it taxes the
Clojure prior; remove. A deviation with no type or backend payoff
isn't neutral — it's precisely what the thesis exists to avoid,
because it makes the repair loop fire on language friction
instead of real bugs.

**Operating rules:**

- **Never add new syntax.** No invented operators, forms, or sigils.
  Capabilities that don't fit Clojure-shaped surface live in the
  type or backend layer, not the surface. The pipe family (`|>`,
  `|>>`, `pipe-to`, `pipe-from`) was an Elixir/F# import and was
  hard-removed for exactly this reason — a Clojure-trained agent
  never reaches for them, so they spent surface budget to teach a
  dialect quirk, which is the thesis in reverse. The Clojure
  threading family (`->`, `->>`, `as->`, `cond->`, `cond->>`,
  `some->`, `some->>`) is the canonical replacement.

- **Accept-and-canonicalize applies to real Clojure forms only**
  (`when`, `if-let`, `cond` flat-pair, quoted containers,
  list-wrapped multi-arity). It is **not** license to accept
  Beagle-specific spellings beside Clojure ones.

- **Surface reduction needs a type-system or backend reason —
  never taste.** Steering toward a chosen idiom lives in
  guidance/prompt text; the rejected idiom gets a pointed error
  naming the replacement (per "Zero users" rule). Never silently
  translate one idiom into another.

- **"One canonical idiom is cleaner" is a guidance decision, not
  a removal.** If a form is real Clojure and types fine, keep it
  and steer via guidance rather than hard-removing. The reduction
  reflex applies to *inventions* and *untypeable* forms, not to
  idiomatic Clojure the checker can handle.

Not a new Lisp — a strict, typed *subset* of one.

The turtles pivot (uniform s-expressions, brackets removed,
`hash-map` / `vector` / `hash-set` forms) was tried mid-May 2026
and reverted in code at v0.15.3. Don't reopen that surface debate
without an extraordinary reason. The bracket-using surface
(`[]` / `{}` / `#{}`, keyword keys) is settled.

### Prefix where meaning diverges from Clojure

In beagle, namespace all Nix-specific forms under `nix/`
(`nix/assert`, `nix/with`, etc.) rather than reusing bare Clojure
names whose meaning differs in beagle. When a form's behavior
diverges from its Clojure namesake, prefix it so the name doesn't
collide with Clojure's meaning. Bare names are reserved for forms
that behave as their Clojure equivalent does.

Bare `assert` / `with-cfg` / Nix-scope `with` are HARD-REJECTED — see
commit history for the migration trace; `nix/assert` / `nix/with-cfg` /
`nix/with` are the only accepted forms. The rule above is the standing
principle that applies to every Nix-specific form whose name would
otherwise collide with a Clojure namesake.

### Test tiering during surface iteration

`bin/beagle-test` runs the **active tier only** by default — Nix, Clj,
and CLJS target tests plus the target-agnostic infrastructure. Dormant
target tests (JS, Py, Rkt, SQL) and behavioral/oracle suites are gated;
opt in with `BEAGLE_ALL_TARGETS=1` or per-suite env vars
(`BEAGLE_ORACLE=1`, `BEAGLE_NIX_EVAL_CHECK=1`).

- Active failures: fix until green.
- Demoted / gated failures during surface iteration: **leave alone.**
  The tiering exists so dormant-target test churn doesn't slow the
  active loop. The reflex to "just fix the small thing" is locally cheap
  and globally expensive across drops.

Fixture migrations are not test code — they're test inputs and **must**
be migrated when surface changes break them.

### Don't add features to the operative checker

Classic checker wins; operative is quarantined behind
`BEAGLE_EXPERIMENTAL_OPERATIVE`. Folding operative→classic or
deleting it outright is a separate plan; until then **no new
operative features without an explicit policy override** — bug
fixes to keep the quarantined path building are fine; new
capability surface there is not.

### Type-system gating policies

These four gates govern type-system work against the v0.15 surface.
Each names the rule, the contrast-doc justification (thread
`20260530180000`), and the activation condition.

1. **Refinement annotations are gated to a single demo file with a
   kill-switch.** No module or stdlib entry adopts a refinement
   annotation in source. Reason: the shipped slice is performative —
   it parses, but fires on only a 5-operator numeric-literal subset
   and is invisible to `firn-validate` (contrast doc §4.2).
   Refinement code currently lives in the operative checker, which
   is itself quarantined. Activation: the static checker handles a
   real, enumerated majority of predicate shapes (separate plan,
   currently unscoped).

2. **Bidirectional inference Layer 2 (full synthesis) is deferred.**
   Reason: the production corpus has 4 `defn`s across 224 `.bnix`
   files — building synthesis for a case that does not occur
   (contrast doc §4.1). The Any-heavy stdlib (§4.4) compounds it:
   even if synthesis shipped, it would dead-end at every arithmetic
   block. Activation: a target corpus where `defn`s are common AND
   ≥30 days of Phase 0 telemetry showing the type-error bucket would
   actually benefit. Neither condition is current.

3. **Types-as-view is a separate experiment with a 3-month kill
   criterion.** Reason: highest-novelty, zero-precedent piece in the
   contrast (§4.3). Start with a `beagle-explain-type` CLI; scale
   only if it gets used in real diagnostic-debugging sessions over
   3 months; delete otherwise. Runs on its own cadence — does NOT
   touch the classic checker, does NOT block other type-system
   work.

4. **Sourcemap fidelity (preserving error-col through
   canonicalization) is the precondition for un-deferring refinement
   work.** Reason: contrast doc §4.6 / §5.4 — without it, refinements
   regress into "diagnostics pointing at generated code the agent
   can't locate," and the whole feedback loop collapses. Not urgent
   while refinements are deferred, but the gate is recorded so
   un-deferring refinements without sourcemap fidelity in place is
   visibly out of order.

5. **Single-colon `:` type annotations are HARD-REJECTED.**
   `(def x : Int 42)` and `(defn add [x : Int] : Int body)` are NOT
   accepted by the parser — they produce an immediate, pointed
   rejection naming the inline `:-` form as the replacement (see
   "Surface lock" anchor for the canonical grammar). Reason: a
   second type-producing surface alongside `:-` is an ambiguity
   surface waiting for an AI generation or copy-paste to wander
   into it (ML/Rust-trained models will emit `(def x : Int 5)`
   from prior; a parser that accepts it lets the wrong glyph back
   in through the side door). Activation: removal landed
   2026-05-31. The empirical-purge (zero corpus hits) is now
   structural — the grammar makes the wrong form unparseable,
   which is the whole point of one canonical form.

### Where papers and plans live

Long-form design papers (role-locality, public-contracts, quarantine,
etc.) live in `~/code/life-os/threads/` with YAML front matter per the
threads/CLAUDE.md spec. **Do not** recreate `~/code/beagle/docs/` — it
was deliberately deleted. In-repo prose belongs under
`lab/journal/synthesis/` if anywhere.

## Conventions

Phase-stable and easy to get wrong:

- `ANY` is `(type-prim 'Any)` — the universal escape type
- `MAP-TAG` and `SET-TAG` are `'#%map` and `'#%set` (well-known
  symbols, NOT gensyms — gensyms break across Racket phase boundaries)
- Reader runs at phase 0, parser at phase 1 — shared symbols must be
  phase-stable
- Params can be `param`, `map-destructure`, or `seq-destructure`
  structs — always check the predicate before calling `(param-name p)`
- `emit-form` handles top-level forms; `emit-expr` handles everything
  else. `check-form` does top-level checking; `infer-expr` is
  expression-level
- **Maps/vectors/sets evaluate. Keys are keywords. `{:enable true}`.** (Rule. Closed. Do not reopen.)
- Current surface uses bare vectors for structural slots: `[x y]` for
  params/fields/binding-zones (no `(params …)` wrapper). `'` is the
  inert marker for lists only: `'(a b c)` for paths/code-as-data.
  Containers `[…]` / `{…}` / `#{…}` are never quote-prefixed.

## What changed recently — read the git log, not this file

Anything beyond the rules-with-teeth is in `git log` and the
life-os threads. If the surface looks different from what you expect,
`git log --since="1 week" CLAUDE.md beagle-lib/private/parse.rkt` will
tell you why.
