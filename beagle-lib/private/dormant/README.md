# `dormant/` — parked target scaffolding

This directory holds Beagle's non-Nix emitters and stdlib catalogs. They
are **parked**, not deleted. The Nix loop is the live happy path; the
other targets are recoverable scaffolding kept out of the default
develop/test/build path so the project stops paying for them during
day-to-day Nix work.

## What's here

| File | Status | Notes |
|---|---|---|
| `emit-clj.rkt` | dormant | Clojure emitter; also reused for ClojureScript via flag |
| `emit-js.rkt` | dormant | JavaScript emitter + the `js/*` typed-JS surface |
| `emit-py.rkt` | dormant | Python emitter (dataclasses, match/case, snake_case) |
| `emit-rkt.rkt` | dormant | Typed Racket emitter — also the oracle target |
| `emit-sql.rkt` | dormant | SQL emitter (CTE / select / insert / update / delete) |
| `emit-scheme.rkt` | dormant | Cyclone Scheme target — never shipped, deferred |
| `emit-jst.rkt` | dormant | Typed-JS (`jst-*`) emission helpers |
| `emit-js-quote.rkt` | dormant | `(js/quote …)` AST rendering |
| `js-emit-utils.rkt` | dormant | Shared JS emit utilities |
| `js-capabilities.rkt` | dormant | JS capability sets (JS-TRANSLATED, etc.) |
| `stdlib-clj.rkt` | dormant | Clojure stdlib catalog |
| `stdlib-cljs.rkt` | dormant | CLJS stdlib catalog |
| `stdlib-js.rkt` | dormant | JS stdlib + JS-NO-EMIT computation |
| `stdlib-py.rkt` | dormant | Python stdlib catalog |
| `stdlib-sql.rkt` | dormant | SQL stdlib (CTE, aggregates, scalar fns) |

## How they're loaded

By default they are **not** loaded. `private/emit.rkt` requires only
`emit-nix.rkt` at module top level; the others sit behind:

```racket
(when (getenv "BEAGLE_ALL_TARGETS")
  (dynamic-require (build-path dormant-dir "emit-clj.rkt") #f)
  …)
```

`private/stdlib-types.rkt` does still require the dormant `stdlib-*.rkt`
files unconditionally — those are consumed by tools the user runs across
any target (LSP hover, `beagle-sig`, `beagle-fields`), and the catalog
data alone is cheap to load.

## Reactivation

Pick one of:

1. **Per-session:** `BEAGLE_ALL_TARGETS=1 bin/beagle-test` (or any
   beagle CLI). Loads the dormant emitters at startup; the dispatch
   table registers them and `#lang beagle/clj`, `#lang beagle/js`, etc.
   work as before.
2. **Per-target (when revisiting one target seriously):** move that
   target's emitter and stdlib out of `dormant/`, update the require
   path in `private/emit.rkt` and `private/stdlib-types.rkt`, and move
   its test files back to the `active` tier in `beagle-test/tiers.rktd`.

The test files for non-Nix targets are in `gated` — opt in with
`BEAGLE_ALL_TARGETS=1` or the test-specific env vars listed in
`tiers.rktd`.

## Why quarantine, not delete

Tom does not regret exploring multi-target — the operative pipeline
proved the abstractions are portable, and any target may return to
live status when its loop becomes valuable. Deleting would force
archaeology to reactivate. Quarantining keeps the work intact and
keeps reactivation cheap: a path flip in two files and a tier move.

See thread `~/code/life-os/threads/20260528233608-beagle_quarantine_non_nix_targets.md`
for the full rationale, audit numbers, and acceptance criteria.
