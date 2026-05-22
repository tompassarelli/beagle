---
status: active
priority: 1
---

# Emit targets — gaps, correctness, coverage

## Nix: multi-arity must fail loudly

- [ ] `emit-nix.rkt`: multi-arity `defn` silently drops all but the first arity.
      Must error at emit time: "multi-arity not supported for Nix target."
      Silent incorrect output is worse than a missing feature.

## Clojure emitter: test backfill

- [ ] Create emit-clj test suite — the emitter has **zero behavioral tests**.
      414 stdlib entries, original target, largest blast radius, no mechanical
      regression detection. JS has 11 suites, Python 63 cases, Nix 53 cases.
      The 11/11 emission parity proof covers JS, not CLJ.
- [ ] Fixture suite comparable to Nix/Python: core forms, defrecord, match,
      threading, interop, destructuring, ns/require emission.

## Oracle CI

- [ ] Oracle CI integration — raco make cross-check on Bun compiler output
      (moved from self-hosting.md)

## New targets

- [ ] `beagle/elixir`
- [ ] `beagle/bash`

## SQL gaps

- [ ] Parameterized queries (bind params, not string interpolation)
- [ ] Dialect testing (Postgres, MySQL round-trip — only SQLite validated)
- [ ] Transactions (BEGIN/COMMIT/ROLLBACK)
- [ ] UPSERT / ON CONFLICT
- [ ] Views (CREATE VIEW, SELECT from views)
- [ ] Derived tables (subquery in FROM)
- [ ] Schema migrations (versioned DDL with up/down)

## Racket target gaps

- [ ] `defenum` keyword-as-member (checker rejects)
- [ ] `count` on strings
- [ ] `Int/Int` division → Exact-Rational
- [ ] defscalar/collection display format differs between targets

## JS target

- [ ] `js-template` — typed splice sites
- [ ] `js/quote` — structural JS quasiquotation

## Misc

- [ ] E13 confound isolation: full prompt vs cheatsheet, daemon vs no daemon
- [ ] Stale `.zo` files across agents (race conditions with PostToolUse hook)
