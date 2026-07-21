<div align="center">

# Beagle

**Typed Clojure that compiles to idiomatic Clojure, JavaScript, Nix, and Odin.**
One AST, many back-ends — never a lowest-common-denominator transpile.

[![license](https://img.shields.io/badge/license-MIT_OR_Apache--2.0-blue.svg)](LICENSE)
[![nix](https://img.shields.io/badge/nix-flake-5277C3.svg)](flake.nix)
[![status](https://img.shields.io/badge/status-pre--1.0-orange.svg)](#what-it-isnt)

</div>

Beagle's types exist for a specific job: making authoring, diagnostics, and AI
repair reliable. They check at compile time and erase before emit. The point
isn't to reject bad code — it's to tell repair tools *what* kind of mistake
happened, *where* in the source, after *which* canonicalization, against
*which* target.

## The compiler compiles itself

The `clj`-target compiler is written in Beagle (`self-host/`). The checked-in
seed is that compiler's own emitted output, and CI holds the pair to a
byte-level bootstrap fixpoint (`bin/beagle-remint`) plus byte-agreement with
the original Racket compiler, which now serves as the conformance oracle
(`bin/beagle-certify`).

On top of the fixed corpus, a nightly differential-fuzz campaign (`fuzz/`,
`.github/workflows/fuzz-nightly.yml`) generates fresh programs and holds the
two compilers to byte-exact agreement — acceptance, diagnostics, and emitted
output — with an **empty** exemption list. Any divergence, of any class, is a
red build with a shrunk repro attached.

**Stage0 is a native binary.** The canonical self-hosted compiler ships as a
self-contained GraalVM native-image (`self-host/native/beagle-selfhost`), built
reproducibly with `nix build .#beagle-selfhost`. Running the seed under babashka
(`bb -cp self-host/seed …`) is a dev convenience and the substrate for the
remint fixpoint loop — the two are held byte-identical, so the native binary is
the distribution artifact and bb is the fallback. Details:
[`self-host/README.md`](self-host/README.md).

## Real codebases author against Beagle

- **[firn](https://github.com/tompassarelli/firn)** — a complete NixOS
  system, authored in `.bnix` and schema-typed end to end; it builds from
  `flake.bnix` directly (Nix target).
- **[gjoa](https://github.com/tompassarelli/gjoa)** — a highly optimized Firefox
  fork tuned for power users, authored in `.bjs` (JS target).
- **[wake](https://github.com/tompassarelli/wake)** — an application compiler
  (declare entities, views, routes → plain direct-DOM JS), itself authored in
  `.bjs` (JS target).
- **[fram](https://github.com/tompassarelli/fram)** — an append-only fact engine
  (facts + stratified Datalog), authored in `.bclj` (Clojure target).
- **[north](https://github.com/tompassarelli/north)** — fact-native work
  coordination (CLI + MCP, on babashka), authored in `.bclj` (Clojure target).

## One source, many back-ends

The same source body, saved as `.bclj`, `.bjs`, and `.bnix`:

```clojure
(defn even-doubles [xs :- (List Int)] :- (List Int)
  (->> xs
       (filter even?)
       (map (fn [n :- Int] :- Int (* n 2)))))
```

Each target renders it idiomatically — not transliterated:

```clojure
;; → Clojure: threading macro and seq fns preserved
(defn even-doubles [xs]
  (->> xs (filter even?) (map (fn [n] (* n 2)))))
```

```javascript
// → JavaScript: array methods + arrow functions
function even_doubles(xs) {
  return xs.filter(((_x) => _x % 2 === 0)).map((n) => (n * 2));
}
```

```nix
# → Nix: lazy let-bindings and curried lambdas
let
  even-doubles = xs: builtins.map (n: (n * 2)) (builtins.filter even_p xs);
in
null
```

Same logic, three back-ends. Notice `even?` becomes `even_p` where the target's
identifiers can't carry a `?` — names follow each language's rules, the shape
follows each language's idiom. (Types erase: they did their job at check time.)

## Typed against the target's real schema

Types aren't just shapes you declare — they can come from the target itself. A
NixOS module, authored against the typed option schema:

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

`services.openssh.enable` is typed `Bool`, resolved from the schema cache.
Assigning a `String` fails at check time with `file:line:col` precision —
*before* `nixos-rebuild` is ever invoked. Unknown option paths fail at parse
time; wrong-typed values fail at type-check time.

## Targets

One AST, idiomatic output per backend — Nix as lazy attrsets, Clojure as eager
maps, JavaScript as native arrays and arrows, Odin as structs and procs.

| Target     | Status                                                        |
|------------|---------------------------------------------------------------|
| Clojure    | Live — self-hosted, oracle-certified, fuzz-guarded            |
| JavaScript | Live — self-hosted, oracle-certified, fuzz-guarded            |
| Nix        | Live — self-hosted, oracle-certified, fuzz-guarded            |
| Odin       | Live — Racket emitter (self-host port pending conformance goldens) |

Targets are removed, not deprecated, when they stop earning their place —
reviving one means re-wiring the emitter and proving it against a real
consumer, not flipping a switch. (SQL removed 2026-06-28 — unused, rotting;
tag `sql-archive-2026-06-28`. ClojureScript removed 2026-07-04 — zero users,
redundant against the native JS target; tag `cljs-final`.)

## How it compiles

```
.bclj / .bjs / .bnix / .bodin  ──▶  parse ──▶ check ──▶ emit  ──▶  .clj / .js / .nix / .odin
                                                          ▲
                                            macros, schema, stdlib, type narrowing
                                            all share one AST + diagnostic path
```

`check` is where the NixOS option schema (loaded from a cache at compile time)
becomes typed context: unknown option paths fail at parse time, wrong-typed
values fail at type-check time, ahead of any build. Sourcemap fidelity is
preserved through every canonicalization, so diagnostics point at the author's
position — not a desugared intermediate.

## Surface highlights

A taste of the surface — every snippet here passes `bin/beagle syntax`:

```clojure
;; types ride on bindings; interiors inferred
(defn double [n :- Int] :- Int (* n 2))

;; macros + quasi-quote (Scheme-style unquote: `,x`, splice `,@xs`)
(defmacro inc1 [x] `(+ ,x 1))

;; Clojure threading family, reader conditionals, canonical keyword access
(-> 1 (+ 2) (* 3))
(def msg #?(:clj "hello" :nix "bonjour" :default "hi"))
(:name {:name "ada"})
```

- **Inline `:-` annotations** on the typed boundaries `def` / `defn` /
  `defonce` / `defrecord`; interiors and `let`-locals are inferred.
- **`defmacro` + quasi-quote / unquote / unquote-splicing.**
- **Clojure threading family:** `->`, `->>`, `as->`, `cond->`, `cond->>`,
  `some->`, `some->>`.
- **Reader conditionals** `#?(:clj … :nix … :default …)` and `#?@(…)`.
- **Quoted containers** `'[…]`, `'{…}`, `'#{…}` self-evaluate.
- **Sourcemap fidelity:** the author's position survives every
  canonicalization, guarded by a dedicated bench.
- **Typo suggestions** for mistyped NixOS options: segment-aware Levenshtein
  against the option schema.
- **Per-target prefixes** (`nix/`, `js/`, …) for forms whose meaning genuinely
  diverges per backend.

## What it isn't

- **Not a schema language, not a validation runtime** — types check at compile
  time, then erase.
- **Not a new Lisp in spirit** — a strict typed subset of Clojure. Where the
  surface diverges from Clojure, that divergence must serve the type system or a
  backend, or it dies.
- **Not stable.** Pre-1.0, the surface still moves, and removals are hard
  breaks — there is no deprecation path.

## Getting started

**Just compile something** — the stage0 native binary needs no Racket, no JVM:

```sh
git clone https://github.com/tompassarelli/beagle
cd beagle
nix build .#beagle-selfhost
./result/bin/beagle-selfhost emit --target js hello.bjs   # ~7ms startup
```

**Hack on the compiler** — the flake pins everything, including the exact
Racket the oracle compiles under (never use a system Racket here; see
`bin/_beagle-racket`):

```sh
direnv allow                        # flake devshell
raco pkg install --link beagle-lib/ beagle-test/ beagle/
bin/beagle test --active-only       # active tier
```

For a real-world `.bnix` corpus, clone
[firn](https://github.com/tompassarelli/firn) — schema-typed end to end; the
NixOS system builds from `flake.bnix` directly.

<details>
<summary><b>The CLI &amp; repair loop</b></summary>

Static reference docs are intentionally thin while the surface moves — the
compiler is the source of truth, fronted by one CLI:

```sh
bin/beagle doctor               # is the repair loop online and working?
bin/beagle syntax FILE          # parse check (+ --repair --emit-patch)
bin/beagle check FILE           # typed checker
bin/beagle validate [FILE...]   # parse + check + schema validation
bin/beagle build [PATH...]      # compile to target (--out DIR)
bin/beagle sig NAME FILE...     # typed signature
bin/beagle fields RECORD FILE   # record fields, types, accessors
bin/beagle callers NAME FILE... # call sites
bin/beagle expand FILE          # macro-expanded source
bin/beagle explain-type FILE    # inferred types as a view
```

`bin/beagle help` lists every command. The repair loop — a watch daemon, an
on-edit syntax/type hook, and machine-applicable fixes — is where the type
signal becomes applied edits; `bin/beagle doctor` health-checks it end to end.
Deeper dev tools stay as `bin/beagle-*` (blame, specfix, trace, cascade).

</details>

<details>
<summary><b>Project layout</b></summary>

- `beagle-lib/private/parse.rkt` — surface form set; the source of truth.
- `beagle-lib/private/check.rkt` — type checker.
- `beagle-lib/private/emit-{clj,js,nix,odin}.rkt` — live emitters;
  `beagle-lib/private/dormant/` holds the parked ones.
- `beagle-lib/private/nixos-schema.rkt` — the typed NixOS-option environment.
- `beagle-lib/private/diagnostic-kind.rkt` — the `cause-class?` taxonomy.
- `beagle-test/` — tiered test suite; `beagle-test/tiers.rktd` is the
  authoritative tier classification.
- `CLAUDE.md` — the operating discipline; its three-statement generative spec
  (Clojure + types / load-bearing divergence / idiomatic per target) is the
  canonical anchor for any surface question.
- `docs/` — distilled, rot-resistant artifacts: `INFLUENCES.md` (lineage +
  thesis) and the generated `CHEATSHEET.md`.

</details>

## Design discipline

The discipline is intentionally tight:

- **Hard removal over deprecation.** No back-compat shims.
- **Divergence from Clojure must serve types or a backend, or it dies.** Inert
  syntactic novelty is rejected.
- **Each target renders idiomatically** — same surface, faithful per backend.
- **Gates have stated jurisdiction.** When ambiguous, ask; don't silently defer.

See [`CLAUDE.md`](CLAUDE.md) for the full rule set.

## License

Licensed under either the [MIT License](LICENSE-MIT) or the
[Apache License, Version 2.0](LICENSE-APACHE), at your option. See
[`LICENSE`](LICENSE) for the chooser.
