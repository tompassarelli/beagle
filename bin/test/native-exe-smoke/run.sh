#!/usr/bin/env bash
# Compile and execute one complete native module through both supported C17
# frontends. The entry exercises the generated arena/capability ABI and returns
# the two-element module-global vector length as its process status.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source_file="$repo/bin/test/native-exe-smoke/entry_core.bgl"
projection_source="$repo/bin/test/native-exe-smoke/entry_projection.bgl"
qbe_source="$repo/bin/test/native-exe-smoke/entry_qbe.bgl"
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
        --entry "native.core-entry/$entry" \
        --cc "$compiler" \
        --artifacts "$stage" \
        "$source_file" >"$log"

    [[ -x "$executable" ]]
    grep -Fqx \
        "native-exe-entry PASS name=native.core-entry/$entry symbol=$symbol return=Int abi=$abi" \
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

run_frontend gcc "$gcc_bin" global-size native_m0_fn_0 arena+capability 2
run_frontend clang "$clang_bin" local-shadow-size native_m0_fn_0 arena+capability 3

projection_c17="$scratch/projection-c17"
"$repo/bin/beagle" build --materializer c17 \
    --out "$projection_c17" \
    --entry native.entry-projection/entry \
    --entry native.entry-projection/second \
    "$projection_source" >"$scratch/projection-c17.log"

for expected in \
    "source-entry native.entry-projection/entry" \
    "source-entry native.entry-projection/second" \
    "source-definitions 6" \
    "world-functions 4" \
    "lowered fn_0 box-value 1 blocks" \
    "lowered fn_1 helper 1 blocks" \
    "lowered fn_2 entry 1 blocks" \
    "lowered fn_3 second 3 blocks" \
    "stage typed-to-native COMPLETE" \
    "materialize-c17 OK module_0.h module_0.c" \
    "result PASS"; do
    grep -Fqx "$expected" "$projection_c17/report.txt"
done
[[ "$(grep -c '^obligation-projection PASS ' "$projection_c17/report.txt")" == "7" ]]
[[ -f "$projection_c17/module_0.c" && ! -e "$projection_c17/module_0.ssa" ]]
if grep -Eq 'unreachable|bad-entry|hidden|^pending ' "$projection_c17/report.txt"; then
    echo "native-exe smoke: entry projection retained unreachable definitions" >&2
    exit 1
fi
printf 'native-exe smoke: repeatable entry closure + exact function map ok\n'

qbe_c17="$scratch/qbe-c17"
qbe_qbe="$scratch/qbe-qbe"
"$repo/bin/beagle" build --materializer c17 \
    --out "$qbe_c17" \
    --entry native.qbe-entry/entry \
    "$qbe_source" >"$scratch/qbe-c17.log"
"$repo/bin/beagle" build --materializer qbe \
    --out "$qbe_qbe" \
    --entry native.qbe-entry/entry \
    "$qbe_source" >"$scratch/qbe-qbe.log"
grep -Fqx "materialize-c17 OK module_0.h module_0.c" "$qbe_c17/report.txt"
grep -Fqx "materialize-qbe OK module_0.ssa" "$qbe_qbe/report.txt"
grep -Fqx "result PASS" "$qbe_c17/report.txt"
grep -Fqx "result PASS" "$qbe_qbe/report.txt"
[[ "$(grep -c '^obligation-projection PASS ' "$qbe_c17/report.txt")" == "7" ]]
[[ "$(grep -c '^obligation-projection PASS ' "$qbe_qbe/report.txt")" == "7" ]]
cmp "$qbe_c17/module.native-world" "$qbe_qbe/module.native-world"
cmp "$qbe_c17/module.native-world.sha256" "$qbe_qbe/module.native-world.sha256"
[[ -f "$qbe_c17/module_0.c" && ! -e "$qbe_c17/module_0.ssa" ]]
[[ -f "$qbe_qbe/module_0.ssa" && ! -e "$qbe_qbe/module_0.c" ]]
printf 'native-exe smoke: one sealed Native World + explicit C17/QBE materializers ok\n'

set +e
"$repo/bin/beagle" build --materializer c17 \
    --out "$scratch/full-module" \
    "$projection_source" >"$scratch/full-module.stdout" 2>"$scratch/full-module.stderr"
full_rc=$?
"$repo/bin/beagle" build --materializer c17 \
    --out "$scratch/reachable-refusal" \
    --entry native.entry-projection/bad-entry \
    "$projection_source" \
    >"$scratch/reachable-refusal.stdout" 2>"$scratch/reachable-refusal.stderr"
refusal_rc=$?
"$repo/bin/beagle" build --materializer c17 \
    --out "$scratch/private-entry" \
    --entry native.entry-projection/hidden \
    "$projection_source" \
    >"$scratch/private-entry.stdout" 2>"$scratch/private-entry.stderr"
private_rc=$?
"$repo/bin/beagle" build --materializer c17 \
    --out "$scratch/try-reachable" \
    --entry native.entry-projection/try-entry \
    "$projection_source" \
    >"$scratch/try-reachable.stdout" 2>"$scratch/try-reachable.stderr"
try_rc=$?
set -e
[[ $full_rc -ne 0 && $refusal_rc -ne 0 && $private_rc -ne 0 && $try_rc -ne 0 ]]
grep -Fq 'pending TODO-NATIVE-FUNCTION-BODY:' "$scratch/full-module/report.txt"
grep -Fq '[unreachable]' "$scratch/reachable-refusal/report.txt"
grep -Fqx 'entry-error entry is private, not exported: native.entry-projection/hidden' \
    "$scratch/private-entry/report.txt"
grep -Fq 'TODO-NATIVE-FORM-unsupported-try' "$scratch/try-reachable/report.txt"
for helper in try-body-helper try-catch-helper try-finally-helper; do
    grep -Fq $'\tname\tt\t'"$helper" "$scratch/try-reachable/source.facts"
done
if grep -Fq $'\tname\tt\tunreachable' "$scratch/try-reachable/source.facts"; then
    echo "native-exe smoke: try projection retained an unreachable definition" >&2
    exit 1
fi
printf 'native-exe smoke: full default + reachable/private refusals fail closed\n'
printf 'native-exe smoke: try child reachability + lowering refusal ok\n'

missing="$scratch/missing-entry"
printf 'stale executable\n' >"$missing"
set +e
"$repo/bin/beagle" native-exe \
    --out "$missing" \
    --entry native.core-entry/missing \
    --cc "$gcc_bin" \
    "$source_file" >"$scratch/missing.stdout" 2>"$scratch/missing.stderr"
missing_rc=$?
set -e
[[ $missing_rc -ne 0 ]]
[[ ! -e "$missing" ]]
grep -Fqx \
    "beagle native-exe: exported entry not found: native.core-entry/missing" \
    "$scratch/missing.stderr"
printf 'native-exe smoke: missing export fails closed\n'

set +e
"$repo/bin/beagle" build --materializer c17 --out "$scratch/hosted-refusal" \
    "$repo/native-core/validation/slice-strings/text_ops.bclj" \
    >"$scratch/hosted-refusal.stdout" 2>"$scratch/hosted-refusal.stderr"
hosted_rc=$?
set -e
[[ $hosted_rc -ne 0 ]]
grep -Fq 'Core accepts .bgl only' "$scratch/hosted-refusal.stderr"
printf 'native-exe smoke: hosted .bclj-to-native route is absent\n'
