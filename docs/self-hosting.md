# How the compiler is held correct

The full mechanics live in [`self-host/README.md`](../self-host/README.md); this
page is the summary the README points at.

This page separates shipped evidence from the destination. The evidence below
is about the current compiler routes and their checks. The destination is a
native executor whose steady-state use no longer needs host scripts; that does
not remove the planning, scheduling, reconciliation, or receipt-bearing effect
semantics that connect programs to external reality.

## The compiler compiles itself

The `clj`-target compiler is written in Beagle (`self-host/`). The checked-in
seed is that compiler's own emitted output, and CI holds the pair to a
byte-level bootstrap fixpoint plus agreement with the current Racket compiler
through `bin/beagle-remint --oracle` and `self-host/verify-selfhost.sh`.

## Differential fuzz, empty exemption list

On top of the fixed corpus, a nightly differential-fuzz campaign (`fuzz/`,
`.github/workflows/fuzz-nightly.yml`) generates fresh programs and holds the two
compilers to byte-exact agreement — acceptance, diagnostics, and emitted output
— with an **empty** exemption list. Any divergence, of any class, is a red build
with a shrunk repro attached.

## Stage0 is a native binary

The canonical self-hosted compiler ships as a self-contained GraalVM
native-image (`self-host/native/beagle-selfhost`), built reproducibly with `nix
build .#beagle-selfhost`. Running the seed under babashka (`bb -cp
self-host/seed …`) is the substrate for the remint fixpoint loop — the two are
held byte-identical, so the native binary is the distribution artifact;
Babashka remains a remint/bootstrap boundary only.

The parity harness (`self-host/verify-selfhost.sh`) prefers a checkout-local
native binary only when its `.seed-nar-hash` sidecar matches the exact seed; a
missing or stale sidecar fails visibly. Override the path deliberately with
`BEAGLE_NATIVE_BIN`; an empty or unavailable native path fails.

## Normal hosted route

`bin/beagle` selects native stage0 before any Racket setup for the public
self-host surfaces: single-source `build`, plain single-source `check`, plain
single-source `ast`, and `facts-roundtrip`. All three hosted targets (`clj`,
`js`, and `nix`) use the same Graal artifact:

```sh
nix build .#beagle-selfhost
export BEAGLE_NATIVE_BIN="$PWD/result/bin/beagle-selfhost"
bin/beagle build example.bclj
```

The selected binary must be the exact realized `.#beagle-selfhost` artifact;
missing or mismatched store paths fail before compilation. A checkout-local
ad-hoc binary retains the existing matching `.seed-nar-hash` requirement.
Native diagnostics and nonzero exits are final and never trigger Racket or
Babashka. The packaged `beagle` launcher binds `BEAGLE_NATIVE_BIN` to the exact
`packages.beagle-selfhost` store artifact from the same flake evaluation.

The self-host does not yet implement syntax-only validation, batch output,
checked bundles, interface-digest output, project sessions, or Native Core
materialization. Those surfaces are deliberately outside this cutover. Direct
`bin/beagle-build`, `bin/beagle-build-all`, `bin/beagle-check`,
`bin/beagle-check-all`, and `bin/beagle-ast` invocations remain explicit pinned-
Racket oracle/recovery routes.

## What this does and does not claim

These gates are correctness gates: byte-exact bootstrap fixpoint, oracle
agreement, and differential fuzz with no exemptions. They say nothing about
compile speed or runtime speed, and the repository publishes no performance
measurements.

The intended compounding compiler-development feedback loop is stronger than a
cache-hit claim: as the repository and compiler scale, a one-function edit
should visit only its true dependents and agree with sampled clean results.
An unchanged hit alone does not establish edit proportionality; this remains a
validation target, not current performance evidence.
