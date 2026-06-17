#!/usr/bin/env bash
# Build reproducibility — the same source compiles BYTE-IDENTICALLY every build.
#
# match's emit used (random 99999) for its `match__N` temp, so two builds of the
# same source produced different .clj (broke byte-reproducible builds + forced the
# code-as-claims recompile gate to guard around it). Now the temp is a deterministic
# per-program counter. This gate builds a match-using module TWICE and asserts the
# emitted .clj is byte-identical. Racket-only.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
fail=0

echo "================ build reproducibility (deterministic emit) ================"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
"$ROOT/bin/beagle-build-all" "$HERE/match-fixture.bclj" --out "$W/o1" >/dev/null 2>&1
"$ROOT/bin/beagle-build-all" "$HERE/match-fixture.bclj" --out "$W/o2" >/dev/null 2>&1
c="$(find "$W/o1" -name '*.clj' | head -1)"
if [ -z "$c" ]; then echo "  FAIL  fixture did not build"; exit 1; fi
rel="${c#"$W/o1/"}"
echo "  match temps emitted: $(grep -oE 'match__[0-9]+' "$c" | sort -u | tr '\n' ' ')(deterministic counter, not random)"
if diff -q "$W/o1/$rel" "$W/o2/$rel" >/dev/null 2>&1; then
  echo "  PASS  same source -> byte-identical .clj across two builds"
else
  echo "  FAIL  build is non-deterministic:"; diff "$W/o1/$rel" "$W/o2/$rel" | head; fail=1
fi

echo
[ "$fail" = 0 ] && echo "RESULT: PASS — emit is byte-reproducible (match temps deterministic)." || { echo "RESULT: FAIL"; exit 1; }
