#!/usr/bin/env bash
# Scope-correct rename — repair as a graph operation, the COMPLETE engine.
#
# One engine (Beagle Store's resolve.clj, Turtle #5: a lexical resolver that adds
# refers_to edges, then renames a def by editing ONE node — references follow
# refers_to). It is correct across all three scope hazards, which a text sed cannot
# be, and O(1) (edits the def, not each reference):
#   1. MODULE COLLISION   — rename mod_a's `helper`; mod_b's same-named one untouched
#   2. SHADOWING          — rename a def; a local of the same name (param/let) untouched
#   3. CROSS-MODULE        — rename a def; every `<alias>/name` reader across files renamed
#   + the collision invariant: a rename onto an existing binding is refused.
# Current candidates check coherently. Needs racket + bb + store out/ resolve.clj.
set -uo pipefail
export RESOLVE_OUT="$(mktemp -d)"   # hermetic: per-run render output (no global /tmp collision)

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RT="$ROOT/beagle-lib/private/facts-roundtrip.rkt"
OVERLAY_CHECK="$ROOT/beagle-lib/private/facts-check-overlay.rkt"
SUPERVISOR="$ROOT/native-core/bin/run-bounded.rkt"
BEAGLE_STORE_ROOT="$ROOT/store"
BEAGLE_STORE_OUT="${BEAGLE_STORE_OUT:-$BEAGLE_STORE_ROOT/out}"
source "$ROOT/bin/_beagle-racket"
source "$ROOT/bin/_beagle-store-resolver"
BEAGLE_STORE_SRC="${CODE_AS_FACTS_CORPUS:-$BEAGLE_STORE_ROOT/src}"
fail=0

echo "================ scope-correct rename — the complete engine (resolve.clj) ================"
[ -d "$BEAGLE_STORE_OUT" ] || { echo "  (need BEAGLE_STORE_OUT)"; exit 3; }
RES="$(find_store_resolver)" || exit 3
chk() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi; }
run_phase() {
  local name="$1" deadline="$2"
  shift 2
  echo "  PHASE $name (deadline ${deadline}s)" >&2
  "$RACKET" "$SUPERVISOR" "$deadline" 5 -- "$@"
}
phase_must_pass() {
  local name="$1" deadline="$2"
  shift 2
  run_phase "$name" "$deadline" "$@"
  local status=$?
  if [[ $status -ne 0 ]]; then
    echo "  FAIL  $name (status $status)"
    exit "$status"
  fi
}
W="$(mktemp -d)"; trap 'rm -rf "${W:?}" "${RESOLVE_OUT:?}"' EXIT

# --- 1. module collision: rename mod_a/helper; mod_b/helper untouched -----------
echo "--- 1. module collision (mod_a/helper renamed; mod_b/helper untouched) ---"
"$RACKET" "$RT" --emit-edn "$HERE/rename-corpus/mod_a.bclj" 2>/dev/null > "$W/a.edn"
"$RACKET" "$RT" --emit-edn "$HERE/rename-corpus/mod_b.bclj" 2>/dev/null > "$W/b.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename helper safe-add mod_a "$W/a.edn" "$W/b.edn" 2>/dev/null
ma="$("$RACKET" "$RT" --render $RESOLVE_OUT/resolved-mod_a.bclj.edn 2>/dev/null)"
mb="$("$RACKET" "$RT" --render $RESOLVE_OUT/resolved-mod_b.bclj.edn 2>/dev/null)"
chk "mod_a renamed (def + caller -> safe-add)" "grep -q 'defn safe-add' <<<\"\$ma\" && grep -q '(safe-add x)' <<<\"\$ma\""
chk "mod_b helper UNTOUCHED"                   "grep -q 'defn helper' <<<\"\$mb\" && ! grep -q 'safe-add' <<<\"\$mb\""

# --- 2. shadowing: rename def; shadowing param untouched ------------------------
echo "--- 2. shadowing (def renamed; shadowing local + its use untouched) ---"
"$RACKET" "$RT" --emit-edn "$HERE/shadow-corpus/mod.bclj" 2>/dev/null > "$W/s.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename helper add-one mod "$W/s.edn" 2>/dev/null
sm="$("$RACKET" "$RT" --render $RESOLVE_OUT/resolved-mod.bclj.edn 2>/dev/null)"
chk "def + ref renamed to add-one"   "grep -q 'defn add-one' <<<\"\$sm\" && grep -q '(add-one y)' <<<\"\$sm\""
chk "shadowing param + use UNTOUCHED" "grep -qF 'other [(helper Int)]' <<<\"\$sm\" && grep -qF '(* helper 2)' <<<\"\$sm\""

# --- 3. cross-module: authoritative owner + minimal qualified consumer ---------
echo "--- 3. cross-module (authoritative Beagle Store owner + qualified consumer) ---"
E="$W/e"
R="$W/r"
C="$W/corpus"
mkdir -p "$E" "$R" "$C"

