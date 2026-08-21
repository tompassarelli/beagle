+++
id = "beagle-types-qa"
title = "Source-grounded answers on generics, predicate factories, and union wildcards"
shape = "thread"
life = "internalized"
updated_at = "2026-08-17T19:24:14+08:00"
owners = ["codex:/root"]
depends_on = []
+++

# Beagle type-system Q&A

Scope: source and tests in `beagle:main` were read only. Verification used
`nice -n 19 bin/beagle check --agent` against temporary `#lang beagle/clj`
files in `/tmp/beagle-types-qa/`; it did not edit the Beagle checkout.

## Q1 — Generics

Beagle has real parametric polymorphism. The spelling is a `forall` type
scheme, either `(forall [T] ...)` or `(forall (T) ...)`; a bounded variable is
`(forall [(T <: Bound)] ...)`. A variable is in scope only inside that scheme.
For a user-authored generic identity, put the scheme on a value and return an
ordinary typed function:

```clojure
(def identity (forall [T] (Fn [T] T))
  (fn [(x T)] T x))

(def number Int (identity 42))
(def label String (identity "beagle"))
```

Actual checker output:

```text
$ nice -n 19 bin/beagle check --agent /tmp/beagle-types-qa/generics-ok.bclj
0 errors
```

Generic nominal unions are also supported, with the type variables on the
union name, not through row types:

```clojure
(defunion (Result T E)
  (Ok [(value T)])
  (Err [(error E)]))

(defn unwrap-or [(result (Result Int String))] Int
  (match result
    [(Ok value) value]
    [(Err error) 0]))
```

`(U A B)` is a finite structural union, not a row-polymorphic type; there is
no row-variable spelling in the type grammar. The portable standard library's
`map` is itself polymorphic over `A` and `B`, while `mapv` returns `(Vec B)`.
This is deliberately bounded rather than a claim of full Hindley–Milner:
mandatory boundary annotations plus definition-local generalization keep the
surface small and machine-checkable.

Source citations:

- `beagle:beagle-lib/private/types.rkt:143` parses `forall` variables and bounds; `beagle:beagle-lib/private/types.rkt:205` accepts the two `forall` vector/list spellings; `beagle:beagle-lib/private/types.rkt:264` scopes an authored type variable.
- `beagle:beagle-lib/private/types.rkt:222` defines structural `(U ...)`; `beagle:beagle-lib/private/types.rkt:235` recognizes parameterized constructors such as `(Vec T)` and `(Result T E)`.
- `beagle:beagle-lib/private/parse.rkt:3382` recognizes `(defunion (Name T ...) ...)`; `beagle:beagle-lib/private/parse.rkt:5040` validates and registers its parameters.
- `beagle:beagle-lib/private/stdlib-portable.rkt:68` gives `map` its `A`/`B` polymorphic signature; `beagle-test/tests/fixtures/check/poly-forall.bclj:1` is the repository's direct `forall` fixture.
- `beagle:docs/INFLUENCES.md:74`–`beagle:docs/INFLUENCES.md:90` states the explicit/bounded-polymorphism choice and the deliberate non-claim of full HM.

Recommended cheatsheet addition (exact text):

> **Generics:** Beagle supports parametric polymorphism. Write a user-authored scheme as `(forall [T] (Fn [T] T))` (or `(forall [(T <: Bound)] ...)`) and use `T` inside its body, e.g. `(def identity (forall [T] (Fn [T] T)) (fn [(x T)] T x))`. Parameterize a nominal union as `(defunion (Result T E) ...)` and use it as `(Result Int String)`. `(U A B)` is a finite union, not row polymorphism.

## Q2 — Constraint factory proofs

There is no `:synchronous`, metadata tag, or proof token to add at the call
site. For a local predicate factory, the author must give the factory an
explicit callable return type and return a predicate whose full body the
checker can prove synchronous on every path. That declared `(Fn [Int] Bool)`
return makes the factory eligible for returned-callable analysis; the positive
effect proof is then inferred from the returned `fn` and its call graph.

```clojure
(defn at-least? [(minimum Int)] (Fn [Int] Bool)
  (fn [(value Int)] Bool
    (>= value minimum)))

(defn accept [(value Int (at-least? 10))] Int
  value)
```

Actual checker output:

```text
$ nice -n 19 bin/beagle check --agent /tmp/beagle-types-qa/factory-ok.bclj
0 errors
```

The same callable type from an external declaration is insufficient: the
external interface has not published the returned-callable synchronization
fact, so the checker fails closed.

```clojure
(declare-extern at-least? (Fn [Int] (Fn [Int] Bool)))

(defn accept [(value Int (at-least? 10))] Int
  value)
```

Actual checker output:

