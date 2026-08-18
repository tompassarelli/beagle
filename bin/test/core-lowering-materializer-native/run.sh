#!/usr/bin/env bash
# COLD-EMIT-T0 + T0-PARALLEL-BYTE-IDENTITY.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
gate="COLD-EMIT-T0/T0-PARALLEL-BYTE-IDENTITY"
native_bin="${BEAGLE_NATIVE_COMPILER_BIN:-}"
build_deadline="${BEAGLE_T0_BUILD_DEADLINE_SECONDS:-180}"
cold_deadline="${BEAGLE_COLD_EMIT_T0_DEADLINE_SECONDS:-165}"
suite_deadline="${BEAGLE_T0_SUITE_DEADLINE_SECONDS:-180}"
kill_grace="${BEAGLE_T0_KILL_GRACE_SECONDS:-5}"
platform_supervisor="$root/native-core/bin/run-bounded"

for value in "$build_deadline" "$cold_deadline" "$suite_deadline" "$kill_grace"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
        echo "$gate: timeout values must be positive integers" >&2
        exit 2
    }
done
[[ -x "$platform_supervisor" ]] || {
    echo "$gate: platform supervisor is unavailable: $platform_supervisor" >&2
    exit 2
}

scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-t0-emission.XXXXXX")"
cleanup() {
    local rc=$?
    if [[ "$rc" == 1 ]]; then
        echo "$gate: failure artifacts retained at $scratch" >&2
    else
        rm -rf "${scratch:?}"
    fi
    return "$rc"
}
trap cleanup EXIT

echo "$gate: platform supervisor normal-reap START"
normal_receipt="$scratch/platform-normal.receipt"
BEAGLE_BOUNDED_COMPLETION_RECEIPT="$normal_receipt" \
    "$platform_supervisor" 5 1 -- \
    bash -c 'setsid sh -c "sleep 30" >/dev/null 2>&1 & exit 0'
grep -Fqx 'subtree-reaped-v0 exit status=0' "$normal_receipt" || {
    echo "$gate: platform supervisor omitted its normal completion receipt" >&2
    exit 1
}

echo "$gate: platform supervisor timeout-reap START"
timeout_receipt="$scratch/platform-timeout.receipt"
set +e
BEAGLE_BOUNDED_COMPLETION_RECEIPT="$timeout_receipt" \
    "$platform_supervisor" 1 1 -- \
    bash -c 'setsid sh -c "sleep 30" >/dev/null 2>&1 & wait'
timeout_status=$?
set -e
[[ "$timeout_status" == 124 ]] &&
    grep -Fqx 'subtree-reaped-v0 timeout status=124' "$timeout_receipt" || {
        echo "$gate: wedged child was not visibly timed out and reaped" >&2
        exit 1
    }
echo "$gate: platform supervisor normal and timeout receipts PASS"

# Every live emission target remains in this landing gate.  These are the same
# focused suites used by the preceding projection seam, including both Nix
# emission and Nix error behavior.
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

# Thirty-two deliberately ordered functions make every requested worker count
# (4, 8, and 16) own multiple non-adjacent fragments.  Explicit worker counts
# bypass the retained 1024-function automatic threshold; the gate measures the
# partition/ordered-merge invariant without weakening the small-workload guard.
fixture="$scratch/parallel-identity.bgl"
{
    printf '#lang beagle\n(ns native.t0-parallel-identity)\n\n'
    for index in $(seq 0 31); do
        printf '(defn f%02d [(value Int)] Int (+ value %d))\n' \
            "$index" "$index"
    done
    printf '\n(defn entry [(value Int)] Int (f31 value))\n'
} >"$fixture"

compiled_override="${BEAGLE_T0_COMPILED_OVERRIDE:-}"
if [[ -z "$compiled_override" ]]; then
    compiled_override="$scratch/compiled"
    echo "$gate: Racket shadow compiler projection START"
    env -u BEAGLE_NATIVE_COMPILER_BIN \
        BEAGLE_CORE_BUILD_CACHE="$scratch/projection-cache" \
        BEAGLE_CORE_PROJECTION_ONLY=1 \
        BEAGLE_CORE_PROJECTION_ONLY_OUT="$compiled_override" \
        "$root/bin/beagle-build-core" --materializer c17 \
        --out "$scratch/projection-out" "$fixture"
    echo "$gate: Racket shadow compiler projection END"
fi
[[ -f "$compiled_override/native/core.clj" ]] || {
    echo "$gate: compiled override omitted native/core.clj: $compiled_override" >&2
    exit 2
}

run_shadow() {
    local workers="$1"
    local output="$scratch/shadow-$workers" log="$scratch/shadow-$workers.log"
    local started elapsed
    started="$(date +%s)"
    env -u BEAGLE_NATIVE_COMPILER_BIN \
        BEAGLE_CORE_COMPILED_OVERRIDE="$compiled_override" \
        BEAGLE_CORE_BUILD_CACHE="$scratch/shadow-cache-$workers" \
        BEAGLE_CORE_OVERALL_TIMEOUT_SECONDS="$build_deadline" \
        BEAGLE_CORE_LOWERING_TIMEOUT_SECONDS="$build_deadline" \
        BEAGLE_CORE_EMIT_WORKER_TIMEOUT_SECONDS="$build_deadline" \
        "$root/bin/beagle-build-core" --materializer c17 \
        --emit-workers "$workers" --out "$output" "$fixture" \
        >"$log" 2>&1
    elapsed=$(( $(date +%s) - started ))
    echo "$gate: existing-route workers=$workers seconds=$elapsed PASS"
}

