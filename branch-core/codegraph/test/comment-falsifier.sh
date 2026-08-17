#!/usr/bin/env bash
# ============================================================================
# Turtle #6 falsifier — comments as RESOLVED references.
# ============================================================================
# The load-bearing claim: a doc comment's identifier mentions follow a rename
# *scope-correctly*, while substrings and quoted strings do NOT — the thing a
# text/sed rename structurally cannot do. Rename `red`->`crimson` in module A:
#   A's comment:  both `red` mentions -> `crimson`
#                 `red-zone` UNTOUCHED  (a \bred\b sed corrupts it to crimson-zone)
#                 "red"      UNTOUCHED  (a quoted string is not a symbol mention)
#   B's comment:  `red` UNCHANGED      (B's red is a different binding node)
# Any divergence falsifies the claim and fails the gate.
set -o pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BR="${BEAGLE:-$HOME/code/beagle/main}/bin/beagle-roundtrip"
FRAM="${FRAM:-$(cd "$HERE/.." && pwd)}"
A="$HERE/test/cmt-a.bjs"; B="$HERE/test/cmt-b.bjs"

"$BR" --emit-edn "$A" > /tmp/cf-a.edn 2>/dev/null
"$BR" --emit-edn "$B" > /tmp/cf-b.edn 2>/dev/null
bb -cp "$FRAM/out" "$FRAM/out/resolve.clj" rename red crimson cmt-a /tmp/cf-a.edn /tmp/cf-b.edn >/dev/null 2>&1
RA="$("$BR" --render /tmp/resolved-cmt-a.bjs.edn 2>/dev/null)"
RB="$("$BR" --render /tmp/resolved-cmt-b.bjs.edn 2>/dev/null)"

fails=0
check(){ # <description> <haystack> <grep-pattern> <expect: yes|no>
  local desc="$1" hay="$2" pat="$3" want="$4"
  if echo "$hay" | grep -qF "$pat"; then got=yes; else got=no; fi
  if [[ "$got" == "$want" ]]; then printf "  PASS  %s\n" "$desc"
  else printf "  FAIL  %s  (wanted %s, got %s)\n" "$desc" "$want" "$got"; fails=$((fails+1)); fi
}

echo "── module A (renamed red->crimson) ─────────────────────────────────────────"
check "comment: 'the red path'   -> 'the crimson path'"      "$RA" "the crimson path"      yes
check "comment: 'keep red fast'  -> 'keep crimson fast'"     "$RA" "keep crimson fast"     yes
check "comment: 'red-zone' substring UNTOUCHED"              "$RA" "red-zone"              yes
check "comment: quoted \"red\" UNTOUCHED"                    "$RA" '"red"'                 yes
check "comment: no stale bare 'crimson-zone' corruption"     "$RA" "crimson-zone"          no
check "code:    (defn crimson ...) renamed"                  "$RA" "(defn crimson"         yes
check "code:    no leftover (defn red"                       "$RA" "(defn red"             no

echo "── module B (NOT targeted — scope-correct) ─────────────────────────────────"
check "comment: B's 'red' mentions UNCHANGED"                "$RB" "mention red here, must stay red" yes
check "comment: B never says crimson"                        "$RB" "crimson"               no
check "code:    B's (defn red ...) UNCHANGED"                "$RB" "(defn red"             yes

echo "────────────────────────────────────────────────────────────────────────────"
if [[ $fails -eq 0 ]]; then
  echo "TURTLE #6 FALSIFIER: PASS — comments rename scope-correctly; substrings/strings/other-scope untouched."
  exit 0
else
  echo "TURTLE #6 FALSIFIER: FAIL — $fails assertion(s) falsified."
  exit 1
fi
