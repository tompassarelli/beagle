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
# --promote. Set SELFHOST_OUT=/tmp/stage to verify an isolated authored-source
# compilation without changing the checked-in seed.
# Usage: self-host/verify-target-nix.sh [FIXTURE.bnix ...]
set -uo pipefail
WT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WT"
source bin/_beagle-racket
OUT="${SELFHOST_OUT:-self-host/seed}"
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
checked_only = {"provenance", "inferredType", "effectiveType", "raises",
                "constraintSynchronous", "recordUpdate", "recordFieldAccess"}
def parser_shape(value):
    if isinstance(value, dict):
        return {
            key: parser_shape(item)
            for key, item in value.items()
            if key not in checked_only and not (key == "doc" and item is False)
        }
    if isinstance(value, list):
        return [parser_shape(item) for item in value]
    return value
same_forms = parser_shape(a.get("forms")) == parser_shape(b.get("forms"))
same_meta = all(a.get(k) == b.get(k) for k in ["requires","imports","namespace","mode","target"])
sys.exit(0 if same_forms and same_meta else 1)
EOF
  then
    ok "$name AST parity (forms/requires/imports/namespace/mode/target)"
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

echo "=== 4b. known-valid oracle build control ==="
VALID_ORACLE_CONTROL=beagle-test/tests/fixtures/nix-simple-pkg.bnix
oracle_builder_ready=0
control_out="$LAB/nix-valid-oracle-control.nix"
control_stdout="$LAB/nix-valid-oracle-control.out"
control_stderr="$LAB/nix-valid-oracle-control.err"
if BEAGLE_EMIT_SRCLOC=0 bin/beagle-build "$VALID_ORACLE_CONTROL" "$control_out" \
    >"$control_stdout" 2>"$control_stderr"; then
  ok "known-valid nix oracle control emits"
  oracle_builder_ready=1
else
  bad "known-valid nix oracle control failed — inspect $control_stderr"
  sed -n '1,8p' "$control_stderr" >&2
fi

echo "=== 5. E021 free-dotted-name — oracle + selfhost must BOTH reject ==="
if [ -f "$FREE_DOTTED" ]; then
  oracle_out="$LAB/nix-free-dotted-oracle.nix"
  oracle_stdout="$LAB/nix-free-dotted-oracle.out"
  oracle_stderr="$LAB/nix-free-dotted-oracle.err"
  selfhost_out="$LAB/nix-free-dotted-selfhost.out"
  if [ "$oracle_builder_ready" -ne 1 ]; then
    bad "nix-free-dotted oracle rejection not evaluated (known-valid build control failed)"
  elif BEAGLE_EMIT_SRCLOC=0 bin/beagle-build "$FREE_DOTTED" "$oracle_out" \
      >"$oracle_stdout" 2>"$oracle_stderr"; then
    bad "nix-free-dotted oracle accepted (should reject E021) — emitted $oracle_out"
  elif sh_main check --target nix "$FREE_DOTTED" >"$selfhost_out" 2>&1; then
    bad "nix-free-dotted selfhost accepted (should reject E021) — inspect $selfhost_out"
  else
    ok "nix-free-dotted E021 rejected (oracle + selfhost, exit nonzero)"
  fi
fi

echo ""
echo "=== verify-target-nix: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
