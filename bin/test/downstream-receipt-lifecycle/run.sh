#!/usr/bin/env bash
# Downstream gate — layer-5 receipt & temp-root LIFECYCLE containment probe.
#
# Proves bin/beagle-ci's layer-5 block (BEAGLE_DOWNSTREAM_GATE=1) leaves ZERO
# new owned receipt/temp roots on every exit path — success, forced consumer
# failure, planted exception, timeout(1) (SIGTERM), a directed SIGINT, and a
# directed SIGTERM — while (a) an explicit caller-owned receipt destination
# (BEAGLE_DOWNSTREAM_RECEIPT) stays DURABLE and schema-valid, and (b) a
# concurrent gate run's temp root is PRESERVED (cleanup is identity-scoped, not
# a glob over the shared prefix).
#
# Method (mirrors bin/test/downstream-ci-gate/run.sh, the C4 propagation probe):
#   * The EXACT shipped layer-5 block is extracted VERBATIM from bin/beagle-ci
#     by line-anchor (never re-implemented); if the anchor drifts the probe
#     fails loudly instead of silently testing nothing.
#   * Every gate invocation runs under a PRIVATE TMPDIR, so mktemp(1) (the ci
#     receipt root) AND make-temporary-file (the runner scratch) both land in
#     one dir this probe can census EXHAUSTIVELY — concurrency-robust, no
#     dependence on a shared /tmp shape.
#   * Fixtures are throwaway git repos + registries (never a real consumer), so
#     the probe is hermetic and deterministic regardless of live repo state.
#
# The controls are LOAD-BEARING: a positive sensitivity control proves the root
# census is not always-green, and the sibling-preservation control fails if
# cleanup ever regresses to a prefix glob (`rm -rf $TMPDIR/beagle-ci-downstream.*`).
#
# Racket-only, hermetic. Not part of `bin/beagle test`'s active tier — a focused
# release-seam probe you run directly.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT" || exit 1

fail=0
BASE="$(mktemp -d -t downstream-receipt-lifecycle-XXXXXX)"
cleanup() { rm -rf "${BASE:?}"; }
trap cleanup EXIT

echo "============ downstream layer-5 — receipt & temp-root lifecycle ============"

# --- fixtures ---------------------------------------------------------------
mk_fixture_repo() { # <dir> <bjs-content>
    local dir="$1" content="$2"
    mkdir -p "$dir/js"
    printf '%s' "$content" > "$dir/js/mod.bjs"
    git -C "$dir" init -q
    git -C "$dir" config user.email "t@example.com"
    git -C "$dir" config user.name "t"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m fixture
}

