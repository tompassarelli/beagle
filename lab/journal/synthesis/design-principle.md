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

### Pattern algebra closure (before match `or`-extension ships)

Adding `or` as a match pattern primitive commits beagle to having a
*pattern algebra*. The natural neighbors are:

- `and`-patterns (match all of)
- `not`-patterns (match anything but)
- guard clauses (`:when expr` in pattern position)

Some pattern-matching languages have all of these (Haskell, OCaml,
Scala). Some have only some. The question: what is beagle's closure?
Three positions are coherent:

1. **`or` only.** Other algebra composes from existing forms (nested
   match, manual conditions). Position: pattern algebra is just `or`
   because it's the one composition that *can't* be expressed any
   other way at the pattern level.
2. **`or` + guards.** Add `:when expr` because guards interact
   meaningfully with destructuring (you need the bindings in scope
   for the guard). Skip `and` and `not`.
3. **`or` + `and` + `not` + guards.** Full pattern algebra, ML-family
   posture.

This is a position that needs to be argued, not defaulted into.
The or-extension PR should state which closure beagle is committing
to and why.

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

### `do`-form examination (post-`when`-drop)

After dropping `when`, the new canonical for side-effect-sequence is
`(do ...)`. `do` becomes more visible, used inside `if` branches and
elsewhere. Under the principle:

- Not bracket-clause-shaped (so not in that family)
- Sequencing-of-effects is its own concept that nothing else does
  (so pattern-isolated)
- But it's *the only way* to compose multiple statements where one
  is needed (so structurally load-bearing)

The audit verdict is probably "keep" because there's no composition
that replaces it (every Lisp has progn/begin). But put it on the
radar for explicit examination after `when` drops, so the principle
isn't assumed to give an answer it hasn't been asked.

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