owner="$BEAGLE_STORE_SRC/store/rpc_limits.bgl"
consumer="$C/code_as_facts_consumer.bgl"
[[ -f "$owner" ]] || { echo "  FAIL  missing current Beagle Store authority: $owner"; exit 3; }
cat > "$consumer" <<'EOF'
#lang beagle
(ns code-as-facts.consumer)
(require [store.rpc-limits :as limits])
(def observed-depth Int limits/term-codec-v1-max-depth)
EOF
old_name="term-codec-v1-max-depth"
new_name="code-as-facts-max-depth"
owner_scope="rpc_limits"
owner_expect="(def code-as-facts-max-depth"
old_reader="limits/term-codec-v1-max-depth"
new_reader="limits/code-as-facts-max-depth"
untouched="rpc-v2-list-envelope-depth"

echo "  AUTHORITY $owner"
sources=("$owner" "$consumer")
edns=()
for source in "${sources[@]}"; do
  base="$(basename "$source")"
  edn="$E/$base.edn"
  phase_must_pass "project $base" 60 "$RACKET" "$RT" --emit-edn "$source" > "$edn"
  edns+=("$edn")
done

phase_must_pass "resolve qualified rename" 180 \
  bb -cp "$BEAGLE_STORE_OUT" "$RES" rename "$old_name" "$new_name" "$owner_scope" "${edns[@]}"

resolved_edns=()
rendered=()
for source in "${sources[@]}"; do
  base="$(basename "$source")"
  resolved="$RESOLVE_OUT/resolved-$base.edn"
  output="$R/$base"
  [[ -f "$resolved" ]] || { echo "  FAIL  resolver omitted $base"; exit 1; }
  phase_must_pass "render $base" 60 "$RACKET" "$RT" --render "$resolved" > "$output"
  resolved_edns+=("$resolved")
  rendered+=("$output")
done

phase_must_pass "check coherent candidate overlay" 180 \
  "$RACKET" "$OVERLAY_CHECK" --check-only "${resolved_edns[@]}" > "$W/overlay.json"

owner_rendered="$R/$(basename "$owner")"
consumer_rendered="$R/$(basename "$consumer")"
chk "authoritative owner definition renamed" "grep -Fq -- '$owner_expect' '$owner_rendered'"
chk "old qualified reader absent"            "! grep -Fq -- '$old_reader' '$consumer_rendered'"
chk "qualified reader follows owner rename"  "grep -Fq -- '$new_reader' '$consumer_rendered'"
chk "nearby distinct symbol untouched"       "grep -Fq -- '$untouched' '$owner_rendered'"
chk "candidate facts check coherently"      "grep -q '\"ok\":true' '$W/overlay.json'"

# --- 4. collision invariant: rename onto an existing binding refused ------------
echo "--- 4. collision invariant (rename helper -> other refused) ---"
"$RACKET" "$RT" --emit-edn "$HERE/shadow-corpus/mod.bclj" 2>/dev/null > "$W/s2.edn"
if bb -cp "$BEAGLE_STORE_OUT" "$RES" rename helper other mod "$W/s2.edn" >/dev/null 2>&1; then
  echo "  FAIL  collision NOT refused"; fail=1
else echo "  PASS  rename onto existing binding refused"; fi

# --- 5. scope hazards that can compile with changed meaning ----------------------
echo "--- 5. adversarial scope hazards (paren-param shadowing + capture refusal) ---"
# 5a. typed structural param `(red Int)` must shadow the def — renaming the def must
#     NOT touch the param or its body use (the param-binding wasn't being collected).
printf '#lang beagle/clj\n(ns demo.p)\n(def red Int 1)\n(defn ps [(red Int)] Int (+ red 100))\n' > "$W/p.bclj"
"$RACKET" "$RT" --emit-edn "$W/p.bclj" 2>/dev/null > "$W/p.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename red crimson p "$W/p.edn" 2>/dev/null
pp="$("$RACKET" "$RT" --render $RESOLVE_OUT/resolved-p.bclj.edn 2>/dev/null)"
chk "paren-param def renamed (crimson)"        "grep -q '(def crimson' <<<\"\$pp\""
chk "paren-param + body use UNTOUCHED"         "grep -qF '[(red Int)]' <<<\"\$pp\" && grep -qF '(+ red 100)' <<<\"\$pp\""
# 5b. CAPTURE via param: rename src->dst where dst is a param must be REFUSED
#     (else (+ dst src) -> (+ dst dst), a silent name-capture that recompiles).
printf '#lang beagle/clj\n(ns demo.c)\n(def src Int 1)\n(defn f [(dst Int)] Int (+ dst src))\n' > "$W/c.bclj"
"$RACKET" "$RT" --emit-edn "$W/c.bclj" 2>/dev/null > "$W/c.edn"
if bb -cp "$BEAGLE_STORE_OUT" "$RES" rename src dst c "$W/c.edn" >/dev/null 2>&1; then
  echo "  FAIL  param capture NOT refused"; fail=1
else echo "  PASS  param capture refused (no-capture invariant)"; fi
# 5c. CAPTURE via let-local: rename total->sum where sum is a let-local must be REFUSED.
printf '#lang beagle/clj\n(ns demo.l)\n(def total Int 100)\n(defn g [(x Int)] Int (let [sum (+ x 1)] (* sum total)))\n' > "$W/l.bclj"
"$RACKET" "$RT" --emit-edn "$W/l.bclj" 2>/dev/null > "$W/l.edn"
if bb -cp "$BEAGLE_STORE_OUT" "$RES" rename total sum l "$W/l.edn" >/dev/null 2>&1; then
  echo "  FAIL  let-local capture NOT refused"; fail=1
