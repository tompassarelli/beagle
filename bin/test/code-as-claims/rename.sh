#!/usr/bin/env bash
# Scope-correct rename — repair as a graph operation, the COMPLETE engine.
#
# One engine (chartroom's resolve.clj, Turtle #5: a lexical resolver that adds
# refers_to edges, then renames a def by editing ONE node — references follow
# refers_to). It is correct across all three scope hazards, which a text sed cannot
# be, and O(1) (edits the def, not each reference):
#   1. MODULE COLLISION   — rename mod_a's `helper`; mod_b's same-named one untouched
#   2. SHADOWING          — rename a def; a local of the same name (param/let) untouched
#   3. CROSS-MODULE        — rename a def; every `<alias>/name` reader across files renamed
#   + the collision invariant: a rename onto an existing binding is refused.
# Each renamed tree recompiles. Needs racket + bb + fram out/ + chartroom resolve.clj.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RT="$ROOT/beagle-lib/private/claims-roundtrip.rkt"
FRAM_OUT="${FRAM_OUT:-$HOME/code/fram/out}"
CHARTROOM="${CHARTROOM:-$HOME/code/chartroom}"
RES="$CHARTROOM/src/resolve.clj"
FRAM_SRC="${CODE_AS_CLAIMS_CORPUS:-$HOME/code/fram/src}"
fail=0

echo "================ scope-correct rename — the complete engine (resolve.clj) ================"
[ -d "$FRAM_OUT" ] || { echo "  (need FRAM_OUT)"; exit 3; }
[ -f "$RES" ]     || { echo "  (need CHARTROOM resolve.clj)"; exit 3; }
chk() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi; }
W="$(mktemp -d)"; trap 'rm -rf "$W" /tmp/resolved-*.edn' EXIT

# --- 1. module collision: rename mod_a/helper; mod_b/helper untouched -----------
echo "--- 1. module collision (mod_a/helper renamed; mod_b/helper untouched) ---"
racket "$RT" --emit-edn "$HERE/rename-corpus/mod_a.bclj" 2>/dev/null > "$W/a.edn"
racket "$RT" --emit-edn "$HERE/rename-corpus/mod_b.bclj" 2>/dev/null > "$W/b.edn"
bb -cp "$FRAM_OUT" "$RES" rename helper safe-add mod_a "$W/a.edn" "$W/b.edn" 2>/dev/null
ma="$(racket "$RT" --render /tmp/resolved-mod_a.bclj.edn 2>/dev/null)"
mb="$(racket "$RT" --render /tmp/resolved-mod_b.bclj.edn 2>/dev/null)"
chk "mod_a renamed (def + caller -> safe-add)" "grep -q 'defn safe-add' <<<\"\$ma\" && grep -q '(safe-add x)' <<<\"\$ma\""
chk "mod_b helper UNTOUCHED"                   "grep -q 'defn helper' <<<\"\$mb\" && ! grep -q 'safe-add' <<<\"\$mb\""

# --- 2. shadowing: rename def; shadowing param untouched ------------------------
echo "--- 2. shadowing (def renamed; shadowing local + its use untouched) ---"
racket "$RT" --emit-edn "$HERE/shadow-corpus/mod.bclj" 2>/dev/null > "$W/s.edn"
bb -cp "$FRAM_OUT" "$RES" rename helper add-one mod "$W/s.edn" 2>/dev/null
sm="$(racket "$RT" --render /tmp/resolved-mod.bclj.edn 2>/dev/null)"
chk "def + ref renamed to add-one"   "grep -q 'defn add-one' <<<\"\$sm\" && grep -q '(add-one y)' <<<\"\$sm\""
chk "shadowing param + use UNTOUCHED" "grep -qE 'other \[helper' <<<\"\$sm\" && grep -qF '(* helper 2)' <<<\"\$sm\""

