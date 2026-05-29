# Beagle

**A typed, LLM-optimized authoring surface for Nix. Schema-driven
validation, sub-second re-checks, round-trips real-world Nix without
semantic loss.**

Five other backends (Clojure, ClojureScript, JavaScript, Python, SQL,
Typed Racket) sit in [`beagle-lib/private/dormant/`](beagle-lib/private/dormant/) —
parked, not deleted, reactivate with `BEAGLE_ALL_TARGETS=1`. The live
loop is Nix only.

## Design notes

- [`docs/motivation.md`](docs/motivation.md) — the bet: typed-Lisp-for-AI threading the needle between sprawl and bloat
- [`docs/principles.md`](docs/principles.md) — seven load-bearing surface principles
- [`docs/lock-in.md`](docs/lock-in.md) — form changes require measurable deltas on documented benchmarks
- [`docs/research.md`](docs/research.md) — frozen results from the lab (E1–E22)

## Targets

| Target | `#lang` | Stdlib | Status |
|---|---|---|---|
| Nix | `beagle/nix` | 523 entries | **live** — schema-typed, round-trips real-world Nix |
| Clojure | `beagle/clj` | 397 | dormant |
| ClojureScript | `beagle/cljs` | 132 | dormant |
| JavaScript | `beagle/js` | 102 + 28 typed `js/*` | dormant |
| Python | `beagle/py` | 348 | dormant |
| SQL | `beagle/sql` | 59 | dormant |
| Typed Racket | `beagle/rkt` | (oracle) | dormant |

Plus 269 portable stdlib entries shared across all targets. Dormant
emitters and catalogs are intact under `beagle-lib/private/dormant/`;
opt in for one session with `BEAGLE_ALL_TARGETS=1`.

## Install

Requires [Racket](https://racket-lang.org/) 8.x+.

```sh
git clone https://github.com/tompassarelli/beagle
cd beagle
raco pkg install --link beagle-lib/ beagle-test/ beagle/
bin/beagle-test    # Nix-tier (~55s)
```

For NixOS users dogfooding their config: clone
[firnos](https://github.com/tompassarelli/firnos) for a real working
example, or run `beagle init` in a fresh dir to scaffold.

## Documentation

There is no static reference catalog — the surface churns and static
docs go stale within a day. To know anything mechanical, query the
compiler:

```sh
bin/beagle-syntax FILE        # parse check + repair
bin/beagle-sig X FILE...      # typed signature
bin/beagle-fields R FILE...   # record fields
bin/beagle-provides FILE      # module exports
bin/beagle-callers X FILE...  # call sites
```

For the form set, read `beagle-lib/private/parse.rkt`. For the typed
externs, read `beagle-lib/private/stdlib-nix.rkt` and `stdlib-portable.rkt`.
See `CLAUDE.md` for the full tool list and rules-with-teeth (no escape
hatches, tiering discipline, etc.).

## Status

`#lang beagle` v0.15.1 — Nix-tier active loop is green; dormant-tier
opt-in via `BEAGLE_ALL_TARGETS=1`. **No v1.0 until others have used it
in anger.** The author dogfoods on a 220-file NixOS config
([firnos](https://github.com/tompassarelli/firnos)) — schema-typed
end-to-end, system builds from `flake.bnix` directly. Production-grade
for one user, ready-for-adventure for others.

## License

MIT.