else echo "  PASS  let-local capture refused (no-capture invariant)"; fi

# --- 6. type renames (constructor heads, defunion variants, cross-module, single-colon) -
# Types are first-class refactor targets, so every use must follow the rename.
echo "--- 6. type resolution (constructors, defunion, cross-module, structural bindings) ---"
# 6a. defrecord constructor (Point 1 2) must rename with the type
printf '#lang beagle/clj\n(ns tp)\n(defrecord Point\n  [(x Int)\n   (y Int)])\n(defn mk [] Point (Point 1 2))\n' > "$W/tp.bclj"
"$RACKET" "$RT" --emit-edn "$W/tp.bclj" 2>/dev/null > "$W/tp.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename Point Pt tp "$W/tp.edn" 2>/dev/null
tp="$("$RACKET" "$RT" --render $RESOLVE_OUT/resolved-tp.bclj.edn 2>/dev/null)"
chk "constructor (Point ..) renamed with the type" "grep -qF '(Pt 1 2)' <<<\"\$tp\" && ! grep -qF '(Point 1 2)' <<<\"\$tp\""
# 6b. defunion variant constructor renames (and the union name independently)
printf '#lang beagle/clj\n(ns tu)\n(defunion Shape (Circle [(r Float)]) (Square [(s Float)]))\n(defn mk [(r Float)] Shape (Circle r))\n' > "$W/tu.bclj"
"$RACKET" "$RT" --emit-edn "$W/tu.bclj" 2>/dev/null > "$W/tu.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename Circle Disc tu "$W/tu.edn" 2>/dev/null
tu="$("$RACKET" "$RT" --render $RESOLVE_OUT/resolved-tu.bclj.edn 2>/dev/null)"
chk "defunion variant (Circle r) renamed" "grep -qF '(Disc r)' <<<\"\$tu\" && grep -qF '(Disc [(r Float)])' <<<\"\$tu\" && grep -qF '(Square' <<<\"\$tu\""
# 6c. cross-module type: consumer's t/Type annotation cascades
printf '#lang beagle/clj\n(ns tlib)\n(defrecord Widget [(n Int)])\n' > "$W/tlib.bclj"
printf '#lang beagle/clj\n(ns tcon)\n(require [tlib :as t])\n(defn use [(w t/Widget)] Int 1)\n' > "$W/tcon.bclj"
"$RACKET" "$RT" --emit-edn "$W/tlib.bclj" 2>/dev/null > "$W/tlib.edn"
"$RACKET" "$RT" --emit-edn "$W/tcon.bclj" 2>/dev/null > "$W/tcon.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename Widget Gadget tlib "$W/tlib.edn" "$W/tcon.edn" 2>/dev/null
chk "cross-module type ref t/Widget -> t/Gadget" "grep -qF 't/Gadget' <<<\"\$(\"$RACKET\" \"$RT\" --render $RESOLVE_OUT/resolved-tcon.bclj.edn 2>/dev/null)\""
# 6d. structural `(name Type)` annotation cascades (legal field/param surface)
printf '#lang beagle/clj\n(ns tsc)\n(defrecord Thing [(n Int)])\n(defn f [(x Thing)] Int 1)\n' > "$W/tsc.bclj"
"$RACKET" "$RT" --emit-edn "$W/tsc.bclj" 2>/dev/null > "$W/tsc.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename Thing Item tsc "$W/tsc.edn" 2>/dev/null
chk "structural param (x Thing) -> (x Item)" "grep -qF '(x Item)' <<<\"\$(\"$RACKET\" \"$RT\" --render $RESOLVE_OUT/resolved-tsc.bclj.edn 2>/dev/null)\""
# 6e. rename that matches nothing is refused (not a silent 0-edit success)
printf '#lang beagle/clj\n(ns tz)\n(defn keep-me [(x Int)] Int x)\n' > "$W/tz.bclj"
"$RACKET" "$RT" --emit-edn "$W/tz.bclj" 2>/dev/null > "$W/tz.edn"
if bb -cp "$BEAGLE_STORE_OUT" "$RES" rename nonexistent whatever tz "$W/tz.edn" >/dev/null 2>&1; then
  echo "  FAIL  rename-of-nothing not refused"; fail=1
else echo "  PASS  rename matching no binding refused (no silent 0-edit success)"; fi

