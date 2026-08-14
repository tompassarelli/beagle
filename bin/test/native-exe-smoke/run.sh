#!/usr/bin/env bash
# Compile and execute one complete native module through both supported C17
# frontends. The entry exercises the generated arena/capability ABI and returns
# the two-element module-global vector length as its process status.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source_file="$repo/bin/test/native-exe-smoke/entry_core.bgl"
projection_source="$repo/bin/test/native-exe-smoke/entry_projection.bgl"
qbe_source="$repo/bin/test/native-exe-smoke/entry_qbe.bgl"
fixed_width_source="$repo/bin/test/native-exe-smoke/entry_fixed_width.bgl"
threading_source="$repo/bin/test/native-exe-smoke/entry_threading.bgl"
record_with_source="$repo/bin/test/native-exe-smoke/entry_record_with.bgl"
record_with_unknown_field="$repo/bin/test/native-exe-smoke/entry_record_with_unknown_field.bgl"
record_with_wrong_type="$repo/bin/test/native-exe-smoke/entry_record_with_wrong_type.bgl"
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
    [[ "$(grep -c '^obligation-projection PASS ' "$stage/report.txt")" == "10" ]]

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
    --entry native.entry-projection/alias-entry \
    "$projection_source" >"$scratch/projection-c17.log"

for expected in \
    "source-entry native.entry-projection/entry" \
    "source-entry native.entry-projection/second" \
    "source-entry native.entry-projection/alias-entry" \
    "source-definitions 8" \
    "program-functions 5" \
    "lowered fn_0 box-value 1 blocks" \
    "lowered fn_1 helper 1 blocks" \
    "lowered fn_2 entry 1 blocks" \
    "lowered fn_3 second 3 blocks" \
    "lowered fn_4 alias-entry 1 blocks" \
    "stage typed-to-native COMPLETE" \
    "materialize-c17 OK module_0.h module_0.c" \
    "result PASS"; do
    grep -Fqx "$expected" "$projection_c17/report.txt"
done
[[ "$(grep -c '^obligation-projection PASS ' "$projection_c17/report.txt")" == "10" ]]
[[ -f "$projection_c17/module_0.c" && ! -e "$projection_c17/module_0.ssa" ]]
if grep -Eq 'unreachable|bad-entry|hidden|^pending ' "$projection_c17/report.txt"; then
    echo "native-exe smoke: entry projection retained unreachable definitions" >&2
    exit 1
fi
printf 'native-exe smoke: repeatable entry closure + exact function map ok\n'

qbe_both="$scratch/qbe-both"
"$repo/bin/beagle" build --materializer c17 --materializer qbe \
    --out "$qbe_both" \
    --entry native.qbe-entry/entry \
    "$qbe_source" >"$scratch/qbe-both.log"
grep -Fqx "materialize-c17 OK module_0.h module_0.c" "$qbe_both/report.txt"
grep -Fqx "materialize-qbe OK module_0.ssa" "$qbe_both/report.txt"
grep -Fqx "result PASS" "$qbe_both/report.txt"
[[ "$(grep -c '^obligation-projection PASS ' "$qbe_both/report.txt")" == "10" ]]
[[ "$(grep -c '^stage-progress source-freeze ' "$qbe_both/report.txt")" == "1" ]]
[[ "$(grep -c '^stage-progress source-to-typed ' "$qbe_both/report.txt")" == "1" ]]
[[ "$(grep -c '^stage-progress typed-to-native ' "$qbe_both/report.txt")" == "1" ]]
[[ -f "$qbe_both/module_0.c" && -f "$qbe_both/module_0.ssa" ]]
printf 'native-exe smoke: one frozen native program + explicit C17/QBE materializers ok\n'

fixed_width_c17="$scratch/fixed-width-c17"
fixed_width_executable="$fixed_width_c17/bin/fixed-width"
mkdir -p "$fixed_width_c17/bin"
"$repo/bin/beagle" native-exe \
    --out "$fixed_width_executable" \
    --entry native.fixed-width-entry/layout-entry \
    --cc "$gcc_bin" \
    --artifacts "$fixed_width_c17" \
    "$fixed_width_source" >"$scratch/fixed-width-c17.log"
for backing in int32_t uint32_t int16_t uint8_t; do
    grep -Eq "^typedef $backing native_m0_type_[0-9]+;$" \
        "$fixed_width_c17/module_0.h"
