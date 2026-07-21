#!/usr/bin/env bash
# verify-target-nix: oracle ladder for the self-hosted NIX backend.
#
# Mirrors verify-selfhost.sh, retargeted to nix. Each rung isolates one stage
# against the Racket compiler as oracle; the frozen conformance goldens under
# beagle-test/conformance/expected/nix/ are the byte-parity truth.
#
#   1. module self-tests under bb (parse / check / emit-nix)
#   2. emit parity, stage-isolated : Racket AST -> self emit-nix vs golden
#   3. AST parity                  : self reader+parse vs bin/beagle-ast
#   4. full chain                  : selfhost.main emit --target nix vs golden
#   5. E021 free-dotted-name       : selfhost + oracle both REJECT the ratchet
#
# Runs against the blessed seed (self-host/seed) — run after bin/beagle-remint
# --promote. Usage: self-host/verify-target-nix.sh [FIXTURE.bnix ...]
set -uo pipefail
WT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WT"
source bin/_beagle-racket
OUT=self-host/seed
LAB=.lab
GOLD=beagle-test/conformance/expected/nix
mkdir -p "$LAB"

# A checkout-local native is mutable build output. Use it only when its seed
# provenance sidecar matches this checkout; otherwise use the current seed.
# The stage-isolated -e evals (rungs 1-3) stay bb — native exposes only the CLI.
source self-host/native/stage0-select.sh
beagle_select_stage0 "$OUT" self-host/native/beagle-selfhost || exit $?
sh_main() { # selfhost CLI: <subcommand> [args...]
  if [ "$STAGE0" = native ]; then "$NATIVE_BIN" "$@"; else bb -cp "$OUT" -m selfhost.main "$@"; fi
}
beagle_stage0_banner "$OUT"

FIXTURES=("$@")
if [ ${#FIXTURES[@]} -eq 0 ]; then
  FIXTURES=(beagle-test/tests/fixtures/nix-*.bnix)
fi
# The E021 ratchet fixture (a `reject` corpus entry, not an emit golden).
FREE_DOTTED=beagle-test/conformance/corpus/nix-free-dotted.bnix

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== 1. module self-tests (bb) ==="
for m in parse check emit-nix; do
  ns="selfhost.$m"
  f="$OUT/selfhost/$(echo "$m" | tr '-' '_').clj"
  if [ ! -f "$f" ]; then bad "$m (not built: $f)"; continue; fi
  if bb -cp "$OUT" -e "(require '[$ns :as m]) (System/exit (m/run-tests!))" >/dev/null 2>&1; then
    ok "$m self-tests"
  else
    bad "$m self-tests"
  fi
done

for src in "${FIXTURES[@]}"; do
  name="$(basename "$src" .bnix)"
  gold="$GOLD/$name.nix"
  astj="$LAB/$name-nix-ast.json"
  [ -f "$gold" ] || { echo "=== skip $name (no golden) ==="; continue; }

  echo "=== oracle AST mint: $name ==="
  bin/beagle-ast "$src" > "$astj" 2>/dev/null || { bad "$name racket AST (oracle mint)"; continue; }

  echo "=== 2. emit parity (racket AST -> self emit-nix) : $name ==="
  bb -cp "$OUT" -e "(require '[selfhost.emit-nix :as e] '[cheshire.core :as json]) (print (e/emit-program! (json/parse-string (slurp \"$astj\") false)))" > "$LAB/$name-nix-stage2.nix" 2>"$LAB/$name-nix-stage2.err"
  if diff -q "$gold" "$LAB/$name-nix-stage2.nix" >/dev/null 2>&1; then
    ok "$name emit byte-parity (stage-isolated)"
  else
    bad "$name emit byte-parity (stage-isolated) — diff $gold $LAB/$name-nix-stage2.nix"
  fi

  echo "=== 3. AST parity (self reader+parse vs beagle-ast) : $name ==="
  bb -cp "$OUT" -e "(require '[selfhost.reader :as r] '[selfhost.parse :as p] '[cheshire.core :as json]) (print (json/generate-string (p/parse-program! (r/read-program (slurp \"$src\")))))" > "$LAB/$name-nix-self-ast.json" 2>"$LAB/$name-nix-stage3.err"
  if python3 - "$LAB/$name-nix-self-ast.json" "$astj" <<'EOF' >/dev/null 2>&1
import json, sys
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
sys.exit(0 if all(a.get(k) == b.get(k) for k in ["forms","requires","namespace","mode","target"]) else 1)
EOF
  then
    ok "$name AST parity (forms/requires/namespace/mode/target)"
  else
    bad "$name AST parity — compare $LAB/$name-nix-self-ast.json vs $astj"
  fi

  echo "=== 4. full self-hosted chain ($STAGE0) vs golden : $name ==="
  sh_main emit --target nix "$src" > "$LAB/$name-nix-chain.nix" 2>"$LAB/$name-nix-chain.err"
  if diff -q "$gold" "$LAB/$name-nix-chain.nix" >/dev/null 2>&1; then
    ok "$name FULL-CHAIN byte-parity"
  else
    bad "$name FULL-CHAIN byte-parity — diff $gold $LAB/$name-nix-chain.nix"
  fi
done

echo "=== 5. E021 free-dotted-name — oracle + selfhost must BOTH reject ==="
if [ -f "$FREE_DOTTED" ]; then
  if BEAGLE_EMIT_SRCLOC=0 bin/beagle-build "$FREE_DOTTED" /dev/null >/dev/null 2>&1; then
    bad "nix-free-dotted oracle accepted (should reject E021)"
  elif sh_main check --target nix "$FREE_DOTTED" >/dev/null 2>&1; then
    bad "nix-free-dotted selfhost accepted (should reject E021)"
  else
    ok "nix-free-dotted E021 rejected (oracle + selfhost, exit nonzero)"
  fi
fi

echo ""
echo "=== verify-target-nix: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