# --- 7. sequential binding scope + :or defaults ----------------------------------
# let/loop/for bindings are SEQUENTIAL and :or defaults are LIVE refs — both were
# silent miscompiles (a default left dangling; a sibling-capturing rename accepted).
echo "--- 7. sequential bindings + :or defaults ---"
# 7a. :or default referencing a def cascades on rename
printf '#lang beagle/clj\n(ns sa)\n(def base Int 10)\n(defn f [{:keys [x] :or {x base}}] Int (+ x 1))\n' > "$W/sa.bclj"
"$RACKET" "$RT" --emit-edn "$W/sa.bclj" 2>/dev/null > "$W/sa.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename base base2 sa "$W/sa.edn" 2>/dev/null
chk ":or default ref renamed (not left dangling)" "grep -qF ':or {x base2}' <<<\"\$(\"$RACKET\" \"$RT\" --render $RESOLVE_OUT/resolved-sa.bclj.edn 2>/dev/null)\""
# 7b. for :let sequential capture refused
printf '#lang beagle/clj\n(ns sb)\n(def factor Int 10)\n(defn go [(xs (Vec Int))] (Vec Int) (for [x xs :let [g (+ x 1) h (* x factor)]] h))\n' > "$W/sb.bclj"
"$RACKET" "$RT" --emit-edn "$W/sb.bclj" 2>/dev/null > "$W/sb.edn"
if bb -cp "$BEAGLE_STORE_OUT" "$RES" rename factor g sb "$W/sb.edn" >/dev/null 2>&1; then
  echo "  FAIL  for :let sequential capture not refused"; fail=1
else echo "  PASS  for :let sequential capture refused"; fi
# 7c. let sequential capture refused
printf '#lang beagle/clj\n(ns sc)\n(def total Int 100)\n(defn h [(x Int)] Int (let [s (+ x 1) t (* s total)] t))\n' > "$W/sc.bclj"
"$RACKET" "$RT" --emit-edn "$W/sc.bclj" 2>/dev/null > "$W/sc.edn"
if bb -cp "$BEAGLE_STORE_OUT" "$RES" rename total s sc "$W/sc.edn" >/dev/null 2>&1; then
  echo "  FAIL  let sequential capture not refused"; fail=1
else echo "  PASS  let sequential capture refused"; fi
# 7d. CONTROL: a legitimate sequential rename still succeeds (no over-refusal)
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename total grand sc "$W/sc.edn" 2>/dev/null
chk "legitimate sequential rename succeeds (total->grand)" "grep -qF '(* s grand)' <<<\"\$(\"$RACKET\" \"$RT\" --render $RESOLVE_OUT/resolved-sc.bclj.edn 2>/dev/null)\""

# --- 8. quasiquote templates + bracketed :refer + import collision ---------------
echo "--- 8. quasiquote macro templates + bracketed :refer + import collision ---"
# 8a. a quasiquote template ref keeps its definition-site provider edge and renames
printf '#lang beagle/clj\n(ns qq)\n(def base Int 1)\n(defmacro add-base [n] (quasiquote (+ base (unquote n))))\n' > "$W/qq.bclj"
"$RACKET" "$RT" --emit-edn "$W/qq.bclj" 2>/dev/null > "$W/qq.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename base base2 qq "$W/qq.edn" 2>/dev/null
qq="$("$RACKET" "$RT" --render $RESOLVE_OUT/resolved-qq.bclj.edn 2>/dev/null)"
chk "quasiquote template ref renamed (+ base2 ..)" "grep -qF '\`(+ base2 ~n)' <<<\"\$qq\""
# 8b. CONTROL: a let-local inside a template must NOT rename (hygiene)
printf '#lang beagle/clj\n(ns qh)\n(def base Int 1)\n(defmacro mk [x] (quasiquote (let [tmp (unquote x)] (+ tmp base))))\n' > "$W/qh.bclj"
"$RACKET" "$RT" --emit-edn "$W/qh.bclj" 2>/dev/null > "$W/qh.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename base base2 qh "$W/qh.edn" 2>/dev/null
chk "template local 'tmp' untouched, base->base2" "grep -qF '\`(let [tmp ~x] (+ tmp base2))' <<<\"\$(\"$RACKET\" \"$RT\" --render $RESOLVE_OUT/resolved-qh.bclj.edn 2>/dev/null)\""
# 8c. canonical bracketed :refer cross-module refs rename
printf '#lang beagle/clj\n(ns rlib)\n(defn red [(x Int)] Int x)\n' > "$W/rlib.bclj"
printf '#lang beagle/clj\n(ns rcon)\n(require [rlib :refer [red]])\n(defn use [(y Int)] Int (red y))\n' > "$W/rcon.bclj"
"$RACKET" "$RT" --emit-edn "$W/rlib.bclj" 2>/dev/null > "$W/rlib.edn"
"$RACKET" "$RT" --emit-edn "$W/rcon.bclj" 2>/dev/null > "$W/rcon.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename red crimson rlib "$W/rlib.edn" "$W/rcon.edn" 2>/dev/null
chk "bracketed :refer'd ref renames cross-module (red->crimson)" "grep -qF '(crimson y)' <<<\"\$(\"$RACKET\" \"$RT\" --render $RESOLVE_OUT/resolved-rcon.bclj.edn 2>/dev/null)\""
# 8d. import collision: consumer :refer's old AND already binds new -> refuse
printf '#lang beagle/clj\n(ns rcon2)\n(require [rlib :refer [red]])\n(defn blue [(y Int)] Int (red y))\n' > "$W/rcon2.bclj"
"$RACKET" "$RT" --emit-edn "$W/rcon2.bclj" 2>/dev/null > "$W/rcon2.edn"
if bb -cp "$BEAGLE_STORE_OUT" "$RES" rename red blue rlib "$W/rlib.edn" "$W/rcon2.edn" >/dev/null 2>&1; then
  echo "  FAIL  import collision not refused"; fail=1