mk_registry() { # <path> <name> <repo-dir>
    cat > "$1" <<EOF
((consumer
  (name "$2")
  (repo-env "DOWNSTREAM_RECEIPT_FIXTURE_REPO")
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

GREEN_REPO="$BASE/green-repo"; GREEN_REG="$BASE/green-registry.rktd"
mk_fixture_repo "$GREEN_REPO" "$GOOD_JS"
mk_registry "$GREEN_REG" "forced-pass" "$GREEN_REPO"

# A DELIBERATELY heavier healthy fixture (many small modules) so a run stays
# in-flight for several seconds — the signal cases (6/7/8) can then deliver a
# signal that is reliably MID-run (not racing a sub-second completion), which
# is what actually exercises subtree reaping + scratch reclamation.
mk_slow_fixture_repo() { # <dir> <n-files>
    local dir="$1" n="$2" i
    mkdir -p "$dir/js"
    for ((i=0; i<n; i++)); do
        printf '#lang beagle/js\n(ns fixture.m%s)\n(defn f%s [a :- Int b :- Int] :- Int (+ a b))\n' \
            "$i" "$i" > "$dir/js/mod$i.bjs"
    done
    git -C "$dir" init -q
    git -C "$dir" config user.email "t@example.com"
    git -C "$dir" config user.name "t"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m fixture
}
SIG_REPO="$BASE/slow-repo"; SIG_REG="$BASE/slow-registry.rktd"
mk_slow_fixture_repo "$SIG_REPO" 150
mk_registry "$SIG_REG" "slow-pass" "$SIG_REPO"

RED_REPO="$BASE/red-repo"; RED_REG="$BASE/red-registry.rktd"
mk_fixture_repo "$RED_REPO" "$BAD_JS"
mk_registry "$RED_REG" "forced-fail" "$RED_REPO"

MISSING_REG="$BASE/does-not-exist.rktd"   # planted exception: unreadable registry

# --- extract the shipped layer-5 block VERBATIM -----------------------------
anchor='if \[\[ "\${BEAGLE_DOWNSTREAM_GATE:-0}" == "1" \]\]; then'
start_line="$(grep -n "$anchor" bin/beagle-ci | head -1 | cut -d: -f1)"
if [[ -z "$start_line" ]]; then
    echo "  FAIL: layer-5 anchor not found in bin/beagle-ci — probe is stale, fix the anchor"
    echo "downstream-receipt-lifecycle: FAIL"
    exit 1
fi
LAYER5="$BASE/layer5.sh"
{ echo '#!/usr/bin/env bash'; echo 'set -euo pipefail'; echo "cd \"$ROOT\""; echo 'repo="'"$ROOT"'"';
  tail -n +"$start_line" bin/beagle-ci | sed '/^echo "beagle-ci/,$d'; } > "$LAYER5"
chmod +x "$LAYER5"

# --- census helpers ---------------------------------------------------------
# Owned roots = anything the layer-5 block or its runner can leave in a TMPDIR:
# the ci receipt root (beagle-ci-downstream.*) and the runner scratch
# (beagle-downstream-*). A fresh private TMPDIR per case makes this exact.
owned_roots() { # <tmpdir>  -> one path per line
    find "$1" -maxdepth 1 -mindepth 1 \
        \( -name 'beagle-ci-downstream.*' -o -name 'beagle-downstream-*' \) 2>/dev/null
}
count_roots() { owned_roots "$1" | grep -c . ; }

fresh_tmp() { local d; d="$(mktemp -d "$BASE/gate-tmp-XXXXXX")"; printf '%s' "$d"; }

# --- (0) sensitivity control: the census actually sees an owned root --------
echo "--- (0) census sensitivity: a planted owned root is detected (not always-green) ---"
gt="$(fresh_tmp)"; mkdir "$gt/beagle-ci-downstream.DECOYSEED"
if [[ "$(count_roots "$gt")" -ge 1 ]]; then
    echo "  PASS: root census detects a planted beagle-ci-downstream.* root"
else
    echo "  FAIL: root census is blind — it would pass even if the gate leaked"
    fail=1
fi

# --- (1) success: ephemeral receipt + all temp roots reclaimed --------------
echo "--- (1) success (healthy consumer): zero owned roots remain ---"
gt="$(fresh_tmp)"; out="$BASE/case1.out"
if TMPDIR="$gt" BEAGLE_DOWNSTREAM_GATE=1 BEAGLE_DOWNSTREAM_REGISTRY="$GREEN_REG" \
        "$LAYER5" >"$out" 2>&1; then
    n="$(count_roots "$gt")"
    if [[ "$n" -eq 0 ]]; then
        echo "  PASS: healthy gate exited 0 and left zero owned receipt/temp roots"
    else
        echo "  FAIL: healthy gate left $n owned root(s):"; owned_roots "$gt" | sed 's/^/    /'; fail=1
    fi
else
    echo "  FAIL: healthy gate exited non-zero"; sed 's/^/    /' "$out"; fail=1
fi

# --- (2) forced consumer failure: non-zero, still zero owned roots ----------
echo "--- (2) forced consumer failure: non-zero exit, zero owned roots ---"
gt="$(fresh_tmp)"; out="$BASE/case2.out"
if TMPDIR="$gt" BEAGLE_DOWNSTREAM_GATE=1 BEAGLE_DOWNSTREAM_REGISTRY="$RED_REG" \
        "$LAYER5" >"$out" 2>&1; then
    echo "  FAIL: forced-fail gate exited 0"; sed 's/^/    /' "$out"; fail=1
else
    n="$(count_roots "$gt")"
    if grep -q 'VERDICT: fail' "$out" && [[ "$n" -eq 0 ]]; then
        echo "  PASS: forced-fail gate exited non-zero (verdict=fail) and left zero owned roots"
    else
        echo "  FAIL: forced-fail left $n owned root(s) or no verdict=fail:"; owned_roots "$gt" | sed 's/^/    /'; fail=1
    fi
fi

# --- (3) planted exception: unreadable registry -> non-zero, zero roots ------
echo "--- (3) planted exception (unreadable registry): non-zero exit, zero owned roots ---"
gt="$(fresh_tmp)"; out="$BASE/case3.out"
if TMPDIR="$gt" BEAGLE_DOWNSTREAM_GATE=1 BEAGLE_DOWNSTREAM_REGISTRY="$MISSING_REG" \
        "$LAYER5" >"$out" 2>&1; then
    echo "  FAIL: gate exited 0 despite an unreadable registry"; sed 's/^/    /' "$out"; fail=1
else
    n="$(count_roots "$gt")"
    if [[ "$n" -eq 0 ]]; then
        echo "  PASS: planted exception propagated non-zero and left zero owned roots"
    else
        echo "  FAIL: planted exception left $n owned root(s):"; owned_roots "$gt" | sed 's/^/    /'; fail=1
    fi
fi

# --- (4) sibling preservation: a concurrent run root survives ---------------
echo "--- (4) sibling preservation: a concurrent gate root is NOT deleted ---"
gt="$(fresh_tmp)"; out="$BASE/case4.out"
sibling="$gt/beagle-ci-downstream.SIBLINGRUN"; mkdir "$sibling"
touch "$sibling/receipt.json"
if TMPDIR="$gt" BEAGLE_DOWNSTREAM_GATE=1 BEAGLE_DOWNSTREAM_REGISTRY="$GREEN_REG" \
        "$LAYER5" >"$out" 2>&1; then
    if [[ -d "$sibling" && -f "$sibling/receipt.json" ]]; then
        # exactly the sibling remains — the gate's OWN root was reclaimed
        remaining="$(owned_roots "$gt")"
        if [[ "$remaining" == "$sibling" ]]; then
            echo "  PASS: sibling run root preserved; gate reclaimed only its own root"
        else
            echo "  FAIL: unexpected roots remain (sibling + a leaked own root?):"; echo "$remaining" | sed 's/^/    /'; fail=1
        fi
    else
        echo "  FAIL: gate deleted a concurrent run's root (identity-scope violation)"; fail=1
    fi
else
    echo "  FAIL: healthy gate exited non-zero"; sed 's/^/    /' "$out"; fail=1
fi

# --- (5) durable explicit receipt: written, schema-valid, no ephemeral leak --
echo "--- (5) explicit BEAGLE_DOWNSTREAM_RECEIPT: durable + schema-valid, zero ephemeral roots ---"
gt="$(fresh_tmp)"; out="$BASE/case5.out"; keep="$BASE/kept-receipt.json"
rm -f "$keep"
if TMPDIR="$gt" BEAGLE_DOWNSTREAM_GATE=1 BEAGLE_DOWNSTREAM_REGISTRY="$GREEN_REG" \
        BEAGLE_DOWNSTREAM_RECEIPT="$keep" "$LAYER5" >"$out" 2>&1; then
    n="$(count_roots "$gt")"
    if [[ -f "$keep" ]] && grep -q '"schema":"beagle-downstream/1"' "$keep" \
            && grep -q '"verdict":"pass"' "$keep" && [[ "$n" -eq 0 ]]; then
        echo "  PASS: caller-owned receipt durable (schema beagle-downstream/1, verdict pass), zero ephemeral roots"
    else
        echo "  FAIL: receipt missing/invalid or an ephemeral root leaked (n=$n):"
        [[ -f "$keep" ]] && sed 's/^/    /' "$keep" || echo "    (receipt absent)"
        fail=1
    fi
else
    echo "  FAIL: healthy gate with explicit receipt exited non-zero"; sed 's/^/    /' "$out"; fail=1
fi
# forced-fail durable receipt is still written and schema-valid
gt="$(fresh_tmp)"; keep2="$BASE/kept-receipt-fail.json"; rm -f "$keep2"
TMPDIR="$gt" BEAGLE_DOWNSTREAM_GATE=1 BEAGLE_DOWNSTREAM_REGISTRY="$RED_REG" \
    BEAGLE_DOWNSTREAM_RECEIPT="$keep2" "$LAYER5" >/dev/null 2>&1 || true
if [[ -f "$keep2" ]] && grep -q '"schema":"beagle-downstream/1"' "$keep2" \
        && grep -q '"verdict":"fail"' "$keep2" && [[ "$(count_roots "$gt")" -eq 0 ]]; then
    echo "  PASS: caller-owned receipt durable + truthful (verdict fail) on forced failure, zero ephemeral roots"
else
    echo "  FAIL: forced-fail durable receipt missing/invalid or an ephemeral root leaked"; fail=1
fi

# Identity-scoped process census: any surviving proc whose argv names the
# private TMPDIR is an un-reaped owned child. Poll briefly so a grandchild
# caught mid-death isn't miscounted (subtree INT is delivered, then reaped).
owned_children() { # <tmpdir> -> count, after settling
    local gtl="$1" i n
    for i in 1 2 3 4 5 6; do
        n="$(pgrep -af -- "$gtl" 2>/dev/null | grep -v pgrep | grep -c . || true)"
        [[ "$n" -eq 0 ]] && break
        sleep 0.5
    done
    printf '%s' "$n"
}

# --- signal helper: run the gate, deliver a signal mid-run, census ----------
# Returns via globals: SIG_RC (script exit code), SIG_ROOTS (leftover count),
# SIG_CHILDREN (leftover owned child procs).
run_signalled() { # <signal> <tmpdir> <outfile>
    local sig="$1" gtl="$2" of="$3" lp
    # Job control (`set -m`) so the backgrounded gate lands in its OWN process
    # group with DEFAULT SIGINT. Without it, a non-interactive shell forces
    # SIGINT/SIGQUIT to SIG_IGN on an async child (POSIX) and "signals ignored
    # on entry cannot be trapped" — the gate could never see our SIGINT, a
    # harness artifact, not the foreground reality bin/beagle-ci ships for.
    set -m
    TMPDIR="$gtl" BEAGLE_DOWNSTREAM_GATE=1 BEAGLE_DOWNSTREAM_REGISTRY="$SIG_REG" \
        "$LAYER5" >"$of" 2>&1 &
    lp=$!
    set +m
    sleep 1.5                    # heavier fixture -> reliably still compiling
    kill -"$sig" "$lp" 2>/dev/null || true
    SIG_RC=0; wait "$lp" || SIG_RC=$?
    SIG_ROOTS="$(count_roots "$gtl")"
    SIG_CHILDREN="$(owned_children "$gtl")"
}

# --- (6) directed SIGINT mid-run: zero owned roots + zero owned children -----
echo "--- (6) SIGINT mid-run: zero owned roots, zero owned children ---"
gt="$(fresh_tmp)"; run_signalled INT "$gt" "$BASE/case6.out"
if [[ "$SIG_ROOTS" -eq 0 && "$SIG_CHILDREN" -eq 0 ]]; then
    echo "  PASS: SIGINT left zero owned roots and zero owned children (rc=$SIG_RC)"
else
    echo "  FAIL: SIGINT left $SIG_ROOTS root(s), $SIG_CHILDREN child(ren) (rc=$SIG_RC):"
    owned_roots "$gt" | sed 's/^/    /'; fail=1
fi

# --- (7) directed SIGTERM mid-run: zero owned roots + zero owned children ----
echo "--- (7) SIGTERM mid-run: zero owned roots, zero owned children ---"
gt="$(fresh_tmp)"; run_signalled TERM "$gt" "$BASE/case7.out"
if [[ "$SIG_ROOTS" -eq 0 && "$SIG_CHILDREN" -eq 0 ]]; then
    echo "  PASS: SIGTERM left zero owned roots and zero owned children (rc=$SIG_RC)"
else
    echo "  FAIL: SIGTERM left $SIG_ROOTS root(s), $SIG_CHILDREN child(ren) (rc=$SIG_RC):"
    owned_roots "$gt" | sed 's/^/    /'; fail=1
fi

# --- (8) timeout(1) wrapper (SIGTERM at deadline): zero owned roots ----------
echo "--- (8) timeout(1) wrapper reaches deadline: zero owned roots, zero owned children ---"
gt="$(fresh_tmp)"; out="$BASE/case8.out"
TMPDIR="$gt" BEAGLE_DOWNSTREAM_GATE=1 BEAGLE_DOWNSTREAM_REGISTRY="$SIG_REG" \
    timeout -s TERM 2 "$LAYER5" >"$out" 2>&1 || true
n_roots="$(count_roots "$gt")"
n_kids="$(owned_children "$gt")"
if [[ "$n_roots" -eq 0 && "$n_kids" -eq 0 ]]; then
    echo "  PASS: timeout(1) deadline left zero owned roots and zero owned children"
else
    echo "  FAIL: timeout(1) left $n_roots root(s), $n_kids child(ren):"; owned_roots "$gt" | sed 's/^/    /'; fail=1
fi

echo
if [[ "$fail" -eq 0 ]]; then
    echo "downstream-receipt-lifecycle: PASS — layer-5 receipt/temp roots are contained on every exit path; explicit receipts stay durable; concurrent run roots are preserved"
else
    echo "downstream-receipt-lifecycle: FAIL"
fi
exit "$fail"
