#!/usr/bin/env bash
# Engine demo — ONE engine answers REASON and REPAIR consistently, on REAL code.
#
# The agent-facing loop, end-to-end on fram/src (real multi-module beagle):
#   NL: "what breaks if I change fram.store/value! ?"  -> REASON: blast radius (call graph)
#   NL: "rename value! to intern!"                   -> REPAIR: scope-correct cross-module rename
# Both answers come from the SAME converged refers_to resolver (chartroom resolve.clj):
# reasoning (read) derives the blast radius; repair (write) performs the cascade. The payoff
# this gate asserts: the rename's cross-module reach is EXACTLY within the reasoning's
# blast radius — reasoning predicts repair, because they are the same engine. And the
# repaired tree recompiles. Needs racket + bb + fram out/ + chartroom + fram/src.
set -uo pipefail
export RESOLVE_OUT="$(mktemp -d)"   # hermetic: per-run render output (no global /tmp collision)

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RT="$ROOT/beagle-lib/private/facts-roundtrip.rkt"
FRAM_OUT="${FRAM_OUT:-$HOME/code/fram/out}"
CHARTROOM="${CHARTROOM:-$HOME/code/fram/chartroom}"
RES="$CHARTROOM/src/resolve.clj"
SRC="${CODE_AS_FACTS_CORPUS:-$HOME/code/fram/src}"
export FRAM_OUT CHARTROOM
fail=0

echo "================ engine demo — one engine: REASON + REPAIR on real code ================"
[ -d "$FRAM_OUT" ] || { echo "  (need FRAM_OUT)"; exit 3; }
[ -f "$RES" ]     || { echo "  (need CHARTROOM resolve.clj)"; exit 3; }
[ -d "$SRC" ]     || { echo "  (need fram/src)"; exit 3; }
chk() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi; }
W="$(mktemp -d)"; trap 'rm -rf "$W" $RESOLVE_OUT/resolved-*.edn' EXIT

# ---- REASON: blast radius of fram.store/value! (the call graph, cross-module) ---------
echo '--- NL: "what breaks if I change fram.store/value! ?"  -> REASON (blast radius) ---'
BLAST_MODS="$("$ROOT/bin/beagle-callgraph" "$SRC" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); nm={x['key']:(x['name'],x['module']) for x in d['defns']}
vk=[k for k,(n,m) in nm.items() if n=='value!' and m=='fram.store']
mods=set(); defs=set()
for k in vk:
    for b in d['blast'].get(k,[]):
        n,m=nm[b]; mods.add(m); defs.add(n)
print('MODS '+' '.join(sorted(mods)))
print('  reasoning: changing fram.store/value! impacts %d function(s) across modules %s:' % (len(defs), sorted(mods)), file=sys.stderr)
print('   ', sorted(defs), file=sys.stderr)
")"
echo "$BLAST_MODS" | grep -v '^MODS' >&2 || true
MODS="$(grep '^MODS' <<<"$BLAST_MODS" | sed 's/^MODS //')"
chk "blast radius is non-empty AND cross-module (impacts a module other than fram.store)" \
    "[ -n \"\$MODS\" ] && grep -qv 'fram.store' <<<\"\$(tr ' ' '\n' <<<\"\$MODS\")\""

# ---- REPAIR: rename value! -> intern! across fram/src (the cascade) -------------------
echo '--- NL: "rename fram.store/value! to intern!"  -> REPAIR (scope-correct cross-module rename) ---'
E="$W/e"; mkdir -p "$E" "$W/regen"; edns=()
while IFS= read -r f; do b="$(basename "$f")"; racket "$RT" --emit-edn "$f" 2>/dev/null > "$E/$b.edn"; edns+=("$E/$b.edn"); done < <(find "$SRC" -name '*.bclj' | sort)
bb -cp "$FRAM_OUT" "$RES" rename value! intern! store "${edns[@]}" 2>/dev/null
while IFS= read -r f; do b="$(basename "$f")"; racket "$RT" --render "$RESOLVE_OUT/resolved-$b.edn" 2>/dev/null > "$W/regen/$b"; done < <(find "$SRC" -name '*.bclj' | sort)
chk "repair recompiles (the renamed tree builds clean)" \
    "\"$ROOT/bin/beagle-build-all\" '$W/regen' --out '$W/o' 2>&1 | grep -q '0 error'"
chk "cross-module readers rewritten c/value! -> c/intern!" \
    "! grep -rqh '/value!' '$W/regen/' && grep -rqh '/intern!' '$W/regen/'"

# ---- TIE: reasoning predicted repair's reach (same engine) ---------------------------
echo '--- the payoff: every module the REPAIR rewrote is within the REASON blast radius ---'
# modules whose files contain a renamed cross-module c/intern! call site:
TOUCHED="$(grep -rl '/intern!' "$W/regen/" 2>/dev/null | while read -r f; do grep -m1 '^(ns ' "$f" | sed 's/^(ns \([^ )]*\).*/\1/'; done | sort -u | tr '\n' ' ')"
echo "    reason → impacted modules: [$MODS]"
echo "    repair → rewrote modules:  [$TOUCHED]"
miss=0
for m in $TOUCHED; do grep -qw "$m" <<<"$MODS" || { [ "$m" = "fram.store" ] || miss=1; }; done
chk "repair's cross-module reach ⊆ reasoning's blast radius (one engine, consistent)" "[ $miss -eq 0 ]"

echo
if [ "$fail" = 0 ]; then
  echo "RESULT: PASS — one engine answered both: blast radius (reason) predicted the rename's"
  echo "        cross-module reach (repair), and the repaired tree recompiles. Real code, one resolver."
else echo "RESULT: FAIL"; exit 1; fi
