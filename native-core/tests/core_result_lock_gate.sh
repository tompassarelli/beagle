#!/usr/bin/env bash
# The Core result-cache lock must be a LOOKUP lock, not a whole-build lock.
#
# It used to be taken before the cache lookup and released on no path at all,
# so one `exec {fd}>` held it until the process exited. Any build that misses
# the early alias -- every Wasm build, and every cold build of anything -- then
# held it through compilation, and a sibling building the same thing waited out
# the entire `-w` window and died with "timed out acquiring the Core result
# cache lock". This gate holds a build inside that window and proves the lock
# is free there.
#
# Both halves are guarded against a false green. A `flock` probe that always
# succeeds proves nothing, so the probe is first run against a lock this script
# holds itself and is required to FAIL. A second build that "passed" because it
# hit the timeout and exited proves nothing either, so the second build must
# exit 0, must not report the timeout, and must show its own cache MISS line --
# the line it can only print after it is past the lock.
set -euo pipefail
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
beagle_cli="${BEAGLE_CORE_LOCK_GATE_BEAGLE:-$repo/bin/beagle}"
# The caller passes a build cache whose Core compiler projection is already
# warm; constructing one is a multi-minute phase and is not what this proves.
cache_root="${1:-${BEAGLE_CORE_BUILD_CACHE:-$repo/.beagle-out/core-result-lock-cache}}"
gate="core-result-lock"

