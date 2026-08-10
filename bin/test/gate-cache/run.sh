#!/usr/bin/env bash
# Under-key regression tests for bin/_gate-cache-run.
#
# Each check plants the failure mode that would make the cache UNSOUND —
# serving a stale green proof after an input changed — and proves the cache
# re-runs instead. Everything runs in a throwaway sandbox (cache root included,
# via BEAGLE_GATE_CACHE), with a synthetic gate whose input closure exercises
# every record kind: a transitively-sourced module, a data file, an
# ENOENT-probed flag, and a directory listing.
#
# These tests run strace themselves, so they must NOT run under an outer
# gate-cache trace (ptrace allows one tracer); the runner skips cleanly there.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WRAP="$ROOT/bin/_gate-cache-run"

if [[ -n "${BEAGLE_GATE_CACHE_INNER:-}" ]]; then
    echo "gate-cache tests: SKIP (already under a gate-cache trace; ptrace allows one tracer)"
    exit 0
fi
if ! command -v strace >/dev/null 2>&1; then
    echo "gate-cache tests: SKIP (strace unavailable; the cache degrades to plain runs)"
    exit 0
fi

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/gate-cache-test.XXXXXX")"
trap 'rm -rf "${sandbox:?}"' EXIT
export BEAGLE_GATE_CACHE="$sandbox/cache"
unset BEAGLE_GATE_NO_CACHE

mkdir -p "$sandbox/lib" "$sandbox/data" "$sandbox/fixtures"
cat > "$sandbox/lib/module_b.sh" <<'EOF'
b_value="from-b-v1"
EOF
cat > "$sandbox/lib/module_a.sh" <<'EOF'
source "$(dirname "${BASH_SOURCE[0]}")/module_b.sh"
a_value="from-a:$b_value"
EOF
echo "input-v1" > "$sandbox/data/in.txt"
echo "fix1" > "$sandbox/fixtures/one.txt"
cat > "$sandbox/gate.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
d="$(cd "$(dirname "$0")" && pwd)"
source "$d/lib/module_a.sh"
echo "module says: $a_value"
cat "$d/data/in.txt"
[ -f "$d/feature.flag" ] && echo "flag on" || true
ls "$d/fixtures" | sort
echo "gate ok"
EOF
chmod +x "$sandbox/gate.sh"

run_gate() {  # -> combined output on stdout, exit status preserved
    "$WRAP" --domain test --id sandbox-gate --watch "$sandbox" -- \
        "$sandbox/gate.sh" 2>&1
}

failures=0
check() {  # NAME COND-EXIT DESCRIPTION
    local name="$1" rc="$2"
    if [[ "$rc" -eq 0 ]]; then
        echo "PASS  $name"
    else
        echo "FAIL  $name"
        failures=$((failures + 1))
    fi
}

# t1: cold run executes and stores; identical rerun is served as cached-green.
out1="$(run_gate)"; rc1=$?
[[ $rc1 -eq 0 && "$out1" == *"gate ok"* && "$out1" != *cached-green* ]]
check "cold run executes (ran-green, stored)" $?
out2="$(run_gate)"; rc2=$?
[[ $rc2 -eq 0 && "$out2" == *cached-green* ]]
check "byte-identical closure replays as cached-green" $?

# t2: the replay is the same proof — stdout replayed verbatim.
body1="$(printf '%s\n' "$out1" | grep -v '^beagle-gate-cache: ')"
body2="$(printf '%s\n' "$out2" | grep -v '^beagle-gate-cache: ')"
[[ "$body1" == "$body2" ]]
check "cached replay reproduces the stored stdout" $?

# t3: touching a TRANSITIVELY loaded module (gate -> module_a -> module_b)
# invalidates the result.
echo 'b_value="from-b-v2"' > "$sandbox/lib/module_b.sh"
out3="$(run_gate)"
[[ "$out3" != *cached-green* && "$out3" == *"from-a:from-b-v2"* ]]
check "transitively-loaded module change invalidates" $?

