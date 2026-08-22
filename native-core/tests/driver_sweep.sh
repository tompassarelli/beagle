#!/usr/bin/env bash
# driver_sweep.sh: run every native-core validation driver; each driver's
# green result is cached on its own traced input closure (bin/_gate-cache-run:
# compiler sources, beagle-lib, and the driver script).
# Compiler unchanged + driver unchanged = cached-green, replayed not re-run.
# BEAGLE_GATE_NO_CACHE=1 forces full runs.
#
# Usage:
#   driver_sweep.sh                # all drivers (BEAGLE_SWEEP_JOBS parallel, default 8)
#   driver_sweep.sh --list         # enumerate driver names
#   driver_sweep.sh --one NAME     # run one driver directly (the cached unit)
#
# Aggregate status is 0 when every driver finishes green, 124 when at least
# one driver authenticates a deadline, and 1 when any driver fails or emits an
# invalid verdict. A completed failure outranks a simultaneous diagnostic.
# A driver authenticates its 124 by validating its supervisor receipt and
# emitting `beagle-native-driver: DIAGNOSTIC authenticated-timeout-v0` exactly.
#
# Every NATIVE_*_ARTIFACTS variable mentioned by a driver is pointed at its own
# empty temporary directory, and every NATIVE_*_REPO variable at this repo.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
validation="$repo/native-core/validation"
self="$here/$(basename "${BASH_SOURCE[0]}")"
diagnostic_marker="beagle-native-driver: DIAGNOSTIC authenticated-timeout-v0"

driver_names() {
    local d
    for d in "$validation"/*/; do
        if [[ -f "$d/drive.sh" || -f "$d/run.sh" || -f "$d/runner.bgl" ]]; then
            basename "$d"
        fi
    done | LC_ALL=C sort
}

run_one() {
    local name="$1" dir="$validation/$1" driver var work dest
    local -a case_files
    if [[ -f "$dir/drive.sh" ]]; then
        driver="$dir/drive.sh"
    elif [[ -f "$dir/run.sh" ]]; then
        driver="$dir/run.sh"
    elif [[ -f "$dir/runner.bgl" ]]; then
        driver="$dir/runner.bgl"
    else
        echo "driver_sweep.sh: no driver in $dir" >&2
        return 2
    fi

    work="$(mktemp -d "${TMPDIR:-/tmp}/sweep-$name.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '${work:?}'" RETURN
    if [[ "$driver" == *.bgl ]]; then
        mapfile -d '' -t case_files < <(
            find "$dir/cases" -maxdepth 1 -type f -name '*.edn' -print0 |
                LC_ALL=C sort -z
        )
        [[ ${#case_files[@]} -gt 0 ]] || {
            echo "driver_sweep.sh: no case data in $dir/cases" >&2
            return 2
        }
        "$repo/bin/beagle" native-exe \
            --module-root "native-core/src=$repo/native-core/src" \
            --out "$work/case-runner" \
            --artifacts "$work/artifacts" \
            --entry native.case-runner/-main \
            "$driver" || return $?
        (cd "$repo" && "$work/case-runner" "${case_files[@]}")
        return $?
    fi

    while IFS= read -r var; do
        dest="$work/${var,,}"
        mkdir -p "$dest"
        export "$var=$dest"
    done < <(grep -oE '\bNATIVE_[A-Z_]*ARTIFACTS\b' "$driver" | LC_ALL=C sort -u)
    while IFS= read -r var; do
        export "$var=$repo"
    done < <(grep -oE '\bNATIVE_[A-Z_]*REPO\b' "$driver" | LC_ALL=C sort -u)
    (cd "$repo" && bash "$driver")
}

case "${1:-}" in
    --list)
        driver_names
        exit 0
        ;;
    --one)
        [[ -n "${2:-}" && -d "$validation/${2:-}" ]] ||
            { echo "driver_sweep.sh: --one needs a validation driver name" >&2; exit 2; }
        run_one "$2"
        exit $?
        ;;
    "") ;;
    *)
        echo "driver_sweep.sh: unknown argument: $1" >&2
        exit 2
        ;;
esac

jobs="${BEAGLE_SWEEP_JOBS:-8}"
logs="$(mktemp -d "${TMPDIR:-/tmp}/driver-sweep.XXXXXX")"
trap 'rm -rf "${logs:?}"' EXIT

mapfile -t names < <(driver_names)
echo "=== native-core driver sweep: ${#names[@]} drivers, $jobs at a time ==="

sweep_child() {  # NAME -> writes $logs/NAME.log and $logs/NAME.status
    local name="$1" rc
    if [[ -x "$repo/bin/_gate-cache-run" ]]; then
        "$repo/bin/_gate-cache-run" --domain driver --id "$name" -- \
            "$self" --one "$name" > "$logs/$name.log" 2>&1
    else
        "$self" --one "$name" > "$logs/$name.log" 2>&1
    fi
    rc=$?
    case "$rc" in
        0)
            if grep -q '^beagle-gate-cache: cached-green ' "$logs/$name.log"; then
                echo "CACHED" > "$logs/$name.status"
            elif grep -q '^SKIP' "$logs/$name.log"; then
                echo "SKIP" > "$logs/$name.status"
            else
                echo "PASS" > "$logs/$name.status"
            fi
            ;;
        124)
            # GNU timeout also returns 124 when its child exits 124. The driver
            # must validate its own supervisor receipt before emitting this
            # exact marker; a bare status cannot authenticate a deadline.
            if grep -Fqx "$diagnostic_marker" "$logs/$name.log"; then
                echo "DIAGNOSTIC" > "$logs/$name.status"
            else
                echo "driver_sweep.sh: unauthenticated child status 124" \
                    >> "$logs/$name.log"
                echo "FAIL" > "$logs/$name.status"
            fi
            ;;
        *)   echo "FAIL" > "$logs/$name.status" ;;
    esac
}

active=0
for name in "${names[@]}"; do
    sweep_child "$name" &
    active=$((active + 1))
    if [[ $active -ge $jobs ]]; then
        wait -n || true
        active=$((active - 1))
    fi
done
wait || true

summarize_results() {
    local failures=0 diagnostics=0 cached=0 name status
    for name in "${names[@]}"; do
        status="$(cat "$logs/$name.status" 2>/dev/null || true)"
        case "$status" in
            PASS|SKIP|CACHED|DIAGNOSTIC|FAIL) ;;
            *)
                status="FAIL"
                echo "driver_sweep.sh: missing or invalid child status for $name" \
                    >> "$logs/$name.log"
                ;;
        esac
        printf '%-10s %s\n' "$status" "$name"
        case "$status" in
            FAIL)
                failures=$((failures + 1))
                sed 's/^/    /' "$logs/$name.log" | tail -25
                ;;
            DIAGNOSTIC)
                diagnostics=$((diagnostics + 1))
                sed 's/^/    /' "$logs/$name.log" | tail -25
                ;;
            CACHED) cached=$((cached + 1)) ;;
        esac
    done

    echo
    if [[ $failures -gt 0 ]]; then
        echo "driver_sweep: $failures of ${#names[@]} drivers FAILED ($diagnostics diagnostic, $cached cached-green)"
        return 1
    fi
    if [[ $diagnostics -gt 0 ]]; then
        echo "driver_sweep: $diagnostics of ${#names[@]} drivers DIAGNOSTIC -- killed unfinished ($cached cached-green)"
        return 124
    fi
    echo "driver_sweep: all ${#names[@]} drivers green ($cached cached-green, $(( ${#names[@]} - cached )) ran)"
}

summarize_results
exit $?
