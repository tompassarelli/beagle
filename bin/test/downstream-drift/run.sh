#!/usr/bin/env bash
# Downstream drift exit-classification controls.
#
# Proves the public CLI contract for `bin/beagle-downstream --run`: every
# representative registry-drift class exits EXACTLY 3 with one pointed, stable
# diagnostic line and NO Racket thread traceback, while the other exit classes
# are preserved — real consumer compile failure = 1, dirty-consumer refusal = 2,
# clean success = 0.
#
# The pre-fix bug: drift thrown inside --run worker execution escaped the worker
# thread as an uncaught-exception traceback (exit 1), diverging from --list's
# clean exit 3. This probe is the red/green control for that fix.
#
# Racket-only, hermetic (throwaway git fixture repos under $TMPDIR; never touches
# a real consumer). Run directly; not part of `bin/beagle test`'s active tier.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT"
source bin/_beagle-racket >/dev/null 2>&1 || true

fail=0
BASE="$(mktemp -d -t downstream-drift-XXXXXX)"
cleanup() { rm -rf "$BASE"; }
trap cleanup EXIT

echo "================ downstream drift — exit classification controls ================"

mk_repo() { # mk_repo <dir> ; caller populates it first, then this commits it
    git -C "$1" init -q
    git -C "$1" config user.email t@example.com
    git -C "$1" config user.name t
    git -C "$1" add -A
    git -C "$1" commit -q -m fixture --allow-empty
}

GOOD_JS='#lang beagle/js
(ns fixture.good)
(defn add [a :- Int b :- Int] :- Int (+ a b))
'
BAD_JS='#lang beagle/js
(ns fixture.bad)
(defn f [] :- Int "not an int")
'

# assert_run <label> <expected-exit> <expect-drift?> <registry> [extra args...]
assert_run() {
    local label="$1" want="$2" drift="$3" reg="$4"; shift 4
    local out="$BASE/${label}.out"
    bin/beagle-downstream --run --registry "$reg" "$@" >"$out" 2>&1
    local got=$?
    if [[ "$got" -ne "$want" ]]; then
        echo "  FAIL [$label]: expected exit $want, got $got"
        sed 's/^/    /' "$out"; fail=1; return
    fi
    if [[ "$drift" == "yes" ]]; then
        if ! grep -q '^FAIL (drift): downstream drift: ' "$out"; then
            echo "  FAIL [$label]: exit $got but no single pointed 'FAIL (drift):' line"
            sed 's/^/    /' "$out"; fail=1; return
        fi
        if grep -q 'context\.\.\.' "$out"; then
            echo "  FAIL [$label]: exit $got but a Racket thread traceback ('context...') leaked"
            sed 's/^/    /' "$out"; fail=1; return
        fi
    fi
    echo "  PASS [$label]: exit $got${drift:+ (drift=$drift)}"
}

