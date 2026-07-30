#!/usr/bin/env bash
# Regression test + proof artifact for graph-native cascade.
#
# The fixture defines `helper` in BOTH mod_a and mod_b, each with its own caller
# chain. Changing mod_a/helper must blast ONLY mod_a (midA, topA); mod_b's helper
# and its callers must be untouched. A bare-symbol (regex) call graph cannot tell
# the two `helper`s apart and wrongly blasts both modules.
#
# This script:
#   1. runs the CURRENT (graph-native) cascade and ASSERTS scope-correctness,
#   2. (if a pre-migration regex cascade is reachable in git) renders the two
#      result sets side by side on the identical collision case — the receipt.
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

# --- 1. the graph result, and the assertions that make it a proof ----------
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

# --- 2. the side-by-side receipt (best-effort: needs the old regex cascade) -
# Default baseline = the pre-migration (regex) cascade, pinned by SHA so the
# side-by-side stays meaningful after main fast-forwards onto the graph version.
OLD="$(git -C "$BIN" show "${CASCADE_BASELINE:-4203c1be6c9b529dba169e2e7cc50bdb4324eada}:bin/beagle-cascade" 2>/dev/null || true)"
if [[ -n "$OLD" ]]; then
  # Run the baseline FROM the real bin/ so its dirname-based tool lookups
  # (beagle-provides) resolve — a /tmp copy would find no functions.
  TMP="$BIN/.cascade-baseline.$$"; printf '%s' "$OLD" > "$TMP"; chmod +x "$TMP"
  # the regex tool has no module concept — the equivalent query is bare `helper`.
  REGEX_OUT="$("$TMP" "$CORPUS" "$VERIFY" --modified helper 2>/dev/null || true)"
  rm -f "$TMP"
  echo "================ RECEIPT — same fixture, same change, two engines ================"
  echo "QUERY: change \`helper\` in mod_a."
  echo
  echo "REGEX (pre-migration, bare-symbol) — direct callers + predicted failures:"
  grep -E 'direct callers:|a-result|b-result|Summary:' <<<"$REGEX_OUT" | sed 's/^/    /'
  echo
  echo "GRAPH (scope-correct, off the Fram calls-graph):"
  grep -E 'direct callers:|a-result|b-result|Summary:' <<<"$GRAPH_OUT" | sed 's/^/    /'
  echo
  echo "The regex engine pulls mod_b/midB into the blast of a function it never"
  echo "touched and predicts b-result fails. The graph engine leaves mod_b alone."
else
  echo "(side-by-side receipt skipped: no pre-migration cascade reachable at"
  echo " \${CASCADE_BASELINE:-main}:bin/beagle-cascade — the assertions above still gate.)"
fi

echo
if [[ "$fail" == 0 ]]; then
  echo "RESULT: PASS — graph-native cascade is scope-correct on the collision."
else
  echo "RESULT: FAIL"; exit 1
fi
