#!/usr/bin/env bash
# CORE-COMPILER-PROJECTION-NATIVE: compiler-module bundle parity and cache proof.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
gate="CORE-COMPILER-PROJECTION-NATIVE"
native_bin="${BEAGLE_NATIVE_COMPILER_BIN:-}"
native_deadline="${BEAGLE_CORE_PROJECTION_DEADLINE_SECONDS:-30}"
shadow_deadline="${BEAGLE_CORE_PROJECTION_SHADOW_DEADLINE_SECONDS:-180}"
suite_deadline="${BEAGLE_CORE_PROJECTION_SUITE_DEADLINE_SECONDS:-180}"
kill_grace="${BEAGLE_CORE_PROJECTION_KILL_GRACE_SECONDS:-5}"

for value in "$native_deadline" "$shadow_deadline" "$suite_deadline" "$kill_grace"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
        echo "$gate: timeout values must be positive integers" >&2
        exit 2
    }
done

scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-core-projection-native.XXXXXX")"
cleanup() {
    local rc=$?
    rm -rf "${scratch:?}"
    return "$rc"
}
trap cleanup EXIT

fixture_sources=(
    "$root/native-core/validation/zero-variant/action.bgl"
    "$root/native-core/validation/zero-variant/fixture.bgl"
)

run_projection() {
    local label="$1" route="$2" cache="$3" projection="$4" log="$5"
    local compiler="${6:-$native_bin}" deadline
    local stdout="$scratch/$label.stdout" stderr="$scratch/$label.stderr"
    local build_out="$scratch/$label-build"
    local route_env=()
    if [[ "$route" == native ]]; then
        route_env=("BEAGLE_NATIVE_COMPILER_BIN=$compiler")
        deadline="$native_deadline"
    else
        route_env=(-u BEAGLE_NATIVE_COMPILER_BIN)
        deadline="$shadow_deadline"
    fi
    env "${route_env[@]}" \
        BEAGLE_CORE_BUILD_CACHE="$cache" \
        BEAGLE_CORE_PROJECTION_ONLY=1 \
        BEAGLE_CORE_PROJECTION_ONLY_OUT="$projection" \
        BEAGLE_CORE_PROJECTION_ONLY_LOG="$log" \
        timeout --foreground --kill-after="${kill_grace}s" "$deadline" \
        "$root/bin/beagle-build-core" \
        --materializer c17 --out "$build_out" "${fixture_sources[@]}" \
        >"$stdout" 2>"$stderr"
}

tree_equal() {
    local left="$1" right="$2"
    diff -ru --no-dereference "$left" "$right" >/dev/null
}

echo "$gate: focused emission suites START"
source "$root/bin/_beagle-racket"
suites=(
    beagle-test/tests/emit.rkt
    beagle-test/tests/emit-clj-behavioral.rkt
    beagle-test/tests/emit-js.rkt
    beagle-test/tests/emit-js-behavioral.rkt
    beagle-test/tests/emit-nix.rkt
    beagle-test/tests/nix-emit-errors.rkt
    beagle-test/tests/emit-matrix.rkt
)
for suite in "${suites[@]}"; do
    echo "$gate: suite $suite START"
    timeout --foreground --kill-after="${kill_grace}s" "$suite_deadline" \
        "$RACO" test "$root/$suite"
    echo "$gate: suite $suite END"
done
echo "$gate: focused emission suites PASS"

echo "$gate: Racket shadow projection START"
shadow_start="$(date +%s)"
set +e
run_projection racket-shadow racket "$scratch/racket-cache" \
    "$scratch/racket-projection" "$scratch/racket.compiler-stream"
shadow_status=$?
set -e
shadow_elapsed=$(( $(date +%s) - shadow_start ))
if [[ "$shadow_status" == 0 ]]; then
    echo "$gate: Racket shadow projection PASS seconds=$shadow_elapsed"
else
    echo "$gate: Racket shadow projection diagnostic status=$shadow_status seconds=$shadow_elapsed" >&2
    sed -n '1,120p' "$scratch/racket-shadow.stderr" >&2 || true
fi

if [[ -z "$native_bin" ]]; then
    echo "$gate: native binary is absent; native assertions are pending" >&2
    if [[ "$shadow_status" != 0 ]]; then
        echo "$gate: Racket shadow projection also remains diagnostic status=$shadow_status" >&2
    fi
    echo "$gate: pending exact compiled tree, exact native compiler stream, native miss/hit keys, digest invalidation, and <=${native_deadline}s cold projection" >&2
    exit 2