else echo "  PASS  import collision (consumer already binds new) refused"; fi

# --- 9. deeper type/quasiquote forms ---------------------------------------------
echo "--- 9. parameterized defunion + protocol return type + quasiquote quote-data ---"
# 9a. parameterized defunion name (Result T E) renames + its annotations cascade
printf '#lang beagle/clj\n(ns pd)\n(defunion (Result T E) (Ok [(v T)]) (Err [(e E)]))\n(defn mk [(v Int)] (Result Int Int) (Ok v))\n' > "$W/pd.bclj"
"$RACKET" "$RT" --emit-edn "$W/pd.bclj" 2>/dev/null > "$W/pd.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename Result Either pd "$W/pd.edn" 2>/dev/null
pd="$("$RACKET" "$RT" --render $RESOLVE_OUT/resolved-pd.bclj.edn 2>/dev/null)"
chk "parameterized defunion (Result T E)->(Either T E) + annotation" "grep -qF '(defunion (Either T E)' <<<\"\$pd\" && grep -qF -- '] (Either Int Int)' <<<\"\$pd\""
# 9b. defprotocol method RETURN type cascades
printf '#lang beagle/clj\n(ns pp)\n(defrecord Box [(v Int)])\n(defprotocol Maker (make [self] Box))\n' > "$W/pp.bclj"
"$RACKET" "$RT" --emit-edn "$W/pp.bclj" 2>/dev/null > "$W/pp.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename Box Crate pp "$W/pp.edn" 2>/dev/null
chk "defprotocol method return Box becomes Crate" "grep -qF '(make [self] Crate)' <<<\"\$(\"$RACKET\" \"$RT\" --render $RESOLVE_OUT/resolved-pp.bclj.edn 2>/dev/null)\""
# 9c. (quote ..) inside a quasiquote is inert DATA — must NOT be renamed
printf '#lang beagle/clj\n(ns qd)\n(def red Int 1)\n(defmacro mk [] (quasiquote (quote (red))))\n' > "$W/qd.bclj"
"$RACKET" "$RT" --emit-edn "$W/qd.bclj" 2>/dev/null > "$W/qd.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename red crimson qd "$W/qd.edn" 2>/dev/null
qd="$("$RACKET" "$RT" --render $RESOLVE_OUT/resolved-qd.bclj.edn 2>/dev/null)"
chk "quasiquote (quote (red)) data untouched; def->crimson" "grep -qF '(quote (red))' <<<\"\$qd\" && grep -qF '(def crimson' <<<\"\$qd\""

# --- 10. quasiquote quote/unquote nesting + nullary variants ---------------------
echo "--- 10. unquote-inside-quote + nullary defunion variant ---"
# 10a. an (unquote ..) nested inside a (quote ..) within a template STILL escapes -> renames
printf '#lang beagle/clj\n(ns qn)\n(defn red [(x Int)] Int x)\n(defmacro mk [] (quasiquote (quote (unquote (red 1)))))\n' > "$W/qn.bclj"
"$RACKET" "$RT" --emit-edn "$W/qn.bclj" 2>/dev/null > "$W/qn.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename red crimson qn "$W/qn.edn" 2>/dev/null
chk "unquote inside quote escapes + renames" "grep -qF '\`(quote ~(crimson 1))' <<<\"\$(\"$RACKET\" \"$RT\" --render $RESOLVE_OUT/resolved-qn.bclj.edn 2>/dev/null)\""
# 10b. a nullary (bare-symbol) defunion variant is renameable
printf '#lang beagle/clj\n(ns nv)\n(defunion Maybe (Some [(v Int)]) None)\n(defn f [(x Int)] Int x)\n' > "$W/nv.bclj"
"$RACKET" "$RT" --emit-edn "$W/nv.bclj" 2>/dev/null > "$W/nv.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename None Nothing nv "$W/nv.edn" 2>/dev/null
chk "nullary variant None -> Nothing" "grep -qF '(Some [(v Int)]) Nothing)' <<<\"\$(\"$RACKET\" \"$RT\" --render $RESOLVE_OUT/resolved-nv.bclj.edn 2>/dev/null)\""

