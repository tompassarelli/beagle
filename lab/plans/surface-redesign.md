---
status: done
priority: 1
depends-on: —
blocks: cyclone-self-host.md
closed: 2026-05-25
---

# Surface redesign — agent-first, principled, no compat

**Status: closed 2026-05-25.** All four endpoint criteria from
`design-principle.md` reached. Surface-redesign-as-dominant-mode is
over. Two outstanding questions (nil-semantics and macro-DSL audit)
remain, but both are gated on external triggers (concrete need /
Cyclone landing), not on more audit cycles. cyclone-self-host.md is
unblocked. See `design-principle.md` "Endpoint reached — 2026-05-25"
section for the full closure note and `lab/journal/log/027-night-
audit.md` for the closeout audit that absorbed the final deferred
items.

## Why now

The Cyclone self-host work is going to lock beagle's surface for years.
The surface we self-host *into* is the surface we have forever (or until
the next equally-disruptive re-host, which we don't want).

Before porting, we redesign. Not audit, not cleanup. **Redesign**.

## Principles

1. **Agent-as-primary-author.** Beagle's user is an LLM generating beagle
   code from a spec. Not a Clojure dev with muscle memory; not a Scheme
   purist with aesthetic preferences. A model that picks forms by
   probability over training data. The surface should minimize the
   probability of picking wrong.

2. **One canonical idiom per concept.** Every concept with N equivalent
   idioms is a 1/N hallucination opportunity at generation time. Five
   threading macros isn't ergonomics — it's five chances to pick wrong.
   Drop redundancy ruthlessly.

3. **Verbose-with-clarity over concise-with-magic.** Explicit positional
   args > auto-currying. Named bindings > implicit context. Spelled-out
   forms > terse aliases. Generation cost is amortized to the model;
   ambiguity cost compounds.

4. **Failure modes that localize.** When the agent writes the wrong
   thing, the error should pinpoint *which form* and *what shape* was
   expected. Forms whose shape matches what the type system understands
   produce better errors.

5. **No backwards compatibility.** Beagle is pre-1.0. The only user is
   the maintainer; the only corpus is files the maintainer controls.
   Migration tooling is for projects with external users. We have none.
   Rewrite the corpus by hand; faster than building a sound transform.

## Non-goals

- Familiarity to Clojure developers
- Familiarity to Scheme developers
- Minimum-keystroke surface (humans don't type beagle; agents emit it)
- Preserving existing idioms because they exist

The trap on the other side is replacing Clojure-cosplay with
Scheme-cosplay. Beagle's surface should be **beagle's** — borrow from
either tradition where the answer is genuinely best, invent where
neither tradition has a good answer, drop what either tradition has
that doesn't earn its place under the principles above.

## Plan

### Day 0 — observation pass

Author 5-10 representative tasks under the current surface. Capture
every friction point: "wait, which form do I use here?", "the type
checker rejected this in a way I didn't expect", "I had to read the
docs to know if this form exists", "I picked X but Y was canonical."

Task list (representative coverage of the surface):

1. **Typed function with records.** Define `Account` record, `deposit`
   function that returns updated record.
2. **Pattern match on defunion.** Compute area of `Shape`.
3. **List processing pipeline.** Filter, transform, sum.
4. **Recursive algorithm.** Tree-walk; tail-recursive accumulator.
5. **Conditional pipeline.** "if X then Y, then if Z then W, else skip."
6. **Polymorphism.** Two types that respond to the same operation.
7. **Macro that generates code.** Auto-derive getters for a record.
8. **Error handling.** Custom error type + try/catch/throw.
9. **Cross-module import.** Selective import + alias.
10. **Side effects.** Print, file I/O, timing measurement.

Output: `lab/journal/log/N-surface-friction-observation.md` —
chronological friction notes per task.

### Day 1-2 — surface redesign

Sit down with the friction list and the principles. Redesign from
scratch. Not "keep X, drop Y" — answer "what's the canonical form for
concept Z?" without reference to the current surface.

Categories to redesign:
- Definitions (`def`, `defn`, `defrecord`, `defunion`, `defenum`,
  `defscalar`, `deftype`, `deferror`, polymorphism story)
- Bindings (`let`, `let*`, `letfn`, `loop`, `when-let`, `if-let`,
  `if-some`)
- Conditionals (`if`, `cond`, `case`, `when`, `unless`, `match`)
- Pipelines (`->`, `->>`, `as->`, `cond->`, `some->`)
- Iteration (`for`, `doseq`, `dotimes`, `loop`/`recur`)
- Function values (`fn`, `partial`, `comp`, `apply`)
- Data literals (vector, map, set, keyword)
- Sequences (which names are canonical: `first`/`car`, `count`/`length`,
  etc.)
- Errors (`try`, `catch`, `throw`, `rescue`, `check`)
- Macros (`define-macro safe`, `define-macro unsafe`,
  `define-macro beagle`)
- Modules (`ns`, `require`, `declare-extern`, `import`)

### Day 2-3 — surface spec

Single document: `beagle-doc/scribblings/surface-spec.scrbl`. For each
form:

1. **Concept.** One sentence.
2. **Canonical form.** The shape, with one minimal example.
3. **Failure mode.** What error the agent sees if they reach for it
   wrong.
4. **Types.** What it consumes / produces.
5. **Non-features.** What this form intentionally does NOT do (so the
   agent doesn't overfit).
6. **Rationale.** Why this is the canonical form (vs the alternatives
   considered during redesign).

### Day 3-5 — rewrite beagle

- Parser: drop pattern matches for dropped forms; add patterns for new
  forms.
- Type checker: update inference for the new shapes.
- Emitters: update each (clj, js, py, nix, sql, rkt, scheme).
- Lint: update for the new canonical-vs-alternative warnings.
- Stdlib: update names per the canonicality verdicts.

The existing implementation is scaffolding; cannibalize aggressively.

### Day 5-6 — rewrite the corpus by hand

- `beagle-test/tests/fixtures/*` (all of them, every extension)
- `oracle/fixtures/*.bgl`
- `self-host/*.bjs` (these need rewriting anyway for the Cyclone port)
- `bench/e23-sql-schema-roi/*.bsql`
- `examples/*` (if any beagle source there)
- `~/code/nixos-config/**/*.bnix` (the firnos dogfood — primary user)

By hand because (a) the corpus is small enough, (b) hand-rewrite catches
forms that would have machine-translated badly, (c) it doubles as a
sanity check on whether the new surface is pleasant to write.

### Day 6-7 — empirical verification

Re-run the Day 0 tasks under the new surface. Compare:
- Reasoning steps required (rough count of "decisions")
- Error rate (compiles first try? type-checks first try?)
- Subjective friction (still need to recheck docs?)

Output: `lab/journal/log/N+1-surface-redesign-verification.md`. If the
new surface shows clear friction reduction → ship. If it doesn't → diagnose
which redesign choices didn't help, iterate before declaring done.

### Then — resume Cyclone self-host

The cleaned, redesigned surface is what gets ported. emit-scheme.rkt
gets rewritten against the new surface (most of what I just wrote will
need updates).

## What this plan deliberately doesn't do

- **No migration tooling.** Hand-rewrite is faster for our corpus size.
- **No deprecation period.** Old forms are deleted; new forms exist.
- **No "support both surfaces during transition."** There is no
  transition. Cut over.
- **No bikeshedding "the perfect surface."** Time-box at 5-7 days. The
  surface needs to be *better* than the current one and *coherent*;
  it does not need to be optimal.

## Anti-trap reminders

- **Don't replace Clojure-cosplay with Scheme-cosplay.** The Beagle-honest
  move is "use the name that reads clearly," not "use the Scheme primitive
  because it's Scheme." `first`/`rest`/`count`/`empty?` beat `car`/`cdr`/
  `length`/`null?` on clarity. Keep them.
- **Don't preserve forms because they exist.** Inertia ≠ canonicality.
- **Don't add forms speculatively.** New forms get added only if the
  observation pass shows the absence of them caused friction.
- **Don't perform maturity.** Beagle is pre-1.0; act like it.