# --- 3. cross-module: rename a def + all its qualified readers across files ------
echo "--- 3. cross-module (fram.cnf/value! -> intern! across fram/src, recompiles) ---"
E="$W/e"; mkdir -p "$E" "$W/r/fram"; edns=()
while IFS= read -r f; do b="$(basename "$f")"; racket "$RT" --emit-edn "$f" 2>/dev/null > "$E/$b.edn"; edns+=("$E/$b.edn"); done < <(find "$FRAM_SRC" -name '*.bclj' | sort)
bb -cp "$FRAM_OUT" "$RES" rename value! intern! cnf "${edns[@]}" 2>/dev/null
while IFS= read -r f; do b="$(basename "$f")"; racket "$RT" --render "/tmp/resolved-$b.edn" 2>/dev/null > "$W/r/fram/$b"; done < <(find "$FRAM_SRC" -name '*.bclj' | sort)
chk "cnf def renamed (intern!)"               "grep -q 'defn intern!' '$W/r/fram/cnf.bclj'"
chk "NO '/value!' cross-module ref left"      "! grep -rqh '/value!' '$W/r/fram/'"
chk "'/intern!' cross-module refs present"    "grep -rqh '/intern!' '$W/r/fram/'"
chk "value-id UNTOUCHED (diff symbol)"        "grep -rqh 'value-id' '$W/r/fram/'"
chk "cross-module tree recompiles"            "\"$ROOT/bin/beagle-build-all\" '$W/r' --out '$W/o' 2>&1 | grep -q '0 error'"

# --- 4. collision invariant: rename onto an existing binding refused ------------
echo "--- 4. collision invariant (rename helper -> other refused) ---"
racket "$RT" --emit-edn "$HERE/shadow-corpus/mod.bclj" 2>/dev/null > "$W/s2.edn"
if bb -cp "$FRAM_OUT" "$RES" rename helper other mod "$W/s2.edn" >/dev/null 2>&1; then
  echo "  FAIL  collision NOT refused"; fail=1
else echo "  PASS  rename onto existing binding refused"; fi

# --- 5. adversarial findings (scope hazards that recompiled-but-wrong) -----------
# All three were found by the unified-engine adversarial sweep; each is a SILENT
# meaning change that compiled clean, the most dangerous failure mode.
echo "--- 5. adversarial scope hazards (paren-param shadowing + capture refusal) ---"
# 5a. typed PAREN param `(red :- Int)` must shadow the def — renaming the def must
#     NOT touch the param or its body use (the param-binding wasn't being collected).
printf '#lang beagle/clj\n(ns demo.p)\n(def red :- Int 1)\n(defn ps [(red :- Int)] :- Int (+ red 100))\n' > "$W/p.bclj"
racket "$RT" --emit-edn "$W/p.bclj" 2>/dev/null > "$W/p.edn"
bb -cp "$FRAM_OUT" "$RES" rename red crimson p "$W/p.edn" 2>/dev/null
pp="$(racket "$RT" --render /tmp/resolved-p.bclj.edn 2>/dev/null)"
chk "paren-param def renamed (crimson)"        "grep -q '(def crimson' <<<\"\$pp\""
chk "paren-param + body use UNTOUCHED"         "grep -qF '[(red :- Int)]' <<<\"\$pp\" && grep -qF '(+ red 100)' <<<\"\$pp\""
# 5b. CAPTURE via param: rename src->dst where dst is a param must be REFUSED
#     (else (+ dst src) -> (+ dst dst), a silent name-capture that recompiles).
printf '#lang beagle/clj\n(ns demo.c)\n(def src :- Int 1)\n(defn f [dst :- Int] :- Int (+ dst src))\n' > "$W/c.bclj"
racket "$RT" --emit-edn "$W/c.bclj" 2>/dev/null > "$W/c.edn"
if bb -cp "$FRAM_OUT" "$RES" rename src dst c "$W/c.edn" >/dev/null 2>&1; then
  echo "  FAIL  param capture NOT refused"; fail=1
else echo "  PASS  param capture refused (no-capture invariant)"; fi
# 5c. CAPTURE via let-local: rename total->sum where sum is a let-local must be REFUSED.
printf '#lang beagle/clj\n(ns demo.l)\n(def total :- Int 100)\n(defn g [x :- Int] :- Int (let [sum (+ x 1)] (* sum total)))\n' > "$W/l.bclj"
racket "$RT" --emit-edn "$W/l.bclj" 2>/dev/null > "$W/l.edn"
if bb -cp "$FRAM_OUT" "$RES" rename total sum l "$W/l.edn" >/dev/null 2>&1; then
  echo "  FAIL  let-local capture NOT refused"; fail=1
else echo "  PASS  let-local capture refused (no-capture invariant)"; fi

