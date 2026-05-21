---
status: paused
priority: 3
---

# Emit targets — gaps and new targets

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
