# Beagle's design principle: enough familiarity to bootstrap, don't overfit

This is the load-bearing principle for every beagle surface decision,
and it is **upstream of everything else in this document**. The
consistency-compounds rule, the two-bar test, the asymmetric burden
of proof, the temporal asymmetry — these are all *how to operate
within* the bootstrap-vs-native distinction. They are methodology;
this is the principle.

## The upstream principle

Beagle's surface has two parts with different design disciplines:

**The entry hall (Clojure-shaped).** `defn`, `let`, `if`, threading
macros, bracket literals, `for` comprehensions, `match`, `case`-as-was.
These exist primarily to lower the activation energy for the first
authors — agents and humans — who encounter beagle. They're patterns
you already know if you've seen Clojure. The entry hall is the reason
beagle has any adoption ramp at all.

**The building (beagle-native).** defunion / defenum / defscalar, the
type system, multi-target emit, schema ingestion, the ADT primitives.
These exist because beagle does things Clojure doesn't, and they must
derive from beagle's own principles (multi-target IR, typed end-to-end,
schema-typed paths, agent-first), not from Clojure's. The building is
the reason beagle has any reason to exist as a distinct language.

Both parts are necessary. The tension between them is the actual
design problem:

- **Too little familiarity** → no adoption ramp, beagle dies at the
  bootstrapping phase. Empty-corpus problem (no training data, no
  muscle memory, nothing to pattern-match to).
- **Too much familiarity** → indistinguishable from Clojure, beagle
  has no reason to exist. Clojure wins on its own terms (15 years of
  ecosystem, library coverage, community knowledge).

The sweet spot: familiar enough that you can write working beagle on
day one if you know Clojure, distinct enough that the things beagle
does *better* are visible and reachable.

## The first frame for any design question

1. **Is this question about the entry hall or the building?**
2. **For the entry hall:** does this form pay off for bootstrap, or
   is it dead weight that survives only because Clojure-trained agents
   reflexively type it?
3. **For the building:** does this form derive from beagle's own
   principles, or am I reaching for "what does Clojure do here?"
   when I should be deriving from first principles?

## Temporal calibration of the entry hall

The entry hall is **not permanent**. As beagle accumulates its own
gravity — more native idiom, more agent training data influenced by
beagle examples, more users who learn beagle before they learn
Clojure — the bootstrap cost of cutting entry-hall forms drops. The
right policy is to start with enough scaffolding to enable bootstrap
and progressively shed it as native gravity grows.

