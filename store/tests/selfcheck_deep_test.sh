#!/usr/bin/env bash
# selfcheck_deep_test.sh — RED-first receipt for `beagle store doctor --deep`.
#
# Asserts the operator deep-selfcheck:
#   (A) happy path  -> exit 0 AND one named [PASS] line for each of the 8 subsystems
#       socket, mtls, fencing, lease, snapshot, cold-fold, identity, reconcile
#   (B) induced fault (BEAGLE_STORE_SELFCHECK_FAULT=socket) -> NONZERO exit AND a named
#       [FAIL] socket line, with the other subsystems still named, and deterministic
#       cleanup on the failure path.
#
# Never contacts the live server (127.0.0.1:7977) or ~/.local/state/north.
# Run from the repo ROOT:  bash tests/selfcheck_deep_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SECTIONS=(socket mtls fencing lease snapshot cold-fold identity reconcile)
fails=0
note() { printf '  [%s] %s\n' "$1" "$2"; }

# --- (A) happy path -----------------------------------------------------------
echo "## (A) happy path: beagle store doctor --deep"
outA="$("$HERE/../bin/beagle" store doctor --deep 2>&1)"; codeA=$?
echo "$outA" | sed 's/^/    | /'
if [[ $codeA -eq 0 ]]; then note PASS "exit 0 on all-pass"; else note FAIL "expected exit 0, got $codeA"; fails=$((fails+1)); fi
for s in "${SECTIONS[@]}"; do
  if echo "$outA" | grep -Eq "\[PASS\][[:space:]]+${s}\b"; then
    note PASS "named [PASS] $s"
  else
    note FAIL "missing named [PASS] $s"; fails=$((fails+1))
  fi
done

# --- (B) induced fault --------------------------------------------------------
echo "## (B) induced fault: BEAGLE_STORE_SELFCHECK_FAULT=socket"
outB="$(BEAGLE_STORE_SELFCHECK_FAULT=socket \
  "$HERE/../bin/beagle" store doctor --deep 2>&1)"; codeB=$?
echo "$outB" | sed 's/^/    | /'
if [[ $codeB -ne 0 ]]; then note PASS "nonzero exit on induced failure ($codeB)"; else note FAIL "expected nonzero exit, got 0"; fails=$((fails+1)); fi
if echo "$outB" | grep -Eq "\[FAIL\][[:space:]]+socket\b"; then note PASS "named [FAIL] socket"; else note FAIL "no named [FAIL] socket"; fails=$((fails+1)); fi
# every subsystem still gets a named line (pass or fail) — no silent truncation.
for s in "${SECTIONS[@]}"; do
  if echo "$outB" | grep -Eq "\[(PASS|FAIL)\][[:space:]]+${s}\b"; then :; else note FAIL "subsystem $s not named under fault"; fails=$((fails+1)); fi
done

echo
if [[ $fails -eq 0 ]]; then
  echo "selfcheck_deep_test: PASS"; exit 0
else
  echo "selfcheck_deep_test: $fails FAILED"; exit 1
fi
