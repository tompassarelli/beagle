# Beagle

**A typed, LLM-optimized authoring surface that compiles to multiple
targets. Built for provably-fast developer feedback loops and stronger
composition than the underlying target languages permit on their own.**

The identity: beagle emits to seven backends (Clojure, ClojureScript,
JavaScript, Python, Nix, SQL, Typed Racket) from one typed AST. The
same source can be typed, macro-expanded, and validated against
schemas before it ever reaches the target runtime — eval-time errors
become parse-time errors, schema mismatches become compile-time
diagnostics, repeated structure becomes a typed macro authored once.

The current emphasis: making the Nix authoring loop measurably better
than hand-writing Nix. Concrete targets are sub-second re-checks
on edits, schema-driven validation across the full NixOS option
universe, and a converter that round-trips real-world Nix code through
beagle without semantic loss. The other targets stay first-class
structurally; they aren't the current focus of test-pass investment
or community-adoption work.

The first paragraph is the identity. The second is the current phase.
The phase shifts as use cases mature; the identity doesn't.

```racket
#lang beagle/nix
(ns hosts.whiterabbit)

(module [config lib pkgs]
  (def msg : String config.services.openssh.enable))
;; ✗ hosts/whiterabbit.bnix:4:0: def msg: expected String, got Bool
;;   (resolved from .beagle-cache/schema.json — services.openssh.enable : bool)
```

The schema knows `services.openssh.enable` is `Bool`. Beagle knows that too. You assign it to a `String` field; you get a compile error with file:line:col precision — **before `nixos-rebuild` ever runs**.

## The bet

Today's typed languages have rich type systems but baroque human-optimized
surfaces. Today's dynamic languages have clean surfaces but no type-level
scaffolding. Both flavors evolved before AI code generation existed, and
both made trade-offs that are wrong for models generating code from a spec.

Python is the default model-authored language today by training-data weight;
the model writes it fluently. What the model can't do well in Python is
**lift repeated structure into typed primitives**. Every Django model,
every Pydantic schema, every API client gets hand-written each time because
Python has no macro layer and no rich type system to express the pattern
once. As a domain specializes and the codebase grows, the model's
compression ceiling becomes the bottleneck — not because the model is bad
but because the language doesn't give it the abstractions.

Typed languages with rich macro systems (Common Lisp, Racket, OCaml,
the ML family) hit a different problem: surface sprawl. Five threading
macros means five chances to pick wrong, and the model has no human's
accumulated taste to guide the choice.

Beagle threads the needle: a typed Lisp with **one canonical idiom per
concept**, a curated catalog of typed externs, and rich enough macros to
lift repeated structure — but no more surface than the model actually
needs. The compression ceiling moves up; the hallucination surface stays
low.

## Core Principles

Every surface decision was filtered through these. They are load-bearing.

1. **S-expressions, no compromise on composability.** Uniform
   parenthesized syntax for every construct. No special-case grammar
   per form. Macros, tools, agents all manipulate code as the same
   tree-of-symbols data structure that the parser produces. The cost
   is "looks weird at first to humans"; the payoff is decades of
   compounding tooling leverage and the only family of languages
   where the language and the meta-language are the same. Beagle
   doesn't negotiate this — it's the substrate on which everything
   else rests.

2. **Immutability by default; explicit side-effects.** Bindings are
   immutable. Records are functional (update returns a new record).
   There is no implicit aliasing, no `set!`, no in-place mutation
   without an explicit marker. State changes go through visible
   plumbing — IO actions, atom-style references, target-specific
   forms that say what they're doing. Concurrency reasoning,
   refactoring safety, agent-driven rewrites all stay sane because
   the reader can trust that `(let [x ...] ...)` means `x` doesn't
   become something else mid-scope.

3. **One canonical idiom per concept.** Every concept with N equivalent
   idioms is a 1/N hallucination opportunity. Where two forms claim to
   express the same concept, one gets removed.

