#!/usr/bin/env bash
# AUTHORING-as-claims gate (move 4, the GAP closed).
#
# rename/delete (authoring.sh) only EDIT or REMOVE existing names. The ~95% case —
# AUTHORING new code — had NO graph operation and fell back to text Edit/Write. This
# gate proves the missing verbs exist as CLAIM OPERATIONS on the lossless AST-claims
# projection, reusing resolve.clj's edit+render machinery (the rename/delete template):
#
#   upsert-form : add a NEW top-level def (append a wrapper fN edge) OR replace an
#                 existing def by name (supersede its wrapper fN edge -> a fresh subtree)
#   set-body    : replace a defn's BODY (supersede its post-params fN edges -> a fresh body)
#
# The structured edit spec the agent emits is data, not text: an EDN datum (the new
# form / body) minted into the SAME Fram store as kind/v/fN claims. For each verb the
# gate runs the full loop and HARD-ASSERTS:
#   1. project .bclj -> claims          (claims-roundtrip --emit-edn)
#   2. apply the edit AS A CLAIM OP      (resolve.clj upsert-form / set-body)
#   3. regenerate byte-stable .bclj      (--render)
#   4. the edit is PRESENT, the module RECOMPILES (beagle-build-all '0 error'),
#      it is SCOPE-CORRECT (a new def references an existing one and resolves via
#      refers_to; a body edit leaves sibling forms + comments intact), and the edit
#      was a CLAIM OP not a text splice (the EDN delta shows freshly-minted node ids
#      carrying kind/v/fN claims + a re-pointed wrapper/body fN edge).
#
# Needs racket + bb + fram out/ + chartroom (resolve.clj). Fail-closed: an edit the
# engine refuses, or that does not recompile, is REJECTED with no tree written.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RT="$ROOT/beagle-lib/private/claims-roundtrip.rkt"
FRAM_OUT="${FRAM_OUT:-$HOME/code/fram/out}"
CHARTROOM="${CHARTROOM:-$HOME/code/fram/chartroom}"
RESOLVE="$CHARTROOM/src/resolve.clj"
fail=0

