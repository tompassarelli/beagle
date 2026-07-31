# Beagle

**Typed Clojure that compiles to idiomatic <!-- beagle:langs names -->Clojure, JavaScript, Nix, Odin, Zig, and TypeScript<!-- /beagle:langs -->.**

Beagle is a typed Lisp that compiles to six languages — including Zig and Odin,
which link to native executables. You write one high-level source; each backend
renders it as code that language's own programmers would recognize, not a
lowest-common-denominator transliteration.

Types exist here for a specific job: making authoring, diagnostics, and
automated repair reliable. They check at compile time and erase before emit. The
point isn't to reject bad code — it's to tell a repair tool *what* kind of
mistake happened, *where* in the source, after *which* canonicalization, against
*which* target.

## Documentation

- [`docs/CHEATSHEET.md`](docs/CHEATSHEET.md) — the language surface, generated
  from the compiler; every example is parse- and type-checked by the suite.
- [`docs/surface.md`](docs/surface.md) — what the cheatsheet does not
  enumerate: macros, threading, reader conditionals, sourcemap fidelity.
- [`docs/targets-by-example.md`](docs/targets-by-example.md) — one source body
  across three backends, and a NixOS module typed against the option schema.
- [`docs/cli.md`](docs/cli.md) — the CLI and the repair loop.
- [`docs/architecture.md`](docs/architecture.md) — pipeline, layout, where to change what.
- [`docs/self-hosting.md`](docs/self-hosting.md) — how the compiler is held correct.
- [`docs/target-policy.md`](docs/target-policy.md) — why targets get removed, not deprecated.
- [`docs/INFLUENCES.md`](docs/INFLUENCES.md) — lineage and thesis.

Static reference stays thin on purpose — the compiler answers instead: `beagle
help`, `beagle langs`, `beagle sig`, `beagle fields`.

## Quickstart

The flake pins the whole toolchain, including the Zig the native backend links
with. Inside the devshell (`direnv allow`), the binary is `bin/beagle` — written
`beagle` below:

```console
$ cat src/main.bzig
#lang beagle/zig
(ns main)

(defn main [] :- Nil
  (println "hello from beagle"))

$ beagle build --target zig --exe ./hello src/main.bzig
src/main.bzig -> ./hello

$ ./hello
hello from beagle
```

`beagle init --target TARGET DIR` scaffolds a project for any of the six;
`beagle build FILE OUT` writes the target's source instead of linking a binary.

## Think high-level, get native

Three lines of Beagle:

```clojure
(ns g)
(defn calc [a :- Int b :- Int c :- Int] :- Int
  (+ (* a b) (- c a) (quot b 2) (rem c 3) (mod a 5)))
```

become Zig that reaches for the language's own operators rather than a runtime
shim (module preamble elided):

```zig
pub fn calc(a: i64, b: i64, c: i64) i64 {
    return ((a * b) + (c - a) + @divTrunc(b, 2) + @rem(c, 3) + @mod(a, 5));
}
```

Both halves are committed goldens in
[`beagle-test/tests/fixtures/zig-golden`](beagle-test/tests/fixtures/zig-golden)
and the suite fails when the emitter drifts from them.

The leverage runs upward too: types can come from the target itself. A NixOS
option carries one in the schema, so `services.openssh.enable` is known to be
`Bool` at compile time — assigning a `String` fails with `file:line:col`
precision *before* `nixos-rebuild` is ever invoked.

## Targets

One AST, idiomatic output per backend — <!-- beagle:langs idioms -->Clojure eager persistent maps, JavaScript plain objects and ES modules, Nix lazy attrsets, Odin structs and explicit context, Zig explicit allocators and error unions, TypeScript typed function boundaries over JS<!-- /beagle:langs -->.

The table is generated from `beagle-lib/private/targets.rkt` by `beagle
doc-fill`; query it live with `beagle langs` (`--view domains` for what each
target is *for*).

<!-- beagle:langs table -->
| target | language | source | `#lang` | output | status |
|---|---|---|---|---|---|
| `clj` | Clojure | `.bclj` | `#lang beagle` | `.clj` | live — self-hosted, oracle-certified, fuzz-guarded |
| `js` | JavaScript | `.bjs` | `#lang beagle/js` | `.js` | live — self-hosted, oracle-certified, fuzz-guarded |
| `nix` | Nix | `.bnix` | `#lang beagle/nix` | `.nix` | live — self-hosted, oracle-certified, fuzz-guarded |
| `odin` | Odin | `.bodin` | `#lang beagle/odin` | `.odin` | live — Racket emitter; self-host port pending conformance goldens |
| `zig` | Zig | `.bzig` | `#lang beagle/zig` | `.zig` | live — Racket emitter with restored structural goldens |
| `scriptc` | TypeScript | `.bsc` | `#lang beagle/scriptc` | `.ts` | live — Racket emitter over the JS lowering; experimental boundary |

Six language targets. `facts` is not one of them — it is the lossless CNF fact-triple projection of the AST (`bin/beagle facts-roundtrip`), a query surface rather than a language you author against.
<!-- /beagle:langs -->

That `status` column is the maturity ordering: the three source-to-source
backends are oracle-certified and fuzz-guarded, the two native backends are held
by structural goldens. Targets are removed rather than deprecated when they stop
earning their place — [`docs/target-policy.md`](docs/target-policy.md).

## Real codebases author against Beagle

- **[firn](https://github.com/tompassarelli/firn)** — a complete NixOS system,
  authored in `.bnix` and schema-typed end to end; builds from `flake.bnix`.
- **[gjoa](https://github.com/tompassarelli/gjoa)** — a Firefox fork tuned for
  power users, authored in `.bjs`.
- **[wake](https://github.com/tompassarelli/wake)** — an application compiler
  (entities, views, routes → direct-DOM JS), itself authored in `.bjs`.
- **[fram](https://github.com/Autonymy/fram)** — a slot-addressable,
  typed-triple substrate with stratified Datalog, authored in `.bclj`.
- **[north](https://github.com/tompassarelli/north)** — a work tracker and
  agent orchestrator over one triple graph, authored in `.bclj`.

## How it is held correct

The `clj`-target compiler is written in Beagle and compiles itself to a
byte-level fixpoint, with the original Racket compiler as a conformance oracle
and a nightly differential fuzz campaign holding the two to byte-exact agreement
on an empty exemption list — [`docs/self-hosting.md`](docs/self-hosting.md).

## What it isn't

- **Not a schema language, not a validation runtime** — types check at compile
  time, then erase.
- **Not a new Lisp in spirit** — a strict typed subset of Clojure; divergence
  from Clojure must serve the type system or a backend, or it dies.
- **Not stable.** Pre-1.0, the surface still moves, and removals are hard breaks:
  there is no deprecation path.
- **Not benchmarked.** The repository gates correctness, not speed, and publishes
  no performance numbers.

## Contributing

Read [`CLAUDE.md`](CLAUDE.md) first — its three-statement generative spec is the
canonical anchor for any surface question.

## License

MIT or Apache-2.0, at your option — see [`LICENSE`](LICENSE).
