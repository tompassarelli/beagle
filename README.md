# Beagle

Beagle is a typed Clojure subset that compiles one AST to idiomatic code
in many languages — [five live targets, four dormant](#targets).

Its types exist for a specific job: making authoring, diagnostics, and AI
repair reliable. They check at compile time and erase before emit. The
point isn't to reject bad code — it's to tell repair tools *what* kind of
mistake happened, *where* in the source, after *which* canonicalization,
against *which* target.

Real codebases author against Beagle:

- [firnos](https://github.com/tompassarelli/firnos) — a complete NixOS
  system, typed end-to-end against its 16k-option schema (Nix target).
- [gjoa](https://github.com/tompassarelli/gjoa) — a Firefox overlay UI,
  43 `.bjs` modules ported from TypeScript (JS target).
- [chelonia](https://github.com/tompassarelli/chelonia) — a claim-native
  coordination engine, 7 `.bclj` modules (Clojure target).

## Targets

One AST, idiomatic output per backend — Nix as lazy attrsets, Clojure as
eager maps, ClojureScript as Clojure-shaped JS, Odin as structs and procs.
Never a lowest-common-denominator transpile.

| Target        | Status  |
|---------------|---------|
| Clojure       | Live    |
| ClojureScript | Live    |
| JavaScript    | Live    |
| Nix           | Live    |
| Odin          | Live    |
| SQL           | Dormant emitter (schema-typing live) |

The SQL emitter sits under `dormant/`, one flag (`BEAGLE_ALL_TARGETS=1`)
away; its schema-typing is live in the checker. (Python / Typed Racket /
Scheme / Zig were removed 2026-06-15 — recoverable from the
`dormant-targets-archive-2026-06-15` tag.)

## How it compiles

```
.bclj / .bcljs / .bjs / .bnix / .bodin  ──▶  parse ──▶ check ──▶ emit  ──▶  .clj / .cljs / .js / .nix / .odin
                                                          ▲
                                            macros, schema, stdlib, type narrowing
                                            all share one AST + diagnostic path
```

`check` is where the 16k-option NixOS schema becomes typed context:
unknown option paths fail at parse time, wrong-typed values fail at
type-check time — before `nixos-rebuild` is invoked. Sourcemap
fidelity is preserved through every canonicalization so diagnostics
point at the author's position, not a desugared intermediate.

## What it isn't

- Not a schema language, not a validation runtime — types check at
  compile time, then erase.
- Not a new Lisp in spirit — a strict typed subset of Clojure. Where
  the surface diverges from Clojure, that divergence must serve the
  type system or a backend, or it dies.
- Not stable. Pre-1.0, surface still moves. No deprecation aisle —
  removals are hard.

## Quick taste

Portable surface — parses for any target:

```clojure
;; types ride on bindings; interiors inferred
(defn double [n :- Int] :- Int
  (* n 2))

;; macros + quasi-quote (Scheme-style unquote: `,x`, splice `,@xs`)
(defmacro inc1 [x] `(+ ,x 1))

;; Clojure threading
(-> 1 (+ 2) (* 3))

;; reader conditionals for target-divergent code
(def msg #?(:clj "hello" :cljs "hi" :nix "bonjour"))

;; keyword access canonicalizes — `(:k m)` and `(get m :k)` are the same node
(:name {:name "ada"})
```

Nix flavor — a NixOS module authored against the typed schema:

```clojure
#lang beagle/nix
(ns ssh)

(nix/module [config lib pkgs ...]
  {:options.myConfig.modules.ssh.enable (lib.mkEnableOption "SSH server")
   :config
    (lib.mkIf config.myConfig.modules.ssh.enable
      {:services.openssh.enable true})})
```

emits:

```nix
{ config, lib, pkgs, ... }:
{
  options.myConfig.modules.ssh.enable = lib.mkEnableOption "SSH server";
  config = lib.mkIf config.myConfig.modules.ssh.enable {
    services.openssh.enable = true;
  };
}
```

`services.openssh.enable` is typed `Bool` (resolved from the schema
cache). Assigning a `String` fails at check time with file:line:col
precision — before `nixos-rebuild` is invoked.

Every snippet above passes `bin/beagle-syntax`.

## Surface highlights

- **Inline `:-` annotations** on the typed boundaries `def` / `defn` /
  `defonce` / `defrecord`; interiors and `let`-locals are inferred.
- **`defmacro` + quasi-quote / unquote / unquote-splicing.**
- **Clojure threading family:** `->`, `->>`, `as->`, `cond->`,
  `cond->>`, `some->`, `some->>`.
- **Reader conditionals** `#?(:clj … :cljs … :nix … :default …)` and
  `#?@(…)` splice.
- **Quoted containers** `'[…]`, `'{…}`, `'#{…}` self-evaluate.
- **Sourcemap fidelity:** author position survives every
  canonicalization (11/11 on the fidelity bench).
- **Typo suggestions** against the 16k-option NixOS schema:
  segment-aware Levenshtein, 96.9% Top-1, ~130 ms/query.
- **Per-target prefixes** (`nix/`, `js/`, …) for forms whose meaning
  genuinely diverges per backend.

## How it's organized

- `beagle-lib/private/parse.rkt` — surface form set. The source of
  truth; static docs go stale.
- `beagle-lib/private/check.rkt` — type checker.
- `beagle-lib/private/emit-{clj,cljs,js,nix,odin}.rkt` — live emitters;
  `beagle-lib/private/dormant/` holds the parked ones.
- `beagle-lib/private/nixos-schema.rkt` — 16k-option typed environment.
- `beagle-lib/private/diagnostic-kind.rkt` — `cause-class?` taxonomy.
- `beagle-test/` — tiered test suite; `beagle-test/tiers.rktd` is the
  authoritative tier classification.
- `CLAUDE.md` — the operating discipline. The preamble's
  three-statement generative spec (Clojure + types / load-bearing
  divergence / idiomatic per target) is the canonical anchor for any
  surface question.
- `docs/` — distilled, rot-resistant artifacts: `INFLUENCES.md`
  (lineage + thesis) and the generated `CHEATSHEET.md`.

## Getting started

Requires Racket 8.x+.

```sh
git clone https://github.com/tompassarelli/beagle
cd beagle
raco pkg install --link beagle-lib/ beagle-test/ beagle/
bin/beagle-test --active-only       # active tier
```

For a real-world `.bnix` corpus, clone
[firnos](https://github.com/tompassarelli/firnos) — schema-typed end to
end; the NixOS system builds from `flake.bnix` directly.

## Tooling

Static reference docs are intentionally thin while the surface is
moving — the compiler is the source of truth, fronted by one CLI:

```sh
bin/beagle doctor               # is the repair loop online and working?
bin/beagle syntax FILE          # parse check (+ --repair --emit-patch)
bin/beagle check FILE           # typed checker
bin/beagle validate [FILE...]   # parse + check + schema validation
bin/beagle sig NAME FILE...     # typed signature
bin/beagle fields RECORD FILE   # record fields, types, accessors
bin/beagle callers NAME FILE... # call sites
bin/beagle expand FILE          # macro-expanded source
bin/beagle explain-type FILE    # inferred types as a view
```

`bin/beagle help` lists every command. The repair loop — a watch daemon,
an on-edit syntax/type hook, and machine-applicable fixes — is what makes
the types pay off; `bin/beagle doctor` health-checks it end to end. Deeper
dev tools stay as `bin/beagle-*` (blame, specfix, trace, cascade).

## Design discipline

The discipline is intentionally tight:

- **Hard removal over deprecation.** No back-compat shims.
- **Divergence from Clojure must serve types or a backend, or it
  dies.** Inert syntactic novelty is rejected.
- **Each target renders idiomatically** — same surface, faithful per
  backend.
- **Gates have stated jurisdiction.** When ambiguous, ask; don't
  silently defer.

See `CLAUDE.md` for the full rule set.

## License

MIT. See [`LICENSE`](LICENSE).