run_shadow 1
for workers in 4 8 16; do
    run_shadow "$workers"
    diff -ru --no-dereference "$scratch/shadow-1" "$scratch/shadow-$workers" \
        >/dev/null || {
            echo "$gate: existing-route workers=$workers changed output bytes" >&2
            diff -ru --no-dereference "$scratch/shadow-1" \
                "$scratch/shadow-$workers" >&2 || true
            exit 1
        }
    echo "$gate: existing-route workers=$workers exact serial bytes PASS"
done

if [[ -z "$native_bin" ]]; then
    echo "$gate: existing route 4/8/16 exact serial bytes PASS" >&2
    echo "$gate: native full-compiler route, native 1/4/8/16 identity, and empty-cache fram-server-native-v1 16-worker <=${cold_deadline}s await BEAGLE_NATIVE_COMPILER_BIN" >&2
    exit 2
fi
[[ -x "$native_bin" ]] || {
    echo "$gate: BEAGLE_NATIVE_COMPILER_BIN is not executable: $native_bin" >&2
    exit 2
}

run_native() {
    local workers="$1"
    local output="$scratch/native-$workers" log="$scratch/native-$workers.log"
    BEAGLE_NATIVE_COMPILER_BIN="$native_bin" \
        BEAGLE_CORE_BUILD_CACHE="$scratch/native-projection-cache" \
        BEAGLE_CORE_OVERALL_TIMEOUT_SECONDS="$build_deadline" \
        BEAGLE_CORE_LOWERING_TIMEOUT_SECONDS="$build_deadline" \
        "$root/bin/beagle-build-core" --materializer c17 \
        --emit-workers "$workers" --out "$output" "$fixture" \
        >"$log" 2>&1
}

run_native 1
diff -ru --no-dereference "$scratch/shadow-1" "$scratch/native-1" >/dev/null || {
    echo "$gate: native serial bytes differ from the existing serial route" >&2
    exit 1
}
for workers in 4 8 16; do
    run_native "$workers"
    diff -ru --no-dereference "$scratch/native-1" "$scratch/native-$workers" \
        >/dev/null || {
            echo "$gate: native workers=$workers changed output bytes" >&2
            exit 1
        }
    echo "$gate: native workers=$workers exact serial bytes PASS"
done

# fram-server-native-v1 is the checked 21-source closure and eight server ABI
# entries.  The selected compiler binary is an allowed prior input; this run
# gives every semantic/native cache a fresh root and admits exactly one timed
# 16-worker lowering/emission sample.
fram_root="${BEAGLE_T0_FRAM_ROOT:-/home/tom/code/fram/main}"
[[ -d "$fram_root/src/fram" ]] || {
    echo "$gate: fram-server-native-v1 source root is unavailable: $fram_root" >&2
    exit 2
}
mapfile -t fram_sources < <(
    find "$fram_root/src/fram" -maxdepth 1 -type f -name '*.bgl' -printf '%f\n' |
        LC_ALL=C sort
)
[[ "${#fram_sources[@]}" == 21 ]] || {
    echo "$gate: fram-server-native-v1 requires 21 sources, found ${#fram_sources[@]}" >&2
    exit 2
}
fram_entries=(
    fram.native-server/server-generated-abi
    fram.native-server/server-store-boot!
    fram.native-server/server-store-dispatch!
    fram.native-server/server-store-shutdown
    fram.native-server/server-codec-read-request!
    fram.native-server/server-codec-write-response!
    fram.native-server/server-codec-release-request
    fram.native-server/server-codec-release-response
)
cold_args=(--materializer c17 --emit-workers 16 --out "$scratch/fram-cold")
for entry in "${fram_entries[@]}"; do
    cold_args+=(--entry "$entry")
done
cold_args+=("${fram_sources[@]}")

echo "$gate: fram-server-native-v1 empty-cache 16-worker sample START"
(
    cd "$fram_root/src/fram"
    BEAGLE_NATIVE_COMPILER_BIN="$native_bin" \
        BEAGLE_CORE_BUILD_CACHE="$scratch/fram-empty-cache" \
        BEAGLE_CORE_OVERALL_TIMEOUT_SECONDS="$((cold_deadline + 60))" \
        BEAGLE_CORE_LOWERING_TIMEOUT_SECONDS="$cold_deadline" \
        "$root/bin/beagle-build-core" "${cold_args[@]}"
) >"$scratch/fram-cold.stdout" 2>"$scratch/fram-cold.stderr"
cold_seconds="$(sed -n \
    's/^beagle build: phase core-lowering SECONDS \([0-9][0-9]*\)$/\1/p' \
    "$scratch/fram-cold.stderr")"
[[ "$cold_seconds" =~ ^[0-9]+$ && "$cold_seconds" -le "$cold_deadline" ]] || {
    echo "$gate: COLD-EMIT-T0 missing or over limit: seconds=${cold_seconds:-missing} limit=$cold_deadline" >&2
    exit 1
}
echo "$gate: COLD-EMIT-T0 PASS workers=16 seconds=$cold_seconds limit=$cold_deadline"
echo "$gate: T0-PARALLEL-BYTE-IDENTITY PASS workers=4,8,16"
