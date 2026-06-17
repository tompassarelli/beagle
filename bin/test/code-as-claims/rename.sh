#!/usr/bin/env bash
# Capstone — repair as a GRAPH OPERATION.
#
# A scope-correct rename performed as a CLAIM EDIT on the canonical Fram store
# (supersede the symbol's `v` claims in one module), then exported byte-stable and
# recompiled. The fixture defines `helper` in BOTH mod_a and mod_b; we rename only
# mod_a's. The proof:
#   - mod_a's helper is renamed everywhere it binds (def + callers)
#   - mod_b's identically-named helper is UNTOUCHED (scope-correct by construction;
#     a text `sed s/helper/.../` would corrupt both)
#   - the renamed tree RECOMPILES clean
#   - renaming onto an existing binding is REFUSED (the collision invariant)
# This ties move 1 (scope-correct graph) + move 2 (byte-stable emit) + move 3
# (canonical store) into the concrete crown jewel. Needs racket + bb + fram out/.
#
# HONEST SCOPE: the rename is MODULE-LOCAL — it renames every occurrence of the
# symbol in the target module (def + callers), and the cross-MODULE collision case
# (mod_a vs mod_b) is correct by construction. It does NOT yet distinguish a
# local-shadowing binding inside the module (a `let [helper ...]` would also be
# renamed) — exact intra-module scoping awaits id-reference resolution (chartroom's
# noted follow-up). The cross-file rename-CASCADE (update qualified refs in OTHER
# modules) is the next extension. It does NOT touch `helper` inside strings/keywords
# (only symbol leaves) — proven, and the key difference from a text sed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RT="$ROOT/beagle-lib/private/claims-roundtrip.rkt"
RIS="$HERE/rename-in-store.clj"
FRAM_OUT="${FRAM_OUT:-$HOME/code/fram/out}"
C="$HERE/rename-corpus"
fail=0

echo "================ capstone — repair as a graph operation (scope-correct rename) ================"
[ -d "$FRAM_OUT" ] || { echo "  (need FRAM_OUT)"; exit 3; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/regen"

racket "$RT" --emit-edn "$C/mod_a.bclj" 2>/dev/null > "$W/a.edn"
racket "$RT" --emit-edn "$C/mod_b.bclj" 2>/dev/null > "$W/b.edn"

# the edit: rename helper -> safe-add in modules matching "mod_a"
bb -cp "$FRAM_OUT" "$RIS" helper safe-add mod_a "$W/out" "$W/a.edn" "$W/b.edn" 2>/dev/null
racket "$RT" --render "$W/out/mod_a.bclj.edn" 2>/dev/null > "$W/regen/mod_a.bclj"
racket "$RT" --render "$W/out/mod_b.bclj.edn" 2>/dev/null > "$W/regen/mod_b.bclj"

chk() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi; }
echo "--- the graph edit ---"
chk "mod_a: helper renamed to safe-add"          "grep -q 'safe-add' '$W/regen/mod_a.bclj'"
chk "mod_a: no 'helper' left (def + caller both)" "! grep -q 'helper' '$W/regen/mod_a.bclj'"
chk "mod_b: helper UNTOUCHED (scope-correct)"     "grep -q 'helper' '$W/regen/mod_b.bclj'"
chk "mod_b: NOT renamed (no safe-add leaked)"     "! grep -q 'safe-add' '$W/regen/mod_b.bclj'"

echo "--- the renamed program recompiles ---"
if bin/beagle-build-all "$W/regen" --out "$W/o" 2>&1 | grep -q '0 error'; then
  echo "  PASS  renamed tree builds clean"
else
  echo "  FAIL  renamed tree does not build"; fail=1
fi

echo "--- collision invariant (rename onto an existing binding is refused) ---"
# use-a already binds in mod_a; renaming helper -> use-a must be refused (exit 3).
if bb -cp "$FRAM_OUT" "$RIS" helper use-a mod_a "$W/out2" "$W/a.edn" "$W/b.edn" >/dev/null 2>&1; then
  echo "  FAIL  collision NOT refused"; fail=1
else
  echo "  PASS  rename onto existing binding refused (no claims mutated)"
fi

echo
if [ "$fail" = 0 ]; then
  echo "RESULT: PASS — scope-correct rename as a graph operation: propagated, byte-stable, recompiles, collision-safe."
else
  echo "RESULT: FAIL"; exit 1
fi
