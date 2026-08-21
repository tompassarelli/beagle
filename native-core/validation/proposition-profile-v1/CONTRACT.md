# Experimental proposition profile v1

Status: bounded executable experiment. This is not a registered source profile,
Store profile, compiler IR, or effect surface.

## Existing gap

Beagle's system thesis names one semantic architecture, but the current checked
Lisp AST, compiler fact projections, and Store Terms are distinct
representations with only partial world/provenance bridges. This experiment
works inside that existing gap. Its term arena is profile-local evidence, not a
candidate universal IR, and its derived answers are not Store assertions.

## Hypothesis

A relation can retain one declarative identity while different admitted modes
select different bounded executable strategies. Query execution can consume a
typed semantic world while source files remain replaceable projections that
carry names, ordering, paths, spans, and layout rather than semantic authority.

The four contracts are deliberately separate:

```text
relation     declarative meaning and typed participant slots
mode         known/logic positions and solution cardinality
strategy     algorithm, cost class, bounds, and termination claim
realization  authorization, attempt, receipt, and observation (out of scope)
```

## Semantic model

- The fixed v1 sorts are `Symbol` and `SymbolList`.
- Terms live in an admitted acyclic arena. A node is a typed logic variable, a
  semantic Symbol identity, or a constructor application. Constructor edges
  must point to earlier nodes, so recursive host values and `Any` are absent.
- The fixed constructors are `nil : SymbolList` and
  `cons : Symbol × SymbolList -> SymbolList`.
- A variable is `(query-local scope, arena ordinal)`. Its stored ordinal must
  equal its node position, so two runtime-distinct nodes cannot canonicalize as
  one variable. Preferred names are source-projection data and never
  participate in unification or answer identity. Every clause invocation
  receives a fresh scope.
- Equality is first-order unification with full substitution walking and a
  mandatory occurs-check. Rational trees are excluded.
- A clause body is a left-to-right conjunction of equality and relation-call
  goals. The ordered clause vector supplies disjunction. An empty body is
  success; failure is the absence of an admitted unification branch. Each
  clause occurrence retains its relation-local ordinal, even when two
  occurrences have identical content and evidence.
- Search uses a FIFO small-step agenda. Observable ordering never depends on a
  map/set iteration order, clock, random source, parallel scheduler, or target.
- A query supplies finite reduction, agenda, and answer bounds. Arena admission
  supplies a finite per-reduction term bound. Exhaustion is `Truncated`, never
  logical failure or false completeness.
- Answers are unique by canonical projected term structure and retain
  deterministic discovery order within a query identity. Proof occurrences
  are separate: two ordered clause occurrences may prove one answer without
  duplicating the answer value.

## Modes, strategies, and receipts

A top-level query names an admitted mode. `ground` positions must contain no
logic variables; `logic` positions must contain at least one. Unsupported modes
are invalid rather than silently searched.

Determinism is checked only after agenda exhaustion:

```text
det       exactly one answer
semidet   zero or one answer
multi     one or more answers
nondet    zero or more answers
```

A complete result that violates its declaration is invalid. A truncated result
never certifies determinism.

The experiment admits three strategy families:

- `fifo-clauses`: fair bounded clause search with first-order unification;
- `fact-forward`: scan a fact-only relation in participant order; and
- `fact-reverse`: scan the same fact-only relation from its reversed known
  participant.

Strategy selection emits a pure receipt naming the semantic profile, relation,
mode, selected strategy, bounds, query identity, and reachable relation
closure. It is an explanation of computation, not an external effect receipt.

## World and source projections

`TheoryWorldV1` is the only input to query execution. Its audit identity covers
the semantic profile, type/constructor schema, relation contracts, mode and
strategy contracts, and ordered clauses.

`SourceProjectionV1` is separate. It maps semantic identities to preferred
renderings and carries source-content, path, and layout identities. Projection
changes remint a provenance receipt but do not remint the world, query, answer,
or strategy-selection identity.

