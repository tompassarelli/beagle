#!/usr/bin/env bash
# Scope-correctness test for graph-native cascade.
#
# The fixture defines `helper` in BOTH mod_a and mod_b, each with its own caller
# chain. Changing mod_a/helper must blast only mod_a (midA, topA); mod_b's helper
# and its callers must be untouched.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$HERE/../.." && pwd)"
CORPUS="$HERE/corpus"
VERIFY="$HERE/verify.bclj"
fail=0

RESOLVER_PROBE="$(mktemp -d)"
mkdir -p "$RESOLVER_PROBE/out" "$RESOLVER_PROBE/chartroom"
touch "$RESOLVER_PROBE/out/resolve.clj"
resolver_status=0
(
  FRAM_OUT="$RESOLVER_PROBE/out"
  CHARTROOM="$RESOLVER_PROBE/chartroom"
  source "$BIN/_fram-resolver"
  resolved="$(find_fram_resolver)" || exit 1
  [[ "$resolved" == "$FRAM_OUT/resolve.clj" ]]
) || resolver_status=$?
rm -rf "${RESOLVER_PROBE:?}"
if [[ "$resolver_status" -ne 0 ]]; then
  echo "cascade-graph: resolver did not honor FRAM_OUT/resolve.clj" >&2
  exit 1
fi

echo "================ graph-native cascade — collision fixture ================"
echo "fixture: helper defined in BOTH mod_a and mod_b; change ONLY mod_a/helper."
echo

# The graph result and the assertions that make it a proof.
GRAPH_ERR="$(mktemp)"
graph_status=0
GRAPH_OUT="$("$BIN/beagle-cascade" "$CORPUS" "$VERIFY" --modified mod_a/helper 2>"$GRAPH_ERR")" \
  || graph_status=$?
if [[ "$graph_status" -ne 0 || -z "$GRAPH_OUT" ]]; then
  cat "$GRAPH_ERR" >&2
  rm -f "$GRAPH_ERR"
  if [[ "$graph_status" -ne 0 ]]; then
    echo "cascade-graph: beagle-cascade failed (exit $graph_status)" >&2
  else
    echo "cascade-graph: beagle-cascade produced empty output" >&2
  fi
  exit 1
fi
rm -f "$GRAPH_ERR"

check() {  # check <description> <grep-pattern> <must-be-present:yes|no>
  local desc="$1" pat="$2" want="$3"
  if grep -qE "$pat" <<<"$GRAPH_OUT"; then have=yes; else have=no; fi
  if [[ "$have" == "$want" ]]; then
    echo "  PASS  $desc"
  else
    echo "  FAIL  $desc  (wanted $want, got $have)"; fail=1
  fi
}

echo "--- assertions on the graph result (change mod_a/helper) ---"
check "mod_a/midA is in the blast radius"        'direct callers:.*mod_a/midA' yes
check "a-result is predicted at risk"            'a-result' yes
check "mod_b/midB is NOT in the blast radius"    'mod_b/midB' no
check "mod_b is NOT mentioned at all"            'mod_b'      no
check "b-result is NOT predicted at risk"        'b-result'   no
check "risks exactly ONE assertion"              'risks 1 assertion' yes
echo

echo
if [[ "$fail" == 0 ]]; then
  echo "RESULT: PASS — graph-native cascade is scope-correct on the collision."
else
  echo "RESULT: FAIL"; exit 1
fi
