#!/usr/bin/env bash
# Regression test + proof for move 2 — byte-stable emit.
#
# The pretty-printer (datum->pretty in beagle-lib/private/facts-roundtrip.rkt)
# turns facts back into source. It must satisfy the move-2 contract:
#   1. idempotent fixed-point  — pretty(parse(pretty(x))) == pretty(x)
#   2. canonical round-trip    — pretty text re-reads to the CANONICAL datum
#                                (only the retired grouped spelling changes)
#   3. LOCAL                    — a one-token change => a small, local diff
#                                (the property determinism does NOT give for free)
#   4. comment-preserving       — comments survive the facts->source render
#
# Racket-only (no store, no bb). Gates in CI.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"   # repo root (bin/test/byte-stable-emit -> 3 up)
RT="$ROOT/beagle-lib/private/facts-roundtrip.rkt"
fail=0

source "$ROOT/bin/_beagle-racket"

echo "================ move 2 — byte-stable emit gate ================"

# 1 + 2: idempotent fixed-point + round-trip over the in-repo corpus.
echo "--- fixed-point + round-trip over beagle-test/tests/fixtures ---"
GATE_OUT="$("$RACKET" "$RT" --pretty-gate "$ROOT/beagle-test/tests/fixtures" 2>&1)"
grep -E 'files:|GATE:' <<<"$GATE_OUT" | sed 's/^/  /'
grep -q 'GATE: PASS' <<<"$GATE_OUT" || { echo "  FAIL: corpus fixed-point/round-trip not green"; fail=1; }

# 3: locality — a one-token change yields a single-line diff.
echo "--- locality (one-token change -> small diff) ---"
T="$(mktemp -d)"
cp "$HERE/locality-fixture.bclj" "$T/a.bclj"
sed 's/(> x threshold)/(>= x threshold)/' "$T/a.bclj" > "$T/b.bclj"
"$RACKET" "$RT" --pretty "$T/a.bclj" 2>/dev/null > "$T/a.txt"
"$RACKET" "$RT" --pretty "$T/b.bclj" 2>/dev/null > "$T/b.txt"
CHANGED=$(diff "$T/a.txt" "$T/b.txt" | grep -cE '^[<>]' || true)
echo "  diff lines for a one-token change: $CHANGED  (a single changed line = 2: one '<', one '>')"
[ "$CHANGED" -le 2 ] || { echo "  FAIL: one-token change touched $CHANGED diff-lines (>2) — not local"; fail=1; }
rm -rf "$T"

# 4: comments survive the facts->source render, and the render re-reads cleanly.
echo "--- comment preservation + rendered text round-trips ---"
T="$(mktemp -d)"
"$RACKET" "$RT" --emit-edn "$HERE/comment-fixture.bclj" > "$T/c.edn" 2>/dev/null
"$RACKET" "$RT" --render "$T/c.edn" 2>/dev/null > "$T/rendered.bclj"
for needle in 'leading comment on area' 'trailing note'; do
  grep -q "$needle" "$T/rendered.bclj" || { echo "  FAIL: comment '$needle' dropped on render"; fail=1; }
done
grep -q 'GATE: PASS' <<<"$("$RACKET" "$RT" --pretty-gate "$T" 2>&1)" || { echo "  FAIL: rendered (commented) text does not round-trip"; fail=1; }
rm -rf "$T"

echo
if [ "$fail" = 0 ]; then
  echo "RESULT: PASS — emit is deterministic, local, round-tripping, and comment-preserving."
else
  echo "RESULT: FAIL"; exit 1
fi