# --- 11. defrecord+defunion, multi-arity defn, ->ctor -----------------------------
echo "--- 11. defrecord+defunion idiom + multi-arity defn + ->Name constructor ---"
# 11a. the shipped match-fixture idiom: a defrecord that is also a defunion member renames as ONE type
printf '#lang beagle/clj\n(ns ri)\n(defrecord Ok [(value Any)])\n(defrecord Err [(error String)])\n(defunion Result Ok Err)\n(defn h [(r Result)] Any (match r [(Ok v) v] [(Err e) e]))\n' > "$W/ri.bclj"
"$RACKET" "$RT" --emit-edn "$W/ri.bclj" 2>/dev/null > "$W/ri.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename Ok Yes ri "$W/ri.edn" 2>/dev/null
ri="$("$RACKET" "$RT" --render $RESOLVE_OUT/resolved-ri.bclj.edn 2>/dev/null)"
chk "defrecord+union+match all rename together (no type split)" "grep -qF '(defrecord Yes' <<<\"\$ri\" && grep -qF '(defunion Result Yes Err)' <<<\"\$ri\" && grep -qF '[(Yes v)' <<<\"\$ri\" && grep -qF '(defrecord Err' <<<\"\$ri\""
# 11b. multi-arity defn: a def used in EVERY arity body renames
printf '#lang beagle/clj\n(ns rm)\n(def base Int 5)\n(defn f\n  ([(x Int)] Int (+ x base))\n  ([(x Int)\n    (y Int)] Int (+ x y base)))\n' > "$W/rm.bclj"
"$RACKET" "$RT" --emit-edn "$W/rm.bclj" 2>/dev/null > "$W/rm.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename base unit rm "$W/rm.edn" 2>/dev/null
rmr="$("$RACKET" "$RT" --render $RESOLVE_OUT/resolved-rm.bclj.edn 2>/dev/null)"
chk "multi-arity defn: both arity bodies renamed" "grep -qF '(+ x unit)' <<<\"\$rmr\" && grep -qF '(+ x y unit)' <<<\"\$rmr\""
# 11c. ->Name auto-constructor renames with the type (same-module)
printf '#lang beagle/clj\n(ns rc)\n(defrecord Point\n  [(x Int)\n   (y Int)])\n(defn mk [] Point (->Point 0 0))\n' > "$W/rc.bclj"
"$RACKET" "$RT" --emit-edn "$W/rc.bclj" 2>/dev/null > "$W/rc.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename Point Pt rc "$W/rc.edn" 2>/dev/null
chk "->Name constructor renamed (->Point -> ->Pt)" "grep -qF '(->Pt 0 0)' <<<\"\$(\"$RACKET\" \"$RT\" --render $RESOLVE_OUT/resolved-rc.bclj.edn 2>/dev/null)\""
# 11d. quasiquote reader ~ escapes (live) inside a quote; quoted data preserved
printf '#lang beagle/clj\n(ns rq)\n(def base Int 1)\n(defmacro mk [y] `(quote ~(base y)))\n' > "$W/rq.bclj"
"$RACKET" "$RT" --emit-edn "$W/rq.bclj" 2>/dev/null > "$W/rq.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename base root rq "$W/rq.edn" 2>/dev/null
chk "reader ~ unquote inside quote escapes + renames" "grep -qF '(root y)' <<<\"\$(\"$RACKET\" \"$RT\" --render $RESOLVE_OUT/resolved-rq.bclj.edn 2>/dev/null)\""

# --- 12. match patterns + typed let + map->/accessor factories -------------------
echo "--- 12. match-pattern scope + typed let + map->/accessor cascade ---"
# 12a. match constructor pattern renames with the type; match-local not over-renamed
cat > "$W/mt.bclj" <<'EOF'
#lang beagle/clj
(ns mt)
(defrecord Ok [(value Int)])
(defrecord Err [(error Int)])
(defunion Result Ok Err)
(def src Int 100)
(defn f [(r Result)] Int (match r [(Ok v) (+ v src)] [(Err e) e]))
EOF
"$RACKET" "$RT" --emit-edn "$W/mt.bclj" 2>/dev/null > "$W/mt.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename Ok Good mt "$W/mt.edn" 2>/dev/null
chk "match pattern (Ok v) renames with the type" "grep -qF '[(Good v)' <<<\"\$(\"$RACKET\" \"$RT\" --render $RESOLVE_OUT/resolved-mt.bclj.edn 2>/dev/null)\""
# 12b. renaming a def to a match-bound var name is REFUSED (capture)
if bb -cp "$BEAGLE_STORE_OUT" "$RES" rename src v mt "$W/mt.edn" >/dev/null 2>&1; then
  echo "  FAIL  match-pattern capture not refused"; fail=1
else echo "  PASS  match-pattern capture refused"; fi
# 12c. renaming the def does NOT touch the match-bound local of a different name
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename src total mt "$W/mt.edn" 2>/dev/null
chk "match-local 'v' untouched when def renamed" "grep -qF '(+ v total)' <<<\"\$(\"$RACKET\" \"$RT\" --render $RESOLVE_OUT/resolved-mt.bclj.edn 2>/dev/null)\""
# 12d. typed let binding annotation cascades on a type rename
printf '#lang beagle/clj\n(ns tl)\n(defrecord Foo [(v Int)])\n(defn g [(p Foo)] Foo (let [(q Foo) p] q))\n' > "$W/tl.bclj"
"$RACKET" "$RT" --emit-edn "$W/tl.bclj" 2>/dev/null > "$W/tl.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename Foo Bar tl "$W/tl.edn" 2>/dev/null
chk "typed let binding (q Foo) cascades" "grep -qF '(let [(q Bar) p]' <<<\"\$(\"$RACKET\" \"$RT\" --render $RESOLVE_OUT/resolved-tl.bclj.edn 2>/dev/null)\""
# 12e. map-> factory AND synthesized field accessor carry the rename
cat > "$W/fa.bclj" <<'EOF'
#lang beagle/clj
(ns fa)
(defrecord Point
  [(x Int)
   (y Int)])
