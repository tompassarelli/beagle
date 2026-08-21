#!/usr/bin/env bash
# Tiny controlled proof for the host resource-envelope contract.

set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
runner="$repo/tools/compiler-resource-envelope/run.sh"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-compiler-envelope.XXXXXX")"

cleanup() {
    local status=$?
    if [[ "$status" -eq 0 ]]; then
        rm -rf "${scratch:?}"
    else
        echo "compiler-resource-envelope: preserved failure evidence at $scratch" >&2
    fi
    return "$status"
}
trap cleanup EXIT

[[ -x "$runner" ]] || {
    echo "compiler-resource-envelope: runner is not executable: $runner" >&2
    exit 2
}

# This runs two real copies of the checked-AST verifier-pool fixture through
# the production build driver while each outer candidate process fans out to
# its inherited worker budget. The fixture supplies fake compiler children, so
# it proves scheduling, cancellation, and deterministic merge order without a
# Store/Firn/native build or a shared Racket bytecode write.
candidate_probe() {
    : "${BEAGLE_ENVELOPE_OUTPUT:?}"
    : "${BEAGLE_ENVELOPE_WORKERS:?}"
    mkdir -p "$BEAGLE_ENVELOPE_OUTPUT/workers"
    for ((worker = 0; worker < BEAGLE_ENVELOPE_WORKERS; worker++)); do
        (
            awk '/^Cpus_allowed_list:/ { print $2 }' /proc/self/status \
                >>"$BEAGLE_ENVELOPE_OUTPUT/workers/affinity"
            awk '{ print $19 }' /proc/self/stat \
                >>"$BEAGLE_ENVELOPE_OUTPUT/workers/nice"
            ionice >>"$BEAGLE_ENVELOPE_OUTPUT/workers/ionice"
            sleep 0.20
        ) &
    done
    wait
    nproc >"$BEAGLE_ENVELOPE_OUTPUT/nproc"
    printf '%s:%s:%s\n' "$BEAGLE_CORE_MODULE_JOBS" "$BEAGLE_TEST_JOBS" \
        "$BEAGLE_EVAL_JOBS" >"$BEAGLE_ENVELOPE_OUTPUT/nested-budgets"
    printf 'candidate fixture v1\n' >"$BEAGLE_ENVELOPE_OUTPUT/result"
    "$BEAGLE_ENVELOPE_REPO/bin/test/ast-verify-parallel/run.sh" \
        >"$BEAGLE_ENVELOPE_OUTPUT/ast-verifier.log"
}

canonical_probe() {
    awk '/^Cpus_allowed_list:/ { print $2 }' /proc/self/status \
        >"$BEAGLE_ENVELOPE_OUTPUT/affinity"
    awk '{ print $19 }' /proc/self/stat >"$BEAGLE_ENVELOPE_OUTPUT/nice"
    nproc >"$BEAGLE_ENVELOPE_OUTPUT/nproc"
    printf '%s:%s:%s\n' "$BEAGLE_CORE_MODULE_JOBS" "$BEAGLE_TEST_JOBS" \
        "$BEAGLE_EVAL_JOBS" >"$BEAGLE_ENVELOPE_OUTPUT/nested-budgets"
    printf 'canonical fixture v1\n' >"$BEAGLE_ENVELOPE_OUTPUT/result"
}
export -f candidate_probe canonical_probe

"$runner" --root "$scratch/run" candidate-a 120 2 -- \
    bash -ceu candidate_probe &
candidate_a_pid=$!
"$runner" --root "$scratch/run" candidate-b 120 2 -- \
    bash -ceu candidate_probe &
candidate_b_pid=$!
wait "$candidate_a_pid"
wait "$candidate_b_pid"

"$runner" --root "$scratch/run" canonical 30 2 -- \
    bash -ceu canonical_probe

if "$runner" --root "$scratch/rejected" candidate-a 30 2 -- \
    printf --emit-workers 9; then
    echo 'compiler-resource-envelope: accepted an oversubscribed emission pool' >&2
    exit 1
fi

cmp "$scratch/run/candidate-a/out/result" \
    "$scratch/run/candidate-b/out/result"

for lane in canonical candidate-a candidate-b; do
    [[ -f "$scratch/run/$lane/provenance.env" ]] || exit 1
    [[ -f "$scratch/run/$lane/subtree-reaped.receipt" ]] || exit 1
    grep -Fqx 'worker_budget=8' "$scratch/run/$lane/provenance.env"
    grep -Fqx '8' "$scratch/run/$lane/out/nproc"
    grep -Fqx '8:8:8' "$scratch/run/$lane/out/nested-budgets"
done

grep -Fqx '0-3,12-15' "$scratch/run/canonical/out/affinity"
grep -Fqx '0' "$scratch/run/canonical/out/nice"
grep -Fqx '4-7,16-19' "$scratch/run/candidate-a/out/workers/affinity"
grep -Fqx '8-11,20-23' "$scratch/run/candidate-b/out/workers/affinity"
[[ "$(wc -l <"$scratch/run/candidate-a/out/workers/affinity")" == 8 ]]
[[ "$(wc -l <"$scratch/run/candidate-b/out/workers/affinity")" == 8 ]]
grep -Fqx '19' "$scratch/run/candidate-a/out/workers/nice"
grep -Fqx '19' "$scratch/run/candidate-b/out/workers/nice"
grep -Fq 'idle' "$scratch/run/candidate-a/out/workers/ionice"
grep -Fq 'idle' "$scratch/run/candidate-b/out/workers/ionice"
grep -Fqx 'ast-verify-parallel: PASS overlap=3 order=stable arbitration=complete siblings=reaped' \
    "$scratch/run/candidate-a/out/ast-verifier.log"
grep -Fqx 'ast-verify-parallel: PASS overlap=3 order=stable arbitration=complete siblings=reaped' \
    "$scratch/run/candidate-b/out/ast-verifier.log"

for lane in canonical candidate-a candidate-b; do
    [[ -d "$scratch/run/$lane/cache" ]]
    [[ -d "$scratch/run/$lane/tmp" ]]
    [[ -d "$scratch/run/$lane/out" ]]
done

echo 'compiler-resource-envelope: PASS lanes=3 workers=8+8 cache/tmp/output=private ast-pools=concurrent'
