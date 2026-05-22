---
status: active
priority: 1
---

# Emit targets — gaps, correctness, coverage

## Nix: multi-arity must fail loudly

- [x] `emit-nix.rkt`: multi-arity `defn` errors at emit time (both Racket + Bun emitters).

## Clojure emitter: test backfill

- [x] Create emit-clj-behavioral.rkt — 51 end-to-end tests (compile → bb → verify output).
      Covers: def, defn, defrecord, defunion, let, destructuring, cond/if/when/case,
      loop/recur, for/doseq/dotimes, try/catch, threading, higher-order, atoms, letfn,
      defmulti/defmethod, collections, strings.
- [x] defenum keyword emission fix (emitted symbols instead of keywords).
- [x] defmethod return type annotation leak fix.
- [x] Expand: add multi-module tests (ns + require round-trip via bb classpath).
- [x] Expand: add defprotocol/deftype/extend-type behavioral tests.

## Oracle CI

- [x] Oracle CI integration — raco make cross-check on Bun compiler output
      (23/30 oracle pass, 22/30 emission parity; 8 known Bun emit-rkt.bjs gaps tracked)

## JS target

- [x] `js-template` — typed splice sites (collection types raise E016 diagnostic)
- [x] `js/quote` — structural JS quasiquotation (already complete: 3 splice kinds)

## Cancelled

- **beagle/elixir, beagle/bash** — Speculative targets with no experiments, no
  stdlib work, no user demand. Adding a new target is ~2 weeks of work (emitter,
  stdlib, tests). No evidence these would be used. Resurrect if a concrete use
  case appears.

- **SQL gaps (parameterized queries, dialect testing, transactions, UPSERT,
  views, derived tables, schema migrations)** — SQL target is compile-only
  verification (54 stdlib entries, no runtime deployment). Nobody deploys SQL
  from beagle. These are features for a target that serves as a type-checking
  demo, not a production emitter. If SQL becomes a real deployment target,
  resurrect from this list.

- **Racket target gaps (defenum keyword, count on strings, Int/Int division,
  display format)** — Racket target is the oracle/verification target. These are
  minor emission differences that don't affect type validation (the oracle's
  purpose). None block any workflow.

- **E13 confound isolation** — E13 completed (287s avg, per-bug faster than
  Python+mypy). The confound (full prompt vs cheatsheet, daemon vs no daemon)
  would not change any design decision already made. The result stands.

- **Stale .zo files across agents** — Speculative. Not demonstrably causing
  failures. If an agent hits a stale .zo, re-running the command works. No
  user report of this being a real problem.
