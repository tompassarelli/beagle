#!/usr/bin/env bash
# Build the self-hosted emitters and verify against Racket emitter output.
set -euo pipefail

BEAGLE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BEAGLE_ROOT"
source "$BEAGLE_ROOT/bin/_beagle-racket"

PASS=0
FAIL=0

# --- JS emitter --------------------------------------------------------------

echo "=== Building self-hosted JS emitter ==="
bin/beagle-build self-host/emit-js.bjs
cp runtime/src/self/host/emit/js.js self-host/dist/emit-js.mjs

echo "=== JS: Testing against hello-js.bjs ==="
RACKET_OUT=$(bin/beagle-build beagle-test/tests/fixtures/hello-js.bjs 2>/dev/null && cat runtime/src/app/main.js)
SELF_OUT=$(bin/beagle-self-emit beagle-test/tests/fixtures/hello-js.bjs 2>/dev/null)

if diff <(echo "$RACKET_OUT" | tail -n +2) <(echo "$SELF_OUT" | tail -n +2) > /dev/null 2>&1; then
    echo "  PASS: self-hosted JS output matches Racket emitter"
    PASS=$((PASS + 1))
else
    echo "  FAIL: JS outputs differ"
    diff <(echo "$RACKET_OUT" | tail -n +2) <(echo "$SELF_OUT" | tail -n +2)
    FAIL=$((FAIL + 1))
fi

echo "=== JS: Fixed-point check (gen2 = gen1) ==="
GEN2=$(bin/beagle-self-emit self-host/emit-js.bjs 2>/dev/null)
GEN1_OUT=$(bin/beagle-self-emit beagle-test/tests/fixtures/hello-js.bjs 2>/dev/null)

echo "$GEN2" > /tmp/beagle-gen2-emitter.mjs
GEN2_OUT=$(bin/beagle-ast beagle-test/tests/fixtures/hello-js.bjs 2>/dev/null | bun run /tmp/beagle-gen2-emitter.mjs)

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

# --- Nix emitter --------------------------------------------------------------

echo ""
echo "=== Building self-hosted Nix emitter ==="
bin/beagle-build self-host/emit-nix.bjs
cp runtime/src/self/host/emit/nix.js self-host/dist/emit-nix.mjs

for fixture in nix-builtins nix-simple-pkg nix-rec-assert nix-let-cond nix-interp-ms; do
    echo "=== NIX: Testing against ${fixture}.bnix ==="
    # Build canonical output
    bin/beagle-build "beagle-test/tests/fixtures/${fixture}.bnix" 2>/dev/null
    NS=$(grep -E '^\(ns' "beagle-test/tests/fixtures/${fixture}.bnix" | head -1 | \
         sed -E 's/^\(ns[[:space:]]+([^)]+)\).*/\1/' | tr -d '[:space:]')
    REL=$(echo "$NS" | sed 's/[.-]/\//g')
    NIX_FILE="runtime/src/${REL}.nix"
    RACKET_SRC=$(cat "$NIX_FILE")
    SELF_OUT=$(bin/beagle-self-emit-nix "beagle-test/tests/fixtures/${fixture}.bnix" 2>/dev/null)

    if diff <(echo "$RACKET_SRC") <(echo "$SELF_OUT") > /dev/null 2>&1; then
        echo "  PASS: ${fixture}.bnix matches"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${fixture}.bnix differs"
        diff <(echo "$RACKET_SRC") <(echo "$SELF_OUT")
        FAIL=$((FAIL + 1))
    fi
done

# --- Racket emitter -----------------------------------------------------------

echo ""
echo "=== Building self-hosted Racket emitter ==="
bin/beagle-build self-host/emit-rkt.bjs
cp runtime/src/self/host/emit/rkt.js self-host/dist/emit-rkt.mjs

RKT_PASS=0
RKT_TOTAL=0
for fixture in oracle/fixtures/*.bgl; do
    fname=$(basename "$fixture" .bgl)
    RKT_TOTAL=$((RKT_TOTAL + 1))
    RACKET_OUT=$("$RACKET" "$fixture" 2>/dev/null) || continue
    SELF_OUT=$(bin/beagle-self-emit-rkt "$fixture" 2>/dev/null) || continue

    if diff <(echo "$RACKET_OUT") <(echo "$SELF_OUT") > /dev/null 2>&1; then
        RKT_PASS=$((RKT_PASS + 1))
    fi
done
echo "  RKT: ${RKT_PASS}/${RKT_TOTAL} fixtures match"
if [ "$RKT_PASS" -gt 0 ]; then
    PASS=$((PASS + 1))
fi

# --- Lint check ---------------------------------------------------------------

echo ""
echo "=== Building self-hosted lint ==="
bin/beagle-build self-host/lint.bjs

echo "=== LINT: Testing against mathlib.bclj ==="
RACKET_LINT=$(bin/beagle-build beagle-test/tests/fixtures/mathlib.bclj 2>&1 | grep "beagle \[lint\]" | sort)
SELF_LINT=$(bin/beagle-ast beagle-test/tests/fixtures/mathlib.bclj 2>/dev/null | node runtime/src/self/host/lint.js 2>&1 | grep "beagle \[lint\]" | sort)

if diff <(echo "$RACKET_LINT") <(echo "$SELF_LINT") > /dev/null 2>&1; then
    echo "  PASS: lint output matches"
    PASS=$((PASS + 1))
else
    echo "  FAIL: lint outputs differ"
    diff <(echo "$RACKET_LINT") <(echo "$SELF_LINT")
    FAIL=$((FAIL + 1))
fi

# --- Types module -------------------------------------------------------------

echo ""
echo "=== Building self-hosted types ==="
bin/beagle-build self-host/types.bjs

echo "=== TYPES: Running self-tests ==="
TYPES_OUT=$(node runtime/src/self/host/types.js 2>&1)
TYPES_RC=$?

echo "$TYPES_OUT"
if [ $TYPES_RC -eq 0 ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

# --- Macros module ------------------------------------------------------------

echo ""
echo "=== Building self-hosted macros ==="
bin/beagle-build self-host/macros.bjs

echo "=== MACROS: Running self-tests ==="
MACROS_OUT=$(node runtime/src/self/host/macros.js 2>&1)
MACROS_RC=$?

echo "$MACROS_OUT"
if [ $MACROS_RC -eq 0 ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

# --- AST module ---------------------------------------------------------------

echo ""
echo "=== Building self-hosted AST ==="
bin/beagle-build self-host/ast.bjs

echo "=== AST: Running self-tests ==="
AST_OUT=$(node runtime/src/self/host/ast.js 2>&1)
AST_RC=$?

echo "$AST_OUT"
if [ $AST_RC -eq 0 ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

# --- Parser module ------------------------------------------------------------

echo ""
echo "=== Building self-hosted parser ==="
bin/beagle-build self-host/parse.bjs

echo "=== PARSE: Running self-tests ==="
PARSE_OUT=$(node runtime/src/self/host/parse.js 2>&1)
PARSE_RC=$?

echo "$PARSE_OUT"
if [ $PARSE_RC -eq 0 ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

# --- Checker module -----------------------------------------------------------

echo ""
echo "=== Building self-hosted checker ==="
bin/beagle-build self-host/check.bjs

echo "=== CHECK: Running self-tests ==="
CHECK_OUT=$(node runtime/src/self/host/check.js 2>&1)
CHECK_RC=$?

echo "$CHECK_OUT"
if [ $CHECK_RC -eq 0 ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

# --- Summary ------------------------------------------------------------------

echo ""
echo "=== Self-hosting checks: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]] || exit 1
