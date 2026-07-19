#!/usr/bin/env bash
# Downstream gate C4: forced-failure propagation probe.
#
# Proves the hermetic downstream gate (bin/beagle-downstream, gate C2) is
# LOAD-BEARING once wired into bin/beagle-ci's layer 5
# (BEAGLE_DOWNSTREAM_GATE=1): a deterministic, planted consumer defect makes
# `bin/beagle-ci` exit non-zero via that EXACT shipped shell block, and a
# deterministic healthy consumer leaves it at exit 0.
#
# Independent of gjoa's actual (currently real, pre-existing) E009 breakage:
# this plants its OWN throwaway consumer via a fixture registry
# (BEAGLE_DOWNSTREAM_REGISTRY), so the probe stays green/red deterministically
# regardless of the live gjoa repo's repair state.
#
# KNOWN PRE-EXISTING BLOCKER (unrelated to this gate, not introduced here):
# `raco test beagle-test/tests/` (layer 1, base commit 18f7e40) currently has
# 2 failures in beagle-test/tests/nix-import-roundtrip.rkt (importer ~''
# multiline-string emission) — confirmed pre-existing via `git diff 18f7e40 --
# beagle-test/tests/nix-import-roundtrip.rkt` (no diff: this worktree never
# touched that file) and reproduces on a bare raco test run with no downstream
# env vars set. That failure alone makes a full `bin/beagle-ci` run non-zero
# REGARDLESS of the downstream gate (layer 1 aborts under `set -e` before
# layer 5 ever runs) — it would falsely satisfy a naive "exit non-zero" probe
# without proving downstream-gate propagation specifically. So this probe:
#   (1) proves the EXACT shipped layer-5 shell block (extracted verbatim from
#       bin/beagle-ci by line-anchor, not a re-implementation) reads
#       BEAGLE_DOWNSTREAM_GATE/_REGISTRY/_CONSUMER/_ALLOW_DIRTY and propagates
#       bin/beagle-downstream's exit code correctly, isolated from layers 1-4
#       so the pre-existing unrelated failure cannot mask or fake the result;
#   (2) additionally runs one REAL end-to-end `bin/beagle-ci` invocation with
#       the forced-fail fixture to show current full-script behavior honestly
#       (today: non-zero either way, because of the pre-existing layer-1 bug
#       OR the planted layer-5 defect — both are real reasons to block a
#       release, so this is not a false negative, but it cannot by itself
#       distinguish the two causes, which is exactly why (1) exists).
#
# Racket-only, hermetic (throwaway git fixture repos under $TMPDIR; never
# touches a real consumer). Not part of `bin/beagle test`'s active tier — a
# focused probe you run directly (see AGENTS.md "full relevant gates").
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT"

fail=0
BASE="$(mktemp -d -t downstream-ci-gate-XXXXXX)"
cleanup() { rm -rf "$BASE"; }
trap cleanup EXIT

echo "================ downstream gate C4 — forced-failure propagation ================"

mk_fixture_repo() { # mk_fixture_repo <dir> <bjs-content>
    local dir="$1" content="$2"
    mkdir -p "$dir/js"
    printf '%s' "$content" > "$dir/js/mod.bjs"
    git -C "$dir" init -q
    git -C "$dir" config user.email "t@example.com"
    git -C "$dir" config user.name "t"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m fixture
}

