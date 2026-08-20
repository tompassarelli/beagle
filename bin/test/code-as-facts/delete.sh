#!/usr/bin/env bash
# Delete as a graph operation — the no-orphaned-references invariant.
#
# The second verb in the authoring vocabulary (after rename). Deleting a def is a
# fact edit on the canonical store, gated by a REASONING query the graph can answer
# exactly and text cannot: "does any reference point at this binding?" (refers_to).
#   - SAFE (no references): remove the def's form + project; the rest of the file
#     survives (the renderer reads CRDT-ordered children, so the engine must
#     supersede the selected slot without disturbing sibling order) and
#     recompiles.
#   - UNSAFE (a reference would be orphaned, in THIS module or a CONSUMER via alias):
#     refuse, mutate nothing (fail closed).
# Needs racket + bb + store out/ resolve.clj.
set -uo pipefail
export RESOLVE_OUT="$(mktemp -d)"   # hermetic: per-run render output (no global /tmp collision)

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RT="$ROOT/beagle-lib/private/facts-roundtrip.rkt"
BEAGLE_STORE_REPO="${BEAGLE_STORE_REPO:-$HOME/code/store/main}"
BEAGLE_STORE_OUT="${BEAGLE_STORE_OUT:-$BEAGLE_STORE_REPO/out}"
source "$ROOT/bin/_beagle-racket"
source "$ROOT/bin/_beagle-store-resolver"
CORP="$HERE/delete-corpus"
fail=0

echo "================ delete as a graph op — no-orphaned-references invariant ================"
[ -d "$BEAGLE_STORE_OUT" ] || { echo "  (need BEAGLE_STORE_OUT)"; exit 3; }
RES="$(find_store_resolver)" || exit 3
chk() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi; }
W="$(mktemp -d)"; trap 'rm -rf "${W:?}" "${RESOLVE_OUT:?}"' EXIT

# --- 1. SAFE delete: remove an unreferenced def; before/after forms survive --------
echo "--- 1. safe delete (unreferenced 'dead'; 'before'/'after' survive, recompiles) ---"
"$RACKET" "$RT" --emit-edn "$CORP/del_unused.bclj" 2>/dev/null > "$W/u.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" delete dead unused "$W/u.edn" 2>/dev/null
du="$("$RACKET" "$RT" --render $RESOLVE_OUT/resolved-del_unused.bclj.edn 2>/dev/null)"
chk "'dead' def removed"                "! grep -q 'defn dead' <<<\"\$du\""
chk "'before' SURVIVES (no truncation)" "grep -q 'defn before' <<<\"\$du\""
chk "'after' SURVIVES (no truncation)"  "grep -q 'defn after' <<<\"\$du\""
printf '%s\n' "$du" > "$W/regen.bclj"
chk "deleted result recompiles"         "\"$ROOT/bin/beagle-build-all\" '$W/regen.bclj' --out '$W/o1' 2>&1 | grep -q '0 error'"

# --- 2. UNSAFE same-module: 'helper' is called by 'caller' -> refuse ----------------
echo "--- 2. same-module reference -> refuse (orphan) ---"
"$RACKET" "$RT" --emit-edn "$CORP/del_used.bclj" 2>/dev/null > "$W/d.edn"
if bb -cp "$BEAGLE_STORE_OUT" "$RES" delete helper used "$W/d.edn" >/dev/null 2>&1; then
  echo "  FAIL  same-module orphan NOT refused"; fail=1
else echo "  PASS  same-module reference refuses delete (no-orphaned-refs)"; fi

# --- 3. UNSAFE cross-module: consumer refers l/shared -> refuse --------------------
echo "--- 3. cross-module reference (l/shared) -> refuse (orphan) ---"
"$RACKET" "$RT" --emit-edn "$CORP/del_lib.bclj" 2>/dev/null > "$W/lib.edn"
"$RACKET" "$RT" --emit-edn "$CORP/del_consumer.bclj" 2>/dev/null > "$W/con.edn"
if bb -cp "$BEAGLE_STORE_OUT" "$RES" delete shared lib "$W/lib.edn" "$W/con.edn" >/dev/null 2>&1; then
  echo "  FAIL  cross-module orphan NOT refused"; fail=1
