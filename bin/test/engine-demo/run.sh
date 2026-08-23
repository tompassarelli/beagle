#!/usr/bin/env bash
# Engine demo — ONE engine answers REASON and REPAIR consistently, on REAL code.
#
# The agent-facing loop, end-to-end on a current real Beagle Store owner and the exact
# qualified consumer forms shipped in two real Beagle Store modules:
#   NL: "what breaks if I change the term codec depth limit?" -> REASON
#   NL: "rename term-codec-v1-max-depth"                     -> REPAIR
# Both answers come from the SAME converged refers_to resolver. Loading the full
# consumer modules makes cold corpus-table construction exceed the fleet's gate
# ceiling, so this gate first proves the two current source forms still exist,
# then mirrors those exact forms into minimal hosted modules around a profile-only
# mirror of the real Core owner. The owner forms are unchanged; only its #lang is
# selected explicitly so the repaired overlay can compile against the full,
# unchanged Beagle Store module root. Gate 3 separately proves full-corpus identity.
set -euo pipefail
export RESOLVE_OUT="$(mktemp -d)"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RT="$ROOT/beagle-lib/private/facts-roundtrip.rkt"
source "$ROOT/bin/_beagle-racket"
BEAGLE_STORE_ROOT="$ROOT/store"
BEAGLE_STORE_OUT="${BEAGLE_STORE_OUT:-$BEAGLE_STORE_ROOT/out}"
source "$ROOT/bin/_beagle-store-resolver"
SRC="${CODE_AS_FACTS_CORPUS:-$BEAGLE_STORE_ROOT/src}"
export BEAGLE_STORE_OUT
fail=0

TARGET=term-codec-v1-max-depth
REPLACEMENT=engine-demo-max-depth
TARGET_MODULE=store.rpc-limits
TARGET_SCOPE=rpc_limits
TARGET_FILE="$SRC/store/rpc_limits.bgl"

echo "================ engine demo — one engine: REASON + REPAIR on real code ================"
[ -d "$BEAGLE_STORE_OUT" ] || { echo "  (need BEAGLE_STORE_OUT)"; exit 3; }
RES="$(find_store_resolver)" || exit 3
[ -d "$SRC" ] || { echo "  (need store/src)"; exit 3; }
[ -f "$TARGET_FILE" ] || { echo "  FAIL  missing real target: $TARGET_FILE"; exit 1; }
chk() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi; }
W="$(mktemp -d)"; trap 'rm -rf "${W:?}" "${RESOLVE_OUT:?}"' EXIT

chk "current target exists exactly once and replacement is absent" \
    "[ \"\$(grep -hF '(def $TARGET' '$TARGET_FILE' | wc -l)\" -eq 1 ] && ! grep -Rqw '$REPLACEMENT' '$SRC'"
chk "two current real Beagle Store modules consume the target with these exact forms" \
    "grep -Fq '(def term-codec-v1-depth-limit Int limits/$TARGET)' '$SRC/store_rpc.bclj' && grep -Fq '(def rpc-v2-max-term-depth Int limits/$TARGET)' '$SRC/store/native_wire_codec.bgl'"

mkdir -p "$W/slice"
sed '1s/^#lang beagle$/#lang beagle\/clj/' "$TARGET_FILE" > "$W/slice/rpc_limits.bclj"
cat > "$W/slice/store_rpc_consumer.bclj" <<EOF
#lang beagle/clj
(ns engine-demo.store.rpc)
(require [store.rpc-limits :as limits])
(def term-codec-v1-depth-limit Int limits/$TARGET)
EOF
cat > "$W/slice/native_wire_consumer.bclj" <<EOF
#lang beagle/clj
(ns engine-demo.native-wire-codec)
(require [store.rpc-limits :as limits])
(def rpc-v2-max-term-depth Int limits/$TARGET)
EOF
SOURCES=("$W/slice/rpc_limits.bclj" "$W/slice/store_rpc_consumer.bclj" "$W/slice/native_wire_consumer.bclj")
EXPECTED="engine-demo.store.rpc engine-demo.native-wire-codec"