fi
[[ -x "$native_bin" ]] || {
    echo "$gate: BEAGLE_NATIVE_COMPILER_BIN is not executable: $native_bin" >&2
    exit 2
}
[[ "$shadow_status" == 0 ]] || {
    echo "$gate: Racket shadow projection failed; native dual-run comparison is not admissible" >&2
    exit 1
}

native_cache="$scratch/native-cache"
native_start="$(date +%s)"
run_projection native-cold native "$native_cache" \
    "$scratch/native-cold-projection" "$scratch/native-cold.compiler-stream"
native_elapsed=$(( $(date +%s) - native_start ))
[[ "$native_elapsed" -le "$native_deadline" ]] || {
    echo "$gate: cold native projection took ${native_elapsed}s; limit=${native_deadline}s" >&2
    exit 1
}

tree_equal "$scratch/racket-projection" "$scratch/native-cold-projection" || {
    echo "$gate: compiled compiler-module trees differ" >&2
    diff -ru --no-dereference "$scratch/racket-projection" \
        "$scratch/native-cold-projection" >&2 || true
    exit 1
}
cmp -s "$scratch/racket.compiler-stream" "$scratch/native-cold.compiler-stream" || {
    echo "$gate: compiler streams differ between Racket shadow and native route" >&2
    diff -u "$scratch/racket.compiler-stream" \
        "$scratch/native-cold.compiler-stream" >&2 || true
    exit 1
}
echo "$gate: exact compiled tree and compiler streams PASS"

run_projection native-warm native "$native_cache" \
    "$scratch/native-warm-projection" "$scratch/native-warm.compiler-stream"
native_cold_key="$(sed -n \
    's/^beagle build: core-compiler-cache MISS \([0-9a-f]\{64\}\)$/\1/p' \
    "$scratch/native-cold.stderr")"
native_warm_key="$(sed -n \
    's/^beagle build: core-compiler-cache HIT \([0-9a-f]\{64\}\)$/\1/p' \
    "$scratch/native-warm.stderr")"
[[ "$native_cold_key" =~ ^[0-9a-f]{64}$ && "$native_warm_key" == "$native_cold_key" ]] || {
    echo "$gate: native miss/hit keys were not exact and stable" >&2
    sed -n '1,200p' "$scratch/native-cold.stderr" >&2
    sed -n '1,200p' "$scratch/native-warm.stderr" >&2
    exit 1
}
tree_equal "$scratch/native-cold-projection" "$scratch/native-warm-projection" || {
    echo "$gate: native cache hit changed the compiled tree" >&2
    exit 1
}
echo "$gate: native miss/hit key $native_cold_key and warm tree identity PASS"

# A byte-different executable wrapper preserves compiler behavior while proving
# the cache key follows the artifact digest rather than its filesystem path.
wrapper="$scratch/native-wrapper"
native_quoted="$(printf '%q' "$native_bin")"
printf '#!/usr/bin/env bash\nexec %s "\$@"\n' "$native_quoted" >"$wrapper"
chmod 0755 "$wrapper"
run_projection native-digest-change native "$native_cache" \
    "$scratch/native-digest-change-projection" "$scratch/native-digest-change.compiler-stream" \
    "$wrapper"
digest_change_key="$(sed -n \
    's/^beagle build: core-compiler-cache MISS \([0-9a-f]\{64\}\)$/\1/p' \
    "$scratch/native-digest-change.stderr")"
[[ "$digest_change_key" =~ ^[0-9a-f]{64}$ && "$digest_change_key" != "$native_cold_key" ]] || {
    echo "$gate: compiler artifact digest did not invalidate the projection cache" >&2
    sed -n '1,200p' "$scratch/native-digest-change.stderr" >&2
    exit 1
}
tree_equal "$scratch/native-cold-projection" "$scratch/native-digest-change-projection" || {
    echo "$gate: digest-only compiler wrapper changed projection bytes" >&2
    exit 1
}
echo "$gate: artifact digest invalidation key $digest_change_key PASS"
echo "$gate: exact tree, streams, miss/hit keys, digest identity, and cold projection ${native_elapsed}s PASS"
