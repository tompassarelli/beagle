#!/usr/bin/env bash
# Build the self-hosted JS emitter and verify fixed-point.
set -euo pipefail

BEAGLE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BEAGLE_ROOT"

echo "=== Building self-hosted emitter ==="
bin/beagle-build self-host/emit-js.bjs
cp runtime/src/self/host/emit/js.js self-host/dist/emit-js.mjs

echo "=== Testing against hello-js.bjs ==="
RACKET_OUT=$(bin/beagle-build beagle-test/tests/fixtures/hello-js.bjs 2>/dev/null && cat runtime/src/app/main.js)
SELF_OUT=$(bin/beagle-self-emit beagle-test/tests/fixtures/hello-js.bjs 2>/dev/null)

if diff <(echo "$RACKET_OUT" | tail -n +2) <(echo "$SELF_OUT") > /dev/null 2>&1; then
    echo "  PASS: self-hosted output matches Racket emitter"
else
    echo "  FAIL: outputs differ"
    diff <(echo "$RACKET_OUT" | tail -n +2) <(echo "$SELF_OUT")
    exit 1
fi

echo "=== Fixed-point check (gen2 = gen1) ==="
GEN2=$(bin/beagle-self-emit self-host/emit-js.bjs 2>/dev/null)
GEN1_OUT=$(bin/beagle-self-emit beagle-test/tests/fixtures/hello-js.bjs 2>/dev/null)

echo "$GEN2" > /tmp/beagle-gen2-emitter.mjs
GEN2_OUT=$(bin/beagle-ast beagle-test/tests/fixtures/hello-js.bjs 2>/dev/null | node /tmp/beagle-gen2-emitter.mjs)

if diff <(echo "$GEN1_OUT") <(echo "$GEN2_OUT") > /dev/null 2>&1; then
    echo "  PASS: gen2 output matches gen1 (fixed-point reached)"
else
    echo "  FAIL: gen2 differs from gen1"
    exit 1
fi

rm -f /tmp/beagle-gen2-emitter.mjs
echo "=== All self-hosting checks passed ==="
