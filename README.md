# Beagle

**A typed authoring language that catches your config bugs before they reach Nix, Clojure, JavaScript, or Python.**

```racket
#lang beagle/nix
(ns hosts.whiterabbit)

(module [config lib pkgs]
  (def msg : String config.services.openssh.enable))
;; ✗ hosts/whiterabbit.bnix:4:0: def msg: expected String, got Bool
;;   (resolved from .beagle-cache/schema.json — services.openssh.enable : bool)
```

The schema knows `services.openssh.enable` is `Bool`. Beagle knows that too. You assign it to a `String` field; you get a compile error with file:line:col precision — **before `nixos-rebuild` ever runs**.

## What it is

Beagle is a typed s-expression language that emits ordinary Nix / Clojure / JavaScript / Python / Racket / SQL / ClojureScript. You write one typed source; you get plain target code anyone can deploy or audit.

```
.bnix / .bclj / .bjs / .bpy → parse → check → emit → .nix / .clj / .js / .py
                                       ↑
                            macros, schema, stdlib, type narrowing
                            all share one AST + diagnostic path
```

**Design principles** (the ones that actually shape the surface):

- **One canonical idiom per concept.** No `with-do` vs `with`. No `inh` and `inherit`. Single name, single shape.
- **Zero escape hatches.** No `unsafe-nix`, no `unsafe-js`, no `any`. If the stdlib doesn't cover something, add a one-line type signature.
- **Schema is types.** NixOS option schemas (16k+ options) flow into the type checker. Misspelled option paths fail at parse time. Wrong-typed values fail at type-check time. You never wait for `nixos-rebuild` to find out.
- **LLM authoring is first-class.** Rich types, explicit forms, structured errors, "did you mean?" suggestions, low syntactic surface area.

## Demo: the NixOS story

Write your config in `.bnix`:

```racket
#lang beagle/nix
(ns modules.demo)

(module [config lib pkgs]
  (with-cfg config.myConfig.modules.demo
    {:options.myConfig.modules.demo
     {:enable (lib/mkEnableOption "demo service")
      :port (lib/mkOption {:type lib/types.port :default 8080})}

     :config (lib/mkIf cfg.enable
       {:environment.systemPackages [pkgs.hello]
        :networking.firewall.allowedTCPPorts [cfg.port]})}))
```

Compiles to:

```nix
{ config, lib, pkgs, ... }:
let cfg = config.myConfig.modules.demo; in {
  options.myConfig.modules.demo = {
    enable = lib.mkEnableOption "demo service";
    port = lib.mkOption { type = lib.types.port; default = 8080; };
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.hello ];
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
```

What you get for free:

| Mistake | When you find out |
|---|---|
| `services.opensh.enable` (typo) | parse time, with "did you mean services.openssh.enable?" |
| `(lib/mkOption {:type true})` (Bool where NixType expected) | type check |
| `(derivation {:src ./.})` (missing `:pname`/`:name`) | type check, with explanation |
| `(unsafe-nix "...")` (escape hatch) | parse rejection — no escape hatches exist |
| `(if config.X.enable foo bar)` where foo and bar are different types | type check (flow narrowing) |
| Forgetting to git-add new modules | rebuild prereq check |

## Compared to

| | beagle | Nickel | Dhall | raw Nix + nil |
|---|---|---|---|---|
| Static type checking | ✓ | ✓ | ✓ | partial (nil LSP) |
| **Schema-derived types** | **✓** | manual | manual | – |
| Multi-target backends | **✓** (7) | – | – | – |
| Procedural macros with typed AST contracts | **✓** | – | – | – |
| Zero escape hatches | **✓** | `Dyn` exists | – | `builtins.unsafeDiscardOutputDependency` etc. |
| LSP / hover / completion | ✓ | ✓ | partial | ✓ (nil) |
| Native NixOS module integration | ✓ | partial | – | ✓ |
| Compiles to (rather than replacing) Nix | ✓ | – | – | – |

The "compiles to" part is the unique structural choice. Beagle outputs real `.nix` files that any NixOS or nix-darwin user can read, audit, and build with stock tools. You're not asking your team to deploy a new runtime — you're asking them to read better-typed Nix.

## Targets