# --- 6. type renames (constructor heads, defunion variants, cross-module, single-colon) -
# All found by adversarial sweep #2 — each was a silent miss (type renamed, a USE of it
# left dangling) that recompiled. Types are first-class refactor targets.
echo "--- 6. type resolution (constructors, defunion, cross-module types, single-colon) ---"
# 6a. defrecord constructor (Point 1 2) must rename with the type
printf '#lang beagle/clj\n(ns tp)\n(defrecord Point [(x :- Int) (y :- Int)])\n(defn mk [] :- Point (Point 1 2))\n' > "$W/tp.bclj"
racket "$RT" --emit-edn "$W/tp.bclj" 2>/dev/null > "$W/tp.edn"
bb -cp "$FRAM_OUT" "$RES" rename Point Pt tp "$W/tp.edn" 2>/dev/null
tp="$(racket "$RT" --render /tmp/resolved-tp.bclj.edn 2>/dev/null)"
chk "constructor (Point ..) renamed with the type" "grep -qF '(Pt 1 2)' <<<\"\$tp\" && ! grep -qF '(Point 1 2)' <<<\"\$tp\""
# 6b. defunion variant constructor renames (and the union name independently)
printf '#lang beagle/clj\n(ns tu)\n(defunion Shape (Circle [r :- Float]) (Square [s :- Float]))\n(defn mk [r :- Float] :- Shape (Circle r))\n' > "$W/tu.bclj"
racket "$RT" --emit-edn "$W/tu.bclj" 2>/dev/null > "$W/tu.edn"
bb -cp "$FRAM_OUT" "$RES" rename Circle Disc tu "$W/tu.edn" 2>/dev/null
tu="$(racket "$RT" --render /tmp/resolved-tu.bclj.edn 2>/dev/null)"
chk "defunion variant (Circle r) renamed" "grep -qF '(Disc r)' <<<\"\$tu\" && grep -qF '(Disc [r' <<<\"\$tu\" && grep -qF '(Square' <<<\"\$tu\""
# 6c. cross-module type: consumer's t/Type annotation cascades
printf '#lang beagle/clj\n(ns tlib)\n(defrecord Widget [(n :- Int)])\n' > "$W/tlib.bclj"
printf '#lang beagle/clj\n(ns tcon)\n(require tlib :as t)\n(defn use [w :- t/Widget] :- Int 1)\n' > "$W/tcon.bclj"
racket "$RT" --emit-edn "$W/tlib.bclj" 2>/dev/null > "$W/tlib.edn"
racket "$RT" --emit-edn "$W/tcon.bclj" 2>/dev/null > "$W/tcon.edn"
bb -cp "$FRAM_OUT" "$RES" rename Widget Gadget tlib "$W/tlib.edn" "$W/tcon.edn" 2>/dev/null
chk "cross-module type ref t/Widget -> t/Gadget" "grep -qF 't/Gadget' <<<\"\$(racket \"$RT\" --render /tmp/resolved-tcon.bclj.edn 2>/dev/null)\""
# 6d. single-colon ':' annotation cascades (legal field/param surface)
printf '#lang beagle/clj\n(ns tsc)\n(defrecord Thing [(n :- Int)])\n(defn f [(x : Thing)] :- Int 1)\n' > "$W/tsc.bclj"
racket "$RT" --emit-edn "$W/tsc.bclj" 2>/dev/null > "$W/tsc.edn"
bb -cp "$FRAM_OUT" "$RES" rename Thing Item tsc "$W/tsc.edn" 2>/dev/null
chk "single-colon (x : Thing) -> (x : Item)" "grep -qF '(x : Item)' <<<\"\$(racket \"$RT\" --render /tmp/resolved-tsc.bclj.edn 2>/dev/null)\""
# 6e. rename that matches nothing is refused (not a silent 0-edit success)
printf '#lang beagle/clj\n(ns tz)\n(defn keep-me [x :- Int] :- Int x)\n' > "$W/tz.bclj"
racket "$RT" --emit-edn "$W/tz.bclj" 2>/dev/null > "$W/tz.edn"
if bb -cp "$FRAM_OUT" "$RES" rename nonexistent whatever tz "$W/tz.edn" >/dev/null 2>&1; then
  echo "  FAIL  rename-of-nothing not refused"; fail=1
else echo "  PASS  rename matching no binding refused (no silent 0-edit success)"; fi

