#!/usr/bin/env bash
# beagle-repair consumes semantic suspicions as structured
# records (blame.rkt's JSON), not by regex-scraping the prose SUSPECT line.
#
# Fixture: two functions both trip the "name implies aggregation — subtraction is
# suspicious" rule. The structured path must carry both function names verbatim,
# including the valid `=` suffix in `total=`.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$HERE/../.." && pwd)"
CORPUS="$HERE/corpus"
VERIFY="$HERE/verify.bclj"
fail=0

echo "================ beagle-repair semantic suspicions ================"
echo "fixture: grand-total + total= (valid names requiring exact preservation)"
echo

NEW_OUT="$("$BIN/beagle-repair" "$CORPUS" "$VERIFY" 2>&1 || true)"

check() {  # check <desc> <pattern> <want:yes|no>
  if grep -qE "$2" <<<"$NEW_OUT"; then have=yes; else have=no; fi
  if [[ "$have" == "$3" ]]; then echo "  PASS  $1"; else echo "  FAIL  $1 (wanted $3, got $have)"; fail=1; fi
}
echo "--- structured path (current beagle-repair) ---"
check "grand-total suspicion captured"                 'semantic-suspicion: grand-total' yes
check "total= suspicion captured exactly"               'semantic-suspicion: total='     yes

echo
if [[ "$fail" == 0 ]]; then
  echo "RESULT: PASS — structured suspicion names are preserved."
else
  echo "RESULT: FAIL"; exit 1
fi
