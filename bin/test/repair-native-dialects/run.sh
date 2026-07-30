#!/usr/bin/env bash
# Regression test: beagle_repair_apply.resolve_source_file locates native-dialect
# (.bzig/.bodin/.bsc) source files for fix-plan application.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$HERE/../.." && pwd)"
CORPUS="$HERE/corpus"
VERIFY="$HERE/verify.bclj"
fail=0

source "$BIN/_beagle-racket"

echo "================ beagle-repair native-dialect (.bzig) resolution ================"
echo "fixture: badadd.bzig (arity error) + shape.bzig (non-exhaustive match, auto-fix)"
echo

echo "--- structured diagnostic names the .bzig file directly ---"
CHECK_JSON="$(BEAGLE_FIX_PLAN=1 BEAGLE_ERROR_FORMAT=json BEAGLE_SEMANTIC_JSON=1 "$BIN/beagle-check-all" "$CORPUS" 2>&1)"
echo "$CHECK_JSON" | grep -o '"file":"[^"]*shape\.bzig"' | head -1

check() {  # check <desc> <pattern> <want:yes|no>
  if grep -qE "$2" <<<"$1"; then have=yes; else have=no; fi
  if [[ "$have" == "$3" ]]; then echo "  PASS  $4"; else echo "  FAIL  $4 (wanted $3, got $have)"; fail=1; fi
}
check "$CHECK_JSON" '"file":"[^"]*shape\.bzig".*"kind":"exhaustive-match"' yes "diagnostic names shape.bzig with a fix_plan"
check "$CHECK_JSON" '"file":"[^"]*badadd\.bzig".*"kind":"arity"' yes "diagnostic names badadd.bzig with a fix_plan"

echo
echo "--- resolver locates the .bzig source for fix-plan application (--emit-patch) ---"
PATCH_OUT="$("$BIN/beagle-repair" "$CORPUS" "$VERIFY" --emit-patch --threshold 0.85 2>&1 || true)"
echo "$PATCH_OUT" | grep -A6 '^--- a/shape.bzig'
check "$PATCH_OUT" '^\+\+\+ b/shape\.bzig' yes "resolver applied the auto-fix patch to shape.bzig"
check "$PATCH_OUT" 'handle Triangle' yes "patch inserts the missing Triangle clause"

echo
if [[ "$fail" == 0 ]]; then
  echo "RESULT: PASS — native-dialect (.bzig) diagnostics resolve back to source."
else
  echo "RESULT: FAIL"; exit 1
fi