# --- 7. sequential binding scope + :or defaults (adversarial sweep #2) ---------------
# let/loop/for bindings are SEQUENTIAL and :or defaults are LIVE refs — both were
# silent miscompiles (a default left dangling; a sibling-capturing rename accepted).
echo "--- 7. sequential bindings + :or defaults ---"
# 7a. :or default referencing a def cascades on rename
printf '#lang beagle/clj\n(ns sa)\n(def base :- Int 10)\n(defn f [{:keys [x] :or {x base}}] :- Int (+ x 1))\n' > "$W/sa.bclj"
racket "$RT" --emit-edn "$W/sa.bclj" 2>/dev/null > "$W/sa.edn"
bb -cp "$FRAM_OUT" "$RES" rename base base2 sa "$W/sa.edn" 2>/dev/null
chk ":or default ref renamed (not left dangling)" "grep -qF ':or {x base2}' <<<\"\$(racket \"$RT\" --render /tmp/resolved-sa.bclj.edn 2>/dev/null)\""
# 7b. for :let sequential capture refused
printf '#lang beagle/clj\n(ns sb)\n(def factor :- Int 10)\n(defn go [xs :- (Vec Int)] :- (Vec Int) (for [x xs :let [g (+ x 1) h (* x factor)]] h))\n' > "$W/sb.bclj"
racket "$RT" --emit-edn "$W/sb.bclj" 2>/dev/null > "$W/sb.edn"
if bb -cp "$FRAM_OUT" "$RES" rename factor g sb "$W/sb.edn" >/dev/null 2>&1; then
  echo "  FAIL  for :let sequential capture not refused"; fail=1
else echo "  PASS  for :let sequential capture refused"; fi
# 7c. let sequential capture refused
printf '#lang beagle/clj\n(ns sc)\n(def total :- Int 100)\n(defn h [x :- Int] :- Int (let [s (+ x 1) t (* s total)] t))\n' > "$W/sc.bclj"
racket "$RT" --emit-edn "$W/sc.bclj" 2>/dev/null > "$W/sc.edn"
if bb -cp "$FRAM_OUT" "$RES" rename total s sc "$W/sc.edn" >/dev/null 2>&1; then
  echo "  FAIL  let sequential capture not refused"; fail=1
else echo "  PASS  let sequential capture refused"; fi
# 7d. CONTROL: a legitimate sequential rename still succeeds (no over-refusal)
bb -cp "$FRAM_OUT" "$RES" rename total grand sc "$W/sc.edn" 2>/dev/null
chk "legitimate sequential rename succeeds (total->grand)" "grep -qF '(* s grand)' <<<\"\$(racket \"$RT\" --render /tmp/resolved-sc.bclj.edn 2>/dev/null)\""

# --- 8. quasiquote templates + bare :refer + import collision (adversarial sweep #2) -
echo "--- 8. quasiquote macro templates + bare :refer + import collision ---"
# 8a. a quasiquote template ref to a module def renames (Clojure ` qualifies it / beagle hygiene-aliases)
printf '#lang beagle/clj\n(ns qq)\n(def base :- Int 1)\n(defmacro add-base [n] (quasiquote (+ base (unquote n))))\n' > "$W/qq.bclj"
racket "$RT" --emit-edn "$W/qq.bclj" 2>/dev/null > "$W/qq.edn"
bb -cp "$FRAM_OUT" "$RES" rename base base2 qq "$W/qq.edn" 2>/dev/null
qq="$(racket "$RT" --render /tmp/resolved-qq.bclj.edn 2>/dev/null)"
chk "quasiquote template ref renamed (+ base2 ..)" "grep -qF '(+ base2 (unquote n))' <<<\"\$qq\""
# 8b. CONTROL: a let-local inside a template must NOT rename (hygiene)
printf '#lang beagle/clj\n(ns qh)\n(def base :- Int 1)\n(defmacro mk [x] (quasiquote (let [tmp (unquote x)] (+ tmp base))))\n' > "$W/qh.bclj"
racket "$RT" --emit-edn "$W/qh.bclj" 2>/dev/null > "$W/qh.edn"
bb -cp "$FRAM_OUT" "$RES" rename base base2 qh "$W/qh.edn" 2>/dev/null
chk "template local 'tmp' untouched, base->base2" "grep -qF '(let [tmp (unquote x)] (+ tmp base2))' <<<\"\$(racket \"$RT\" --render /tmp/resolved-qh.bclj.edn 2>/dev/null)\""
# 8c. bare (require m :refer [x]) cross-module ref renames (parse-require handles bare :refer)
printf '#lang beagle/clj\n(ns rlib)\n(defn red [x :- Int] :- Int x)\n' > "$W/rlib.bclj"
printf '#lang beagle/clj\n(ns rcon)\n(require rlib :refer [red])\n(defn use [y :- Int] :- Int (red y))\n' > "$W/rcon.bclj"
racket "$RT" --emit-edn "$W/rlib.bclj" 2>/dev/null > "$W/rlib.edn"
racket "$RT" --emit-edn "$W/rcon.bclj" 2>/dev/null > "$W/rcon.edn"
bb -cp "$FRAM_OUT" "$RES" rename red crimson rlib "$W/rlib.edn" "$W/rcon.edn" 2>/dev/null
chk "bare :refer'd ref renames cross-module (red->crimson)" "grep -qF '(crimson y)' <<<\"\$(racket \"$RT\" --render /tmp/resolved-rcon.bclj.edn 2>/dev/null)\""
# 8d. import collision: consumer :refer's old AND already binds new -> refuse
printf '#lang beagle/clj\n(ns rcon2)\n(require rlib :refer [red])\n(defn blue [y :- Int] :- Int (red y))\n' > "$W/rcon2.bclj"
racket "$RT" --emit-edn "$W/rcon2.bclj" 2>/dev/null > "$W/rcon2.edn"
if bb -cp "$FRAM_OUT" "$RES" rename red blue rlib "$W/rlib.edn" "$W/rcon2.edn" >/dev/null 2>&1; then
  echo "  FAIL  import collision not refused"; fail=1
