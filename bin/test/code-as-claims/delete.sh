#!/usr/bin/env bash
# Delete as a graph operation — the no-orphaned-references invariant.
#
# The second verb in the authoring vocabulary (after rename). Deleting a def is a
# claim edit on the canonical store, gated by a REASONING query the graph can answer
# exactly and text cannot: "does any reference point at this binding?" (refers_to).
#   - SAFE (no references): remove the def's form + project; the rest of the file
#     survives (the renderer reads fN children consecutively, so the engine must
#     RENUMBER to close the gap — a naive edge-drop would truncate the file) and
#     recompiles.
#   - UNSAFE (a reference would be orphaned, in THIS module or a CONSUMER via alias):
#     refuse, mutate nothing (fail closed).
# Needs racket + bb + fram out/ + chartroom resolve.clj.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RT="$ROOT/beagle-lib/private/claims-roundtrip.rkt"
FRAM_OUT="${FRAM_OUT:-$HOME/code/fram/out}"
CHARTROOM="${CHARTROOM:-$HOME/code/chartroom}"
RES="$CHARTROOM/src/resolve.clj"
CORP="$HERE/delete-corpus"
fail=0

echo "================ delete as a graph op — no-orphaned-references invariant ================"
[ -d "$FRAM_OUT" ] || { echo "  (need FRAM_OUT)"; exit 3; }
[ -f "$RES" ]     || { echo "  (need CHARTROOM resolve.clj)"; exit 3; }
chk() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi; }
W="$(mktemp -d)"; trap 'rm -rf "$W" /tmp/resolved-*.edn' EXIT

# --- 1. SAFE delete: remove an unreferenced def; before/after forms survive --------
echo "--- 1. safe delete (unreferenced 'dead'; 'before'/'after' survive, recompiles) ---"
racket "$RT" --emit-edn "$CORP/del_unused.bclj" 2>/dev/null > "$W/u.edn"
bb -cp "$FRAM_OUT" "$RES" delete dead unused "$W/u.edn" 2>/dev/null
du="$(racket "$RT" --render /tmp/resolved-del_unused.bclj.edn 2>/dev/null)"
chk "'dead' def removed"                "! grep -q 'defn dead' <<<\"\$du\""
chk "'before' SURVIVES (no truncation)" "grep -q 'defn before' <<<\"\$du\""
chk "'after' SURVIVES (no truncation)"  "grep -q 'defn after' <<<\"\$du\""
printf '%s\n' "$du" > "$W/regen.bclj"
chk "deleted result recompiles"         "\"$ROOT/bin/beagle-build-all\" '$W/regen.bclj' --out '$W/o1' 2>&1 | grep -q '0 error'"

# --- 2. UNSAFE same-module: 'helper' is called by 'caller' -> refuse ----------------
echo "--- 2. same-module reference -> refuse (orphan) ---"
racket "$RT" --emit-edn "$CORP/del_used.bclj" 2>/dev/null > "$W/d.edn"
if bb -cp "$FRAM_OUT" "$RES" delete helper used "$W/d.edn" >/dev/null 2>&1; then
  echo "  FAIL  same-module orphan NOT refused"; fail=1
else echo "  PASS  same-module reference refuses delete (no-orphaned-refs)"; fi

# --- 3. UNSAFE cross-module: consumer refers l/shared -> refuse --------------------
echo "--- 3. cross-module reference (l/shared) -> refuse (orphan) ---"
racket "$RT" --emit-edn "$CORP/del_lib.bclj" 2>/dev/null > "$W/lib.edn"
racket "$RT" --emit-edn "$CORP/del_consumer.bclj" 2>/dev/null > "$W/con.edn"
if bb -cp "$FRAM_OUT" "$RES" delete shared lib "$W/lib.edn" "$W/con.edn" >/dev/null 2>&1; then
  echo "  FAIL  cross-module orphan NOT refused"; fail=1
else echo "  PASS  cross-module reference refuses delete (no-orphaned-refs)"; fi

echo
if [ "$fail" = 0 ]; then
  echo "RESULT: PASS — delete projects when safe (no truncation), refuses when a reference would orphan."
else echo "RESULT: FAIL"; exit 1; fi