# The compile between a lookup and a publication is seconds; every wait below
# is bounded well above that and fails loudly rather than hanging.
settle_deadline="${BEAGLE_CORE_LOCK_GATE_SETTLE_SECONDS:-120}"
build_deadline="${BEAGLE_CORE_LOCK_GATE_BUILD_SECONDS:-300}"
# The probe must finish while the first build is provably still compiling, so
# it waits barely at all: a lock this build holds is held for its whole
# compile, and one it has given back is free the instant the lookup ends. A
# long wait would let the first build finish underneath the probe and hand back
# a success that means nothing.
probe_wait="${BEAGLE_CORE_LOCK_GATE_PROBE_SECONDS:-1}"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-core-result-lock.XXXXXX")"
first_pid=""
holder_pid=""
cleanup() {
    local rc=$?
    [[ -z "$first_pid" ]] || kill -TERM "$first_pid" 2>/dev/null || true
    [[ -z "$holder_pid" ]] || kill -TERM "$holder_pid" 2>/dev/null || true
    if [[ $rc -ne 0 ]]; then
        local log
        for log in "$scratch"/*.log; do
            [[ -f "$log" ]] || continue
            echo "$gate: failure log $log" >&2
            sed -n '1,120p' "$log" >&2
        done
    else
        rm -rf "${scratch:?}"
    fi
    return "$rc"
}
trap cleanup EXIT

fail() {
    echo "$gate: FAIL: $*" >&2
    exit 1
}

mkdir -p "$cache_root/.result-locks"

# The window this gate probes is a COMPILE. Constructing the Core compiler
# projection is a multi-minute phase and is not that window, so it is put in
# place before anything is timed -- otherwise the first build spends the settle
# deadline building a compiler and the gate reports a hang it did not find. The
# projection tool keeps its own content-addressed cache and the build driver
# reads its copy out of the build cache root, so one seeds the other.
projection_key="$("$repo/bin/beagle-core-compiler-projection" --print-key)"
[[ "$projection_key" =~ ^[0-9a-f]{64}$ ]] ||
    fail "the Core compiler projection did not report a usable key"
projection_source="${XDG_CACHE_HOME:-$HOME/.cache}/beagle/core-compiler-projections/$projection_key"
if [[ ! -f "$cache_root/$projection_key/.complete" ]]; then
    if [[ ! -d "$projection_source/compiled" ]]; then
        echo "$gate: constructing the Core compiler projection (one-time)" >&2
        BEAGLE_CORE_OVERALL_TIMEOUT_SECONDS=1800 \
            "$repo/bin/beagle-core-compiler-projection" --cache >/dev/null ||
            fail "could not construct the Core compiler projection"
    fi
    [[ -d "$projection_source/compiled" ]] ||
        fail "the Core compiler projection is unavailable: $projection_source"
    projection_staging="$(mktemp -d "$cache_root/.projection-seed.XXXXXX")"
    cp -a "$projection_source/compiled" "$projection_staging/compiled"
    : >"$projection_staging/.complete"
    # A concurrent build may have published the same entry first; either way the
    # entry is there afterwards, and it is the same content-addressed bytes.
    mv -T "$projection_staging" "$cache_root/$projection_key" 2>/dev/null ||
        rm -rf -- "${projection_staging:?}"
fi
[[ -f "$cache_root/$projection_key/.complete" ]] ||
    fail "could not seed the Core compiler projection into $cache_root"
echo "$gate: compiler projection $projection_key ready"

# A fixture nobody else has built, so this gate owns its cache keys outright
# and cannot be handed a hit by a neighbouring phase. It carries enough
# definitions that lowering takes seconds rather than an instant: the window
# being probed is the compile, and a compile too short to probe would make this
# gate report inconclusive instead of an answer.
fixture="$scratch/core-result-lock-fixture.bgl"
{
    printf '#lang beagle\n(ns core.result-lock-gate-%s)\n\n' "$$"
    for unit in $(seq 0 63); do
        printf '(defn value-%s [(n Int)] Int\n  (+ n %s))\n\n' "$unit" "$unit"
    done
} >"$fixture"

build() { # build OUT LOG -- runs one Core build against the shared cache
    BEAGLE_CORE_BUILD_CACHE="$cache_root" \
        timeout --foreground "$build_deadline" \
        "$beagle_cli" build --materializer c17 --out "$1" "$fixture" \
        >"$2" 2>&1
}

# --- the probe must have teeth ------------------------------------------------
# A `flock -w` on a lock nobody holds succeeds; so does a `flock` on a path that
# does not exist, because flock(1) creates it. Neither says anything about the
# driver. Prove first that this probe reports a HELD lock as held.
control_lock="$cache_root/.result-locks/.gate-control.$$.lock"
: >"$control_lock"
( flock -x 9 && sleep 30 ) 9>"$control_lock" &
holder_pid=$!
probe_saw_held=0
for _ in $(seq 1 50); do
    if flock -x -w 0 "$control_lock" true 2>/dev/null; then
        sleep 0.1
    else
        probe_saw_held=1
        break
    fi
done
[[ "$probe_saw_held" == 1 ]] ||
    fail "the holder never took the control lock; the probe proves nothing"
if flock -x -w 1 "$control_lock" true 2>/dev/null; then
    fail "the lock probe cannot tell a held lock from a free one"
fi
kill -TERM "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
holder_pid=""
rm -f -- "$control_lock"
echo "$gate: lock probe distinguishes held from free"

# --- hold a build inside the window and probe its lock ------------------------
first_log="$scratch/first.log"
build "$scratch/out-first" "$first_log" &
first_pid=$!

first_key=""
deadline=$((SECONDS + settle_deadline))
while :; do
    first_key="$(sed -n \
        's/^beagle build: core-result-cache MISS \([0-9a-f]\{64\}\)$/\1/p' \
        "$first_log" 2>/dev/null | head -1)"
    [[ -z "$first_key" ]] || break
    kill -0 "$first_pid" 2>/dev/null ||
        fail "the first build ended before it reached its cache lookup"
    if ((SECONDS >= deadline)); then
        # Say which of the two it is rather than reporting a hang either way.
        if grep -Fq 'beagle build: phase core-compiler START' "$first_log"; then
            fail "the first build is constructing a compiler projection, not compiling the fixture; the seeded projection did not take"
        fi
        fail "the first build did not reach its cache lookup within ${settle_deadline}s"
    fi
    sleep 0.2
done

lock_file="$cache_root/.result-locks/$first_key.lock"
# flock(1) would CREATE a missing lock file and succeed on it, which would be a
# green that never touched the driver's lock at all.
[[ -f "$lock_file" ]] ||
    fail "the driver did not create the result lock it is supposed to take: $lock_file"

kill -0 "$first_pid" 2>/dev/null ||
    fail "the first build ended before the lock could be probed"
probe_status=0
flock -x -w "$probe_wait" "$lock_file" true || probe_status=$?
if grep -Fq 'beagle build: phase publish-lock START' "$first_log"; then
    fail "the first build left the compile window before it was probed; inconclusive"
fi
kill -0 "$first_pid" 2>/dev/null ||
    fail "the first build ended during the probe; inconclusive"
[[ "$probe_status" == 0 ]] ||
    fail "the Core result cache lock is still held during compilation (flock exit $probe_status)"
echo "$gate: result lock is free while the first build compiles"

# --- and a real second build must get through --------------------------------
# The mechanism above says the lock is free; this says a build actually gets
# through it. A short lock timeout makes the old failure immediate rather than
# a 30s wait, and the assertions below refuse to accept that failure as a pass.
second_log="$scratch/second.log"
second_status=0
BEAGLE_CORE_LOCK_TIMEOUT_SECONDS=5 \
    build "$scratch/out-second" "$second_log" &
second_pid=$!
# The second build only means something if it started while the first was still
# inside the window, so say so at the moment it started rather than inferring it
# afterwards.
kill -0 "$first_pid" 2>/dev/null ||
    fail "the first build had already finished when the second started; inconclusive"

wait "$second_pid" || second_status=$?
first_status=0
wait "$first_pid" || first_status=$?
first_pid=""

[[ "$second_status" != 124 ]] ||
    fail "the second build exceeded its own ${build_deadline}s deadline; inconclusive"
! grep -Fq 'timed out acquiring the Core result cache lock' "$second_log" ||
    fail "the second build waited out the result cache lock and died"
[[ "$second_status" == 0 ]] ||
    fail "the second build did not complete (exit $second_status)"
[[ "$first_status" == 0 ]] ||
    fail "the first build did not complete (exit $first_status)"
grep -Eq "^beagle build: core-result-cache (MISS|HIT) $first_key\$" "$second_log" ||
    fail "the second build never reported a verdict for $first_key; it did not get past the lock"
[[ -f "$scratch/out-second/build.manifest.sha256" ]] ||
    fail "the second build published no generation marker"
[[ -f "$scratch/out-first/build.manifest.sha256" ]] ||
    fail "the first build published no generation marker"

tree_digest() {
    (
        cd "$1"
        find . -type f ! -name .beagle-publish.lock -print0 |
            LC_ALL=C sort -z | xargs -0 sha256sum
    ) | sha256sum | awk '{print $1}'
}
[[ "$(tree_digest "$scratch/out-first")" == "$(tree_digest "$scratch/out-second")" ]] ||
    fail "two concurrent builds of one source produced different generations"

echo "$gate: concurrent same-key builds both completed and agree"
echo "$gate: PASS"
