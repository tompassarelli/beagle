#!/usr/bin/env bash
# Proof for tools/run-bounded. Runs the binary through the contract the Beagle
# build depends on, in BOTH containment modes (private PID namespace and the
# process-group fallback forced by BEAGLE_BOUNDED_FORCE_PROCESS_GROUP=1).
#
#   tools/run-bounded/test.sh [PATH-TO-BINARY]

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
binary="${1:-$here/target/release/run-bounded}"
[[ -x "$binary" ]] || {
    echo "run-bounded tests: binary is unavailable: $binary" >&2
    echo "build it with: cargo build --release --locked --manifest-path $here/Cargo.toml" >&2
    exit 2
}

scratch="$(mktemp -d "${TMPDIR:-/tmp}/run-bounded-test.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

failures=0
checks=0

check() {
    local label="$1" expected="$2" actual="$3"
    checks=$((checks + 1))
    if [[ "$expected" == "$actual" ]]; then
        echo "  ok   $label"
    else
        echo "  FAIL $label: expected [$expected], got [$actual]"
        failures=$((failures + 1))
    fi
}

# Every case runs twice: once with the preferred private PID namespace, once
# with the containment the supervisor falls back to on a host that forbids
# unprivileged user namespaces. A contract that only holds in one mode is not
# the contract.
for mode in namespace process-group; do
    if [[ "$mode" == process-group ]]; then
        export BEAGLE_BOUNDED_FORCE_PROCESS_GROUP=1
    else
        unset BEAGLE_BOUNDED_FORCE_PROCESS_GROUP
    fi
    echo "== $mode"

    rc=0
    "$binary" 5 1 -- /bin/sh -c 'exit 0' 2>/dev/null || rc=$?
    check "$mode: child exits 0 -> 0" 0 "$rc"

    rc=0
    "$binary" 5 1 -- /bin/sh -c 'exit 7' 2>/dev/null || rc=$?
    check "$mode: child exits 7 -> 7" 7 "$rc"

    # 124 is also a legitimate child status. The receipt, not the shell status
    # alone, is what keeps a semantic rejection distinct from a deadline.
    receipt="$scratch/receipt"
    rc=0
    BEAGLE_BOUNDED_COMPLETION_RECEIPT="$receipt" \
        "$binary" 5 1 -- /bin/sh -c 'exit 124' 2>/dev/null || rc=$?
    check "$mode: child exits 124 -> 124" 124 "$rc"
    check "$mode: exit receipt" "subtree-reaped-v0 exit status=124" "$(cat "$receipt")"

    # Deadline breach: exit 124, and the overrunning child is gone afterward.
    marker="$scratch/overrun.pid"
    rc=0
    stderr="$(BEAGLE_BOUNDED_COMPLETION_RECEIPT="$receipt" \
        "$binary" 1 1 -- /bin/sh -c \
        "trap '' TERM; echo \$\$ > $marker; sleep 300 & wait \$!" 2>&1)" || rc=$?
    check "$mode: overrun -> 124" 124 "$rc"
    check "$mode: timeout receipt" "subtree-reaped-v0 timeout status=124" "$(cat "$receipt")"
    check "$mode: TIMEOUT line" 1 \
        "$(grep -c 'TIMEOUT status=124' <<<"$stderr")"
    overrun_pid="$(cat "$marker" 2>/dev/null || echo 0)"
    if [[ "$mode" == namespace ]]; then
        # A PID means nothing across a namespace boundary; the namespace dying
        # with its PID 1 is what is being asserted, and the sweep below covers
        # the observable part.
        check "$mode: overrun child recorded its pid" 1 \
            "$([[ "$overrun_pid" -gt 0 ]] && echo 1 || echo 0)"
    else
        check "$mode: overrun child is gone" 0 \
            "$(kill -0 "$overrun_pid" 2>/dev/null && echo 1 || echo 0)"
    fi

    # THE case that distinguishes this program from coreutils `timeout`: a
    # setsid'd grandchild that ignores SIGTERM and outlives its parent. `timeout`
    # signals the direct child only, so this tree would survive it. The heartbeat
    # is the real assertion -- a PID is meaningless across a namespace boundary,
    # but a file that stops growing means the writer is gone wherever it was.
    heartbeat="$scratch/heartbeat"
    escapees="$scratch/escapees"
    : >"$heartbeat"
    : >"$escapees"
    rc=0
    stderr="$(BEAGLE_BOUNDED_COMPLETION_RECEIPT="$receipt" \
        "$binary" 2 1 -- /bin/sh -c "
            trap '' TERM
            setsid /bin/sh -c \"trap '' TERM; echo \\\$\\\$ >> $escapees;
                while :; do echo b >> $heartbeat; sleep 0.1; done\" &
            while :; do sleep 0.2; done" 2>&1)" || rc=$?
    check "$mode: setsid'd grandchild -> 124" 124 "$rc"
    check "$mode: no contract failure" 0 \
        "$(grep -c 'descendants remained' <<<"$stderr")"
    beats_at_return="$(wc -c <"$heartbeat")"
    check "$mode: the grandchild actually ran" 1 \
        "$([[ "$beats_at_return" -gt 0 ]] && echo 1 || echo 0)"
    sleep 1
    check "$mode: grandchild stopped writing after the kill grace" \
        "$beats_at_return" "$(wc -c <"$heartbeat")"
    survivors=0
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        kill -0 "$pid" 2>/dev/null && survivors=$((survivors + 1))
    done <"$escapees"
    if [[ "$mode" == process-group ]]; then
        check "$mode: no descendant pid survives" 0 "$survivors"
    fi

    # A malformed bound is a contract failure (2) before any child exists, so it
    # publishes no receipt: a bound that came from a typo is not a bound.
    rm -f "$receipt"
    rc=0
    BEAGLE_BOUNDED_COMPLETION_RECEIPT="$receipt" \
        "$binary" 0 1 -- /bin/sh -c 'exit 1' 2>/dev/null || rc=$?
    check "$mode: zero deadline -> 2" 2 "$rc"
    check "$mode: contract failure publishes no receipt" 0 \
        "$([[ -e "$receipt" ]] && echo 1 || echo 0)"

    rc=0
    "$binary" 5 1 -- /definitely/missing/beagle-command 2>/dev/null || rc=$?
    check "$mode: missing command -> 2" 2 "$rc"

    # A signalled child is reported the way a shell and the incumbent Racket
    # supervisor report it.
    rc=0
    "$binary" 5 1 -- /bin/sh -c 'kill -TERM $$; sleep 5' 2>/dev/null || rc=$?
    check "$mode: child killed by SIGTERM -> 143" 143 "$rc"

    # stdout and stderr are passed through byte-exactly, including a payload
    # far larger than one pipe buffer.
    "$binary" 20 1 -- /bin/sh -c \
        'i=0; while [ $i -lt 20000 ]; do echo "line $i out"; i=$((i+1)); done' \
        >"$scratch/out" 2>/dev/null
    expected_out="$(/bin/sh -c 'i=0; while [ $i -lt 20000 ]; do echo "line $i out"; i=$((i+1)); done')"
    check "$mode: stdout byte-exact" "$(sha256sum <<<"$expected_out" | cut -c1-64)" \
        "$(sha256sum <"$scratch/out" | cut -c1-64)"
    "$binary" 20 1 -- /bin/sh -c \
        'i=0; while [ $i -lt 5000 ]; do echo "line $i err" >&2; i=$((i+1)); done' \
        2>"$scratch/err" >/dev/null
    grep -v '^beagle supervisor:' <"$scratch/err" >"$scratch/err.child"
    expected_err="$(/bin/sh -c 'i=0; while [ $i -lt 5000 ]; do echo "line $i err"; i=$((i+1)); done')"
    check "$mode: stderr byte-exact" "$(sha256sum <<<"$expected_err" | cut -c1-64)" \
        "$(sha256sum <"$scratch/err.child" | cut -c1-64)"

    # A malformed deadline scale is a contract failure, never a silent 1.
    rc=0
    BEAGLE_DEADLINE_SCALE=oops "$binary" 5 1 -- /bin/sh -c 'exit 0' 2>/dev/null || rc=$?
    check "$mode: malformed BEAGLE_DEADLINE_SCALE -> 2" 2 "$rc"
done
unset BEAGLE_BOUNDED_FORCE_PROCESS_GROUP

# The sweep must reach the supervisor's own subtree and nothing else. This
# canary is exactly what a bare kill(-1) outside a private namespace would take
# down.
sleep 300 &
canary=$!
"$binary" 1 1 -- /bin/sh -c "trap '' TERM; sleep 300 & wait \$!" >/dev/null 2>&1
check "namespace: an unrelated process survives the sweep" 1 \
    "$(kill -0 "$canary" 2>/dev/null && echo 1 || echo 0)"
BEAGLE_BOUNDED_FORCE_PROCESS_GROUP=1 \
    "$binary" 1 1 -- /bin/sh -c "trap '' TERM; sleep 300 & wait \$!" >/dev/null 2>&1
check "process-group: an unrelated process survives the sweep" 1 \
    "$(kill -0 "$canary" 2>/dev/null && echo 1 || echo 0)"
kill "$canary" 2>/dev/null

echo
echo "run-bounded tests: $((checks - failures))/$checks checks passed"
[[ "$failures" -eq 0 ]] || exit 1
