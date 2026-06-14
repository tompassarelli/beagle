# Beagle

Beagle is a typed Clojure subset designed to emit idiomatic code to
multiple targets from a single AST. Five targets are live today —
**Clojure**, **ClojureScript**, **JavaScript**, **Nix**, and **Odin**
— with **Zig**, **Python**, **SQL**, and **Typed Racket** emitters
parked under `dormant/`, one flag (`BEAGLE_ALL_TARGETS=1`) away.

The active distribution effort is **Nix-first**: the language people
actively dislike using, with no incumbent typed alternative, and a
failure profile (eval errors, schema violations, type mismatches in
module composition) that beagle's type system catches at compile time
against a 16k-option typed environment. The language *is* multi-target.
The *campaign* is Nix-first.

Types exist to make authoring, diagnostics, and AI repair reliable;
they check at compile time and erase before emit. The point isn't to
reject bad code — it's to tell repair tools what kind of mistake
happened, where in the source, after which canonicalization, against
which target.

Already used by [firnos](https://github.com/tompassarelli/firnos) to
author a NixOS system end to end against the typed schema.

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

- **Inline `:-` annotations** on `def` / `defn` / `defonce` / `let`.
  The interim `claim` form is gone.
- **`defmacro` + quasi-quote / unquote / unquote-splicing.** Old
  `define-macro` removed.
- **Clojure threading family:** `->`, `->>`, `as->`, `cond->`,
  `cond->>`, `some->`, `some->>`. The old pipe family is gone.
- **Reader conditionals** `#?(:clj … :cljs … :nix … :default …)` and
  `#?@(…)` splice.
- **Quoted containers** `'[…]`, `'{…}`, `'#{…}` self-evaluate.
- **Sourcemap fidelity:** author position survives every
  canonicalization (11/11 on the fidelity bench, up from 5/11).
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
moving. The compiler is the source of truth; query it directly:

```sh
bin/beagle-syntax FILE              # parse check + repair
bin/beagle-validate [FILE...]       # parse + check + schema validation
bin/beagle-check FILE               # typed checker
bin/beagle-expand FILE              # macro-expanded source
bin/beagle-sig NAME FILE...         # typed signature
bin/beagle-fields RECORD FILE...    # record fields
bin/beagle-callers NAME FILE...     # call sites
bin/beagle-rejection-stats DIR      # diagnostics by cause-class
```

`CLAUDE.md` lists the full set including the daemon-backed query tools
and the repair pipeline (`beagle-repair`, `beagle-blame`,
`beagle-specfix`).

## Design discipline

The discipline is intentionally tight:

- **Hard removal over deprecation.** No back-compat shims.
- **Divergence from Clojure must serve types or a backend, or it
  dies.** Inert syntactic novelty is rejected.
- **Each target renders idiomatically** — same surface, faithful per
  backend (Nix as lazy attrsets, Clojure as eager maps, CLJS as
  Clojure-shaped JS).
- **Gates have stated jurisdiction.** When ambiguous, ask; don't
  silently defer.

See `CLAUDE.md` for the full rule set.

## License

MIT. See [`LICENSE`](LICENSE).
