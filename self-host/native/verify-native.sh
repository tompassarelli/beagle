#!/usr/bin/env bash
# verify-native: parity gate for the GraalVM native-image selfhost binary.
# Sibling of self-host/verify-selfhost.sh (same corpus, same oracle discipline):
# for every module the NATIVE binary's emit must be byte-identical to BOTH
#   (a) the bb-run seed compiler's emit, and
#   (b) the Racket compiler's emit (the oracle).
#
# Usage: self-host/native/verify-native.sh [MODULE.bclj ...]
#   default corpus: $FRAM_REPO/src/fram/*.bclj + self-host/fixtures/lowering-temps.bclj
# Requires: self-host/native/beagle-selfhost (run build.sh first), bb, the
# checkout's pinned racket (resolved via bin/_beagle-racket).
# BEAGLE_NATIVE_BIN overrides the binary under test (e.g. a nix-built result).
#
# Corpus rule: a module is byte-compared only when its requires can be served
# under closed module resolution. See core_required_by below.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
NATIVE="${BEAGLE_NATIVE_BIN:-self-host/native/beagle-selfhost}"
SEED=self-host/seed
LAB=.lab/native-verify
mkdir -p "$LAB"

[ -x "$NATIVE" ] || { echo "verify-native: $NATIVE missing — run self-host/native/build.sh" >&2; exit 1; }

FRAM_REPO="${FRAM_REPO:-$HOME/code/fram/main}"
MODULES=("$@")
if [ ${#MODULES[@]} -eq 0 ]; then
    MODULES=("$FRAM_REPO"/src/fram/*.bclj self-host/fixtures/lowering-temps.bclj)
fi

# Pinned racket for the oracle mint (worktree-safe collection routing, as in beagle-remint).
source "$ROOT/bin/_beagle-racket"
collects="$ROOT/.beagle/collects"
mkdir -p "$collects"
ln -sfn "$ROOT/beagle-lib" "$collects/beagle"
export PLTCOLLECTS="$collects:"

# The Core source extension is derived from the target table, never spelled here.
source "$ROOT/share/targets.sh"
CORE_EXT=".${BEAGLE_TARGET_SRC_EXT[core]}"

# Closed module resolution serves a require from the explicit source bundle or
# from a declared module root, and a root candidate always carries the
# IMPORTER's profile extension (beagle-lib/private/module-source-root.rkt,
# mirrored by self-host/src/selfhost/main.bclj). A Beagle Core provider is
# therefore unreachable from a hosted importer through this one-file
# invocation, in every leg — Racket oracle, bb seed, and native binary alike.
# Fram moved fram.types/store/schema/... to Core, so those corpus modules
# cannot be byte-compared here; the same rule already selects
# self-host/verify-selfhost.sh's fram corpus. Read off disk rather than
# hand-listed, so a corpus that moves a provider back to hosted source
# re-enters this gate by itself.
core_required_by() {           # <src> -> prints "NAMESPACE -> PATH", or fails
    local src="$1" namespace relative root required required_relative
    namespace="$(sed -nE 's/^[[:space:]]*\(ns[[:space:]]+([A-Za-z0-9._-]+).*/\1/p' \
                     "$src" | head -1)"
    [ -n "$namespace" ] || return 1
    relative="$(printf '%s' "$namespace" | tr '.-' '/_')"
    root="${src%/"$relative".*}"
    [ "$root" != "$src" ] || return 1
    for required in $(
        {
            grep -oE '\(:?require[[:space:]]+[A-Za-z0-9._-]+' "$src" \
                | sed -E 's/.*[[:space:]]//'
            grep -oE '\[[A-Za-z0-9._-]+[[:space:]]+:as' "$src" \
                | sed -E 's/^\[//; s/[[:space:]]+:as$//'
        } | sort -u
    ); do
        required_relative="$(printf '%s' "$required" | tr '.-' '/_')"
        if [ -f "$root/$required_relative$CORE_EXT" ]; then
            printf '%s -> %s\n' "$required" "$root/$required_relative$CORE_EXT"
            return 0
        fi
    done
    return 1
}

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP+1)); }

for src in "${MODULES[@]}"; do
    name="$(basename "$src" .bclj)"
    oracle="$LAB/$name-oracle.clj"
    bbout="$LAB/$name-bb.clj"
    nativeout="$LAB/$name-native.clj"

    if core_provider="$(core_required_by "$src")"; then
        skip "$name — requires a Beagle Core provider ($core_provider); no leg resolves a Core provider for a hosted importer"
        continue
    fi

    BEAGLE_EMIT_SRCLOC=0 bin/beagle-build "$src" "$oracle" \
        >/dev/null 2>"$LAB/$name-oracle.err" \
        || { bad "$name racket oracle mint — $(head -2 "$LAB/$name-oracle.err" | tr '\n' ' ')"; continue; }
    bb -cp "$SEED" -m selfhost.main emit "$src" > "$bbout" 2>"$LAB/$name-bb.err" \
        || { bad "$name bb emit — $(head -2 "$LAB/$name-bb.err" | tr '\n' ' ')"; continue; }
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
echo "=== verify-native: $PASS passed, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" -eq 0 ]
