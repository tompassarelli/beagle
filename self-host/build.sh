#!/usr/bin/env bash
# Build the self-hosted emitters and verify against Racket emitter output.
set -euo pipefail

BEAGLE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BEAGLE_ROOT"

PASS=0
FAIL=0

# --- JS emitter --------------------------------------------------------------

echo "=== Building self-hosted JS emitter ==="
bin/beagle-build self-host/emit-js.bjs
cp runtime/src/self/host/emit/js.js self-host/dist/emit-js.mjs

echo "=== JS: Testing against hello-js.bjs ==="
RACKET_OUT=$(bin/beagle-build beagle-test/tests/fixtures/hello-js.bjs 2>/dev/null && cat runtime/src/app/main.js)
SELF_OUT=$(bin/beagle-self-emit beagle-test/tests/fixtures/hello-js.bjs 2>/dev/null)

if diff <(echo "$RACKET_OUT" | tail -n +2) <(echo "$SELF_OUT") > /dev/null 2>&1; then
    echo "  PASS: self-hosted JS output matches Racket emitter"
    PASS=$((PASS + 1))
else
    echo "  FAIL: JS outputs differ"
    diff <(echo "$RACKET_OUT" | tail -n +2) <(echo "$SELF_OUT")
    FAIL=$((FAIL + 1))
fi

echo "=== JS: Fixed-point check (gen2 = gen1) ==="
GEN2=$(bin/beagle-self-emit self-host/emit-js.bjs 2>/dev/null)
GEN1_OUT=$(bin/beagle-self-emit beagle-test/tests/fixtures/hello-js.bjs 2>/dev/null)

echo "$GEN2" > /tmp/beagle-gen2-emitter.mjs
GEN2_OUT=$(bin/beagle-ast beagle-test/tests/fixtures/hello-js.bjs 2>/dev/null | node /tmp/beagle-gen2-emitter.mjs)

if diff <(echo "$GEN1_OUT") <(echo "$GEN2_OUT") > /dev/null 2>&1; then
    echo "  PASS: gen2 output matches gen1 (fixed-point reached)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: gen2 differs from gen1"
    FAIL=$((FAIL + 1))
fi
rm -f /tmp/beagle-gen2-emitter.mjs

# --- CLJ emitter -------------------------------------------------------------

echo ""
echo "=== Building self-hosted CLJ emitter ==="
bin/beagle-build self-host/emit-clj.bjs
cp runtime/src/self/host/emit/clj.js self-host/dist/emit-clj.mjs

for fixture in mathlib shapes result; do
    echo "=== CLJ: Testing against ${fixture}.bclj ==="
    RACKET_OUT=$(bin/beagle-build "beagle-test/tests/fixtures/${fixture}.bclj" 2>/dev/null)
    # Find the output file
    NS=$(grep -E '^\(ns' "beagle-test/tests/fixtures/${fixture}.bclj" | head -1 | \
         sed -E 's/^\(ns[[:space:]]+([^)]+)\).*/\1/' | tr -d '[:space:]')
    REL=$(echo "$NS" | tr '.-' '//_')
    RACKET_SRC=$(cat "runtime/src/${REL}.clj" | sed 's/\^{[^}]*} //g')
    SELF_OUT=$(bin/beagle-self-emit-clj "beagle-test/tests/fixtures/${fixture}.bclj" 2>/dev/null)

    if diff <(echo "$RACKET_SRC") <(echo "$SELF_OUT") > /dev/null 2>&1; then
        echo "  PASS: ${fixture}.bclj matches"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${fixture}.bclj differs"
        diff <(echo "$RACKET_SRC") <(echo "$SELF_OUT")
        FAIL=$((FAIL + 1))
    fi
done

# --- Python emitter -----------------------------------------------------------

echo ""
echo "=== Building self-hosted Python emitter ==="
bin/beagle-build self-host/emit-py.bjs
cp runtime/src/self/host/emit/py.js self-host/dist/emit-py.mjs

echo "=== PY: Testing against pytest.bpy ==="
RACKET_OUT=$(bin/beagle-build beagle-test/tests/fixtures/pytest.bpy 2>/dev/null && cat runtime/src/pytest.py)
SELF_OUT=$(bin/beagle-self-emit-py beagle-test/tests/fixtures/pytest.bpy 2>/dev/null)

if diff <(echo "$RACKET_OUT") <(echo "$SELF_OUT") > /dev/null 2>&1; then
    echo "  PASS: pytest.bpy matches"
    PASS=$((PASS + 1))
else
    echo "  FAIL: pytest.bpy differs"
    diff <(echo "$RACKET_OUT") <(echo "$SELF_OUT")
    FAIL=$((FAIL + 1))
fi

# --- Summary ------------------------------------------------------------------

echo ""
echo "=== Self-hosting checks: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]] || exit 1