# t4: BEAGLE_GATE_NO_CACHE=1 bypasses — runs for real, no marker, stores nothing.
run_gate > /dev/null   # re-warm after t3
out4="$(BEAGLE_GATE_NO_CACHE=1 run_gate)"
[[ "$out4" == *"gate ok"* && "$out4" != *"beagle-gate-cache:"* ]]
check "BEAGLE_GATE_NO_CACHE=1 forces a full run" $?
out4b="$(run_gate)"
[[ "$out4b" == *cached-green* ]]
check "bypass run left the stored proof intact" $?

# t5: changing the GATE SCRIPT ITSELF invalidates its own results.
printf '\n# comment that must invalidate\n' >> "$sandbox/gate.sh"
out5="$(run_gate)"
[[ "$out5" != *cached-green* && "$out5" == *"gate ok"* ]]
check "gate script change invalidates its own result" $?

# t6: a file appearing where the run probed ENOENT invalidates.
run_gate > /dev/null
touch "$sandbox/feature.flag"
out6="$(run_gate)"
[[ "$out6" != *cached-green* && "$out6" == *"flag on"* ]]
check "appearance of an ENOENT-probed file invalidates" $?

# t7: a new entry in a listed directory invalidates.
run_gate > /dev/null
echo "fix2" > "$sandbox/fixtures/two.txt"
out7="$(run_gate)"
[[ "$out7" != *cached-green* && "$out7" == *two.txt* ]]
check "listed-directory content change invalidates" $?

# t8: a red result is never cached — both runs execute.
cat > "$sandbox/red.sh" <<'EOF'
#!/usr/bin/env bash
echo "about to fail"
exit 3
EOF
chmod +x "$sandbox/red.sh"
"$WRAP" --domain test --id red --watch "$sandbox" -- "$sandbox/red.sh" > /dev/null 2>&1
rc_red1=$?
red2="$("$WRAP" --domain test --id red --watch "$sandbox" -- "$sandbox/red.sh" 2>&1)"
rc_red2=$?
[[ $rc_red1 -eq 3 && $rc_red2 -eq 3 && "$red2" != *cached-green* ]]
check "red results are never cached (exit code preserved)" $?

# t9: nested invocation (already under a trace) runs direct — no marker,
# nothing stored, exit code preserved.
cache_shape() { find "$sandbox/cache" 2>/dev/null | LC_ALL=C sort | sha256sum; }
shape_before="$(cache_shape)"
out9="$(BEAGLE_GATE_CACHE_INNER=1 "$WRAP" --domain test --id nested --watch "$sandbox" -- "$sandbox/gate.sh" 2>&1)"
rc9=$?
[[ $rc9 -eq 0 && "$out9" != *"beagle-gate-cache:"* ]]
check "nested invocation runs direct without tracing" $?
[[ "$(cache_shape)" == "$shape_before" ]]
check "nested invocation stored nothing new" $?

# t10: a different --id never sees another id's entries (identity separation).
out10="$("$WRAP" --domain test --id other-id --watch "$sandbox" -- "$sandbox/gate.sh" 2>&1)"
[[ "$out10" != *cached-green* && "$out10" == *"gate ok"* ]]
check "distinct --id gets a distinct identity (cold)" $?

# t11: a sanitizer-bearing gate (LeakSanitizer refuses ptrace) is detected,
# flagged untraceable, rerun direct — green result, never cached.
cat > "$sandbox/lsan.sh" <<'EOF'
#!/usr/bin/env bash
tracer="$(sed -n 's/^TracerPid:\t//p' /proc/self/status)"
if [[ "$tracer" != "0" ]]; then
    echo "==1==HINT: LeakSanitizer does not work under ptrace (strace, gdb, etc)" >&2
    exit 1
fi
echo "sanitized ok"
EOF
chmod +x "$sandbox/lsan.sh"
out11="$("$WRAP" --domain test --id lsan --watch "$sandbox" -- "$sandbox/lsan.sh" 2>&1)"
rc11=$?
[[ $rc11 -eq 0 && "$out11" == *"sanitized ok"* && "$out11" == *untraceable* ]]
check "sanitizer refusal flags identity and reruns direct (green)" $?
out11b="$("$WRAP" --domain test --id lsan --watch "$sandbox" -- "$sandbox/lsan.sh" 2>&1)"
rc11b=$?
[[ $rc11b -eq 0 && "$out11b" == *"sanitized ok"* && "$out11b" != *cached-green* && "$out11b" != *untraceable* ]]
check "flagged identity runs direct thereafter (uncached, single run)" $?