For incremental reasoning, a query result is causally keyed by its reachable
relation closure rather than the whole world audit identity. A relevant clause
change must remint the result. An unrelated relation may remint the world while
leaving the result reusable. Positive proof dependencies alone are
insufficient: the closure includes the fixed sort/constructor schemas and
complete ordered reachable relation extents so a new fact cannot create an
unnoticed earlier answer.

## Required executable demonstrations

1. `append([a,b], [c], q)` completes with `q = [a,b,c]`.
2. `append(x, y, [a,b])` completes with the three splits in deterministic
   order.
3. One scope-resolved Beagle dependency relation retains one identity while:
   `calls(blast-closure!, q)` uses `fact-forward`, and
   `calls(q, d/run-rules!)` uses `fact-reverse`.
4. Two source projections with different names, ordering, source paths, and
   layout IDs render the same answers differently while preserving semantic
   world, query, answer, and strategy-selection identities.
5. A relevant `calls` fact change remints the result; an unrelated relation
   change remints only the world audit identity.
6. Duplicate variable-ordinal rejection, occurs-check rejection,
   unsupported-mode rejection, explicit recursive-loop truncation, answer
   deduplication with separate proofs, and exact repeated-run determinism are
   observed canaries. Repeat determinism compares both the complete typed result
   value and its canonical UTF-8 result-receipt bytes.
7. Beagle's tracked branch-compilation corpus supplies a non-toy retrospective
   explanation workload. Given the corpus's observed semantic changes and
   direct-read graph, comment/layout, private-body, and public-interface cases
   reproduce its exact zero-, one-, and two-unit typed/native cones.

## Compiler-oracle explanation workload

The workload copies the exact nine baseline `semantic-unit-v0` identities and
selected before/after source, semantic-content, and module-interface digests
from `beagle:bin/test/branch-compile-corpus/oracle/identities.tsv`. Its six
direct-read facts are the complete non-empty dependency cells in
`beagle:bin/test/branch-compile-corpus/units.tsv`. The driver reconciles both
sets independently against those tracked files before accepting the fixture.
Qualified names such as `corpus.foundation/adjust` are only preferred source
renderings. A join never parses their spelling.

Its fact clauses correspond to these canonical propositions, where each `-id`
is the exact semantic-unit Atom rather than the displayed qualified name:

```text
(adjust-id, :reads_semantic_unit, private-offset-id)
(score-value-id, :reads_semantic_unit, adjust-id)
(stable-score-id, :reads_semantic_unit, double-value-id)
(run-score-id, :reads_semantic_unit, score-value-id)
(run-stable-id, :reads_semantic_unit, stable-score-id)
(run-independent-id, :reads_semantic_unit, independent-value-id)

(private-mutation-id, :changes_semantic_content_of, private-offset-id)

(public-mutation-id, :changes_semantic_content_of, adjust-id)
(public-mutation-id, :changes_semantic_content_of, score-value-id)
(public-mutation-id, :changes_contract_of, adjust-id)
```

The comment/layout mutation has source-provenance identity but no observed
semantic-content or contract-change proposition. Two clauses derive an
explanation of observed unit churn:

```text
(mutation, :observed_unit_churn_of, unit)
  :- (mutation, :changes_semantic_content_of, unit).

(mutation, :observed_unit_churn_of, reader)
  :- (mutation, :changes_contract_of, dependency),
     (reader, :reads_semantic_unit, dependency).
```

One `reads_semantic_unit` relation retains both `[ground logic]` forward and
`[logic ground]` reverse modes. The observed-churn relation has a
`[ground logic]`, `nondet` mode because a comment/layout mutation legitimately
has no answer. The exact required results are:

```text
comment-layout          -> {}
private-implementation  -> {private-offset-id}
public-interface        -> {adjust-id, score-value-id}
```

The public case retains three proof occurrences for two unique answers:
`score-value` has both an observed content-change proof and a direct-reader
proof from the changed `adjust` contract. `run-score` remains excluded because
the fixture records no changed public contract for `score-value`, so the rule
stops at the direct reader. The stable and independent arms remain excluded by
the same exact-set canary.

