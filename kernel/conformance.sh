#!/usr/bin/env bash
# The conformance ritual, mechanized (thread 20260613013145).
# Red/green for: hash baselines (small + big), determinism, and the
# zig-vs-babashka differential. Re-baselining is a deliberate edit to
# the values below — visible in diffs, never silent.
set -euo pipefail
cd "$(dirname "$0")"

SMALL_HASH="0x24CA95E6723F5C2B"   # 1000 ticks, seed 0xBEA61E, semantics v5 (lifecycle: predation + starvation)
BIG_HASH="0xA1C71A319F6024C2"     # 500 ticks,  seed 0xBEA61E, semantics v5 (lifecycle: predation + starvation)
fail=0

echo "── small config (1000 ticks, x2 for determinism)"
zig build -Doptimize=ReleaseSafe >/dev/null 2>&1
h1=$(./zig-out/bin/kernel --headless 1000 2>&1 | grep -o 'hash=0x[0-9A-F]*' | cut -d= -f2)
h2=$(./zig-out/bin/kernel --headless 1000 2>&1 | grep -o 'hash=0x[0-9A-F]*' | cut -d= -f2)
[[ "$h1" == "$SMALL_HASH" ]] && echo "  ok   small hash $h1" || { echo "  FAIL small hash: $h1 != $SMALL_HASH"; fail=1; }
[[ "$h1" == "$h2" ]] && echo "  ok   deterministic" || { echo "  FAIL nondeterministic: $h1 vs $h2"; fail=1; }

echo "── differential (zig vs babashka, same beagle source)"
./differential.sh 5000 >/dev/null && echo "  ok   5000 cases identical" || { echo "  FAIL differential"; fail=1; }

echo "── big config (500 ticks, 200k minds)"
zig build -Dbig=true -Doptimize=ReleaseSafe >/dev/null 2>&1
hb=$(./zig-out/bin/kernel --headless 500 2>&1 | grep -o 'hash=0x[0-9A-F]*' | cut -d= -f2)
[[ "$hb" == "$BIG_HASH" ]] && echo "  ok   big hash $hb" || { echo "  FAIL big hash: $hb != $BIG_HASH"; fail=1; }

# leave the tree in the default build
zig build >/dev/null 2>&1
[[ $fail == 0 ]] && echo "CONFORMANCE GREEN" || { echo "CONFORMANCE RED"; exit 1; }
