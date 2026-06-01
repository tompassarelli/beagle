# beagle

A typed authoring IR. Clojure surface with type annotations threaded
through; multi-target compiler emitting to Nix, Clojure, and
ClojureScript today. Designed as a substrate for AI-augmented authoring:
a sub-second `parse → check → emit` loop with structured diagnostics
(`surface-divergence` / `type-error` / `logic-error`) that downstream
repair tools rank and act on.

## What it isn't

- Not a schema language, not a validation runtime — types check at
  compile time, then erase.
- Not a new Lisp — a strict typed subset of Clojure. Where the surface
  diverges from Clojure, that divergence is either load-bearing for the
  type system or for a backend, or it dies.
- Not stable. Pre-1.0, surface still moves. No deprecation aisle —
  removals are hard.

## Quick taste

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

Every snippet above passes `bin/beagle-syntax`.

## v0.16 surface highlights

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
- **Per-target prefixes** (`nix/`, `js/`, `sql/`) for forms whose
  meaning genuinely diverges per backend.

## How it's organized

- `beagle-lib/private/parse.rkt` — surface form set. The source of
  truth; static docs go stale.
- `beagle-lib/private/check.rkt` — type checker.
- `beagle-lib/private/emit-{nix,clj,cljs}.rkt` — live emitters.
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

There is no static reference catalog — the surface churns and static
docs go stale within a day. Query the compiler instead:

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