**Beagle's current state (2026-05):** one user, one dogfood corpus
(firnos plus what's coming), limited public footprint. The bootstrap
phase is *over* for the current user — beagle's conventions are
internalized, the scaffolding it provided is no longer load-bearing
for active authoring. The next user (future agent or future human) is
hypothetical. **Design coherence outweighs bootstrap convenience right
now. Aggressive entry-hall cuts are correct.**

**Future calibration:** as the public footprint grows, bootstrap-cost
considerations come back into the audit. The pace of entry-hall
reduction slows down. At some maturity point, the surface stabilizes
and further cuts require breaking changes that fork the language —
this is the temporal-asymmetry concern below.

The mature beagle surface — years from now, with self-host, multiple
users, established conventions — looks substantially less Clojure-
shaped than today, because entry-hall scaffolding will have been
retired. The trajectory is from "Clojure-shaped at the surface,
beagle-native underneath" toward "beagle-shaped throughout, with the
beagle-native parts visible and the entry-hall residue minimal."

## The risk the principle names

"Overfitting" doesn't just mean keeping Clojure-shaped forms. It means
*thinking in Clojure shapes* when designing new parts of beagle. The
risk isn't that you have `defn` instead of `define`. The risk is that
when you encounter a new design question (how should X work in
beagle?), you reach for "what does Clojure do here?" instead of asking
from first principles. The entry hall invites that reflex; constant
discipline is required to notice and refuse it.

Most language projects either go pure-familiarity (transpiler to
existing host, surface matches host) or pure-novel (entirely new
syntax, no concession to familiarity). Both are easier than what
beagle is attempting. Beagle attempts the *third* path — familiar
enough to bootstrap, distinct enough to matter — which is harder
because it requires constant discipline about which side of the line
each design decision lands on. There is no template for "language
with deliberately temporal familiarity scaffolding that progressively
reveals its native shape." The methodology in the sections below is
beagle inventing that template as it goes.

---

# A recurring meta-pattern: separate clocks for separate concerns

Several beagle decisions take the same shape: an operational concern
that looks like one thing actually decomposes into multiple independent
functions, each with its own clock (cadence, decision criteria, blocking
behavior). Conflating them creates artificial pressure on at least one,
usually the fast one being gated by the slow one.

The pattern, stated generally:

> **Operational concerns that look like one thing usually decompose
> into multiple independent functions with their own clocks.
> Conflating creates artificial pressure on at least one.**

Naming this meta-pattern explicitly so future instantiations get
recognized as such on first encounter rather than re-derived from
scratch.

Known instantiations:

- **Commits / releases / announcements** — three cadences (commit
  on coherence, release on materially-better, announce on its own
  schedule). Conflating "commit = release" or "release = announce"
  creates pressure (over-batching commits, or holding good releases
  for marketing windows).
- **Test tiers: active / demoted / gated** — three clocks (active
  blocks every iteration, demoted runs continuously but doesn't block
  and gets reconciled in batch, gated runs opt-in). See test-cadence
  section below.
- **Bootstrap entry-hall / beagle-native building** — already discussed
  as the upstream principle, but it's also an instance of this pattern:
  the entry hall has a temporal clock (sheds forms as gravity grows),
  the building has a design clock (derives from first principles),
  they don't share criteria.

Likely future instantiations to watch for:

- Build steps (typecheck / parse / emit / oracle-verify probably
  shouldn't all be one blocking pass).
- Lint passes (warning-vs-blocking-vs-info already implicitly tiered;
  formalize when it grows).
- Documentation generation (Scribble rebuilds, README updates,
  external doc sync — likely separate cadences).
- Surface decisions themselves (audit/decide/execute/reconcile —
  already de facto multi-step; formalizing the steps might help).

The reason to name the meta-pattern: when the next operational concern
shows up looking unified, the question "is this actually one thing or
does it decompose into multiple clocks?" should be reflexive. Without
naming the pattern, each instance has to be discovered fresh.

## Test-cadence decomposition (an instance of the meta-pattern)

Test runs were previously treated as one undifferentiated operation:
`raco test beagle-test/tests/`, everything blocks on any failure.
This conflated three actually-different concerns:

1. **Tests that must pass before the next iteration step.** Surface
   changes break the parser? Block immediately. Active emit target
   regresses? Block. Type checker accepts wrong code? Block.
2. **Tests that should run but shouldn't block iteration.** Behavioral
   tests for non-load-bearing targets — running them tells you whether
   the surface change affected them, but the answer isn't load-bearing
   for the change to ship, because the target isn't load-bearing right
   now. The information is valuable for *eventual* reconciliation, not
   for *immediate* blocking.
3. **Tests that need explicit opt-in to run.** Oracle suites that
   shell out to external interpreters, suites that require uncommon
   tooling installed. These shouldn't run in the default loop because
   they're slow and noisy, but they should be runnable when needed.

Treating all three as "the test suite" gates iteration on the slowest
and most aspirational concerns. The decomposition fixes this:

| Tier | Cadence | Blocking | Reconciliation |
|---|---|---|---|
| **active** | every iteration | yes — fails the build | n/a (kept current always) |
| **demoted** | every CI push (and locally by default in current MVP) | no — failures logged to `lab/surface-debt.md` | batched at strategic milestones (Cyclone self-host, surface stable) |
| **gated** | opt-in (`--include-gated`, env vars) | yes when run, but rarely run | n/a (run only when relevant) |

The mechanism: `beagle-test/tiers.rktd` is the manifest; `bin/beagle-test`
is the tiered runner; `lab/surface-debt.md` is the reconciliation queue.

**Structural floor rule.** All `emit-*.rkt` structural tests stay active
regardless of target status. They're cheap and catch entire-emitter
breakage before it rots invisibly. Only `-behavioral.rkt` tests for
non-load-bearing targets get demoted.

**Promotion criteria.** Demoted → active requires BOTH (a) the surface
is stable enough that reconciliation work won't be redone immediately
AND (b) the target is load-bearing for actual work (real use case,
not hypothetical optionality). Just (a) is not enough — keeping a
target's behavioral suite current costs ongoing maintenance, and that
cost is only worth paying when (b) says someone actually depends on
the runtime correctness.

**Reconciliation contract.** "Demoted" must mean *paused with a
specific reactivation trigger*, not "abandoned." Beagle's trigger is
well-defined: post-Cyclone-self-host + surface stable, do a batched
reconciliation pass against `lab/surface-debt.md` entries. Each entry
captures the surface change, the affected target, and "what the test
was checking" so reconciliation isn't archaeology against git history.

**The deeper point.** The test-cadence decomposition is structurally
identical to the commit/release/announce decomposition: three clocks,
three decision criteria, don't let the slow one gate the fast one.
The same shape will keep showing up. The meta-pattern at the top of
this section is the load-bearing abstraction; test cadence is one
named instance.

---

# Methodology: how to operate within the upstream principle

The sections below are all *consequences* of the principle above.
They are the rules of operation for keeping the entry hall from
accreting un-earned forms and keeping the building coherent under
its own principles.

## Consistency compounds, ergonomic savings don't

A surface form earns its place by being part of a *system* —
reinforcing patterns that show up elsewhere in beagle. Forms that
exist for local ergonomic savings, with no broader pattern they
reinforce, are net-negative even when they save characters at
authoring time.

The asymmetry that makes this load-bearing:

- The ergonomic savings (a few characters at write time, a familiar
  shorthand for trained agents) are paid out *once*, at the moment of
  authoring, by one agent.
- The carrying cost (every agent that ever touches beagle has to
  *know this form exists* and *know when to reach for it*) is paid
  *forever*, on every authoring decision, by every agent.

Consistency compounds. Ergonomic savings don't.

## The two-bar test

Every form in beagle's surface must clear **both** bars:

1. **Semantic uniqueness.** It expresses something the rest of the
   surface can't compose to express cleanly. Composition of existing
   forms doesn't count as "the rest expressing it."

2. **Reach frequency.** That thing is something agents reach for
   often enough that requiring composition would be real friction
   in real authoring.

Failure of either bar = the form does not earn a place. Both
incumbents and proposals face the same bar.

## The asymmetric burden of proof

**Incumbency confers no advantage.** Existing forms are re-examined
under the same bar as new proposals. The frame is not "should we walk
back from this form" but "would we add this form if it didn't exist
today?" The two questions have to produce the same answer.

This is the load-bearing reframe. It changes which forms are actually
solid versus which are surviving on "well, it's already there."

When you find yourself constructing arguments to *retain* an
incumbent form that you wouldn't construct to *add* it fresh, the
form fails the test. The retention-argument is incumbency disguised
as analysis.

## Temporal asymmetry

**Removal is cheap NOW and will not be cheap later.**

Beagle is pre-1.0 with one user (you), one dogfood corpus (firnos),
and minimal external code. Removing a form right now costs a few
file edits and a corpus migration. Three months from now, with more
beagle code in the wild and more agent training data influenced by
beagle examples, each removal costs orders of magnitude more — and
some removals become impossible without breaking changes that fork
the language.

Additions are the opposite. You can add a form anytime. The cost of
adding `cond` back in three months if you cut it today and regret it
is small — write the parser case, write the emit, ship. The cost of
*not* cutting `cond` today and regretting it in three months is
permanent.

This temporal asymmetry means the rational policy in this window is
**cut aggressively now, accept that some cuts will turn out wrong,
treat the option to re-add as real**. The cost of mistaken-cut is
bounded (re-introduce later for cheap). The cost of mistaken-keep is
unbounded (form sits in surface forever, accretion compounds, the
language gets harder to hold in your head every year, and there is no
path back to the smaller state without breaking changes).

The other extreme — Scheme-style cut-too-far where every common
operation has to be re-derived from `cons`/`car`/`cdr` — is also bad.
The principle isn't "smaller is always better." It's "every form
earns its place under the two-bar test, the bar is high, the default
is don't include, and the window for removing un-earned forms is
closing."

## Two cautionary tales

**Common Lisp.** Every form was locally justified at the moment it
was added. `loop` is the canonical example — incredibly powerful, a
whole sublanguage with its own keywords, scoping rules, debugger
experience. Adding it was reasonable. The result is a permanent
surface that nobody can hold in their head. Each addition was
defensible; the *pattern* of defensible additions wasn't, because
the burden of proof asymmetry favored adding.

**Scheme.** R5RS standardized with a deliberately small surface. The
discipline was institutionalized: adding to scheme is harder than
adding to Common Lisp *by design*. Result: scheme is small, the
surface compounds with itself, the language holds together in the
mind.

Beagle is choosing the Scheme posture, not the Common Lisp one. The
mechanism is the asymmetric burden of proof above.

## Two categories of surface addition

**Pattern-extending.** The new form reinforces a regularity that
already exists. Adding it makes the rest of the surface *more
predictable* per form added — the form teaches you the broader
pattern.

- `[1 2 3]` / `{:k v}` / `#{a b}` — bracket-pair delimits collection.
  Three forms, one pattern, mutually reinforcing.
- `def` / `defn` / `defrecord` / `defunion` / `defenum` / `defscalar`
  / `deftype` / `defprotocol` — `def*`-prefix + bracket-params shape.
  Each new def-form is *more* learnable because the pattern is
  predictable.
- `let` / `letfn` / `loop` — bracket-binding shape `[name value ...]`.
- `match` / `cond` / `for` clauses — bracket-pair clause shape (see
  meta-pattern below).

## The bracket-clause meta-pattern

This is the load-bearing regularity that protects several
clause-shaped forms that would otherwise look pattern-isolated.

Beagle has a generalized **bracket-pair clause** shape that recurs
across forms with different left-side interpretations but the same
visual structure:

| Form | Clause shape | Left-side interpretation |
|---|---|---|
| `let` | `[name value]` | Identifier to bind |
| `match` | `[pattern body]` | Pattern to match against the target |
| `cond` | `[test body]` | Boolean test expression |
| `for` | `[var coll :when pred]` | Iteration source + optional modifiers |

These don't share semantics — they share *shape*. An agent who has
internalized "pair-things-up-in-brackets-inside-parens" from any one
of them is primed to parse the others. The visual regularity teaches
the family even when the interpretation differs.

**This is what saves `cond`.** The earlier "drop candidate" verdict
was wrong because it asked "does cond fold into match?" (no — distinct
concept). The right question is "does cond participate in an existing
family?" (yes — bracket-clause family). Participation in a family is
pattern-extension, even when the per-form semantics differ.

**This is what condemns flat-pair `case`.** `(case x 1 :a 2 :b :else)`
breaks the bracket-clause family. Its alternative interpretation
(left side is a literal value to test for equality) would slot
naturally into the family if its syntax were `[1 :a]` `[2 :b]`. The
flat-pair shape is what makes it an island. So the right move for
`case` is either (a) drop in favor of `match` (which already uses
bracket clauses), or (b) reshape `case` to use bracket clauses. Not
"keep as-is."

**Test for any new clause-shaped form:** does it use bracket-pair
clauses consistently with the family, or does it introduce an island
shape? Bracket-pair → pattern-extending → earns its place (assuming
distinct concept). Island shape → pattern-isolated → doesn't.

Future surface decisions should consult this meta-pattern explicitly,
not re-derive it from individual form audits.

**Pattern-isolated.** The new form exists for its own sake, with no
broader regularity it reinforces. Each one is a *separate fact* to
memorize.

- `cond->` — Clojure-precedent, one-off form for "conditionally
  accumulate transformations."
- `some->` — Clojure-precedent, one-off form for nil-chain navigation.
- `inc` / `dec` — sugar over `(+ x 1)` / `(- x 1)`, no broader pattern.
- `not=` — sugar over `(not (= a b))`, no broader pattern.
- `when-not` / `if-not` — sugar over `(when (not c))` / `(if (not c) t e)`.
- `defmulti` / `defmethod` — value-dispatch alternative to `match`,
  competing with the canonical dispatch form for the same problem space.

Pattern-extending additions have **negative marginal cost** — they
make the surface easier to predict, not harder. Pattern-isolated
additions have **positive marginal cost** — each one is its own
thing to learn.

## Categories of drop justification

When a form fails the test, the *why* it failed matters for the
audit. Different categories of failure have different implications
for whether other forms are also suspect.

1. **Pure ergonomic sugar with no semantic content.** Examples: `inc`,
   `dec`, `not=`. The form is one identifier shorter than the
   composition; nothing else. These drop because they're surface
   weight with no payoff.

2. **Pattern-isolated forms that work fine but participate in no
   broader regularity.** Examples: `when-not`, `cond->`, `some->`,
   `defmulti`. Each one is its own fact to memorize; nothing else in
   beagle teaches the pattern. These drop because they're decision
   surface without consistency payoff.

3. **Multi-canonicals where alternatives compete and confuse.**
   Examples: `->` vs. `->>`, `if-some` vs. `if-let`. Drop the
   redundant one so authors have one canonical choice.

4. **Drops that unblock building-side cleanness.** Examples:
   `(:foo m)` keyword-as-fn (its existence overloads `(:keyword x)`
   between record-field-access and map-lookup, preventing the
   syntactic shape from being dedicated to the typed concept).
   The form may not be "wrong" by itself, but its presence
   *prevents the rest of the design from being maximally crisp*.
   These drops are stronger than 1–3: the form isn't just dead
   weight, it's actively blocking structural clarity.

   The category test: does the form overload a syntactic shape that
   beagle wants to dedicate to a typed/native concept? If yes, the
   drop is in category 4 and the justification is stronger than
   pattern-isolated. Look for other forms that fit this pattern —
   they tend to hide because each one looks individually defensible
   ("it's just a convenient shorthand for X").

## The test for any new or existing form

When in doubt about whether a form earns its place, ask:

> Does adding/keeping this form make the rest of the surface more
> predictable, or is it a separate fact to memorize?

If it makes the surface more predictable, it earns its place. If it's
a separate fact, it doesn't — *regardless* of how reflexive it is in
training data, how many characters it saves, how comfortable it feels
to Clojure-trained authors, or how much it appears in any specific
corpus.

The criteria explicitly *not* part of this test:

- **Clojure precedent.** That a form exists in Clojure is irrelevant.
  Clojure optimized for human-concision in a culture where humans
  read code daily. Beagle's audience is agents whose marginal cost
  per form is constant and whose marginal benefit from concision is
  near zero (they don't get tired of typing).
- **Verbosity of replacement.** Composition is often more verbose
  than dedicated sugar. That verbosity is *not* a cost under this
  principle — it's often a feature, because the explicit form
  reveals the composition and makes the language's primitives
  visible.
- **Low corpus usage.** In a one-user pre-1.0 system, the corpus is
  a snapshot of patterns *currently exercised*, not patterns the
  language must support. It's a weak signal at best. Use only as
  confirmation, never as primary evidence.
- **Reach-frequency in training data.** Agent reflex for `cond->`
  or `inc` is real but it's a *transition cost*, paid once per agent
  during initial exposure. Carrying the form to satisfy that reflex
  is paid forever.

## Why this is stronger than "decision-surface minimization"

The minimization framing implies the goal is "fewer forms." That's
half right. The goal is *fewer forms that don't compound*.
Pattern-extending forms add to the surface size but don't add to the
decision burden — they teach the pattern as a side effect of being
learned. Minimization-alone would push to drop bracket-literals
(they add forms!) which would be a real regression.

The consistency-compounds framing handles both directions correctly:
- Drop pattern-isolated forms (they don't compound).
- Keep — and add — pattern-extending forms (they make the surface
  more learnable per form added).

## How this applies historically

The "conservative-early" phase of beagle (2025–early 2026) was the
entry hall doing its job. Beagle paid ergonomic-cost (carrying forms
that exist for Clojure-precedent only) for adoption-benefit (Clojure-
trained agents could write beagle on day one). That bet was correct.
The bootstrap surface was load-bearing — beagle wouldn't have reached
day-one writability without it.

The bootstrap benefit has been collected. The current user has
internalized beagle's conventions; the scaffolding it provided is no
longer load-bearing for active authoring. The next user (future agent
or future human) is hypothetical.

The "liberal-now" phase (2026-05 surface redesign and beyond) is
liberal *in dropping*, conservative *in keeping*. The entry hall
sheds forms that aren't load-bearing for the next user. The surface
gets smaller and more uniform. The temporal-asymmetry analysis above
explains why this window matters: drops now are cheap, drops later
will not be.

## Application: the audit lens

For every form in the current surface, the audit is now three-pass:

1. **Entry hall or building?** Beagle-native machinery (defunion,
   types, multi-target emit) is the building and gets audited under
   beagle's own principles, not Clojure's. Clojure-shaped forms are
   entry hall and get the bootstrap test below.
2. **For entry-hall forms: pattern-extending or pattern-isolated?**
   Pattern-extending forms earn their place by teaching a regularity
   that recurs elsewhere. Pattern-isolated forms are separate facts
   to memorize.
3. **For pattern-isolated entry-hall forms: load-bearing for
   bootstrap?** With current low public gravity, almost no entry-hall
   form is load-bearing for the *active* user. The question is
   whether the form is load-bearing for the hypothetical next user
   reading beagle code with Clojure muscle memory — and whether that
   bootstrap value justifies the perpetual carrying cost.

Forms that fail any pass get dropped.

The forms most likely to fail under this lens (surfaced for
examination, not pre-judged):

- `when-let` / `if-let` — local nil-binding ergonomics, no broader
  pattern they reinforce
- `case` — covers a narrow slice that `match` already covers
- `(:foo m)` keyword-as-function on maps — one-off behavior that
  also conflicts with the typed `(:field record)` lowering
- `when` — sugar for `(if c (do ...))`; extends `if` shape but the
  extension is pure ergonomic
- `cond` — sugar for nested-if; has its own clause shape `[test result]`
  (saved by bracket-clause family — see below)
- `dotimes` — sugar for `(doseq [i (range n)] ...)`
- The macro DSL surface — two kinds, input/output contracts, hygienic
  substitution. An *island*, doesn't reinforce patterns elsewhere.

## The methodology this replaces

Previously the audit used three signals: corpus usage, agent reflex,
verbosity-of-replacement. All three were subordinate signals. The
correct primary signal is the predictability-test above. The three
previous signals can serve as *confirmation* once the test has
delivered a verdict, but they don't generate verdicts on their own.

Where the previous methodology produced bad calls (the macro-eval
deletion, the proposed `->` revert), the failure mode was the same:
applying corpus-data or training-reflex as primary evidence when the
predictability-test would have given the right answer directly.

## Re-examination under the asymmetric burden

The audit was applying a weaker frame ("walk back from existing
forms"). Under the asymmetric burden ("would I add this if it didn't
exist"), several incumbents that the audit treated as defensible
become drop candidates that fail the strict bar.

| Form | Would I add today (fresh)? | Verdict under strict bar |
|---|---|---|
| `case` | No — `match` covers literal dispatch with `or` extension. | Drop (sequenced). |
| `when` | No — `(if c (do body))` composes cleanly. | Drop (sequenced). |
| `dotimes` | No — `(doseq [i (range n)] body)`. | Drop (executed). |
| `(:foo m)` on maps | No — `(get m :foo)` is uniform. Drop also tightens records-vs-maps boundary. | Drop (sequenced). |
| `->` | No — positional convenience, not semantic uniqueness. | Already dropped. |
| `cond` | Yes — bracket-clause family + sequential predicate dispatch; many-clause nested-if is real friction. | Keep. Reprieve holds under strict bar. |
| `when-let` / `if-let` | **No** — `(let [x v] (when x body))` composes. Saves 3-4 characters. Incumbency disguised as "deferred to nil-semantics." | **Drop now** (was deferred; reclassified under strict bar). |
| `for` (simple `[var coll :when pred]`) | Yes — bracket-clause family + comprehension is real win. | Keep. |
| `for` (complex modifiers: `:let`, `:while`, multi-source) | Uncertain. Each modifier is its own addition. | Audit separately. |
| `match` | Yes — pattern dispatch with destructuring is irreducible. | Keep. |

The `cond` reprieve holds. The `when-let`/`if-let` reprieve was
incumbency disguised as deferral and falls under the strict bar.
Other reprieves should be re-examined the same way as audits proceed.

## Open design questions surfaced by the audit

These are questions that the audit raised but that need explicit
design thought before the relevant work ships. Recording them so they
aren't improvised when the time comes.

### Pattern algebra closure — RESOLVED: incremental

The question: does beagle commit to a full pattern algebra (`or`,
`and`, `not`, guards) up-front, or add operators incrementally as
they earn their place?

**Resolution: incremental.** Pattern operators earn their place
individually under the same asymmetric-burden principle as the rest
of the surface. Or-pattern ships first because it absorbs `case`
(its existence-justification). Other operators (`and`, `not`,
guards) wait for concrete need.

This is one specific application of a broader meta-question worth
naming for future audits:

> **Incremental vs. closed-design for new surface families.** When
> adding the first member of a *family* (pattern operators, type
> constructors, control-flow primitives), is the right discipline
> "ship the one member that earns its place, defer the family" or
> "commit to the family up-front because operator interactions
> matter"?

Both are coherent philosophies. Beagle has applied incremental
consistently — Clojure-derived core grew by add-when-earned, audit
cycles trim — so the default lean is incremental unless a specific
argument carries.

The argument *for* closed-design in pattern algebras specifically:
operator interactions are real (`or` inside guards, `and` with
bindings, `not` with destructuring all have subtleties), and most
established pattern-matching languages chose closed-design for this
reason.

The argument *against* in beagle's case: incremental has worked for
the rest of the surface; removal-is-cheap-now-and-expensive-later
applies to operator additions too (each additional operator that
doesn't earn its place becomes permanent); the asymmetric-burden
principle says default-don't-add unless earning proven.

The hygiene that protects future-incremental: the or-pattern AST and
parser should be shaped so adding `and`/`not`/guards later is
mechanical (not a redesign). Specifically, or-pattern is a
*pattern-combinator* AST node, not a special-case in the match
parser. If guards are added later, they slot in as a pattern
modifier. If `and` is added, it's a sibling combinator. None of
these require revisiting the or-pattern.

Open: when nullable narrowing or other type-system work surfaces a
real need for guards, revisit this resolution. Same for `and`/`not`
if a use case appears that composition doesn't cleanly cover.

### Post-nullable-narrowing form for the `when-let` pattern

Dropping `when-let`/`if-let` now is correct, but it doesn't *defer*
the underlying problem — it forces an interim verbose pattern
(`(let [x expr] (if x (do body)))`). When nullable narrowing lands
later, the natural reflex will be to "revive `when-let`" with new
semantics. That would carry the Clojure-shaped name forward into
a beagle-native concept — exactly the overfitting risk.

The eventual form should be designed *as a beagle-native form*, not
as Clojure-`when-let`-with-types. Considerations:

- Name should not inherit Clojure's vocabulary (no `if-let`,
  `when-let`, `if-some`, `when-some`).
- Form should interact with the type system explicitly: binding gets
  narrowed type inside body (`T?` → `T`).
- Should slot into the bracket-clause family if possible.

When the time comes (post-nullable-narrowing), the question is
"what should this form be called and shaped like" — not "should we
revive `when-let`."

### `do`-form examination — RESOLVED: keep

After dropping `when`, `do` becomes the canonical side-effect-sequence
form, used inside `if` branches and `match`/`cond` clause bodies. The
audit considered both the binary keep/drop and the reframe (should
`if`/`match`/`cond` accept multiple body forms implicitly, removing
the need for `do` in those positions?).

**Verdict: keep `do`. Do not change `if`/`match`/`cond` to implicit
multi-body.**

The pattern-isolated bar:
- `do` is not bracket-clause-shaped (not in that family).
- Sequencing-of-effects is its own concept; nothing else expresses it.
- But composition does not replace it — there is no way to express
  "evaluate b1 then b2 then b3 and return last" without a sequencing
  primitive. Every Lisp has progn/begin/do for this reason.

The reframe considered: should `if` accept multi-body in then/else?
Should `match`/`cond` clause bodies accept multi-body?

**`if` with multi-body would create ambiguity.** `(if c b1 b2)` already
means "(if c then-branch=b1 else-branch=b2)". To accept multi-body
would require either (a) syntactic delimiter for then-vs-else (breaks
the current shape), or (b) restricting multi-body to no-else cases
(asymmetric — only one of the two branches gets the affordance).
Either breaks the simple syntactic rule beagle has now ("if has 2 or 3
args"). The cost in unambiguous-parse outweighs the friction-reduction.

**`match`/`cond` clause bodies are similar.** The clause body is the
expression that the clause produces; multi-body would create the same
"where does the expression end" ambiguity. The current shape (single
expression per clause body, wrap in `do` for multi-statement) is
unambiguous.

**Corpus check:** Post-when-drop, `(do …)` appears 1 time in the
beagle-test fixtures corpus (kitchen-sink.bclj log-point). The friction
the audit was concerned about is empirical low. The cost of breaking
unambiguous-parse to remove that friction is high.

**The deeper observation:** the places `do` is required are exactly
the places where pattern-extending alternatives would conflict with
existing unambiguous-parse guarantees. That's not coincidence — it's
the *reason* `do` is required there. It's the syntactically-safe way
to extend single-expression positions to multi-statement sequences.

## Tooling: codemods for corpus-scale migrations

At small corpus sizes (under ~10 sites), hand-migration of dropped
forms is fast and verifiable. At larger sizes (the `when` drop with
67 corpus sites being the first example), hand-migration is slow,
error-prone, and produces inconsistent results. The pattern:

- 1–10 sites: hand-migrate.
- 10+ sites: write a parser-level rewrite codemod, run it, verify
  diff visually, commit migration as one logical unit.

The codemod for `when` is straightforward: `(when c body...)` →
`(if c (do body...))`. Could be a small Racket script that consumes
beagle source and emits rewritten source via the AST. Worth building
once and reusing for future corpus-scale migrations.

Don't ship a drop with hand-migrated corpus when a codemod would do
better. The codemod investment is tiny relative to a hand-migration
of 67 sites, and the resulting migration is uniform.

## Emit-layer obligations for surface drops

When dropping a form that absorbs into another via composition, the
absorbing form's emit layer often needs an optimization to preserve
the dropped form's performance characteristic. Without it, the drop
ships a perf regression.

Concrete instance: dropping `case` in favor of `match` + `or` only
works fully if the emit layer recognizes literal-only `or`-patterns
and lowers them to target-native constant-time dispatch:

- Clojure: `case` form
- ClojureScript: `case` form
- JavaScript: `switch` statement
- Python: `match`/`case` statement
- SQL: `CASE WHEN val IN (...)`
- Nix: chained `if`/`else if` (no native switch)
- Typed Racket: `case` form

If the `match`-or extension ships *without* this optimization, the
case-fold introduces a perf regression on hot dispatch paths that
won't be visible until someone benchmarks. The optimization is
in-scope for the match-or extension work, not a follow-up.

The general rule: when dropping form X by folding into form Y, audit
each target's emit for any optimization X had that Y now needs to
inherit. Add those to Y's emit-layer scope as part of the drop work.

## Next-audit-cycle candidates (under the bootstrap-vs-native lens)

The current audit queue (drops + match-or extension) was assembled
before the bootstrap-vs-native lens was articulated. The lens
changes which forms deserve re-examination. Recording the candidates
here so the next audit cycle sweeps comprehensively rather than only
the items currently flagged.

These are not action items — they're radar items, surfaced so the
next pass under the new lens doesn't miss them.

- **`for` comprehensions.** Kept previously on "better than SRFI 42"
  / "participates in bracket-clause family" grounds. Both correct.
  But under bootstrap-vs-native, `for` is entry-hall — Clojure-shaped
  comprehension that lowers bootstrap cost. The question hasn't been
  asked: is the comprehension shape itself doing beagle-native work,
  or is it pure entry-hall? Distinct from "does for survive the
  predictability test."
- **`defprotocol` / `extend-type`.** Kept after `defmulti` /
  `defmethod` drop because protocol-based polymorphism is the
  remaining canonical dispatch idiom. Still Clojure-shaped
  polymorphism though. The question of whether beagle's polymorphism
  *story* is correct hasn't been asked under the new lens. The
  answer might be "yes, defprotocol/extend-type is the right shape"
  but it hasn't been deliberated.
- **`->>` (last-arg threading).** Kept after `->` drop. Pattern-
  isolated under the strict lens (its bracket-pair shape is in
  arguments, not clauses). Survives mostly on "ubiquitous in
  data-pipeline code" grounds. Worth re-asking whether let-chains
  fully cover it under the asymmetric burden.
- **`loop` / `recur`.** Kept after the day-0 friction list
  re-evaluation. The agent-reflex-signal that justified the
  reprieve is real, but the alternative (named recursive functions)
  is conceptually cleaner. Worth re-asking whether tail-call
  optimization in target emitters covers the use cases.
- **Map literal `{:k v}`.** Bracket-pair shape extends the
  collection family (`[]`, `{}`, `#{}`). Pattern-extending so
  earns its place. But the alternative (`(hash-map :k v)` or
  similar) is more uniform with how other typed constructors work.
  Probably stays — pattern-extending is strong — but the question
  hasn't been re-examined under the new lens.

These don't move now. They get re-examined in the next audit cycle,
which happens after the current queue (match-or, when, when-let,
case drop) ships and the surface is stable enough to re-audit.

## When the audit cycle ends

The audit has been productive and dominant for an extended period.
It also has a natural endpoint — the surface eventually becomes
*done enough* and energy shifts to using the surface (bnix grows,
game/a-life work begins, claim-NF runtime substrate, eventually
Cyclone self-host). The audit is not infinite; it's a phase.

The signal for "audit done enough":

1. **No remaining forms fail the bootstrap-vs-native lens decisively.**
   Every current form has been examined under the lens; what survives
   either pays for itself (pattern-extending + bracket-clause family
   members + Beagle-native machinery) or has been deliberately kept
   as bootstrap scaffolding with a documented future-removal trigger.
2. **No remaining design questions block real usage.** Open questions
   exist (e.g., post-nullable-narrowing form names, pattern-algebra
   closure additions) but none are gating any in-progress work.
3. **The surface compiles cleanly against dogfood corpus without
   friction.** firnos plus bnix plus heist plus whatever else uses
   beagle natively — no daily papercuts that would push for surface
   changes.
4. **No corpus-scale migrations remain.** Whatever automated rewrites
   were going to happen have happened; the codebase is in the shape
   the surface implies.

When all four hold, the audit phase is done enough to step back from.
That doesn't mean future surface changes never happen — but they
become responsive to *concrete need* (an open question got answered;
a use case surfaced a gap) rather than driven by audit cycles.

The current queue (match-or + remaining drops) reduces toward this
state but isn't there yet. After it ships plus the next-cycle
radar items above get one re-examination pass, the surface is
probably in audit-done-enough territory.

The reason to name the endpoint: without it, the audit becomes its
own perpetual mode and crowds out the *using* work that is the
actual point of building beagle in the first place. The audit
exists to make the surface fit-for-use; once the surface fits, the
audit's job is done.

## Endpoint reached — 2026-05-25

All four signals hold:

1. **Bootstrap-vs-native lens — clean.** Every current form has been
   examined. Drops that landed under the lens: `defmulti`/`defmethod`,
   `deftype`, `->`, `as->`/`cond->`/`cond->>`/`some->`/`some->>`,
   `when`, `when-not`/`if-not`, `when-some`/`if-some`, `when-let`/
   `if-let`, `dotimes`, `case`, `(:keyword target)`, `inc`/`dec`,
   `not=`, `deferror`, and the `unsafe` macro kind. Forms that
   survived empirical audit and stay (`loop`/`recur`, `->Name`,
   `->>`, `cond`, `do`, `nth` vs `get`, `for`/`doseq`/`map`/`filter`/
   `reduce`, the three record-access mechanisms) each have a documented
   rationale for why they're distinct concepts rather than redundancy.
2. **Open design questions — bounded.** Two remain: nil semantics
   (gates the typed nullable-narrowing form; interim `(let [x v] (if x
   ...))` works) and the macro-DSL audit (blocked on Cyclone for
   constraint clarity). Neither blocks in-progress work. Both have
   explicit dependencies on external decisions/landings — they are
   "answer when X happens" items, not "think about more" items.
3. **Dogfood corpus compiles cleanly.** firnos (~/code/nixos-config),
   self-host/, and oracle fixtures all green under the post-drop
   surface. The dogfood pass this session surfaced one beagle bug
   (atomic-write, f15ef57) which fix-and-ship rather than surface
   change resolved.
4. **Corpus migrations done.** Hand-migrated 6 fixture files +
   self-host/parse.bjs during the drop sequence; codemod framework
   built (`bin/beagle-rewrite drop-when`) but unused because the
   per-site cost was below the codemod-threshold. No outstanding
   automated rewrites.

**Surface-redesign-as-dominant-mode ends here.** Future surface
changes become responsive to concrete need (an open question got
answered; a use case surfaced a gap), not driven by audit cycles.

What this closure means:
- The audit *cycle* is closed. The *question set* is not — nil-
  semantics and macro-DSL audit still have answers pending. But those
  are bound to external triggers, not to "more thinking."
- Future-instance reading this: if you find yourself wanting to
  re-audit the surface from scratch, stop. The audit endpoint was
  reached. Drop candidates from here forward must come from concrete
  friction in real use, not from another pass through the form list.
- Next priorities (per `lab/plans/CLAUDE.md`): Cyclone self-host
  (architectural identity work), schema-typed-paths (capability
  extension), unsafe-capabilities formalization (depends on Cyclone).
  Plus the unlisted-but-legitimate path: sustained dogfood as
  information-generation about which of those matters most.

See `lab/journal/log/027-night-audit.md` for the closeout audit of
the morning-report's deferred items, which was the last work this
cycle absorbed.
