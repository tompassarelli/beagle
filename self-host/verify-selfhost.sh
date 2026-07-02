#!/usr/bin/env bash
# verify-selfhost: oracle ladder for the .bclj self-hosted compiler (tranche 1).
#
# Rungs (each isolates one stage against the Racket compiler as oracle):
#   1. module self-tests under bb
#   2. emit parity, stage-isolated: Racket AST -> self emit-clj vs Racket emit
#   3. AST parity: self reader+parse vs bin/beagle-ast (data-identical forms)
#   4. full chain: self reader -> parse -> check -> emit-clj vs Racket emit (byte diff)
#
# Usage: self-host/verify-selfhost.sh [MODULE.bclj ...]
#   default corpus: every tracked fixture under self-host/fixtures/, plus
#   ~/code/fram/src/fram/fold.bclj when that checkout exists
set -uo pipefail
WT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WT"
OUT=self-host/seed
LAB=.lab
mkdir -p "$LAB"

MODULES=("$@")
if [ ${#MODULES[@]} -eq 0 ]; then
  MODULES=(self-host/fixtures/*.bclj)
  [ -f "$HOME/code/fram/src/fram/fold.bclj" ] && MODULES+=("$HOME/code/fram/src/fram/fold.bclj")
fi

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== 1. module self-tests (bb) ==="
for m in ast types macros reader parse check emit-clj; do
  ns="selfhost.$m"
  f="$OUT/selfhost/$(echo "$m" | tr '-' '_').clj"
  if [ ! -f "$f" ]; then bad "$m (not built: $f)"; continue; fi
  if bb -cp "$OUT" -e "(require '[$ns :as m]) (System/exit (m/run-tests!))" >/dev/null 2>&1; then
    ok "$m self-tests"
  else
    bad "$m self-tests"
  fi
done

for src in "${MODULES[@]}"; do
  name="$(basename "$src" .bclj)"
  oracle="$LAB/$name-oracle.clj"
  astj="$LAB/$name-ast.json"

  echo "=== oracle mint: $name ==="
  BEAGLE_EMIT_SRCLOC=0 bin/beagle-build "$src" "$oracle" >/dev/null 2>&1 || { bad "$name racket emit (oracle mint)"; continue; }
  bin/beagle-ast "$src" > "$astj" 2>/dev/null || { bad "$name racket AST (oracle mint)"; continue; }

  echo "=== 2. emit parity (racket AST -> self emit) : $name ==="
  bb -cp "$OUT" -e "(require '[selfhost.emit-clj :as e] '[cheshire.core :as json]) (print (e/emit-program! (json/parse-string (slurp \"$astj\") false)))" > "$LAB/$name-stage2.clj" 2>"$LAB/$name-stage2.err"
  if diff -q "$oracle" "$LAB/$name-stage2.clj" >/dev/null 2>&1; then
    ok "$name emit byte-parity (stage-isolated)"
  else
    bad "$name emit byte-parity (stage-isolated) — diff $oracle $LAB/$name-stage2.clj"
  fi

  echo "=== 3. AST parity (self reader+parse vs beagle-ast) : $name ==="
  bb -cp "$OUT" -e "(require '[selfhost.reader :as r] '[selfhost.parse :as p] '[cheshire.core :as json]) (print (json/generate-string (p/parse-program! (r/read-program (slurp \"$src\")))))" > "$LAB/$name-self-ast.json" 2>"$LAB/$name-stage3.err"
  if python3 - "$LAB/$name-self-ast.json" "$astj" <<'EOF' >/dev/null 2>&1
import json, sys
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
# externs delta is a documented tranche-1 gap (no module resolution self-side)
sys.exit(0 if all(a.get(k) == b.get(k) for k in ["forms","requires","namespace","mode","target"]) else 1)
EOF
  then
    ok "$name AST parity (forms/requires/namespace/mode/target)"
  else
    bad "$name AST parity — compare $LAB/$name-self-ast.json vs $astj"
  fi

  echo "=== 4. full self-hosted chain (bb) vs racket emit : $name ==="
  bb -cp "$OUT" -m selfhost.main emit "$src" > "$LAB/$name-chain.clj" 2>"$LAB/$name-chain.err"
  if diff -q "$oracle" "$LAB/$name-chain.clj" >/dev/null 2>&1; then
    ok "$name FULL-CHAIN byte-parity"
  else
    bad "$name FULL-CHAIN byte-parity — diff $oracle $LAB/$name-chain.clj"
  fi
done

echo ""
echo "=== verify-selfhost: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