| Target | `#lang` | Stdlib | Runtime |
|---|---|---|---|
| Clojure | `beagle/clj` | 414 entries | JVM, Babashka |
| JavaScript | `beagle/js` | 55 native + 28 typed `js/*` forms | Node, Bun |
| Python | `beagle/py` | 151 entries | Python 3 |
| Nix | `beagle/nix` | 527 entries (parametric types) | nix-eval |
| ClojureScript | `beagle/cljs` | 86 stdlib entries | browser, Node |
| SQL | `beagle/sql` | 54 stdlib entries | DDL/DML emission |
| Typed Racket | `beagle/rkt` | (oracle) | `raco make` validates type promises |

319 portable stdlib entries shared across all targets, plus the target-specific catalogs above.

## Self-hosting

Beagle compiles itself. The 12 `.bjs` components (reader, parser, type checker, 5 emitters, AST, macros, lint, types) are written in Beagle targeting JavaScript. Bootstrap fixed-point proven: Racket compiler → JS bundle → JS bundle compiles same sources → byte-identical output.

Emission parity verified against [Heist](https://github.com/tompassarelli/heist) (a full-stack dogfood app): 11/11 modules produce byte-identical output from both compilers.

## Install

Requires [Racket](https://racket-lang.org/) 8.x+.

```sh
git clone https://github.com/tompassarelli/beagle
cd beagle
raco pkg install --link beagle-lib/ beagle-test/ beagle-doc/ beagle/
raco test beagle-test/tests/    # 1343 tests
```

For NixOS users dogfooding their config:

```sh
cd ~/your-nixos-config
beagle-extract-schema           # writes .beagle-cache/schema.json
beagle-validate                 # type-check every .bnix
```

## First program (60 seconds)

```racket
#lang beagle/nix
(ns hello)

(def greeting : String "hello, world")
```

```sh
beagle-build hello.bnix          # → hello.nix
nix-instantiate --eval hello.nix # → "hello, world"
```

## Tooling

- **LSP server** — hover (target-aware completion against stdlib + schema), diagnostics, symbols, jump-to-definition. `nvim-lspconfig` and Doom Emacs entries forthcoming.
- **Typed REPL** — persistent environment, parse → check → emit per input
- **Reactive daemon** — AST cache, inotify file watching, ~100ms re-check
- **Property testing** — record generators, return-type inference, differential testing
- **`beagle-validate`** — schema-driven option-path validator with Levenshtein "did you mean", cross-file conflict detection, auto-fix for unambiguous typos
- **`beagle-nix-oracle`** — emit → `nix-instantiate --parse` → classify (independent codegen oracle)
- **`bin/beagle-ci`** — tests + property tests + nixos-config validate gate

## Agent integration

```sh
beagle init --claude-code
beagle-daemon start --watch .
```

Generates a PostToolUse hook, settings, `CLAUDE.md`, and language context. The daemon re-checks within ~100ms of each save. Designed around the finding (E16) that *how* the type checker reaches an agent matters as much as the checker itself.

## Research

| Question | Answer |
|---|---|
| E16: Do types make agents faster? | **24% faster** average, **45% on coordination-heavy features** (n=4). Same checker poorly-wired imposes 76% penalty — *integration matters as much as the type system*. |
| E18: Do proc macros compress code? | **2-3×** at realistic scale (crossover at 2-4 instances). Beagle template macros can't express the test patterns. |
| E19: Can agents write proc macros? | Yes, with docs (271s, 2 iterations). Without docs they invent runtime dispatch — proc macros need discoverability. |
| E1-E15: vs Clojure / Python+mypy | Matches mypy correctness, beats Clojure correctness. mypy edges wall time — Beagle trades single-language speed for one typed surface across N backends. |

[Full lab](https://github.com/tompassarelli/beagle-lab) — E0–E22, methodology, raw results.

## Status

`#lang beagle` v0.13.x — 1343 tests passing. **No v1.0 until others have used it in anger.** The author dogfoods on a 220-file NixOS config; production-grade for one user, ready-for-adventure for others.

If you're a NixOS user who wants to try it: the [nixos-starter template](#) (forthcoming) gets you running in 60 seconds.

## Documentation

- [`docs/cheatsheet.md`](docs/cheatsheet.md) — language summary (single page, designed as LLM context)
- [`beagle-doc/scribblings/nix-target.scrbl`](beagle-doc/scribblings/nix-target.scrbl) — Scribble reference for the Nix target
- [`beagle-doc/scribblings/`](beagle-doc/scribblings/) — Scribble docs (`raco docs beagle` after install)
- [`beagle-lab`](https://github.com/tompassarelli/beagle-lab) — research journal, experiment results

## License

MIT.
