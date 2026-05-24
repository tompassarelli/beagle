# Beagle's dominant design principle: consistency compounds, ergonomic savings don't

This is the load-bearing principle for every beagle surface decision.
When a future audit asks "should this form exist?", this is the lens
to apply. Captured here so it doesn't get re-derived from weaker
framings (decision-surface-minimization, low-corpus-usage, Clojure-
precedent, verbosity-of-replacement — all subordinate to this one).

## The principle, stated plainly

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
- `match` clause patterns reuse the bracket-binding shape.

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

The "conservative-early" phase of beagle (2025–early 2026) paid
ergonomic-cost for adoption-benefit. The bet was that lowering
migration cost for Clojure-trained agents was worth carrying forms
that exist for Clojure-precedent only. That bet was reasonable when
the alternative was "nobody can write beagle without first being
re-trained."

The adoption benefit has been collected. Beagle exists, it works,
agents can write it. The persistent audience is *all future agents*,
not the diminishing transition population of "Clojure-trained agents
needing minimal migration." The carrying cost of Clojure-precedent
forms is now pure cost — no remaining benefit.

The "liberal-now" phase (2026-05 surface redesign and beyond) is
liberal *in dropping*, conservative *in keeping*. The surface gets
smaller and more uniform.

## Application: the audit lens

For every form in the current surface, ask: pattern-extending or
pattern-isolated? Apply the test. Forms that fail get dropped.

The result of this audit will surface real pressure on Clojure-shaped
forms that were kept under the previous (weaker) framing. The pressure
is correct — those forms were kept on the wrong criteria.

This audit is the next concrete deliverable. The surface forms that
are most likely to fail the lens (without committing to drops yet,
just surfacing for examination):

- `when-let` / `if-let` — local nil-binding ergonomics, no broader
  pattern they reinforce
- `case` — covers a narrow slice that `match` already covers
- `(:foo m)` keyword-as-function on maps — one-off behavior
- `when` — sugar for `(if c (do ...))`; extends `if` shape but the
  extension is pure ergonomic
- `cond` — sugar for nested-if; has its own clause shape `[test result]`
  not used elsewhere
- `dotimes` — sugar for `(doseq [i (range n)] ...)`
- The macro DSL surface — two kinds, input/output contracts, hygienic
  substitution. An *island*, doesn't reinforce patterns elsewhere.

These don't drop tonight. They surface for deliberate examination.
The principle says "examine," not "execute reflexively."

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
