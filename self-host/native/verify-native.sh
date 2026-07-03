#!/usr/bin/env bash
# verify-native: parity gate for the GraalVM native-image selfhost binary.
# Sibling of self-host/verify-selfhost.sh (same corpus, same oracle discipline):
# for every module the NATIVE binary's emit must be byte-identical to BOTH
#   (a) the bb-run seed compiler's emit, and
#   (b) the Racket compiler's emit (the oracle).
#
# Usage: self-host/native/verify-native.sh [MODULE.bclj ...]
#   default corpus: ~/code/fram/src/fram/*.bclj + self-host/fixtures/lowering-temps.bclj
# Requires: self-host/native/beagle-selfhost (run build.sh first), bb, the
# checkout's pinned racket (resolved via bin/_beagle-racket).
# BEAGLE_NATIVE_BIN overrides the binary under test (e.g. a nix-built result).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
NATIVE="${BEAGLE_NATIVE_BIN:-self-host/native/beagle-selfhost}"
SEED=self-host/seed
LAB=.lab/native-verify
mkdir -p "$LAB"

[ -x "$NATIVE" ] || { echo "verify-native: $NATIVE missing — run self-host/native/build.sh" >&2; exit 1; }

MODULES=("$@")
if [ ${#MODULES[@]} -eq 0 ]; then
    MODULES=("$HOME"/code/fram/src/fram/*.bclj self-host/fixtures/lowering-temps.bclj)
fi

# Pinned racket for the oracle mint (worktree-safe collection routing, as in beagle-remint).
source "$ROOT/bin/_beagle-racket"
collects="$ROOT/.beagle/collects"
mkdir -p "$collects"
ln -sfn "$ROOT/beagle-lib" "$collects/beagle"
export PLTCOLLECTS="$collects:"

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

for src in "${MODULES[@]}"; do
    name="$(basename "$src" .bclj)"
    oracle="$LAB/$name-oracle.clj"
    bbout="$LAB/$name-bb.clj"
    nativeout="$LAB/$name-native.clj"

    BEAGLE_EMIT_SRCLOC=0 bin/beagle-build "$src" "$oracle" >/dev/null 2>&1 \
        || { bad "$name racket oracle mint"; continue; }
    bb -cp "$SEED" -m selfhost.main emit "$src" > "$bbout" 2>/dev/null \
        || { bad "$name bb emit"; continue; }
    "$NATIVE" emit "$src" > "$nativeout" 2>"$LAB/$name-native.err" \
        || { bad "$name native emit — $(head -2 "$LAB/$name-native.err" | tr '\n' ' ')"; continue; }

    if diff -q "$nativeout" "$bbout" >/dev/null 2>&1; then
        ok "$name native == bb"
    else
        bad "$name native != bb — diff $nativeout $bbout"
    fi
    if diff -q "$nativeout" "$oracle" >/dev/null 2>&1; then
        ok "$name native == racket oracle"
    else
        bad "$name native != oracle — diff $nativeout $oracle"
    fi
done

echo ""
echo "=== verify-native: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
