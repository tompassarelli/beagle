# Beagle

Beagle is a typed Clojure subset that compiles one AST to idiomatic code
for five language targets — Clojure, ClojureScript, JavaScript, Nix, and
Odin.

Its types exist for a specific job: making authoring, diagnostics, and AI
repair reliable. They check at compile time and erase before emit. The
point isn't to reject bad code — it's to tell repair tools what kind of
mistake happened, where in the source, after which canonicalization,
against which target.

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

SQL's schema-typing is live in the checker; its emitter is parked under
`dormant/`, loadable with `BEAGLE_ALL_TARGETS=1`. Targets are removed, not
deprecated, when they stop earning their place — reviving one means
re-wiring `emit.rkt` and proving it against a real consumer, not flipping
a switch.

## How it compiles

```
.bclj / .bcljs / .bjs / .bnix / .bodin  ──▶  parse ──▶ check ──▶ emit  ──▶  .clj / .cljs / .js / .nix / .odin
                                                          ▲
                                            macros, schema, stdlib, type narrowing
                                            all share one AST + diagnostic path
```

`check` is where the NixOS option schema (loaded from a cache at compile
time) becomes typed context: unknown option paths fail at parse time,
wrong-typed values fail at type-check time, ahead of any build. Sourcemap
fidelity is preserved through every canonicalization, so diagnostics point
at the author's position, not a desugared intermediate.

## What it isn't

- Not a schema language, not a validation runtime — types check at
  compile time, then erase.
- Not a new Lisp — a strict typed subset of Clojure. Where the surface
  diverges from Clojure, that divergence must serve the type system or a
  backend, or it dies.
- Not stable. Pre-1.0, the surface still moves, and removals are hard
  breaks — there is no deprecation path.

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

`services.openssh.enable` is typed `Bool` from the schema, so assigning a
`String` fails at check time with file:line:col precision — before
`nixos-rebuild` ever runs.

Every snippet above passes `bin/beagle-syntax`.

## Surface highlights

- **Inline `:-` annotations** on `def` / `defn` / `defonce`; record field
  types ride in the fields list, `(defrecord Point [x :- Int y :- Int])`.
  Interiors and `let`-locals are inferred.
- **`defmacro`** with quasi-quote / unquote / unquote-splicing.
- **The Clojure threading family** — `->`, `->>`, `as->`, `cond->`,
  `cond->>`, `some->`, `some->>`.
- **Reader conditionals** `#?(:clj … :cljs … :nix … :default …)` and
  `#?@(…)` splice.
- **Quoted containers** `'[…]`, `'{…}`, `'#{…}` self-evaluate.
- **Sourcemap fidelity** — the author's position survives every
  canonicalization, guarded by a dedicated bench.
- **Typo suggestions** for mistyped NixOS options — segment-aware
  Levenshtein against the option schema.
- **Per-target prefixes** (`nix/`, `js/`, …) for forms whose meaning
  genuinely diverges per backend.

## How it's organized

- `beagle-lib/private/parse.rkt` — the surface form set, and the source of
  truth; static docs go stale.
- `beagle-lib/private/check.rkt` — the type checker.
- `beagle-lib/private/emit-{clj,cljs,js,nix,odin}.rkt` — the live emitters;
  `beagle-lib/private/dormant/` holds the parked ones.
- `beagle-lib/private/nixos-schema.rkt` — the typed NixOS-option environment.
- `beagle-lib/private/diagnostic-kind.rkt` — the `cause-class?` taxonomy.
- `beagle-test/` — the tiered test suite; `beagle-test/tiers.rktd` is the
  authoritative classification.
- `CLAUDE.md` — the operating discipline, and the reference for any
  question about the surface.
- `docs/` — `INFLUENCES.md` (lineage + thesis) and the generated
  `CHEATSHEET.md`.

## Who authors against it

- [firnos](https://github.com/tompassarelli/firnos) — a complete NixOS
  system authored in `.bnix` and schema-typed end to end; it builds from
  `flake.bnix` directly.
- [gjoa](https://github.com/Autonymy/gjoa) — a Firefox overlay UI ported
  from TypeScript to `.bjs`.

## Getting started

Requires Racket 8.x+.

```sh
git clone https://github.com/Autonymy/beagle
cd beagle
raco pkg install --link beagle-lib/ beagle-test/ beagle/
bin/beagle-test --active-only       # the active tier
```

## Tooling

Static reference docs are intentionally thin while the surface moves — the
compiler is the source of truth, fronted by one CLI:

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
an on-edit syntax/type hook, and machine-applicable fixes — is where the
type signal becomes applied edits; `bin/beagle doctor` health-checks it
end to end. Deeper dev tools stay as `bin/beagle-*` (blame, specfix,
trace, cascade).

The `bin/beagle-claims` / `bin/beagle-roundtrip` backends project Beagle
source into a claim graph for Fram's
[Chartroom](https://github.com/Autonymy/fram/tree/main/chartroom). The
claim log is canonical there — the source text is a view onto the claims,
not a graph derived from text after the fact.

## Design discipline

- **Hard removal over deprecation.** No back-compat shims.
- **Divergence from Clojure must serve types or a backend, or it dies.**
  Inert syntactic novelty is rejected.
- **Each target renders idiomatically** — same surface, faithful per
  backend.
- **Gates have stated jurisdiction.** When ambiguous, ask; don't silently
  defer.

See `CLAUDE.md` for the full rule set.

## License

MIT. See [`LICENSE`](LICENSE).
