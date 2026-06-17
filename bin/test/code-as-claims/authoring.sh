#!/usr/bin/env bash
# NL → edit authoring layer (move 4, the agent-facing surface).
#
# An agent turns prose intent into a STRUCTURED EDIT (data, not text) — the part a
# model can emit reliably and the coordinator can validate. This script is the
# deterministic substrate that edit drives: dispatch the structured op to the
# canonical engine, regenerate byte-stable, and COMMIT only if it recompiles, else
# REJECT (fail closed). The NL→spec step is the agent's; everything after is gated.
#
#   structured edit specs an agent emits (EDN-ish, shown as op + args here):
#     {op rename,  old O, new N, scope S}            -> scope-correct (shadowing) rename (resolve.clj)
#     {op cascade, old O, new N, home H, ns NS}      -> cross-module qualified rename (rename-cascade)
#
# Needs racket + bb + fram out/ + chartroom (resolve.clj). Self-gates with a worked
# NL→edit example (valid commits + recompiles; invalid fails closed).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RT="$ROOT/beagle-lib/private/claims-roundtrip.rkt"
FRAM_OUT="${FRAM_OUT:-$HOME/code/fram/out}"
CHARTROOM="${CHARTROOM:-$HOME/code/chartroom}"
fail=0

# apply <outdir> <corpus> <op> <args...> -> prints COMMITTED | REJECTED
# A claim edit the engine refuses, OR that does not recompile, is REJECTED with no
# tree written (fail closed). The deterministic, validated authoring transaction.
apply_edit() {
  local outdir="$1" corpus="$2" op="$3"; shift 3
  local W; W="$(mktemp -d)"; local E="$W/e"; mkdir -p "$E" "$W/regen"
  local edns=() f b
  for f in "$corpus"/*.bclj; do b="$(basename "$f")"; racket "$RT" --emit-edn "$f" 2>/dev/null > "$E/$b.edn"; edns+=("$E/$b.edn"); done
  case "$op" in
    rename)  # scope-correct (shadowing) — chartroom's refers_to resolver
      bb -cp "$FRAM_OUT" "$CHARTROOM/src/resolve.clj" rename "$1" "$2" "$3" "${edns[@]}" >/dev/null 2>&1 \
        || { echo REJECTED; rm -rf "$W"; return; }
      for f in "$corpus"/*.bclj; do b="$(basename "$f")"; racket "$RT" --render "/tmp/resolved-$b.edn" 2>/dev/null > "$W/regen/$b"; done ;;
    cascade) # cross-module qualified rename
      bb -cp "$FRAM_OUT" "$HERE/rename-cascade.clj" "$1" "$2" "$3" "$4" "$W/out" "${edns[@]}" >/dev/null 2>&1 \
        || { echo REJECTED; rm -rf "$W"; return; }
      for f in "$corpus"/*.bclj; do b="$(basename "$f")"; racket "$RT" --render "$W/out/$b.edn" 2>/dev/null > "$W/regen/$b"; done ;;
    *) echo REJECTED; rm -rf "$W"; return ;;
  esac
  if "$ROOT/bin/beagle-build-all" "$W/regen" --out "$W/o" 2>&1 | grep -q '0 error'; then
    rm -rf "$outdir"; cp -r "$W/regen" "$outdir"; echo COMMITTED
  else echo REJECTED; fi
  rm -rf "$W" /tmp/resolved-*.edn 2>/dev/null || true
}

echo "================ NL → edit authoring layer (recompile-gated, agent-driven) ================"
[ -d "$FRAM_OUT" ] || { echo "  (need FRAM_OUT)"; exit 3; }
[ -f "$CHARTROOM/src/resolve.clj" ] || { echo "  (need CHARTROOM resolve.clj)"; exit 3; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

echo '--- NL: "rename the helper function to add-one" -> the agent emits a structured edit ---'
echo '    spec: {op rename, old "helper", new "add-one", scope "mod"}  (scope-correct via refers_to)'
r="$(apply_edit "$T/a" "$HERE/shadow-corpus" rename helper add-one mod)"
if [ "$r" = COMMITTED ] && grep -q 'add-one' "$T/a/mod.bclj" 2>/dev/null && grep -qE 'other \[helper' "$T/a/mod.bclj"; then
  echo "  PASS  committed; def+ref renamed, shadowing param untouched, recompiled"
else echo "  FAIL  ($r)"; fail=1; fi

echo '--- NL: "rename helper to other" (a name already defined in the module) -> agent emits rename ---'
echo '    spec: {op rename, old "helper", new "other", scope "mod"}  -> engine refuses (collision)'
r="$(apply_edit "$T/b" "$HERE/shadow-corpus" rename helper other mod 2>/dev/null || echo REJECTED)"
if [ "$r" = REJECTED ] && [ ! -d "$T/b" ]; then
  echo "  PASS  invalid intent (collision) fails closed — nothing committed"
else echo "  FAIL  expected REJECTED+no-commit, got '$r'"; fail=1; fi

echo
if [ "$fail" = 0 ]; then
  echo "RESULT: PASS — prose intent -> structured edit -> validated, recompile-gated transaction -> code."
else echo "RESULT: FAIL"; exit 1; fi