else echo "  PASS  cross-module reference refuses delete (no-orphaned-refs)"; fi

# --- 4. a defunion VARIANT is not an independently-deletable top-level form -> refuse --
echo "--- 4. defunion variant delete -> refuse (no false 0-form success) ---"
cat > "$W/uni.bclj" <<'EOF'
#lang beagle/clj
(ns delcorp.uni)
(defunion Shape (Circle [(r Float)]) (Sq [(s Float)]))
(defn mk [(r Float)] Shape (Circle r))
EOF
"$RACKET" "$RT" --emit-edn "$W/uni.bclj" 2>/dev/null > "$W/uni.edn"
if bb -cp "$BEAGLE_STORE_OUT" "$RES" delete Sq uni "$W/uni.edn" >/dev/null 2>&1; then
  echo "  FAIL  variant delete reported success on unchanged tree"; fail=1
else echo "  PASS  defunion variant delete refused (not a top-level form)"; fi

# --- 5. a self-documented def IS deletable (its own doc-comment goes with it) ---------
echo "--- 5. self-documented def delete (own comment pruned, not counted as orphan) ---"
cat > "$W/doc.bclj" <<'EOF'
#lang beagle/clj
(ns delcorp.doc)
;; doc mentioning dead
(defn dead [(x Int)] Int x)
(defn keep-me [(y Int)] Int y)
EOF
"$RACKET" "$RT" --emit-edn "$W/doc.bclj" 2>/dev/null > "$W/doc.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" delete dead doc "$W/doc.edn" 2>/dev/null
dd="$("$RACKET" "$RT" --render $RESOLVE_OUT/resolved-doc.bclj.edn 2>/dev/null)"
chk "self-doc def 'dead' removed (not blocked by its own comment)" "! grep -q 'defn dead' <<<\"\$dd\""
chk "its doc comment removed too"                                  "! grep -q 'doc mentioning dead' <<<\"\$dd\""
chk "'keep-me' survives"                                           "grep -q 'defn keep-me' <<<\"\$dd\""

# --- 6. deleting a defunion that still has live VARIANT-constructor refs -> refuse ----
# (the orphan scan must flag refs to the union's variants, not just the union name)
echo "--- 6. delete defunion with a live variant-ctor ref -> refuse ---"
cat > "$W/var.bclj" <<'EOF'
#lang beagle/clj
(ns delcorp.var)
(defunion Maybe (Some [(v Int)]) None)
(def thing Maybe (Some 7))
EOF
"$RACKET" "$RT" --emit-edn "$W/var.bclj" 2>/dev/null > "$W/var.edn"
if bb -cp "$BEAGLE_STORE_OUT" "$RES" delete Maybe var "$W/var.edn" >/dev/null 2>&1; then
  echo "  FAIL  union delete left a variant-ctor ref orphaned"; fail=1
else echo "  PASS  union delete refused (a variant-ctor ref would orphan)"; fi

# --- 7. a parameterized type head is deletable when unused ----------------------------
echo "--- 7. delete unused parameterized union (Opt A) -> projects ---"
cat > "$W/par.bclj" <<'EOF'
#lang beagle/clj
(ns delcorp.par)
(defunion (Opt A) (Sm [(v A)]) Non)
(defn keep-me [(x Int)] Int x)
EOF
"$RACKET" "$RT" --emit-edn "$W/par.bclj" 2>/dev/null > "$W/par.edn"
bb -cp "$BEAGLE_STORE_OUT" "$RES" delete Opt par "$W/par.edn" 2>/dev/null
pr="$("$RACKET" "$RT" --render $RESOLVE_OUT/resolved-par.bclj.edn 2>/dev/null)"
chk "parameterized union (Opt A) removed"  "! grep -q 'defunion' <<<\"\$pr\""
chk "'keep-me' survives"                   "grep -q 'defn keep-me' <<<\"\$pr\""

# --- 8. multi-arity body refs + ->ctor refs are seen by the orphan scan (sweep #5) ---
echo "--- 8. multi-arity body + ->constructor references block delete ---"
cat > "$W/ma.bclj" <<'EOF'
#lang beagle/clj
(ns delcorp.ma)
(def base Int 5)
(defn f
  ([(x Int)] Int (+ x base))
  ([(x Int) (y Int)] Int (+ x y base)))