This is an oracle explanation, not a predictive compiler work plan.
`semantic-unit-content` churn is post-build evidence; using it to decide which
units must be built would be circular. The tracked oracle also records the
changed `corpus/foundation.bgl` module interface, but it does not expose a
first-class binding-level fact that `adjust` changed contract. The fixture's
`changes_contract_of(public-mutation, adjust)` proposition is therefore a
controlled-corpus assumption supported by the public mutation, not a fact read
directly from the oracle.

The workload is stage-blind. Its relation derives one semantic-unit set. The
driver separately checks every member against the tracked typed-unit cone,
checks that typed-unit and native-unit cones are currently equal, and therefore
does not prove that one unqualified relation would remain correct if those
stages diverged.

Mode and strategy selection is also only demonstrated at top-level queries.
The forward and reverse dependency queries select distinct strategies over one
relation, but relation goals nested in the observed-churn clauses expand
left-to-right under the generic FIFO engine; they do not select their own
mode-specific procedures.

Finally, the reachable-closure identity covers complete reachable relation
extents. The canaries prove that an unrelated relation can preserve reuse while
a relevant reachable fact remints it. A query-irrelevant addition inside any
reachable relation still over-invalidates, so row-local dependency reuse is not
claimed.

A predictive version needs pre-lowering, per-definition facts for body identity
and public contract identity, stage-qualified dependency and result facts, and
honest oriented planning over those inputs. The existing corpus unit-reuse gate
remains authoritative for reuse, stale dependency-context rejection, mixed
assembly, and clean-build byte equality; this focused profile does not replace
or contact that executor.

## Validation execution boundary

The fixture is checked bare `#lang beagle` Core. Its focused driver projects the
checked program through Beagle's production Clojure emitter and executes that
projection with Babashka. Portable UTF-8 and SHA-256 operations are supplied by
the emitter-owned checked runtime; the driver does not inject alternative
implementations. Printing the demo transcript is a harness effect after the
pure canaries pass, not an effect available to the relational profile.

Direct Native materialization is not claimed by this experiment. The current
lowerer accepts source freeze and source-to-typed, then reports explicit pending
support for higher-order `reduce` callbacks and `recur` nested under
short-circuit expressions. Those compiler gaps remain separate from the
semantic-profile verdict.

The frozen dependency sample comes from Beagle's actual compiler-query shape:
scope-resolved `calls-defn` facts and the `blast-closure!` traversal in
`store/src/resolve_query.bclj`. It is copied as semantic identities, not read
from or asserted into a Store during the experiment.

## Authority and effects

Every answer is query-local `Derived` evidence. The profile requests no
capability and cannot contact Store, persist an assertion, claim an observation,
authorize an action, execute an effect, or manufacture an external receipt.
Equality establishes neither truth, trust, freshness, admission, nor authority.

If these propositions are later admitted under a fact-oriented Store profile,
the relation vocabulary and membership must be explicit canonical Triples.
Store's existing advisory profile named `relational` is unrelated and is not an
implementation substrate for this language experiment.

## Stop conditions

Stop rather than extend the experiment if any of these become necessary:

- truncation is reported as failure or completeness;
- recursive term representation introduces `Any` or cyclic host values;
- variable display names affect identity;
- a cyclic arena or substitution is admitted;
- provenance is merged into answer equality;
- source path, order, or layout enters semantic identity;
- a derived result becomes eligible for an effect;
- Store Datalog already supplies the only demonstrated value; or
- production syntax, Store wire changes, persistence, caching, tabling,
  negation, constraints, host predicates, or compatibility code are required
  to make the canaries pass.

Passing this experiment authorizes design of a real reader/checker capsule and
oriented executable IR. It does not authorize changing bare `#lang beagle` or
claiming that Beagle already has one representation shared by source, compiler,
and Store.