(defn a [(p Point)] Int (point-x p))
(defn c [] Point (map->Point {:x 1 :y 2}))
EOF
"$RACKET" "$RT" --emit-edn "$W/fa.bclj" 2>/dev/null > "$W/fa.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename Point Vertex fa "$W/fa.edn" 2>/dev/null
fa="$("$RACKET" "$RT" --render $RESOLVE_OUT/resolved-fa.bclj.edn 2>/dev/null)"
chk "field accessor point-x -> vertex-x" "grep -qF '(vertex-x p)' <<<\"\$fa\""
chk "map->Point -> map->Vertex"          "grep -qF '(map->Vertex' <<<\"\$fa\""

# --- 13. cross-module field accessors carry a record rename ----------------------
echo "--- 13. cross-module field accessor (qualified + :refer'd) cascades ---"
# 13a. qualified c/point-x
printf '#lang beagle/clj\n(ns acore)\n(defrecord Point\n  [(x Int)\n   (y Int)])\n' > "$W/acore.bclj"
printf '#lang beagle/clj\n(ns ause)\n(require [acore :as c])\n(defn u [(p c/Point)] Int (c/point-x p))\n' > "$W/ause.bclj"
"$RACKET" "$RT" --emit-edn "$W/acore.bclj" 2>/dev/null > "$W/acore.edn"
"$RACKET" "$RT" --emit-edn "$W/ause.bclj" 2>/dev/null > "$W/ause.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename Point Coord acore "$W/acore.edn" "$W/ause.edn" 2>/dev/null
chk "qualified accessor c/point-x -> c/coord-x" "grep -qF '(c/coord-x p)' <<<\"\$(\"$RACKET\" \"$RT\" --render $RESOLVE_OUT/resolved-ause.bclj.edn 2>/dev/null)\""
# 13b. :refer'd point-x (import vector + call site)
printf '#lang beagle/clj\n(ns rcore)\n(defrecord Point [(x Int)])\n' > "$W/rcore.bclj"
printf '#lang beagle/clj\n(ns ruse)\n(require [rcore :refer [Point point-x]])\n(defn u [(p Point)] Int (point-x p))\n' > "$W/ruse.bclj"
"$RACKET" "$RT" --emit-edn "$W/rcore.bclj" 2>/dev/null > "$W/rcore.edn"
"$RACKET" "$RT" --emit-edn "$W/ruse.bclj" 2>/dev/null > "$W/ruse.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename Point Coord rcore "$W/rcore.edn" "$W/ruse.edn" 2>/dev/null
ru="$("$RACKET" "$RT" --render $RESOLVE_OUT/resolved-ruse.bclj.edn 2>/dev/null)"
chk ":refer'd accessor point-x -> coord-x (import + call)" "grep -qF ':refer [Coord coord-x]' <<<\"\$ru\" && grep -qF '(coord-x p)' <<<\"\$ru\""

# --- 14. fully-qualified module-name refs + type-name-shape guard ----------------
echo "--- 14. fully-qualified (module-name/Name) refs + Capitalized-type guard ---"
# 14a. (require acc.prod) with FQ refs acc.prod/Box, acc.prod/box-w, acc.prod/->Box all cascade
printf '#lang beagle/clj\n(ns acc.prod)\n(defrecord Box [(w Int)])\n' > "$W/fqp.bclj"
printf '#lang beagle/clj\n(ns acc.cons)\n(require acc.prod)\n(defn u [(b acc.prod/Box)] Int (acc.prod/box-w b))\n(defn mk [] acc.prod/Box (acc.prod/->Box 1))\n' > "$W/fqc.bclj"
"$RACKET" "$RT" --emit-edn "$W/fqp.bclj" 2>/dev/null > "$W/fqp.edn"
"$RACKET" "$RT" --emit-edn "$W/fqc.bclj" 2>/dev/null > "$W/fqc.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename Box Crate fqp "$W/fqp.edn" "$W/fqc.edn" 2>/dev/null
fq="$("$RACKET" "$RT" --render $RESOLVE_OUT/resolved-fqc.bclj.edn 2>/dev/null)"
chk "FQ type+accessor+ctor cascade (acc.prod/Crate, crate-w, ->Crate)" "grep -qF 'acc.prod/Crate' <<<\"\$fq\" && grep -qF '(acc.prod/crate-w b)' <<<\"\$fq\" && grep -qF '(acc.prod/->Crate 1)' <<<\"\$fq\""
# 14b. renaming a TYPE to a lowercase name is refused (beagle type names are Capitalized)
if bb -cp "$BEAGLE_STORE_OUT" "$RES" rename Box crate fqp "$W/fqp.edn" "$W/fqc.edn" >/dev/null 2>&1; then
  echo "  FAIL  lowercase type rename not refused"; fail=1
else echo "  PASS  lowercase type rename refused (type-name shape)"; fi