else echo "  PASS  import collision (consumer already binds new) refused"; fi

# --- 9. deeper type/quasiquote forms (adversarial sweep #3) --------------------------
echo "--- 9. parameterized defunion + protocol return type + quasiquote quote-data ---"
# 9a. parameterized defunion name (Result T E) renames + its annotations cascade
printf '#lang beagle/clj\n(ns pd)\n(defunion (Result T E) (Ok [v :- T]) (Err [e :- E]))\n(defn mk [v :- Int] :- (Result Int Int) (Ok v))\n' > "$W/pd.bclj"
racket "$RT" --emit-edn "$W/pd.bclj" 2>/dev/null > "$W/pd.edn"
bb -cp "$FRAM_OUT" "$RES" rename Result Either pd "$W/pd.edn" 2>/dev/null
pd="$(racket "$RT" --render /tmp/resolved-pd.bclj.edn 2>/dev/null)"
chk "parameterized defunion (Result T E)->(Either T E) + annotation" "grep -qF '(defunion (Either T E)' <<<\"\$pd\" && grep -qF ':- (Either Int Int)' <<<\"\$pd\""
# 9b. defprotocol method RETURN type cascades
printf '#lang beagle/clj\n(ns pp)\n(defrecord Box [(v :- Int)])\n(defprotocol Maker (make [self] :- Box))\n' > "$W/pp.bclj"
racket "$RT" --emit-edn "$W/pp.bclj" 2>/dev/null > "$W/pp.edn"
bb -cp "$FRAM_OUT" "$RES" rename Box Crate pp "$W/pp.edn" 2>/dev/null
chk "defprotocol method return :- Box -> :- Crate" "grep -qF '(make [self] :- Crate)' <<<\"\$(racket \"$RT\" --render /tmp/resolved-pp.bclj.edn 2>/dev/null)\""
# 9c. (quote ..) inside a quasiquote is inert DATA — must NOT be renamed
printf '#lang beagle/clj\n(ns qd)\n(def red :- Int 1)\n(defmacro mk [] (quasiquote (quote (red))))\n' > "$W/qd.bclj"
racket "$RT" --emit-edn "$W/qd.bclj" 2>/dev/null > "$W/qd.edn"
bb -cp "$FRAM_OUT" "$RES" rename red crimson qd "$W/qd.edn" 2>/dev/null
qd="$(racket "$RT" --render /tmp/resolved-qd.bclj.edn 2>/dev/null)"
chk "quasiquote (quote (red)) data untouched; def->crimson" "grep -qF '(quote (red))' <<<\"\$qd\" && grep -qF '(def crimson' <<<\"\$qd\""

echo
if [ "$fail" = 0 ]; then
  echo "RESULT: PASS — one engine: collision/shadowing/cross-module/types/sequential/quasiquote, recompiles."
else echo "RESULT: FAIL"; exit 1; fi