mk_registry() { # mk_registry <path> <name> <repo-dir>
    cat > "$1" <<EOF
((consumer
  (name "$2")
  (repo-env "DOWNSTREAM_CI_GATE_FIXTURE_REPO")
  (repo-default "$3")
  (target "js")
  (enumerators
   ((enumerator (kind glob) (source #f) (root "js") (ext ".bjs")
                (recursive #t) (skip-basenames ()) (skip-suffixes ())
                (skip-prefixes ()) (shape-markers ()))))))
EOF
}

GOOD_JS='#lang beagle/js
(ns fixture.good)
(defn add [a :- Int b :- Int] :- Int (+ a b))
'
BAD_JS='#lang beagle/js
(ns fixture.bad)
(defn f [] :- Int "not an int")
'

RED_REPO="$BASE/red-repo"
RED_REG="$BASE/red-registry.rktd"
mk_fixture_repo "$RED_REPO" "$BAD_JS"
mk_registry "$RED_REG" "forced-fail" "$RED_REPO"

GREEN_REPO="$BASE/green-repo"
GREEN_REG="$BASE/green-registry.rktd"
mk_fixture_repo "$GREEN_REPO" "$GOOD_JS"
mk_registry "$GREEN_REG" "forced-pass" "$GREEN_REPO"

# --- (1) isolated layer-5 block, extracted VERBATIM from bin/beagle-ci ------
# Anchor: the line the layer starts on (kept in sync manually; if this grep
# finds nothing the extraction is stale and the probe fails loudly instead of
# silently testing nothing).
anchor='if \[\[ "\${BEAGLE_DOWNSTREAM_GATE:-0}" == "1" \]\]; then'
start_line="$(grep -n "$anchor" bin/beagle-ci | head -1 | cut -d: -f1)"
if [[ -z "$start_line" ]]; then
    echo "  FAIL: layer-5 anchor not found in bin/beagle-ci — probe is stale, fix the anchor"
    fail=1
else
    layer5_script="$BASE/layer5.sh"
    { echo '#!/usr/bin/env bash'; echo 'set -euo pipefail'; echo "cd \"$ROOT\""; echo 'repo="'"$ROOT"'"';
      tail -n +"$start_line" bin/beagle-ci | sed '/^echo "beagle-ci/,$d'; } > "$layer5_script"
    chmod +x "$layer5_script"

    echo "--- (1a) isolated layer-5: forced consumer defect -> non-zero, names the consumer ---"
    out="$BASE/l5-red.out"
    if BEAGLE_DOWNSTREAM_GATE=1 BEAGLE_DOWNSTREAM_REGISTRY="$RED_REG" "$layer5_script" >"$out" 2>&1; then
        echo "  FAIL: isolated layer-5 exited 0 with a planted consumer defect"
        cat "$out" | sed 's/^/    /'
        fail=1
    elif grep -q 'forced-fail[[:space:]]*fail[[:space:]]' "$out" && grep -q 'VERDICT: fail' "$out"; then
        echo "  PASS: isolated layer-5 exited non-zero with verdict=fail on the forced-fail consumer (real type-check failure, not a fixture bug)"
    else
        echo "  FAIL: isolated layer-5 exited non-zero but not via the expected forced-fail consumer result line"
        cat "$out" | sed 's/^/    /'
        fail=1
    fi

    echo "--- (1b) isolated layer-5: healthy planted consumer -> exit 0 ---"
    out="$BASE/l5-green.out"
    if BEAGLE_DOWNSTREAM_GATE=1 BEAGLE_DOWNSTREAM_REGISTRY="$GREEN_REG" "$layer5_script" >"$out" 2>&1; then
        echo "  PASS: isolated layer-5 exited 0 (sensitive, not always-red)"
    else
        echo "  FAIL: isolated layer-5 exited non-zero with a healthy planted consumer"
        cat "$out" | sed 's/^/    /'
        fail=1
    fi

    echo "--- (1c) isolated layer-5: gate unset -> skip line, exit 0 regardless of registry ---"
    out="$BASE/l5-skip.out"
    if BEAGLE_DOWNSTREAM_REGISTRY="$RED_REG" "$layer5_script" >"$out" 2>&1; then
        if grep -q 'downstream consumer gate (skipped' "$out"; then
            echo "  PASS: gate unset -> skip line printed, exit 0 even with a red fixture registry present"
        else
            echo "  FAIL: gate unset but skip line missing"
            fail=1
        fi
    else
        echo "  FAIL: gate unset but layer exited non-zero (should be independent of the registry)"
        cat "$out" | sed 's/^/    /'
        fail=1
    fi
fi

# --- (2) one real end-to-end bin/beagle-ci run with the forced-fail fixture -
echo "--- (2) real end-to-end: BEAGLE_DOWNSTREAM_GATE=1 bin/beagle-ci with forced-fail registry ---"
e2e_out="$BASE/e2e.out"
if BEAGLE_DOWNSTREAM_GATE=1 BEAGLE_DOWNSTREAM_REGISTRY="$RED_REG" bin/beagle-ci >"$e2e_out" 2>&1; then
    echo "  FAIL: full bin/beagle-ci exited 0 with a planted downstream defect present"
    fail=1
else
    if grep -q '^2/1949 test failures$' "$e2e_out"; then
        echo "  PASS (non-zero, cause = pre-existing unrelated layer-1 nix-import-roundtrip failure, documented above; layer 5 never reached this run)"
    elif grep -q 'forced-fail' "$e2e_out"; then
        echo "  PASS (non-zero, cause = the planted layer-5 downstream defect, reached and propagated)"
    else
        echo "  PASS (non-zero; exact layer not identified by marker match — see $e2e_out)"
    fi
fi

echo
if [[ "$fail" -eq 0 ]]; then
    echo "downstream-ci-gate: PASS — the shipped layer-5 block in bin/beagle-ci propagates a forced consumer failure/success correctly and stays off by default"
else
    echo "downstream-ci-gate: FAIL"
fi
exit "$fail"
