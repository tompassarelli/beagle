#!/usr/bin/env bash
# Regression test + proof: beagle-repair consumes semantic suspicions as STRUCTURED
# records (blame.rkt's JSON), not by regex-scraping the prose SUSPECT line.
#
# Fixture: two functions both trip the "name implies aggregation — subtraction is
# suspicious" rule. `grand-total` parses under the old prose regex; `total=` has a
# valid name with '=' (outside the regex's char class) — the regex matches up to
# `total`, fails on `=`, and SILENTLY DROPS the whole suspicion. The structured
# path carries the function name verbatim and keeps both.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$HERE/../.." && pwd)"
CORPUS="$HERE/corpus"
VERIFY="$HERE/verify.bclj"
fail=0

sem_fns() {  # the function names of captured semantic suspicions, one per line
  grep -oE 'semantic-suspicion: [^ :]+' <<<"$1" | sed 's/semantic-suspicion: //' | sort -u
}

echo "================ beagle-repair semantic suspicions — structured vs prose ================"
echo "fixture: grand-total (regex-parseable) + total= (valid name, breaks the prose regex)"
echo

NEW_OUT="$("$BIN/beagle-repair" "$CORPUS" "$VERIFY" 2>&1 || true)"

check() {  # check <desc> <pattern> <want:yes|no>
  if grep -qE "$2" <<<"$NEW_OUT"; then have=yes; else have=no; fi
  if [[ "$have" == "$3" ]]; then echo "  PASS  $1"; else echo "  FAIL  $1 (wanted $3, got $have)"; fail=1; fi
}
echo "--- structured path (current beagle-repair) ---"
check "grand-total suspicion captured"                 'semantic-suspicion: grand-total' yes
check "total= suspicion captured (prose regex drops it)" 'semantic-suspicion: total='     yes

# --- side-by-side receipt against the pinned pre-migration (regex) beagle-repair -
OLD="$(git -C "$BIN" show "${REPAIR_BASELINE:-a8cf88a7930959120cbdd954bdc51bb5be2fa869}:bin/beagle-repair" 2>/dev/null || true)"
if [[ -n "$OLD" ]]; then
  # Run from the real bin/ so its dirname-based tool + helper-import lookups resolve.
  # It does NOT set BEAGLE_SEMANTIC_JSON, so the current blame.rkt falls back to the
  # prose SUSPECT line — exactly the pre-migration behaviour.
  TMP="$BIN/.repair-baseline.$$"; printf '%s' "$OLD" > "$TMP"; chmod +x "$TMP"
  OLD_OUT="$("$TMP" "$CORPUS" "$VERIFY" 2>&1 || true)"
  rm -f "$TMP"
  echo
  echo "================ RECEIPT — same fixture, two engines ================"
  echo "REGEX (pre-migration, scrapes the prose SUSPECT line) captured:"
  { sem_fns "$OLD_OUT" | sed 's/^/    /'; [[ -z "$(sem_fns "$OLD_OUT")" ]] && echo "    (none)"; }
  echo "STRUCTURED (consumes blame.rkt JSON records) captured:"
  sem_fns "$NEW_OUT" | sed 's/^/    /'
  echo
  if grep -q 'semantic-suspicion: total=' <<<"$OLD_OUT"; then
    echo "  FAIL  regex baseline unexpectedly captured total="; fail=1
  else
    echo "  The regex engine silently DROPPED total= (name has '='). Structured kept it."
  fi
else
  echo "(side-by-side receipt skipped: pre-migration beagle-repair not reachable in git)"
fi

echo
if [[ "$fail" == 0 ]]; then
  echo "RESULT: PASS — structured suspicions survive where the prose regex drops them."
else
  echo "RESULT: FAIL"; exit 1
fi
