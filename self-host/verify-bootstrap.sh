#!/usr/bin/env bash
# Differential check: Bun compiler path vs Racket compiler path.
# Validates the proof ladder for bootstrap closure.
set -euo pipefail

BEAGLE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BEAGLE_ROOT"

CORPUS=(
  self-host/reader.bjs
  self-host/ast.bjs
  self-host/types.bjs
  self-host/macros.bjs
  self-host/parse.bjs
  self-host/check.bjs
  self-host/emit-js.bjs
  self-host/lint.bjs
  self-host/emit-clj.bjs
  self-host/emit-py.bjs
  self-host/emit-nix.bjs
  self-host/emit-rkt.bjs
)

PASS=0
FAIL=0
TOTAL=0

fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); }

# --- P0: Reader ---
echo "=== P0: Reader output matches Racket reader ==="
# Compare Bun reader datums vs Racket AST (both produce JSON AST, compare structure)
for f in "${CORPUS[@]}"; do
  bun_ast=$(bin/beagle-bun "$f" --ast 2>/dev/null || echo "ERROR")
  rkt_ast=$(bin/beagle-ast "$f" 2>/dev/null || echo "ERROR")
  if [ "$bun_ast" = "ERROR" ]; then
    fail "P0 $f (Bun reader/parser failed)"
    continue
  fi
  if [ "$rkt_ast" = "ERROR" ]; then
    fail "P0 $f (Racket AST failed)"
    continue
  fi
  # Compare top-level structure: mode, target, namespace
  bun_meta=$(echo "$bun_ast" | bun -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')); console.log(JSON.stringify({mode:d.mode,target:d.target,ns:d.namespace}))")
  rkt_meta=$(echo "$rkt_ast" | bun -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')); console.log(JSON.stringify({mode:d.mode,target:d.target,ns:d.namespace}))")
  if [ "$bun_meta" = "$rkt_meta" ]; then
    pass "P0 $f (meta matches)"
  else
    fail "P0 $f (meta differs: bun=$bun_meta rkt=$rkt_meta)"
  fi
done

# --- P2: Checker accepts corpus ---
echo ""
echo "=== P2: Checker accepts compiler corpus ==="
for f in "${CORPUS[@]}"; do
  check_err=$(bin/beagle-bun "$f" > /dev/null 2>&1)
  if [ $? -eq 0 ]; then
    pass "P2 $f"
  else
    fail "P2 $f (checker rejected)"
  fi
done

# --- P1: Parser output matches ---
echo ""
echo "=== P1: Parser output matches Racket parser ==="
for f in "${CORPUS[@]}"; do
  bun_ast=$(bin/beagle-bun "$f" --ast 2>/dev/null || echo "ERROR")
  rkt_ast=$(bin/beagle-ast "$f" 2>/dev/null || echo "ERROR")
  if [ "$bun_ast" = "ERROR" ] || [ "$rkt_ast" = "ERROR" ]; then
    fail "P1 $f (AST generation failed)"
    continue
  fi
  bun_forms=$(echo "$bun_ast" | bun -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')); console.log(d.forms.length)")
  rkt_forms=$(echo "$rkt_ast" | bun -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')); console.log(d.forms.length)")
  if [ "$bun_forms" = "$rkt_forms" ]; then
    pass "P1 $f (form count: $bun_forms)"
  else
    fail "P1 $f (form count: bun=$bun_forms rkt=$rkt_forms)"
  fi
done

# --- P3: Emitter output matches ---
echo ""
echo "=== P3: Emitter output matches Racket emitter ==="
for f in "${CORPUS[@]}"; do
  bun_out=$(bin/beagle-bun "$f" --no-check 2>/dev/null || echo "ERROR")
  rkt_out=$(racket "$f" 2>/dev/null || echo "ERROR")
  if [ "$bun_out" = "ERROR" ]; then
    fail "P3 $f (Bun compile failed)"
    continue
  fi
  if [ "$rkt_out" = "ERROR" ]; then
    fail "P3 $f (Racket compile failed)"
    continue
  fi
  # Strip leading blank lines for comparison
  bun_clean=$(echo "$bun_out" | sed '/^$/d' | head -1)
  rkt_clean=$(echo "$rkt_out" | sed '/^$/d' | head -1)
  bun_lines=$(echo "$bun_out" | sed '/^$/d' | wc -l)
  rkt_lines=$(echo "$rkt_out" | sed '/^$/d' | wc -l)
  if [ "$bun_out" = "$rkt_out" ] || diff <(echo "$bun_out" | sed '1{/^$/d}') <(echo "$rkt_out" | sed '1{/^$/d}') > /dev/null 2>&1; then
    pass "P3 $f (exact match)"
  elif [ "$bun_lines" = "$rkt_lines" ]; then
    ndiff=$(diff <(echo "$bun_out") <(echo "$rkt_out") | grep '^[<>]' | wc -l)
    fail "P3 $f (same line count=$bun_lines, $ndiff diff lines)"
  else
    fail "P3 $f (line count: bun=$bun_lines rkt=$rkt_lines)"
  fi
done

# --- P4: Compile one component without Racket ---
echo ""
echo "=== P4: Bun compiler compiles a component whose output runs ==="
bun_reader=$(bin/beagle-bun self-host/reader.bjs --no-check 2>/dev/null)
if echo "$bun_reader" | bun -e "
  $(cat /dev/stdin)
  const r = read_all('(def x 42)');
  if (r.datums && r.datums.length > 0) process.exit(0);
  process.exit(1);
" 2>/dev/null; then
  pass "P4 reader.bjs compiles and runs"
else
  fail "P4 reader.bjs compiled output doesn't run"
fi

# --- P5: Compile the JS emitter ---
echo ""
echo "=== P5: Bun compiler compiles the JS emitter ==="
if bin/beagle-bun self-host/emit-js.bjs --no-check > /dev/null 2>&1; then
  pass "P5 emit-js.bjs compiles"
else
  fail "P5 emit-js.bjs fails to compile"
fi

# --- P6: Fixed-point ---
echo ""
echo "=== P6: Fixed-point (gen1 === gen2 under Bun path) ==="
gen1=$(bin/beagle-bun self-host/emit-js.bjs --no-check 2>/dev/null)
if [ -z "$gen1" ]; then
  fail "P6 gen1 compilation failed"
else
  # Patch line 1 so gen1 can execute (resolve beagle/core.js import)
  tmpgen1=$(mktemp /tmp/beagle-gen1-XXXXXX.cjs)
  echo "$gen1" | sed "1s|import \* as \$\$bc from 'beagle/core.js';|const \$\$bc = require('$BEAGLE_ROOT/beagle-lib/lib/beagle/core.js');|" > "$tmpgen1"
  gen2=$(bin/beagle-bun self-host/emit-js.bjs --ast --no-check 2>/dev/null | bun "$tmpgen1")
  rm -f "$tmpgen1"

  if [ "$gen1" = "$gen2" ]; then
    pass "P6 fixed-point (byte-identical)"
  else
    gen1_body=$(echo "$gen1" | tail -n +2)
    gen2_body=$(echo "$gen2" | tail -n +2)
    if [ "$gen1_body" = "$gen2_body" ]; then
      pass "P6 fixed-point (body identical, import line differs)"
    else
      fail "P6 fixed-point broken"
    fi
  fi
fi

# --- Summary ---
echo ""
echo "=== Bootstrap verification: $PASS passed, $FAIL failed (of $TOTAL checks) ==="
[ "$FAIL" -eq 0 ] || exit 1
