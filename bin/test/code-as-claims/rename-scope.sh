#!/usr/bin/env bash
# Scope-correct rename — the deferred local-shadowing gap, CLOSED.
#
# The name-based rename (rename-in-store) renames every same-named symbol leaf in a
# module, so it CORRUPTS a shadowing local (a param/let named like the def). The fix
# is identity, not spelling: chartroom's resolve.clj (Turtle #5) is a lexical
# resolver that adds `refers_to <binding-node-id>` edges (nearest enclosing scope),
# so renaming a DEF edits one node + references follow refers_to — a shadowing local
# is a DIFFERENT node and is left untouched. That is the principled "id-references"
# fix the deferral named, and it lives in chartroom = Layer 2 (the code-intelligence
# engine); this beagle gate drives it (a consumer renting the engine).
#
# Fixture: `helper` is a top-level def AND a shadowing param in `other`. Renaming the
# def must rename the def + the caller's reference, and leave the shadowing param
# (and its use) ALONE. Needs racket + bb + fram out/ + chartroom's resolve.clj.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RT="$ROOT/beagle-lib/private/claims-roundtrip.rkt"
FRAM_OUT="${FRAM_OUT:-$HOME/code/fram/out}"
CHARTROOM="${CHARTROOM:-$HOME/code/chartroom}"
RES="$CHARTROOM/src/resolve.clj"
fail=0

echo "================ scope-correct rename — shadowing handled (refers_to resolver) ================"
[ -d "$FRAM_OUT" ] || { echo "  (need FRAM_OUT)"; exit 3; }
[ -f "$RES" ]     || { echo "  (need chartroom resolve.clj at $RES — set CHARTROOM)"; exit 3; }

W="$(mktemp -d)"; trap 'rm -rf "$W" /tmp/resolved-mod.bclj.edn' EXIT
racket "$RT" --emit-edn "$HERE/shadow-corpus/mod.bclj" 2>/dev/null > "$W/a.edn"
# the Layer-2 engine: scope-correct rename of the DEF `helper` -> `safe-add`
bb -cp "$FRAM_OUT" "$RES" rename helper safe-add mod "$W/a.edn" 2>/dev/null
racket "$RT" --render /tmp/resolved-mod.bclj.edn 2>/dev/null > "$W/regen.bclj"
echo "--- rename result ---"; sed 's/^/    /' "$W/regen.bclj"

R="$W/regen.bclj"
chk() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi; }
echo "--- assertions ---"
chk "def renamed: '(defn safe-add'"                      "grep -q '(defn safe-add' '$R'"
chk "def name 'helper' gone as a def"                    "! grep -q '(defn helper' '$R'"
chk "caller reference renamed: '(safe-add y)'"           "grep -q '(safe-add y)' '$R'"
chk "SHADOWING param untouched: 'other \[helper'"        "grep -qE 'other \[helper' '$R'"
chk "SHADOWING use untouched: '(* helper 2)'"            "grep -qF '(* helper 2)' '$R'"
echo "--- recompiles ---"
mkdir -p "$W/r/fram"; cp "$R" "$W/r/fram/mod.bclj"
if "$ROOT/bin/beagle-build-all" "$W/r" --out "$W/o" 2>&1 | grep -q '0 error'; then
  echo "  PASS  renamed module builds clean"
else echo "  FAIL  renamed module does not build"; fail=1; fi

echo
if [ "$fail" = 0 ]; then
  echo "RESULT: PASS — rename follows binding identity: def + refs renamed, shadowing local untouched."
else
  echo "RESULT: FAIL"; exit 1
fi