```text
$ nice -n 19 bin/beagle check --agent /tmp/beagle-types-qa/factory-fail.bclj
1 error
- factory-fail.bclj:5 parameter value constraint must be a statically known predicate (Fn [Int] Bool); got (Fn [Int] Bool) (the predicate is not proven synchronous; js/await, async call chains, and callables without interface synchronization metadata are not allowed)
```

Source citations:

- `beagle:beagle-lib/private/check.rkt:926` accepts a call-produced predicate only when its named callee has a returned-callable proof and the call expression is synchronous.
- `beagle:beagle-lib/private/check.rkt:2566`–`beagle:beagle-lib/private/check.rkt:2573` says an omitted or non-callable authored return remains unproved; `beagle:beagle-lib/private/check.rkt:2641`–`beagle:beagle-lib/private/check.rkt:2687` computes the local proof to a fixed point.
- `beagle:beagle-lib/private/check.rkt:2359` defines synchrony as no await/async and only positively proved named calls; `beagle:beagle-lib/private/check.rkt:2218` emits the exact rejection above.
- `beagle:beagle-test/tests/binding-constraint-check.rkt:124` is the matching regression test for a call-produced predicate without return-effect metadata; `beagle:docs/surface.md:38`–`beagle:docs/surface.md:46` states the user-facing rule.

Recommended cheatsheet addition (exact text):

> **Predicate factories:** There is no call-site proof annotation. For `(factory args...)` to be a binding constraint, define the local factory with an explicit callable return such as `(defn factory [(x Int)] (Fn [Int] Bool) (fn [(value Int)] Bool ...))`; Beagle then proves that every returned predicate path is synchronous. An imported/extern factory must publish the same returned-callable effect in its Beagle module interface—its `(Fn [...] (Fn [...] Bool))` type alone is not enough.

## Q3 — Union wildcards

`_` is valid match syntax, and a variable pattern is also catch-all-like for
ordinary matches. Neither is an escape hatch for a nominal `defunion`:
every declared member needs its own explicit pattern. `:else` is not a special
match arm; it likewise does not satisfy union exhaustiveness.

```clojure
(defunion (Result T E)
  (Ok [(value T)])
  (Err [(error E)]))

(defn unwrap-or [(result (Result Int String))] Int
  (match result
    [(Ok value) value]
    [_ 0]))
```

Actual checker output:

```text
$ nice -n 19 bin/beagle check --agent /tmp/beagle-types-qa/wildcard-fail.bclj
1 error
- wildcard-fail.bclj:8 match on Result is not exhaustive; missing cases: Err
```

Replacing `_` with `otherwise`, or with `:else`, produced the same verified
diagnostic at line 8: `match on Result is not exhaustive; missing cases: Err`.
The idiom is to write all member cases. If an arm is intentionally unhandled,
make that decision explicit in that member's arm, commonly by throwing:

```clojure
(match result
  [(Ok value) value]
  [(Err error) (throw "TODO: handle Err")])
```

The policy is intentional: the checker identifies the closed union's missing
constructors and produces ready-to-insert explicit arm skeletons, rather than
letting a catch-all hide a newly added member.

Source citations:

- `beagle:beagle-lib/private/check.rkt:4563` recognizes wildcard and variable patterns, but `beagle:beagle-lib/private/check.rkt:4571` explicitly says a wildcard does not satisfy `defunion` exhaustiveness.
- `beagle:beagle-lib/private/check.rkt:4591`–`beagle:beagle-lib/private/check.rkt:4636` computes the missing members, raises the diagnostic, and constructs the explicit repair clauses.
- `beagle-test/tests/fixtures/check/defunion-match-wildcard.bclj:1`–`beagle-test/tests/fixtures/check/defunion-match-wildcard.bclj:8` is the repository fixture; `beagle:beagle-test/tests/check.rkt:1082`–`beagle:beagle-test/tests/check.rkt:1088` asserts it must fail.
- `beagle:beagle-test/tests/exhaustive-match-fix.rkt:86`–`beagle:beagle-test/tests/exhaustive-match-fix.rkt:104` verifies the repair skeleton for a missing constructor.

Recommended cheatsheet addition (exact text):

> **Exhaustive unions:** `_`, a variable pattern, and `:else` are not escape hatches for a `defunion` match. Every declared member must have an explicit arm; if a case is intentionally unsupported, write that member's arm explicitly (for example `[(Err error) (throw "TODO: handle Err")]`). This lets Beagle name any newly missing constructor and generate its arm skeleton.

## Verification summary

- `nice -n 19 beagle doctor --deep`: `Authoring loop: ok`.
- `generics-ok.bclj`: `0 errors`.
- `factory-ok.bclj`: `0 errors`.
- `factory-fail.bclj`, `wildcard-fail.bclj`, `else-fail.bclj`, and `variable-fail.bclj`: each failed with the diagnostic documented above.
