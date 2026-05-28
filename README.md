# Beagle

**A typed, LLM-optimized authoring surface for Nix. Schema-driven
validation, sub-second re-checks, round-trips real-world Nix without
semantic loss.**

Five other backends (Clojure, ClojureScript, JavaScript, Python, SQL,
Typed Racket) sit in [`beagle-lib/private/dormant/`](beagle-lib/private/dormant/) —
parked, not deleted, reactivate with `BEAGLE_ALL_TARGETS=1`. The live
loop is Nix only.

## Motivation

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
   tree-of-symbols data structure that the parser produces.

2. **Immutability by default; explicit side-effects.** Bindings are
   immutable. Records are functional. There is no implicit aliasing,
   no `set!`, no in-place mutation without an explicit marker. State
   changes go through visible plumbing.

3. **One canonical idiom per concept.** Every concept with N equivalent
   idioms is a 1/N hallucination opportunity. Where two forms claim to
   express the same concept, one gets removed.

4. **Verbose-with-clarity over concise-with-magic.** Explicit positional
   args beat auto-currying. Named bindings beat implicit context.
   Spelled-out forms beat terse aliases.

5. **Failure modes that localize.** When the model writes the wrong
   thing, the error should pinpoint which form and what shape was
   expected.

6. **Zero escape hatches.** No `unsafe-*` anything, no inline target
   passthrough, no verbatim-string-to-target forms under any name.
   Every gap closes by adding a stdlib entry, adding a typed surface
   form, or writing a sibling target-language file and importing it.
   The filesystem boundary is auditable; an inline backdoor is not.

7. **Consistency compounds; ergonomic savings don't.** A form earns its
   place by reinforcing a pattern that shows up elsewhere. Forms that
   exist for local character savings, with no broader pattern, are
   net-negative.

## The lock-in discipline

**A form change requires a measurable delta on a documented benchmark.
Full stop.**

No more "I think this reads better" changes. No more "the model probably
prefers this" changes. If a proposed change can't be measured, it can't
be made. The benchmark methodology has an existence proof (E16, E3b);
generalizing the harness so every future surface change passes through
it is the discipline that converts the surface from open to closed in
practice rather than just in principle.

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

The same typed AST drives every emitter. Nix is live because working
on a non-trivial NixOS configuration produced the design pressure that
shaped `NixType` as an opaque primitive and motivated the schema-driven
validator.

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

There is no static reference. The compiler is the source of truth — the
surface churns and static docs go stale within a day. To know anything
mechanical:

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

## Research

| Question | Answer |
|---|---|
| E16: Do types make agents faster? | **24% faster** average, **45% on coordination-heavy features** (n=4). Same checker poorly-wired imposes 76% penalty — *integration matters as much as the type system*. |
| E18: Do proc macros compress code? | **2-3×** at realistic scale (crossover at 2-4 instances). Beagle template macros can't express the test patterns. |
| E19: Can agents write proc macros? | Yes, with docs (271s, 2 iterations). Without docs they invent runtime dispatch — proc macros need discoverability. |
| E3b: Beagle vs hand-written Clojure | **36% wall-clock improvement** on agent-driven authoring task. |
| E1-E15: vs Clojure / Python+mypy | Matches mypy correctness, beats Clojure correctness. mypy edges wall time — Beagle trades single-language speed for one typed surface across N backends. |

[Full lab](https://github.com/tompassarelli/beagle-lab) — E0–E22, methodology, raw results.

## Status

`#lang beagle` v0.15.0 — Nix-tier active loop is green; dormant-tier
opt-in via `BEAGLE_ALL_TARGETS=1`. **No v1.0 until others have used it
in anger.** The author dogfoods on a 220-file NixOS config
([firnos](https://github.com/tompassarelli/firnos)) — schema-typed
end-to-end, system builds from `flake.bnix` directly. Production-grade
for one user, ready-for-adventure for others.

## License

MIT.