4. **Verbose-with-clarity over concise-with-magic.** Explicit positional
   args beat auto-currying. Named bindings beat implicit context.
   Spelled-out forms beat terse aliases. Generation cost is amortized
   to the model; ambiguity cost compounds at every read site.

5. **Failure modes that localize.** When the model writes the wrong
   thing, the error should pinpoint which form and what shape was
   expected. Forms whose shape matches what the type system understands
   produce better errors.

6. **Zero escape hatches.** No `unsafe-js`, no `unsafe-clj`, no inline
   target passthrough, no `(define-macro unsafe ...)`, no `nix-ident`
   verbatim-string-to-Nix emission. Every gap closes by adding a stdlib
   type signature, adding a typed surface form (the way `flake-input`
   replaced `nix-ident` for flake-attribute access), or writing a
   sibling target-language file and importing it. The filesystem
   boundary is auditable; an inline backdoor is not. The claim holds
   as of 2026-05-25: the `nix-ident` form was the last
   escape-hatch-by-another-name and is now a parse-time error.

7. **Consistency compounds; ergonomic savings don't.** A form earns its
   place by reinforcing a pattern that shows up elsewhere. Forms that
   exist for local character savings, with no broader pattern, are
   net-negative even when they look convenient at authoring time.

## The lock-in discipline

The 2026-05 surface audit cycle closed with surface-redesign-as-dominant-mode
ending. From here forward:

**A form change requires a measurable delta on a documented benchmark.
Full stop.**

No more "I think this reads better" changes. No more "the model probably
prefers this" changes. If a proposed change can't be measured, it can't
be made. The benchmark methodology has an existence proof (E16, E3b);
generalizing the harness so every future surface change passes through
it is the discipline that converts the surface from open to closed in
practice rather than just in principle.

Two open questions remain, both gated on external triggers rather than
on more thinking: nil-semantics (eventual typed nullable-narrowing form,
will NOT reuse the `when-let`/`if-let` name) and macro-DSL audit (blocked
on Cyclone self-host introducing the concrete constraints).

## Targets

| Target | `#lang` | Stdlib | Runtime |
|---|---|---|---|
| Clojure | `beagle/clj` | 397 entries | JVM, Babashka |
| JavaScript | `beagle/js` | 102 native + 28 typed `js/*` forms | Node, Bun |
| Python | `beagle/py` | 348 entries | Python 3 |
| Nix | `beagle/nix` | 523 entries | nix-eval |
| ClojureScript | `beagle/cljs` | 132 entries | browser, Node |
| SQL | `beagle/sql` | 59 entries | DDL/DML emission |
| Typed Racket | `beagle/rkt` | (oracle) | `raco make` independently validates beagle's type promises |

269 portable stdlib entries shared across all targets, plus the
target-specific catalogs above.

The same typed AST drives every emitter. Nix has been the most
generative target for the language itself — working on a non-trivial
NixOS configuration produced design pressure that shaped `NixType` as
an opaque primitive and motivated the schema-driven validator.

## Self-hosting

Beagle compiles itself. The 12 `.bjs` components (reader, parser, type
checker, 5 emitters, AST, macros, lint, types) are written in beagle
targeting JavaScript. Bootstrap fixed-point proven: Racket compiler →
JS bundle → JS bundle compiles same sources → byte-identical output.