# ---- REASON: scope-correct call graph over the bounded current seam -----------------
echo '--- NL: "what breaks if I change store.rpc-limits/term-codec-v1-max-depth?" -> REASON ---'
BLAST_MODS="$("$ROOT/bin/beagle-callgraph" "$W/slice" | python3 -c "
import json,sys
d=json.load(sys.stdin); nm={x['key']:(x['name'],x['module']) for x in d['defns']}
keys=[k for k,(n,m) in nm.items() if n=='$TARGET' and m=='$TARGET_MODULE']
mods=set(); defs=set()
for k in keys:
    for caller in d['blast'].get(k,[]):
        name,module=nm[caller]; mods.add(module); defs.add(name)
print('MODS '+' '.join(sorted(mods)))
print('  reasoning: changing $TARGET_MODULE/$TARGET impacts %d binding(s) across modules %s' % (len(defs), sorted(mods)), file=sys.stderr)
")"
MODS="$(grep '^MODS' <<<"$BLAST_MODS" | sed 's/^MODS //')"
chk "blast radius includes both current consumer modules" \
    "grep -qw 'engine-demo.store.rpc' <<<\"\$MODS\" && grep -qw 'engine-demo.native-wire-codec' <<<\"\$MODS\""

# ---- REPAIR: rename across the same bounded current seam ----------------------------
echo '--- NL: "rename term-codec-v1-max-depth to engine-demo-max-depth" -> REPAIR ---'
mkdir -p "$W/e" "$W/regen"
edns=(); repaired=()
for f in "${SOURCES[@]}"; do
  b="$(basename "$f")"
  "$RACKET" "$RT" --emit-edn "$f" > "$W/e/$b.edn"
  edns+=("$W/e/$b.edn")
  repaired+=("$W/regen/$b")
done
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename "$TARGET" "$REPLACEMENT" "$TARGET_SCOPE" "${edns[@]}"
for f in "${SOURCES[@]}"; do
  b="$(basename "$f")"
  "$RACKET" "$RT" --render "$RESOLVE_OUT/resolved-$b.edn" > "$W/regen/$b"
done
chk "target definition and every qualified consumer were rewritten" \
    "grep -qF '(def $REPLACEMENT' '$W/regen/rpc_limits.bclj' && ! grep -RqhF '/$TARGET' '$W/regen' && [ \"\$(grep -RhlF '/$REPLACEMENT' '$W/regen' | wc -l)\" -eq 2 ]"
if "$ROOT/bin/beagle-build-all" "${repaired[@]}" \
    --module-root corpus="$SRC" --out "$W/o" > "$W/build.log" 2>&1 \
    && grep -q '0 error' "$W/build.log"; then
  echo "  PASS  repaired hosted mirror recompiles against the full Beagle Store module root"
else
  sed -n '1,160p' "$W/build.log" >&2
  echo "  FAIL  repaired hosted mirror recompiles against the full Beagle Store module root"
  fail=1
fi

# ---- TIE: reasoning predicted repair's reach (same engine) ---------------------------
echo '--- the payoff: every module the REPAIR rewrote is within the REASON blast radius ---'
TOUCHED="$(grep -rlF "/$REPLACEMENT" "$W/regen" | while read -r f; do grep -m1 '^(ns ' "$f" | sed 's/^(ns \([^ )]*\).*/\1/'; done | sort -u | tr '\n' ' ')"
echo "    reason -> impacted modules: [$MODS]"
echo "    repair -> rewrote modules:  [$TOUCHED]"
miss=0
for m in $TOUCHED; do grep -qw "$m" <<<"$MODS" || miss=1; done
chk "repair rewrote every selected consumer module" \
    "[ \"\$(tr ' ' '\n' <<<\"\$TOUCHED\" | sed '/^\$/d' | sort)\" = \"\$(tr ' ' '\n' <<<\"\$EXPECTED\" | sed '/^\$/d' | sort)\" ]"
chk "repair's cross-module reach is within reasoning's blast radius" "[ $miss -eq 0 ]"

echo
if [ "$fail" = 0 ]; then
  echo "RESULT: PASS — one resolver's blast radius predicted the current cross-module rename,"
  echo "        both real consumer forms were repaired, and the overlay recompiled."
else
  echo "RESULT: FAIL"; exit 1
fi
