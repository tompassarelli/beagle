# 014 — v0.4.0: consumer hardening, type inference floor, unified CLI

**Date:** 2026-05-17

## Hypothesis

Before building E12 (50K LOC stress test), push the type checker to
its inference floor and harden the consumer surface. The thesis: every
remaining `Any` in the inference path represents a missed opportunity
for beagle to catch bugs. Eliminating them compounds at scale.

## Changes

**Type inference floor (9 changes to check.rkt):**
- Collection literals infer element types (Vec/Map/Set)
- For/doseq bindings inherit element types from collections
- Map + sequential destructuring propagate record field types
- Branch returns merge into unions (if, try, match, case, cond)

After this pass, every remaining `Any` in `infer-expr` is genuinely
dynamic: unsafe blocks, Java interop, unbound symbols, regex, quoted
forms. No more precision to extract without bidirectional type checking.

**Consumer surface:**
- `bin/beagle` unified CLI (check, build, fix, sig, fields, lsp, repl, init)
- `docs/cheatsheet-consumer.md` — 154 lines vs 511 in developer version
- `beagle init` bootstraps .claude/beagle-context.md for consumer projects

**Error messages (8 fixes):**
- Added `#:src` to def, defn, defn-multi, let-binding errors
- `with` unknown field now lists available fields
- Multi-arity arity error now includes signature
- "did you mean?" phrasing for field suggestions
- Literal arg-expr for integers/booleans/keywords in type mismatches

**Dead code / cleanup:**
- Removed RECORD-ORIGIN, ENUM-VALUES, expr-provenance, 4 duplicate functions
- Fixed silent bugs: doseq/case missing from walk-for-provenance + symbols-in
- Updated all docs (README, CLAUDE.md, forms.md, cheatsheet.md, todo.md)

## Result

370 tests, 0 failures. 8 files changed, net reduction in code despite
new features (dead code removal offset the additions).

## Interpretation

The inference floor is real and measurable — you can enumerate every
remaining `Any` source and justify why it's irreducible. This means
E12 results will reflect beagle's actual type-checking capability,
not gaps in inference that happen to be unexercised.

## Next question

Does the type inference floor hold at 50K LOC? E12 (Mini-ML compiler
toolchain) will test whether the advantage compounds or plateaus at
genuine complexity — deep coupling, cross-cutting features, nested
types, mid-build design changes.
