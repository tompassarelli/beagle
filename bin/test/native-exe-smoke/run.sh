#!/usr/bin/env bash
# Compile and execute one complete native module through both supported C17
# frontends. The entry exercises the generated arena/capability ABI and returns
# the two-element module-global vector length as its process status.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source_file="$repo/native-core/validation/slice-strings/text_ops.bclj"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-native-exe-smoke.XXXXXX")"
cleanup() { rm -rf "${scratch:?}"; }
trap cleanup EXIT

gcc_bin="$(command -v gcc 2>/dev/null || true)"
[[ -n "$gcc_bin" ]] || { echo "native-exe smoke: gcc not found" >&2; exit 1; }

find_clang() {
    if command -v clang >/dev/null 2>&1; then
        command -v clang
        return 0
    fi
    local candidate
    candidate="$(compgen -G '/nix/store/*-clang-wrapper-*/bin/clang' | sort -V | tail -1)"
    [[ -n "$candidate" ]] && printf '%s\n' "$candidate"
}

clang_bin="$(find_clang || true)"
[[ -n "$clang_bin" ]] || { echo "native-exe smoke: clang not found" >&2; exit 1; }

run_frontend() {
    local label="$1"
    local compiler="$2"
    local entry="$3"
    local symbol="$4"
    local abi="$5"
    local expected_status="$6"
    local stage="$scratch/$label"
    local executable="$stage/bin/hello-module"
    local log="$stage/build.log"
    mkdir -p "$stage/bin"

    "$repo/bin/beagle" native-exe \
        --out "$executable" \
        --entry "native.text-ops/$entry" \
        --cc "$compiler" \
        --artifacts "$stage" \
        "$source_file" >"$log"

    [[ -x "$executable" ]]
    grep -Fqx \
        "native-exe-entry PASS name=native.text-ops/$entry symbol=$symbol return=Int abi=$abi" \
        "$stage/native-exe.report.txt"
    grep -Fq "native-exe-c17 PASS compiler=" "$stage/native-exe.report.txt"
    [[ "$(grep -c '^obligation-projection PASS ' "$stage/report.txt")" == "7" ]]

    set +e
    env -i "$executable"
    executable_rc=$?
    set -e
    [[ $executable_rc -eq "$expected_status" ]] || {
        echo "native-exe smoke: $label executable returned $executable_rc, expected $expected_status" >&2
        exit 1
    }

    if command -v ldd >/dev/null 2>&1; then
        if ldd "$executable" | grep -Eiq 'libjvm|java|clojure'; then
            echo "native-exe smoke: $label executable has a JVM runtime dependency" >&2
            exit 1
        fi
    fi
    printf 'native-exe smoke: %s compile + link + no-JVM run ok\n' "$label"
}

run_frontend gcc "$gcc_bin" global-size native_m0_fn_21 arena+capability 2
run_frontend clang "$clang_bin" local-shadow-size native_m0_fn_23 pure 3

missing="$scratch/missing-entry"
printf 'stale executable\n' >"$missing"
set +e
"$repo/bin/beagle" native-exe \
    --out "$missing" \
    --entry native.text-ops/missing \
    --cc "$gcc_bin" \
    "$source_file" >"$scratch/missing.stdout" 2>"$scratch/missing.stderr"
missing_rc=$?
set -e
[[ $missing_rc -ne 0 ]]
[[ ! -e "$missing" ]]
grep -Fqx \
    "beagle native-exe: exported entry not found: native.text-ops/missing" \
    "$scratch/missing.stderr"
printf 'native-exe smoke: missing export fails closed\n'
