# How the compiler is held correct

The full mechanics live in [`self-host/README.md`](../self-host/README.md); this
page is the summary the README points at.

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
self-host/seed …`) is a dev convenience and the substrate for the remint fixpoint
loop — the two are held byte-identical, so the native binary is the distribution
artifact and bb is the fallback.

The parity harness (`self-host/verify-selfhost.sh`) prefers a checkout-local
native binary only when its `.seed-nar-hash` sidecar matches the exact seed; a
missing or stale sidecar falls back to the current bb seed. Override the path
deliberately with `BEAGLE_NATIVE_BIN`, or set it empty to force the bb fallback.

## Opt-in development route

`bin/beagle-dev` makes native stage0 the compiler for single-file hosted
development builds while leaving the public, release, and gate routes alone:

```sh
nix build .#beagle-selfhost
export BEAGLE_NATIVE_BIN="$PWD/result/bin/beagle-selfhost"
export BEAGLE_SELFHOST_DEV=1
bin/beagle-dev build example.bclj
```

Set `BEAGLE_SELFHOST_SHADOW_PERCENT` to an integer from 0 through 100 to run a
deterministic sample of those inputs through the pinned-Racket compiler too.
Byte or exit-status differences append a candidate directory containing the
input, both outputs, both digests, stderr, and the input digest under
`docs/private/selfhost-divergences/`. Override that ignored inbox with
`BEAGLE_SELFHOST_DIVERGENCE_DIR`.

The one-line revert is:

```sh
unset BEAGLE_SELFHOST_DEV
```

With the flag absent, and for batch, Core, materializer, query, release, and
gate commands, the wrapper delegates to the unchanged public Racket route.

## What this does and does not claim

These gates are correctness gates: byte-exact bootstrap fixpoint, oracle
agreement, and differential fuzz with no exemptions. They say nothing about
compile speed or runtime speed, and the repository publishes no performance
measurements.