done
grep -Fq '.kind = NATIVE_VALUE_UNSIGNED,' "$fixed_width_c17/module_0.c"
set +e
env -i "$fixed_width_executable"
fixed_width_rc=$?
set -e
[[ $fixed_width_rc -eq 0 ]]

fixed_width_qbe="$scratch/fixed-width-qbe"
"$repo/bin/beagle" build --materializer qbe \
    --out "$fixed_width_qbe" \
    --entry native.fixed-width-entry/qbe-entry \
    "$fixed_width_source" >"$scratch/fixed-width-qbe.log"
grep -Fqx 'materialize-qbe OK module_0.ssa' "$fixed_width_qbe/report.txt"
grep -Fq 'extsw' "$fixed_width_qbe/module_0.ssa"
grep -Fq 'extuw' "$fixed_width_qbe/module_0.ssa"
printf 'native-exe smoke: fixed-width C17 layouts + QBE extensions ok\n'

threading_c17="$scratch/threading-c17"
threading_executable="$threading_c17/bin/threading"
mkdir -p "$threading_c17/bin"
"$repo/bin/beagle" native-exe \
    --out "$threading_executable" \
    --entry native.threading-entry/entry \
    --cc "$gcc_bin" \
    --artifacts "$threading_c17" \
    "$threading_source" >"$scratch/threading-c17.log"
if grep -Fq 'unsupported-threading' "$threading_c17/source.facts"; then
    echo "native-exe smoke: threading marker escaped source projection" >&2
    exit 1
fi
set +e
env -i "$threading_executable"
threading_rc=$?
set -e
[[ $threading_rc -eq 0 ]]
printf 'native-exe smoke: canonical threading desugars before native lowering\n'

record_with_c17="$scratch/record-with-c17"
record_with_executable="$record_with_c17/bin/record-with"
mkdir -p "$record_with_c17/bin"
"$repo/bin/beagle" native-exe \
    --out "$record_with_executable" \
    --entry native.record-with-entry/entry \
    --cc "$gcc_bin" \
    --artifacts "$record_with_c17" \
    "$record_with_source" >"$scratch/record-with-c17.log"
if grep -Fq 'unsupported-with' "$record_with_c17/source.facts"; then
    echo "native-exe smoke: record with escaped source canonicalization" >&2
    exit 1
fi
grep -Fq $'\tcallee\tt\tassoc' "$record_with_c17/source.facts"
grep -Fq 'record-assoc-instruction-v0' "$record_with_c17/module.native-program"
set +e
env -i "$record_with_executable"
record_with_rc=$?
set -e
[[ $record_with_rc -eq 0 ]]

set +e
"$repo/bin/beagle" build --materializer c17 \
    --out "$scratch/record-with-unknown-field" \
    --entry native.record-with-unknown-field/entry \
    "$record_with_unknown_field" \
    >"$scratch/record-with-unknown-field.stdout" \
    2>"$scratch/record-with-unknown-field.stderr"
unknown_field_rc=$?
"$repo/bin/beagle" build --materializer c17 \
    --out "$scratch/record-with-wrong-type" \
    --entry native.record-with-wrong-type/entry \
    "$record_with_wrong_type" \
    >"$scratch/record-with-wrong-type.stdout" \
    2>"$scratch/record-with-wrong-type.stderr"
wrong_type_rc=$?
set -e
[[ $unknown_field_rc -ne 0 && $wrong_type_rc -ne 0 ]]
grep -Fq 'with Fighter: no field :mana' \
    "$scratch/record-with-unknown-field.stderr"
grep -Fq 'with Fighter: field :health expected Int, got String' \
    "$scratch/record-with-wrong-type.stderr"
printf 'native-exe smoke: typed record with canonicalizes to immutable record assoc\n'

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
grep -Fq 'pending TODO-NATIVE-FUNCTION-BODY:' "$scratch/full-module.stderr"
grep -Fq '[unreachable]' "$scratch/reachable-refusal.stderr"
grep -Fqx 'entry-error entry native.entry-projection/hidden must be a public source function' \
    "$scratch/private-entry.stderr"
grep -Fq 'TODO-NATIVE-FORM-unsupported-try' "$scratch/try-reachable.stderr"
for failed in full-module reachable-refusal private-entry try-reachable; do
    [[ ! -e "$scratch/$failed/report.txt" ]]
    [[ ! -e "$scratch/$failed/source.facts" ]]
done
printf 'native-exe smoke: full default + reachable/private refusals fail closed\n'
printf 'native-exe smoke: try lowering refusal stays unpublished\n'

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