# author <outdir> <corpus> <op> <args...> -> prints COMMITTED | REJECTED
#   upsert-form <scope> <spec-file>
#   set-body    <name>  <scope> <body-file>
# An edit the engine refuses OR that does not recompile is REJECTED, no tree written.
author() {
  local outdir="$1" corpus="$2" op="$3"; shift 3
  local W; W="$(mktemp -d)"; local E="$W/e"; mkdir -p "$E" "$W/regen"
  local edns=() f b
  for f in "$corpus"/*.bclj; do b="$(basename "$f")"; racket "$RT" --emit-edn "$f" 2>/dev/null > "$E/$b.edn"; edns+=("$E/$b.edn"); done
  case "$op" in
    upsert-form)  # add a new top-level def, or replace an existing one by name
      bb -cp "$FRAM_OUT" "$RESOLVE" upsert-form "$1" "$2" "${edns[@]}" >/dev/null 2>&1 \
        || { echo REJECTED; rm -rf "$W"; return; }
      for f in "$corpus"/*.bclj; do b="$(basename "$f")"; racket "$RT" --render "/tmp/resolved-$b.edn" 2>/dev/null > "$W/regen/$b"; done ;;
    set-body)     # replace a defn's body
      bb -cp "$FRAM_OUT" "$RESOLVE" set-body "$1" "$2" "$3" "${edns[@]}" >/dev/null 2>&1 \
        || { echo REJECTED; rm -rf "$W"; return; }
      for f in "$corpus"/*.bclj; do b="$(basename "$f")"; racket "$RT" --render "/tmp/resolved-$b.edn" 2>/dev/null > "$W/regen/$b"; done ;;
    *) echo REJECTED; rm -rf "$W"; return ;;
  esac
  if "$ROOT/bin/beagle-build-all" "$W/regen" --out "$W/o" 2>&1 | grep -q '0 error'; then
    rm -rf "$outdir"; cp -r "$W/regen" "$outdir"; echo COMMITTED
  else echo REJECTED; fi
  rm -rf "$W" /tmp/resolved-*.edn 2>/dev/null || true
}

# claim_node_growth <corpus> <op> <args...> -> prints "<orig_nodes> <proj_nodes>".
# The edit projects to MORE kind-claim nodes (a minted subtree), and the projected
# EDN carries kind/v/fN claims the agent never wrote as text -> a graph op, not a
# text splice (a sed/Edit changes characters in place; it mints no claim nodes).
claim_node_growth() {
  local corpus="$1" op="$2"; shift 2
  local W; W="$(mktemp -d)"; local E="$W/e"; mkdir -p "$E"
  local f b first_edn=""
  for f in "$corpus"/*.bclj; do b="$(basename "$f")"; racket "$RT" --emit-edn "$f" 2>/dev/null > "$E/$b.edn"
    [ -z "$first_edn" ] && first_edn="$E/$b.edn"; done
  local edns=("$E"/*.edn)
  case "$op" in
    upsert-form) bb -cp "$FRAM_OUT" "$RESOLVE" upsert-form "$1" "$2" "${edns[@]}" >/dev/null 2>&1 ;;
    set-body)    bb -cp "$FRAM_OUT" "$RESOLVE" set-body "$1" "$2" "$3" "${edns[@]}" >/dev/null 2>&1 ;;
  esac
  local proj="/tmp/resolved-$(basename "$first_edn" .edn).edn"   # /tmp/resolved-<file>.edn
  local o p
  o="$(grep -c '"kind"' "$first_edn")"; p="$(grep -c '"kind"' "$proj")"
  echo "$o $p"
  rm -rf "$W" /tmp/resolved-*.edn 2>/dev/null || true
}

echo "================ AUTHORING-as-claims gate (upsert-form + set-body) ================"
[ -d "$FRAM_OUT" ] || { echo "  (need FRAM_OUT)"; exit 3; }
[ -f "$RESOLVE" ]  || { echo "  (need CHARTROOM resolve.clj)"; exit 3; }
CORPUS="$HERE/authoring-corpus"
[ -d "$CORPUS" ]   || { echo "  (need authoring-corpus)"; exit 3; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------------
echo '--- NL: "add a function add-two that calls base" -> agent emits {op upsert-form, scope authmod, form <datum>} ---'
SPEC1="$T/spec_add.edn"; printf '(defn add-two [x :- Int] :- Int (base (+ x 2)))' > "$SPEC1"
r="$(author "$T/add" "$CORPUS" upsert-form authmod "$SPEC1")"
read -r O P <<<"$(claim_node_growth "$CORPUS" upsert-form authmod "$SPEC1")"   # orig vs projected kind-claim nodes
if [ "$r" = COMMITTED ] \
   && grep -q 'defn add-two' "$T/add/authmod.bclj" \
   && grep -q '(base (+ x 2))' "$T/add/authmod.bclj" \
   && grep -q 'defn base' "$T/add/authmod.bclj" \
   && grep -q 'defn use-base' "$T/add/authmod.bclj" \
   && grep -q ';; base is the helper' "$T/add/authmod.bclj" \
   && [ "${P:-0}" -gt "${O:-0}" ]; then
  echo "  PASS  committed; add-two PRESENT + references base (scope-correct), siblings+comment intact,"
  echo "        recompiled, projection grew $O -> $P kind-claim nodes (minted subtree = graph op, not a text splice)"
else echo "  FAIL  (result=$r nodes:$O->$P)"; fail=1; fi

# ---------------------------------------------------------------------------
echo '--- NL: "set base body to (* x 10)" -> agent emits {op set-body, name base, scope authmod, body <datum>} ---'
BODY1="$T/body_base.edn"; printf '(* x 10)' > "$BODY1"
# capture the projected EDN to prove the new body's leaves entered the store as v-claims
PROJSAVE="$T/setb.proj.edn"
racket "$RT" --emit-edn "$CORPUS/authmod.bclj" 2>/dev/null > "$T/setb.orig.edn"
bb -cp "$FRAM_OUT" "$RESOLVE" set-body base authmod "$BODY1" "$T/setb.orig.edn" >/dev/null 2>&1
cp "/tmp/resolved-authmod.bclj.edn" "$PROJSAVE" 2>/dev/null || true
rm -f /tmp/resolved-*.edn 2>/dev/null || true
r="$(author "$T/setb" "$CORPUS" set-body base authmod "$BODY1")"
if [ "$r" = COMMITTED ] \
   && grep -q '(defn base \[x :- Int\] :- Int (\* x 10))' "$T/setb/authmod.bclj" \
   && grep -q '(defn use-base \[y :- Int\] :- Int (base y))' "$T/setb/authmod.bclj" \
   && grep -q ';; base is the helper' "$T/setb/authmod.bclj" \
   && grep -q '"v" "\*"'  "$PROJSAVE" && grep -q '"v" "10"' "$PROJSAVE"; then
  echo "  PASS  committed; base body replaced (params/ret-type/comment intact), use-base sibling NOT corrupted,"
  echo "        recompiled; new body leaves entered the store as v-claims (\"*\", \"10\") = graph op, not a text splice"
else echo "  FAIL  ($r)"; fail=1; fi

# ---------------------------------------------------------------------------
echo '--- NL: "replace use-base with a 2-arg version" -> agent emits {op upsert-form (existing name), ...} ---'
SPEC2="$T/spec_repl.edn"; printf '(defn use-base [y :- Int z :- Int] :- Int (base (base y)))' > "$SPEC2"
r="$(author "$T/repl" "$CORPUS" upsert-form authmod "$SPEC2")"
if [ "$r" = COMMITTED ] \
   && grep -q '(defn use-base \[y :- Int z :- Int\] :- Int (base (base y)))' "$T/repl/authmod.bclj" \
   && grep -q '(defn base \[x :- Int\] :- Int (+ x 1))' "$T/repl/authmod.bclj" \
   && [ "$(grep -c 'defn use-base' "$T/repl/authmod.bclj")" -eq 1 ]; then
  echo "  PASS  committed; use-base REPLACED in place (one def, slot preserved), base intact, recompiled"
else echo "  FAIL  ($r)"; fail=1; fi

# ---------------------------------------------------------------------------
echo '--- scope-correctness: a rename of `base` must follow the AUTHORED add-two reference ---'
echo '    (proves add-two`s `base` call carries a real refers_to identity edge into the graph, not a name match)'
# author add-two into the corpus, render, then rename base->renamed-base on the AUTHORED tree.
racket "$RT" --emit-edn "$CORPUS/authmod.bclj" 2>/dev/null > "$T/sc.edn"
SPEC3="$T/spec_sc.edn"; printf '(defn add-two [x :- Int] :- Int (base (+ x 2)))' > "$SPEC3"
bb -cp "$FRAM_OUT" "$RESOLVE" upsert-form authmod "$SPEC3" "$T/sc.edn" >/dev/null 2>&1
racket "$RT" --render /tmp/resolved-authmod.bclj.edn 2>/dev/null > "$T/sc_authored.bclj"; rm -f /tmp/resolved-*.edn
racket "$RT" --emit-edn "$T/sc_authored.bclj" 2>/dev/null > "$T/sc_authored.edn"
bb -cp "$FRAM_OUT" "$RESOLVE" rename base renamed-base sc_authored "$T/sc_authored.edn" >/dev/null 2>&1 \
  && racket "$RT" --render /tmp/resolved-sc_authored.bclj.edn 2>/dev/null > "$T/sc_renamed.bclj"
if grep -q '(defn add-two \[x :- Int\] :- Int (renamed-base (+ x 2)))' "$T/sc_renamed.bclj" 2>/dev/null \
   && grep -q '(defn renamed-base ' "$T/sc_renamed.bclj"; then
  echo "  PASS  rename of base (O(1), one binding) propagated to the authored add-two call site"
  echo "        -> the authored reference is wired into the graph by IDENTITY (refers_to), fully scope-correct"
else echo "  FAIL  authored reference did not follow rename (not scope-correct)"; fail=1; fi
rm -f /tmp/resolved-*.edn 2>/dev/null || true

# ---------------------------------------------------------------------------
echo '--- NL: "set the body of nonexistent-fn" -> agent emits set-body on a missing target ---'
BODY2="$T/body_missing.edn"; printf '(+ 1 1)' > "$BODY2"
r="$(author "$T/miss" "$CORPUS" set-body nonexistent-fn authmod "$BODY2" 2>/dev/null || echo REJECTED)"
if [ "$r" = REJECTED ] && [ ! -d "$T/miss" ]; then
  echo "  PASS  set-body on a missing defn fails closed — nothing committed"
else echo "  FAIL  expected REJECTED+no-commit, got '$r'"; fail=1; fi

echo
if [ "$fail" = 0 ]; then
  echo "RESULT: PASS — authoring (add/replace def + set body) IS a recompile-gated CLAIM operation on the lossless AST projection."
else echo "RESULT: FAIL"; exit 1; fi