EOF
"$RACKET" "$RT" --emit-edn "$W/ma.bclj" 2>/dev/null > "$W/ma.edn"
if bb -cp "$BEAGLE_STORE_OUT" "$RES" delete base ma "$W/ma.edn" >/dev/null 2>&1; then
  echo "  FAIL  multi-arity body ref not seen (delete wrongly succeeded)"; fail=1
else echo "  PASS  multi-arity body reference blocks delete"; fi
cat > "$W/ct.bclj" <<'EOF'
#lang beagle/clj
(ns delcorp.ct)
(defrecord Point [(x Int)])
(defn mk [] Point (->Point 1))
EOF
"$RACKET" "$RT" --emit-edn "$W/ct.bclj" 2>/dev/null > "$W/ct.edn"
if bb -cp "$BEAGLE_STORE_OUT" "$RES" delete Point ct "$W/ct.edn" >/dev/null 2>&1; then
  echo "  FAIL  ->ctor ref not seen (delete wrongly succeeded)"; fail=1
else echo "  PASS  ->constructor reference blocks delete"; fi

# --- 9. match-pattern + field-accessor references block delete -------------------
echo "--- 9. match-pattern ctor + field-accessor references block delete ---"
cat > "$W/mt.bclj" <<'EOF'
#lang beagle/clj
(ns delcorp.mt)
(defrecord Ok [(value Int)])
(defrecord Err [(error Int)])
(defunion Result Ok Err)
(defn f [(r Result)] Int (match r [(Ok v) v] [(Err e) e]))
EOF
"$RACKET" "$RT" --emit-edn "$W/mt.bclj" 2>/dev/null > "$W/mt.edn"
if bb -cp "$BEAGLE_STORE_OUT" "$RES" delete Ok mt "$W/mt.edn" >/dev/null 2>&1; then
  echo "  FAIL  match-pattern ctor ref not seen (delete wrongly succeeded)"; fail=1
else echo "  PASS  match-pattern ctor reference blocks delete"; fi
cat > "$W/fa.bclj" <<'EOF'
#lang beagle/clj
(ns delcorp.fa)
(defrecord Point [(x Int)])
(defn a [(p Point)] Int (point-x p))
EOF
"$RACKET" "$RT" --emit-edn "$W/fa.bclj" 2>/dev/null > "$W/fa.edn"
if bb -cp "$BEAGLE_STORE_OUT" "$RES" delete Point fa "$W/fa.edn" >/dev/null 2>&1; then
  echo "  FAIL  field-accessor ref not seen (delete wrongly succeeded)"; fail=1
else echo "  PASS  field-accessor reference blocks delete"; fi

# --- 10. fully-qualified consumer refs block delete ------------------------------
echo "--- 10. fully-qualified consumer references block delete ---"
cat > "$W/fqp.bclj" <<'EOF'
#lang beagle/clj
(ns delcorp.fqp)
(defrecord Box [(w Int)])
EOF
cat > "$W/fqc.bclj" <<'EOF'
#lang beagle/clj
(ns delcorp.fqc)
(require delcorp.fqp)
(defn u [(b delcorp.fqp/Box)] Int (delcorp.fqp/box-w b))
EOF
"$RACKET" "$RT" --emit-edn "$W/fqp.bclj" 2>/dev/null > "$W/fqp.edn"
"$RACKET" "$RT" --emit-edn "$W/fqc.bclj" 2>/dev/null > "$W/fqc.edn"
if bb -cp "$BEAGLE_STORE_OUT" "$RES" delete Box fqp "$W/fqp.edn" "$W/fqc.edn" >/dev/null 2>&1; then
  echo "  FAIL  fully-qualified consumer ref not seen (delete wrongly succeeded)"; fail=1
else echo "  PASS  fully-qualified consumer reference blocks delete"; fi

echo
if [ "$fail" = 0 ]; then
  echo "RESULT: PASS — delete projects when safe (no truncation), refuses orphans/variants, prunes own comment."
else echo "RESULT: FAIL"; exit 1; fi
