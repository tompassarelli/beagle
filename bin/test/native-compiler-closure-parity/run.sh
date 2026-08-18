#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--capture" ]]; then
    out="$2"
    err="$3"
    shift 3
    exec "$@" >"$out" 2>"$err"
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
self="$(realpath "${BASH_SOURCE[0]}")"
manifest="$root/self-host/full-compiler-closure.manifest"
supervisor="$root/native-core/bin/run-bounded.rkt"
native="${BEAGLE_NATIVE_BIN:-$root/.beagle/stage0-result/bin/beagle-selfhost}"
deadline="${BEAGLE_NATIVE_CLOSURE_DEADLINE_SECONDS:-180}"
kill_grace="${BEAGLE_NATIVE_CLOSURE_KILL_GRACE_SECONDS:-5}"
gate="NATIVE-COMPILER-CLOSURE-PARITY"

source "$root/bin/_beagle-racket"

[[ "$deadline" =~ ^[1-9][0-9]*$ ]] || {
    printf '%s: invalid deadline: %s\n' "$gate" "$deadline" >&2
    exit 2
}
[[ "$kill_grace" =~ ^[1-9][0-9]*$ ]] || {
    printf '%s: invalid kill grace: %s\n' "$gate" "$kill_grace" >&2
    exit 2
}
[[ -x "$native" ]] || {
    printf '%s: native stage0 is unavailable: %s\n' "$gate" "$native" >&2
    exit 2
}

scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-native-closure-parity.XXXXXX")"
pids=()
cleanup() {
    local pid
    for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    rm -rf "${scratch:?}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

cd "$root"
mapfile -t modules < <(
    awk '$1 == "input" && $2 == "native-core" {print $3}' "$manifest"
)
if [[ ${#modules[@]} -ne 13 ]]; then
    printf '%s: expected 13 native-core inputs, found %d\n' \
        "$gate" "${#modules[@]}" >&2
    exit 1
fi

bundle_args=()
for module in "${modules[@]}"; do
    bundle_args+=(--source "$module")
done

mkdir -p "$scratch/oracle" "$scratch/native" "$scratch/control"
compile_oracle() {
    local index="$1"
    local module="$2"
    local output="$3"
    local stem source_id rc=0
    stem="$(printf '%02d' "$index")"
    source_id="closure/${module#native-core/src/}"
    "$RACKET" "$supervisor" "$deadline" "$kill_grace" -- \
        "$self" --capture "$output" "$scratch/control/oracle-$stem.stderr" \
        env BEAGLE_EMIT_SRCLOC=0 "$RACKET" \
        "$root/beagle-lib/private/build-one-cli.rkt" \
        --module-root "closure=$root/native-core/src" \
        --source "$root/$module" "$source_id" \
        >"$scratch/control/oracle-$stem.supervisor" 2>&1 || rc=$?
    printf '%s\n' "$rc" >"$scratch/control/oracle-$stem.status"
}

compile_native() {
    local index="$1"
    local module="$2"
    local output="$3"
    local stem rc=0
    stem="$(printf '%02d' "$index")"
    "$RACKET" "$supervisor" "$deadline" "$kill_grace" -- \
        "$self" --capture "$output" "$scratch/control/native-$stem.stderr" \
        env BEAGLE_EMIT_SRCLOC=0 "$native" emit --target clj \
        "${bundle_args[@]}" "$module" \
        >"$scratch/control/native-$stem.supervisor" 2>&1 || rc=$?
    printf '%s\n' "$rc" >"$scratch/control/native-$stem.status"
}

printf '%s: oracle START workers=13 deadline=%ss\n' "$gate" "$deadline"
for index in "${!modules[@]}"; do
    module="${modules[$index]}"
    namespace="$(sed -n 's/^(ns \([^[:space:]()]*\).*/\1/p' "$module")"
    if [[ -z "$namespace" || "$namespace" == *$'\n'* ]]; then
        printf '%s: could not resolve one namespace from %s\n' \
            "$gate" "$module" >&2
        exit 1
    fi
    relative="${namespace//./\/}"
    relative="${relative//-/_}.clj"
    mkdir -p "$scratch/oracle/$(dirname "$relative")"
    compile_oracle "$index" "$module" "$scratch/oracle/$relative" &
    pids+=("$!")
done
for pid in "${pids[@]}"; do
    wait "$pid" || true
done
pids=()
printf '%s: oracle END\n' "$gate"

printf '%s: native START workers=13 deadline=%ss\n' "$gate" "$deadline"
for index in "${!modules[@]}"; do
    module="${modules[$index]}"
    namespace="$(sed -n 's/^(ns \([^[:space:]()]*\).*/\1/p' "$module")"
    relative="${namespace//./\/}"
    relative="${relative//-/_}.clj"
    mkdir -p "$scratch/native/$(dirname "$relative")"
    compile_native "$index" "$module" "$scratch/native/$relative" &
    pids+=("$!")
done
for pid in "${pids[@]}"; do
    wait "$pid" || true
done
pids=()
printf '%s: native END\n' "$gate"

: >"$scratch/control/oracle.stderr"
: >"$scratch/control/native.stderr"
oracle_statuses=()
native_statuses=()
for index in "${!modules[@]}"; do
    stem="$(printf '%02d' "$index")"
    if [[ -f "$scratch/control/oracle-$stem.status" ]]; then
        oracle_status="$(<"$scratch/control/oracle-$stem.status")"
    else
        oracle_status=125
    fi
    if [[ -f "$scratch/control/native-$stem.status" ]]; then
        status="$(<"$scratch/control/native-$stem.status")"
    else
        status=125
    fi
    oracle_statuses+=("$oracle_status")
    native_statuses+=("$status")
    if [[ -f "$scratch/control/oracle-$stem.stderr" ]]; then
        command cat "$scratch/control/oracle-$stem.stderr" \
            >>"$scratch/control/oracle.stderr"
    fi
    if [[ -f "$scratch/control/native-$stem.stderr" ]]; then
        command cat "$scratch/control/native-$stem.stderr" \
            >>"$scratch/control/native.stderr"
    fi
done

fail=0
for index in "${!native_statuses[@]}"; do
    if [[ "${oracle_statuses[$index]}" != 0 ]]; then
        printf '%s: oracle failed for %s: status=%s\n' \
            "$gate" "${modules[$index]}" "${oracle_statuses[$index]}" >&2
        command cat "$scratch/control/oracle-$(printf '%02d' "$index").supervisor" >&2
        fail=1
    fi
    if [[ "${native_statuses[$index]}" != "${oracle_statuses[$index]}" ]]; then
        printf '%s: status mismatch for %s: oracle=%s native=%s\n' \
            "$gate" "${modules[$index]}" "${oracle_statuses[$index]}" \
            "${native_statuses[$index]}" >&2
        command cat "$scratch/control/native-$(printf '%02d' "$index").supervisor" >&2
        fail=1
    fi
done

if ! cmp -s "$scratch/control/oracle.stderr" \
    "$scratch/control/native.stderr"; then
    printf '%s: diagnostic bytes differ: oracle=%s native=%s\n' \
        "$gate" "$(wc -c <"$scratch/control/oracle.stderr")" \
        "$(wc -c <"$scratch/control/native.stderr")" >&2
    fail=1
fi

find "$scratch/oracle" -type f -printf '%P\n' | LC_ALL=C sort \
    >"$scratch/control/oracle.files"
find "$scratch/native" -type f -printf '%P\n' | LC_ALL=C sort \
    >"$scratch/control/native.files"
if ! cmp -s "$scratch/control/oracle.files" "$scratch/control/native.files"; then
    printf '%s: emitted file sets differ\n' "$gate" >&2
    diff -u "$scratch/control/oracle.files" "$scratch/control/native.files" >&2 || true
    fail=1
fi

output_count=0
output_bytes=0
while IFS= read -r relative; do
    [[ -n "$relative" ]] || continue
    output_count=$((output_count + 1))
    output_bytes=$((output_bytes + $(wc -c <"$scratch/oracle/$relative")))
    if [[ ! -f "$scratch/native/$relative" ]] || \
        ! cmp -s "$scratch/oracle/$relative" "$scratch/native/$relative"; then
        printf '%s: output bytes differ: %s\n' "$gate" "$relative" >&2
        fail=1
    fi
done <"$scratch/control/oracle.files"

if [[ "$fail" -ne 0 ]]; then
    exit 1
fi
printf '%s: passed status, diagnostics, %d-file set, and %d output bytes\n' \
    "$gate" "$output_count" "$output_bytes"