# --- 15. defprotocol method names are renameable cross-module --------------------
echo "--- 15. defprotocol method rename (def + :refer + call) ---"
printf '#lang beagle/clj\n(ns pp.lib)\n(defprotocol Priced (price [self] Int))\n' > "$W/plib.bclj"
printf '#lang beagle/clj\n(ns pp.use)\n(require [pp.lib :refer [price]])\n(defn total [(m Int)] Int (price m))\n' > "$W/puse.bclj"
"$RACKET" "$RT" --emit-edn "$W/plib.bclj" 2>/dev/null > "$W/plib.edn"
"$RACKET" "$RT" --emit-edn "$W/puse.bclj" 2>/dev/null > "$W/puse.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename price cost plib "$W/plib.edn" "$W/puse.edn" 2>/dev/null
pl="$("$RACKET" "$RT" --render $RESOLVE_OUT/resolved-plib.bclj.edn 2>/dev/null)"
pu="$("$RACKET" "$RT" --render $RESOLVE_OUT/resolved-puse.bclj.edn 2>/dev/null)"
chk "protocol method def renamed (cost [self] Int)" "grep -qF '(cost [self] Int)' <<<\"\$pl\""
chk "cross-module :refer + call renamed (cost)"        "grep -qF ':refer [cost]' <<<\"\$pu\" && grep -qF '(cost m)' <<<\"\$pu\""

# --- 16. letfn + extend-type binding scopes --------------------------------------
echo "--- 16. letfn + extend-type impl scopes (capture + shadow) ---"
# 16a. letfn-local capture refused; legitimate rename succeeds + leaves the letfn-local alone
cat > "$W/lf.bclj" <<'EOF'
#lang beagle/clj
(ns lf)
(defn helper [(x Int)] Int (* x 10))
(defn run [(n Int)] Int (letfn [(g [(y Int)] Int (+ y 1))] (+ (g n) (helper n))))
EOF
"$RACKET" "$RT" --emit-edn "$W/lf.bclj" 2>/dev/null > "$W/lf.edn"
if bb -cp "$BEAGLE_STORE_OUT" "$RES" rename helper g lf "$W/lf.edn" >/dev/null 2>&1; then
  echo "  FAIL  letfn-local capture not refused"; fail=1
else echo "  PASS  letfn-local capture refused"; fi
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename helper helper2 lf "$W/lf.edn" 2>/dev/null
chk "letfn: legit rename succeeds, letfn-local g untouched" "grep -qF '(g n)' <<<\"\$(\"$RACKET\" \"$RT\" --render $RESOLVE_OUT/resolved-lf.bclj.edn 2>/dev/null)\" && grep -qF '(helper2 n)' <<<\"\$(\"$RACKET\" \"$RT\" --render $RESOLVE_OUT/resolved-lf.bclj.edn 2>/dev/null)\""
# 16b. extend-type impl-param capture refused; impl param shadows; module def ref cascades
cat > "$W/et.bclj" <<'EOF'
#lang beagle/clj
(ns et)
(defrecord Box [(w Int)])
(defprotocol Area (area [self] Int))
(def scale Int 3)
(extend-type Box Area (area [(self Box)] Int (* (box-w self) scale)))
EOF
"$RACKET" "$RT" --emit-edn "$W/et.bclj" 2>/dev/null > "$W/et.edn"
if bb -cp "$BEAGLE_STORE_OUT" "$RES" rename scale self et "$W/et.edn" >/dev/null 2>&1; then
  echo "  FAIL  extend-type impl-param capture not refused"; fail=1
else echo "  PASS  extend-type impl-param capture refused"; fi
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename scale factor et "$W/et.edn" 2>/dev/null
chk "extend-type: module def ref in impl body cascades; impl param self untouched" "grep -qF '(* (box-w self) factor)' <<<\"\$(\"$RACKET\" \"$RT\" --render $RESOLVE_OUT/resolved-et.bclj.edn 2>/dev/null)\""

# --- 17. as-> threading accumulator binding --------------------------------------
echo "--- 17. as-> accumulator scope (capture + shadow) ---"
cat > "$W/at.bclj" <<'EOF'
#lang beagle/clj
(ns at)
(def base Int 1000)
(defn run [(input Int)] Int (as-> input acc (+ acc 1) (+ acc base)))
EOF
"$RACKET" "$RT" --emit-edn "$W/at.bclj" 2>/dev/null > "$W/at.edn"
# 17a. renaming a module def to the accumulator name is refused (capture)
if bb -cp "$BEAGLE_STORE_OUT" "$RES" rename base acc at "$W/at.edn" >/dev/null 2>&1; then
  echo "  FAIL  as-> accumulator capture not refused"; fail=1
else echo "  PASS  as-> accumulator capture refused"; fi
# 17b. a legit rename cascades the module-def ref in the steps; accumulator untouched
bb -cp "$BEAGLE_STORE_OUT" "$RES" rename base total at "$W/at.edn" 2>/dev/null
chk "as->: module ref in step cascades; accumulator acc untouched" "grep -qF '(+ acc total)' <<<\"\$(\"$RACKET\" \"$RT\" --render $RESOLVE_OUT/resolved-at.bclj.edn 2>/dev/null)\""

echo
if [ "$fail" = 0 ]; then
  echo "RESULT: PASS — one engine covers the current Beagle surface."
else echo "RESULT: FAIL"; exit 1; fi
