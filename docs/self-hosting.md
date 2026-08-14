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

## What this does and does not claim

These gates are correctness gates: byte-exact bootstrap fixpoint, oracle
agreement, and differential fuzz with no exemptions. They say nothing about
compile speed or runtime speed, and the repository publishes no performance
measurements.