# --- drift class 1: missing consumer repo -> exit 3 --------------------------
REG="$BASE/reg-missing.rktd"
cat > "$REG" <<EOF
((consumer (name "gone") (repo-env "DRIFT_MISSING") (repo-default "$BASE/does-not-exist")
  (target "js")
  (enumerators ((enumerator (kind glob) (source #f) (root "js") (ext ".bjs")
                (recursive #t) (skip-basenames ()) (skip-suffixes ())
                (skip-prefixes ()) (shape-markers ()))))))
EOF
assert_run "missing-consumer" 3 yes "$REG"

# --- drift class 2: stale bash-array shape (marker renamed) -> exit 3 --------
R="$BASE/wake"; mkdir -p "$R/web/bin" "$R/web/compiler"
printf 'MODULES=(alpha)\n' > "$R/web/bin/wake-compile"     # `modules=(` gone
printf ';;\n' > "$R/web/compiler/alpha.bjs"; mk_repo "$R"
REG="$BASE/reg-array.rktd"
cat > "$REG" <<EOF
((consumer (name "wake") (repo-env "DRIFT_WAKE") (repo-default "$R") (target "js")
  (enumerators ((enumerator (kind bash-array) (source "web/bin/wake-compile")
                (array-name "modules") (template "web/compiler/{}.bjs")
                (shape-markers ("modules=(")))))))
EOF
assert_run "stale-bash-array" 3 yes "$REG"

# --- drift class 3: glob seam grew a manifest -> exit 3 ----------------------
R="$BASE/northweb"; mkdir -p "$R/web-bjs/src"
printf ';;\n' > "$R/web-bjs/src/a.bjs"
printf 'modules=(a)\n' > "$R/web-bjs/build.sh"             # manifest appeared
mk_repo "$R"
REG="$BASE/reg-manifest.rktd"
cat > "$REG" <<EOF
((consumer (name "northweb") (repo-env "DRIFT_NORTHWEB") (repo-default "$R") (target "js")
  (enumerators ((enumerator (kind glob) (source #f) (root "web-bjs/src") (ext ".bjs")
                (recursive #f) (require-absent "web-bjs/build.sh")
                (skip-basenames ()) (skip-suffixes ()) (skip-prefixes ())
                (shape-markers ()))))))
EOF
assert_run "manifest-growth" 3 yes "$REG"

# --- drift class 4: enumerated source vanished -> exit 3 ---------------------
R="$BASE/fram"; mkdir -p "$R/src/fram"
printf 'for m in types store; do build $m; done\n' > "$R/build.sh"
printf ';;\n' > "$R/src/fram/types.bclj"                  # store.bclj MISSING
mk_repo "$R"
REG="$BASE/reg-vanished.rktd"
cat > "$REG" <<EOF
((consumer (name "fram") (repo-env "DRIFT_FRAM") (repo-default "$R") (target "clj")
  (enumerators ((enumerator (kind bash-for-list) (source "build.sh") (loop-var "m")
                (template "src/fram/{}.bclj") (shape-markers ("for m in")))))))
EOF
assert_run "vanished-source" 3 yes "$REG"

# --- preserved: real compile failure -> exit 1 ------------------------------
R="$BASE/redcompile"; mkdir -p "$R/js"
printf '%s' "$BAD_JS" > "$R/js/mod.bjs"; mk_repo "$R"
REG="$BASE/reg-red.rktd"
cat > "$REG" <<EOF
((consumer (name "redc") (repo-env "DRIFT_REDC") (repo-default "$R") (target "js")
  (enumerators ((enumerator (kind glob) (source #f) (root "js") (ext ".bjs")
                (recursive #t) (skip-basenames ()) (skip-suffixes ())
                (skip-prefixes ()) (shape-markers ()))))))
EOF
assert_run "real-compile-fail" 1 no "$REG"

# --- preserved: dirty consumer worktree -> exit 2 ---------------------------
R="$BASE/dirty"; mkdir -p "$R/js"
printf '%s' "$GOOD_JS" > "$R/js/mod.bjs"; mk_repo "$R"
printf '%s' "$GOOD_JS" > "$R/js/uncommitted.bjs"          # untracked -> dirty
REG="$BASE/reg-dirty.rktd"
cat > "$REG" <<EOF
((consumer (name "dirtyc") (repo-env "DRIFT_DIRTY") (repo-default "$R") (target "js")
  (enumerators ((enumerator (kind glob) (source #f) (root "js") (ext ".bjs")
                (recursive #t) (skip-basenames ()) (skip-suffixes ())
                (skip-prefixes ()) (shape-markers ()))))))
EOF
assert_run "dirty-refusal" 2 no "$REG"

# --- preserved: clean success -> exit 0 -------------------------------------
R="$BASE/green"; mkdir -p "$R/js"
printf '%s' "$GOOD_JS" > "$R/js/mod.bjs"; mk_repo "$R"
REG="$BASE/reg-green.rktd"
cat > "$REG" <<EOF
((consumer (name "greenc") (repo-env "DRIFT_GREEN") (repo-default "$R") (target "js")
  (enumerators ((enumerator (kind glob) (source #f) (root "js") (ext ".bjs")
                (recursive #t) (skip-basenames ()) (skip-suffixes ())
                (skip-prefixes ()) (shape-markers ()))))))
EOF
assert_run "clean-success" 0 no "$REG"

# --- scratch containment: no leftover scratch trees after any run above -----
leftover="$(find "${TMPDIR:-/tmp}" /var/tmp -maxdepth 1 -name 'beagle-downstream-*' -newer "$BASE" 2>/dev/null | wc -l)"
if [[ "$leftover" -ne 0 ]]; then
    echo "  FAIL [scratch-containment]: $leftover leftover beagle-downstream-* scratch dir(s)"
    fail=1
else
    echo "  PASS [scratch-containment]: no leftover scratch trees"
fi

echo
if [[ "$fail" -eq 0 ]]; then
    echo "downstream-drift: PASS — all four drift classes exit 3 with a single pointed line and no traceback; compile=1, dirty=2, success=0 preserved"
else
    echo "downstream-drift: FAIL"
fi
exit "$fail"