Emission parity verified against [Heist](https://github.com/tompassarelli/heist)
(full-stack dogfood app): 11/11 modules produce byte-identical output
from both compilers.

Next milestone: Cyclone Scheme self-host, removing the Racket runtime
dependency.

## Install

Requires [Racket](https://racket-lang.org/) 8.x+.

```sh
git clone https://github.com/tompassarelli/beagle
cd beagle
raco pkg install --link beagle-lib/ beagle-test/ beagle/
bin/beagle-test    # ~1190 active-tier tests
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

- **LSP server** — hover (target-aware completion against stdlib + schema), diagnostics, symbols, jump-to-definition. Neovim users: stanza at [`contrib/nvim-lspconfig/`](contrib/nvim-lspconfig/). Tree-sitter grammar: [`tree-sitter-beagle`](https://github.com/tompassarelli/tree-sitter-beagle) (separate repo).
- **Typed REPL** — persistent environment, parse → check → emit per input.
- **Reactive daemon** — AST cache, mtime invalidation, ~100ms re-check, ~0.6s warm builds vs ~3s cold.
- **Property testing** — record generators, return-type inference, differential testing.
- **`beagle-validate`** — schema-driven option-path validator with Levenshtein "did you mean", cross-file conflict detection, auto-fix for unambiguous typos.
- **`beagle-nix-oracle`** — emit → `nix-instantiate --parse` → classify (independent codegen oracle).
- **`bin/beagle-ci`** — tests + property tests + nixos-config validate gate.

For any question about a form, type, or stdlib entry: ask the daemon
(`bin/beagle-sig NAME`, `bin/beagle-fields RECORD NAME`, `bin/beagle-provides FILE`)
or read the source. The reference is the compiler.

## Agent integration

```sh
beagle init --claude-code
beagle-daemon start --watch .
```

Generates a PostToolUse hook, settings, `CLAUDE.md`, and language
context. The daemon re-checks within ~100ms of each save.

## Research

| Question | Answer |
|---|---|
| E16: Do types make agents faster? | **24% faster** average, **45% on coordination-heavy features** (n=4). Same checker poorly-wired imposes 76% penalty — *integration matters as much as the type system*. |
| E18: Do proc macros compress code? | **2-3×** at realistic scale (crossover at 2-4 instances). Beagle template macros can't express the test patterns. |
| E19: Can agents write proc macros? | Yes, with docs (271s, 2 iterations). Without docs they invent runtime dispatch — proc macros need discoverability. |
| E3b: Beagle vs hand-written Clojure | **36% wall-clock improvement** on agent-driven authoring task. |
| E1-E15: vs Clojure / Python+mypy | Matches mypy correctness, beats Clojure correctness. mypy edges wall time — Beagle trades single-language speed for one typed surface across N backends. |

[Full lab](https://github.com/tompassarelli/beagle-lab) — E0–E22, methodology, raw results.

## Where the documentation lives

Beagle does not ship a hand-written form-reference manual. The form
catalog rots faster than humans can maintain it against a moving
surface, and the compiler already knows every form's shape, every
stdlib signature, every type rule. Reference questions get answered
from the source:

- **What forms exist?** Grep `parse.rkt` or run `bin/beagle-provides`
  on the beagle source itself.
- **What's the signature of X?** `bin/beagle-sig X` or read the stdlib
  catalog at `beagle-lib/private/stdlib-*.rkt`.
- **What fields does record R have?** `bin/beagle-fields R FILE`.
- **What does this error mean?** The error message tells you; the
  parser source is `beagle-lib/private/parse.rkt`.

Hand-written documentation is reserved for things the compiler can't
generate from itself:

- [`README.md`](README.md) — this file: what beagle is, the principles, the lock-in discipline.
- [`CLAUDE.md`](CLAUDE.md) — session anchor for LLM context: how to navigate, what tools exist.
- [`beagle-lab`](https://github.com/tompassarelli/beagle-lab) — experiment writeups (E0–E22+) with raw results and methodology.

## Status

`#lang beagle` v0.15.0 — 1190 active-tier tests passing. **No v1.0
until others have used it in anger.** The author dogfoods on a 220-file
NixOS config ([firnos](https://github.com/tompassarelli/firnos)) —
schema-typed end-to-end, system builds from `flake.bnix` directly.
Production-grade for one user, ready-for-adventure for others.

If you're a NixOS user who wants to try it: clone [firnos](https://github.com/tompassarelli/firnos)
for a real working example, or scaffold from scratch — `beagle init`,
then `beagle module add <name>` for a minimal first module.

## License

MIT.