# t12: an ENOENT probe whose path contains `..` must be recorded as spelled.
# gcc probes /lib/../lib64: absent because /lib is missing, yet it collapses
# lexically onto /lib64, which exists. Storing the collapsed path asserts an
# absence that never held, and the entry can never be replayed.
mkdir -p "$sandbox/real"
cat > "$sandbox/dotdot.sh" <<'EOF'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd)"
[ -e "$d/gone/../real" ] && echo "probe resolved" || echo "probe absent"
echo "dotdot ok"
EOF
chmod +x "$sandbox/dotdot.sh"
dotdot() { "$WRAP" --domain test --id dotdot --watch "$sandbox" -- "$sandbox/dotdot.sh" 2>&1; }
out12="$(dotdot)"
[[ "$out12" == *"probe absent"* && "$out12" != *cached-green* ]]
check "\`..\` probe: cold run records the absent path" $?
out12b="$(dotdot)"
[[ "$out12b" == *cached-green* ]]
check "\`..\` probe does not poison the entry (replays cached-green)" $?

# t13: and it is still a live assertion — making the probe resolve invalidates.
mkdir -p "$sandbox/gone"
out13="$(dotdot)"
[[ "$out13" != *cached-green* && "$out13" == *"probe resolved"* ]]
check "\`..\` probe becoming resolvable invalidates" $?

# t14: an access with no kernel-truth cwd must be refused, never guessed.
# execve carries no dirfd, and a forked child has no cwd of its own until it
# chdirs, so `( cd sub; ./tool.sh; echo … )` — not the last command, so bash
# forks — leaves ./tool.sh unplaceable. A same-named DECOY sits at the launch
# cwd, so the guess lands on a real file: the entry then carries the decoy as a
# dependency the run never had, and calls that the proof of the exec. Where the
# guess lands on nothing instead, the same records make the run permanently
# unreplayable. Both are the cache keying on a path it invented.
mkdir -p "$sandbox/sub"
printf '#!/usr/bin/env bash\necho "DECOY TOOL"\n' > "$sandbox/tool.sh"
printf '#!/usr/bin/env bash\necho "REAL TOOL v1"\n' > "$sandbox/sub/tool.sh"
chmod +x "$sandbox/tool.sh" "$sandbox/sub/tool.sh"
cat > "$sandbox/misresolve.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
d="$(cd "$(dirname "$0")" && pwd)"
(
  cd "$d/sub"
  ./tool.sh
  echo "subshell done"
)
echo "misresolve ok"
EOF
chmod +x "$sandbox/misresolve.sh"
misresolve() {
    ( cd "$sandbox" && "$WRAP" --domain test --id misresolve --watch "$sandbox" -- \
        "$sandbox/misresolve.sh" 2>&1 )
}
out14="$(misresolve)"
[[ "$out14" == *"REAL TOOL v1"* && "$out14" == *"not cached: unplaceable"* ]]
check "unplaceable relative exec is refused, not resolved against launch cwd" $?
out14b="$(misresolve)"
[[ "$out14b" != *cached-green* && "$out14b" == *"REAL TOOL v1"* ]]
check "an unplaceable access leaves no proof to replay" $?
printf '#!/usr/bin/env bash\necho "REAL TOOL v2"\n' > "$sandbox/sub/tool.sh"
out14c="$(misresolve)"
[[ "$out14c" == *"REAL TOOL v2"* && "$out14c" != *cached-green* ]]
check "an edit to the real tool is always reflected, never replayed stale" $?

echo
if [[ $failures -gt 0 ]]; then
    echo "gate-cache tests: $failures FAILED"
    exit 1
fi
echo "gate-cache tests: all green"
