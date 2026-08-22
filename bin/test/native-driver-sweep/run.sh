#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
subject="$root/native-core/tests/driver_sweep.sh"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-driver-sweep.XXXXXX")"
trap 'rm -rf -- "${scratch:?}"' EXIT

fixture="$scratch/repo"
mkdir -p \
    "$fixture/native-core/tests" \
    "$fixture/native-core/validation/completed" \
    "$fixture/native-core/validation/unfinished" \
    "$fixture/bin"
cp "$subject" "$fixture/native-core/tests/driver_sweep.sh"
cp "$root/bin/_gate-cache-run" "$fixture/bin/_gate-cache-run"

cat >"$fixture/native-core/validation/completed/drive.sh" <<'DRIVER'
#!/usr/bin/env bash
printf 'completed validation status=%s\n' "${DRIVER_SWEEP_COMPLETED_STATUS:?}"
exit "$DRIVER_SWEEP_COMPLETED_STATUS"
DRIVER

cat >"$fixture/native-core/validation/unfinished/drive.sh" <<'DRIVER'
#!/usr/bin/env bash
printf 'unfinished validation\n'
exit 124
DRIVER

run_case() {
    local label="$1" completed_status="$2" expected_status="$3"
    local log="$scratch/$label.log" status
    set +e
    DRIVER_SWEEP_COMPLETED_STATUS="$completed_status" BEAGLE_SWEEP_JOBS=2 \
        BEAGLE_GATE_NO_CACHE=1 \
        bash "$fixture/native-core/tests/driver_sweep.sh" >"$log" 2>&1
    status=$?
    set -e
    if [[ "$status" -ne "$expected_status" ]]; then
        cat "$log" >&2
        echo "native-driver-sweep: $label returned $status, expected $expected_status" >&2
        exit 1
    fi
    printf '%s' "$log"
}

diagnostic_log="$(run_case diagnostic-only 0 124)"
grep -Eq '^PASS[[:space:]]+completed$' "$diagnostic_log"
grep -Eq '^DIAGNOSTIC[[:space:]]+unfinished$' "$diagnostic_log"
grep -Fqx \
    'driver_sweep: 1 of 2 drivers DIAGNOSTIC -- killed unfinished (0 cached-green)' \
    "$diagnostic_log"
if grep -Fq 'drivers FAILED' "$diagnostic_log"; then
    echo "native-driver-sweep: diagnostic-only run was reported as a product failure" >&2
    exit 1
fi

failure_log="$(run_case failure-outranks-diagnostic 7 1)"
grep -Eq '^FAIL[[:space:]]+completed$' "$failure_log"
grep -Eq '^DIAGNOSTIC[[:space:]]+unfinished$' "$failure_log"
grep -Fqx \
    'driver_sweep: 1 of 2 drivers FAILED (1 diagnostic, 0 cached-green)' \
    "$failure_log"

echo "native driver sweep: diagnostic classification and failure precedence PASS"
