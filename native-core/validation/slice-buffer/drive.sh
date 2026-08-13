#!/usr/bin/env bash
# Freeze, lower, materialize, and execute the root-owned F64 Buffer slice.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-buffer.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

phase() {
  printf 'drive.sh: %s\n' "$1"
}

build_once() {
  local output="$1"
  phase "C17 build $(basename "$output")"
  mkdir -p "$output"
  timeout -k 5s 60s "$repo/bin/beagle" build --materializer c17 --out "$output" \
    "$here/buffer.bgl" >"$output/build.log" 2>&1 || {
      sed -n '1,240p' "$output/build.log" >&2
      exit 1
    }
  grep -qx 'result PASS' "$output/report.txt"
  grep -qx 'stage typed-to-native COMPLETE' "$output/report.txt"
  grep -qx 'stage native-to-epoch COMPLETE' "$output/report.txt"
  grep -qx 'epoch-regions-minted 0' "$output/report.txt"
  test "$(grep -c '^obligation-projection PASS ' "$output/report.txt")" = 9
  test "$(grep -c '^obligation-projection FAIL ' "$output/report.txt")" = 0
}

token_count() {
  local token="$1" file="$2"
  rg -o "$token" "$file" | wc -l | tr -d ' '
}

function_index() {
  local name="$1" report="$2"
  sed -nE "s/^lowered fn_([0-9]+) ${name} .*/\1/p" "$report"
}

compile_probe() {
  local compiler="$1" output="$2" suffix="$3"; shift 3
  phase "$suffix kernel compile"
  timeout -k 5s 60s "$compiler" -std=c17 -Wall -Wextra -Werror "$@" -I "$output" \
    "$output/module_0.c" "$output/native_shim.c" \
    "$here/main.c" -o "$scratch/probe-$suffix"
  phase "$suffix kernel execute"
  timeout -k 2s 10s "$scratch/probe-$suffix"
}

compile_bounds_probe() {
  local compiler="$1" output="$2" suffix="$3" function="$4" index="$5"
  phase "$suffix bounds compile"
  timeout -k 5s 60s "$compiler" -std=c17 -Wall -Wextra -Werror \
    "-DBUFFER_BOUND_FN=$function" -I "$output" \
    "-DBUFFER_BOUND_INDEX=$index" \
    "$output/module_0.c" "$output/native_shim.c" \
    "$here/bounds_main.c" -o "$scratch/bounds-$suffix"
  phase "$suffix bounds execute"
  local observed
  observed="$(timeout -k 2s 10s "$scratch/bounds-$suffix")"
  [[ "$observed" == 'bounds-trap: out-of-range' ]]
}

compile_negative_length_probe() {
  local compiler="$1" output="$2" suffix="$3" function="$4"
  phase "$suffix negative length compile"
  timeout -k 5s 60s "$compiler" -std=c17 -Wall -Wextra -Werror \
    "-DBUFFER_ALLOCATE_FN=$function" -I "$output" \
    "$output/module_0.c" "$output/native_shim.c" \
    "$here/negative_length_main.c" -o "$scratch/negative-length-$suffix"
  phase "$suffix negative length execute"
  local observed
  observed="$(timeout -k 2s 10s "$scratch/negative-length-$suffix")"
  [[ "$observed" == 'length-trap: invalid-argument' ]]
}

compile_wrong_capability_probe() {
  local compiler="$1" output="$2" suffix="$3" operation="$4"
  phase "$suffix wrong capability compile"
  timeout -k 5s 60s "$compiler" -std=c17 -Wall -Wextra -Werror \
    "-DBUFFER_CAPABILITY_OP=$operation" -I "$output" \
    "$output/native_shim.c" "$here/wrong_capability_main.c" \
    -o "$scratch/wrong-capability-$suffix"
  phase "$suffix wrong capability execute"
  local observed
  observed="$(timeout -k 2s 10s "$scratch/wrong-capability-$suffix")"
  [[ "$observed" == 'capability-trap: invalid-argument' ]]
}

compile_wrong_alignment_probe() {
  local compiler="$1" output="$2" suffix="$3" operation="$4"
  phase "$suffix wrong alignment compile"
  timeout -k 5s 60s "$compiler" -std=c17 -Wall -Wextra -Werror \
    "-DBUFFER_ALIGNMENT_OP=$operation" -I "$output" \
    "$output/native_shim.c" "$here/wrong_alignment_main.c" \
    -o "$scratch/wrong-alignment-$suffix"
  phase "$suffix wrong alignment execute"
  local observed
  observed="$(timeout -k 2s 10s "$scratch/wrong-alignment-$suffix")"
  [[ "$observed" == 'alignment-trap: invalid-argument' ]]
}

compile_wasm32_overflow_probe() {
  local compiler="$1" output="$2" suffix="$3"
  phase "$suffix wasm32-sized overflow compile"
  timeout -k 5s 60s "$compiler" -std=c17 -Wall -Wextra -Werror \
    -DNATIVE_DENSE_SIZE_MAX=UINT32_MAX -I "$output" \
    "$output/native_shim.c" "$here/wasm32_overflow_main.c" \
    -o "$scratch/wasm32-overflow-$suffix"
  phase "$suffix wasm32-sized overflow execute"
  local observed
  observed="$(timeout -k 2s 10s "$scratch/wasm32-overflow-$suffix")"
  [[ "$observed" == 'wasm32-size-trap: overflow' ]]
}

run_frozen_ir_corpus() {
  local output="$scratch/frozen-ir-corpus"
  phase "frozen IR Buffer typing/provenance corpus"
  mkdir -p "$output"
  timeout -k 5s 90s "$repo/bin/beagle-build-all" \
    "$repo/native-core/src/native/core.bclj" \
    "$repo/native-core/src/native/validation_corpus.bclj" \
    "$repo/native-core/src/native/obligations.bclj" \
    --out "$output" >"$output/build.log" 2>&1 || {
      sed -n '1,240p' "$output/build.log" >&2
      exit 1
    }
  local records
  records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
    "$output/native/core.clj" | tr '\n' ' ')"
  local generated
  for generated in validation_corpus obligations; do
    sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
      "$output/native/$generated.clj"
    awk -v import="(import '[native.core $records])" \
      '!seen && /^$/ { print import; seen = 1 } { print }' \
      "$output/native/$generated.clj" \
      >"$output/native/$generated.clj.tmp"
    mv "$output/native/$generated.clj.tmp" \
      "$output/native/$generated.clj"
  done
  timeout -k 5s 30s bb -cp "$output" -e \
    "(require '[native.core :as core]
              '[native.obligations :as obligations]
              '[native.validation-corpus :as corpus])
     (let [invalid-programs
           [[\"non-buffer-source\" corpus/buffer-non-buffer-source-program]
            [\"length-non-buffer-source\" corpus/buffer-length-non-buffer-source-program]
            [\"set-non-buffer-source\" corpus/buffer-set-non-buffer-source-program]
            [\"non-int-length\" corpus/buffer-non-int-length-program]
            [\"non-int-index\" corpus/buffer-non-int-index-program]
            [\"set-non-int-index\" corpus/buffer-set-non-int-index-program]
            [\"wrong-allocate-result\" corpus/buffer-wrong-allocate-result-program]
            [\"wrong-length-result\" corpus/buffer-wrong-length-result-program]
            [\"wrong-get-result\" corpus/buffer-wrong-get-result-program]
            [\"wrong-set-result\" corpus/buffer-wrong-set-result-program]
            [\"wrong-set-value\" corpus/buffer-wrong-set-value-program]
            [\"mismatched-element\" corpus/buffer-mismatched-element-program]
            [\"forged-external-root\" corpus/buffer-forged-external-root-program]
            [\"mismatched-arena-producer\" corpus/buffer-mismatched-arena-producer-program]
            [\"wrong-arena-handle\" corpus/buffer-wrong-arena-handle-program]
            [\"wrong-allocate-capability\" corpus/buffer-wrong-allocate-capability-program]
            [\"wrong-read-capability\" corpus/buffer-wrong-read-capability-program]
            [\"wrong-write-capability\" corpus/buffer-wrong-write-capability-program]
            [\"incoherent-root\" corpus/buffer-incoherent-root-program]]
           invalid? (fn [program]
                      (and (not (core/validationreport-passed
                                  (core/validate-program program)))
                           (= \"valid-ssa\"
                              (obligations/verdict-tag
                                (obligations/valid-ssa program)))))]
       (doseq [[name program] invalid-programs]
         (when-not (invalid? program)
           (throw (ex-info (str \"Buffer frozen IR invalid fixture failed: \" name)
                           {}))))
       (when-not (and (core/validationreport-passed
                        (core/validate-program corpus/buffer-program))
                      (obligations/obligation-passed?
                        (obligations/valid-ssa corpus/buffer-program)))
         (throw (ex-info \"Buffer frozen IR corpus failed\" {}))))"
}

compile_holder_probe() {
  local compiler="$1" output="$2" suffix="$3" function="$4"
  phase "$suffix Holder compile"
  timeout -k 5s 60s "$compiler" -std=c17 -Wall -Wextra -Werror \
    "-DBUFFER_HOLDER_FN=$function" -I "$output" \
    "$output/module_0.c" "$output/native_shim.c" \
    "$here/holder_main.c" -o "$scratch/holder-$suffix"
  phase "$suffix Holder execute"
  timeout -k 2s 10s "$scratch/holder-$suffix"
}

expect_native_refusal() {
  local source="$1" pattern="$2" label="$3"
  local output="$scratch/refusal-$label"
  phase "$label refusal build"
  mkdir -p "$output"
  if timeout -k 5s 60s "$repo/bin/beagle" build --materializer c17 \
      --out "$output" "$source" \
      >"$output/build.log" 2>&1; then
    echo "drive.sh: $label unexpectedly materialized" >&2
    exit 1
  fi
  rg -q "$pattern" "$output/report.txt" "$output/build.log"
}

expect_source_refusal() {
  local source="$1" pattern="$2" label="$3"
  local output="$scratch/source-refusal-$label"
  phase "$label source refusal"
  mkdir -p "$output"
  if timeout -k 5s 60s "$repo/bin/beagle" check --agent "$source" \
      >"$output/check.log" 2>&1; then
    echo "drive.sh: $label unexpectedly passed source checking" >&2
    exit 1
  fi
  grep -Fq "$pattern" "$output/check.log"
}

expect_check_refusal() {
  local source="$1" pattern="$2" label="$3"
  local output="$scratch/refusal-$label"
  phase "$label refusal check"
  mkdir -p "$output"
  if timeout -k 5s 60s "$repo/bin/beagle" check --agent "$source" \
      >"$output/check.log" 2>&1; then
    echo "drive.sh: $label unexpectedly passed source checking" >&2
    exit 1
  fi
  rg -q "$pattern" "$output/check.log"
}

expect_buffer_value_refusal() {
  local source="$1" label="$2"; shift 2
  local output="$scratch/refusal-$label"
  phase "$label recursive value-semantics refusal build"
  mkdir -p "$output"
  if timeout -k 5s 60s "$repo/bin/beagle" build --materializer c17 \
      --out "$output" "$source" >"$output/build.log" 2>&1; then
    echo "drive.sh: $label value semantics unexpectedly materialized" >&2
    exit 1
  fi
  test "$(grep -c 'TODO-NATIVE-BUFFER-VALUE-SEMANTICS-V0' \
    "$output/report.txt")" = 3
  local function
  for function in "$@"; do
    grep -Fq "[$function]" "$output/report.txt"
  done
}

expect_qbe_refusal() {
  local output="$scratch/refusal-qbe"
  phase "QBE Buffer refusal build"
  mkdir -p "$output"
  if timeout -k 5s 60s "$repo/bin/beagle" build --materializer qbe \
      --out "$output" "$here/buffer.bgl" >"$output/build.log" 2>&1; then
    echo "drive.sh: QBE unexpectedly materialized Buffer" >&2
    exit 1
  fi
  grep -Fqx \
    'materialize-qbe REFUSED QBE Buffer v0 is unsupported: mutable region-owned storage has no QBE runtime representation' \
    "$output/report.txt"
  test ! -e "$output/module_0.ssa"
}

phase "source API check"
timeout -k 5s 60s "$repo/bin/beagle" check --agent \
  "$here/buffer.bgl" "$here/holder.bgl" "$here/native_exe.bgl"
run_frozen_ir_corpus
build_once "$scratch/first"
build_once "$scratch/second"
cmp "$scratch/first/module.native-program" \
  "$scratch/second/module.native-program"
cmp "$scratch/first/module.native-program.sha256" \
  "$scratch/second/module.native-program.sha256"

program="$scratch/first/module.native-program"
test "$(token_count buffer-v0 "$program")" = 1
test "$(token_count buffer-layout-v0 "$program")" = 1
test "$(token_count buffer-allocate-instruction-v0 "$program")" = 2
test "$(token_count buffer-length-instruction-v0 "$program")" -ge 1
test "$(token_count buffer-get-checked-instruction-v0 "$program")" -ge 1
test "$(token_count buffer-set-checked-instruction-v0 "$program")" -ge 1
rg -q 'slice-arena' "$program"
rg -q 'arena-read' "$program"
rg -q 'arena-write' "$program"
rg -q 'arena-allocate' "$program"

# There are two syntactic Buffer constructions. Each nonempty construction
# performs two raw arena allocations (header + element span), for four total;
# no allocation occurs inside either cell/time loop.
test "$(token_count native_buffer_new "$scratch/first/module_0.c")" = 2
rg -q 'mutable region-owned buffer.*stride 8, alignment 8' \
  "$scratch/first/module_0.h"

run_index="$(function_index 'run-stencil!' "$scratch/first/report.txt")"
fill_index="$(function_index 'fill!' "$scratch/first/report.txt")"
stencil_index="$(function_index 'stencil!' "$scratch/first/report.txt")"
read_index="$(function_index 'read-at' "$scratch/first/report.txt")"
write_index="$(function_index 'write-at!' "$scratch/first/report.txt")"
test -n "$run_index"
test -n "$fill_index"
test -n "$stencil_index"
test -n "$read_index"
test -n "$write_index"

gcc_flags=("-DBUFFER_RUN_FN=native_m0_fn_${run_index}"
  "-DBUFFER_FILL_FN=native_m0_fn_${fill_index}"
  "-DBUFFER_STENCIL_FN=native_m0_fn_${stencil_index}" -pedantic)
compile_probe gcc "$scratch/first" gcc "${gcc_flags[@]}"
compile_bounds_probe gcc "$scratch/first" gcc-read \
  "native_m0_fn_${read_index}" 'INT64_C(1)'
compile_bounds_probe gcc "$scratch/first" gcc-write \
  "native_m0_fn_${write_index}" 'INT64_C(1)'
compile_bounds_probe gcc "$scratch/first" gcc-negative-read \
  "native_m0_fn_${read_index}" '(-INT64_C(1))'
compile_bounds_probe gcc "$scratch/first" gcc-negative-write \
  "native_m0_fn_${write_index}" '(-INT64_C(1))'
for operation in 0 1 2; do
  compile_wrong_capability_probe gcc "$scratch/first" \
    "gcc-operation-$operation" "$operation"
done
for operation in 0 1 2 3; do
  compile_wrong_alignment_probe gcc "$scratch/first" \
    "gcc-operation-$operation" "$operation"
done
compile_wasm32_overflow_probe gcc "$scratch/first" gcc

clang_bin="$(command -v clang 2>/dev/null || \
  ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null | sort -V | tail -1)"
if [[ -n "$clang_bin" ]]; then
  compile_probe "$clang_bin" "$scratch/first" clang \
    "-DBUFFER_RUN_FN=native_m0_fn_${run_index}" \
    "-DBUFFER_FILL_FN=native_m0_fn_${fill_index}" \
    "-DBUFFER_STENCIL_FN=native_m0_fn_${stencil_index}"
  compile_bounds_probe "$clang_bin" "$scratch/first" clang-read \
    "native_m0_fn_${read_index}" 'INT64_C(1)'
  compile_bounds_probe "$clang_bin" "$scratch/first" clang-write \
    "native_m0_fn_${write_index}" 'INT64_C(1)'
  compile_bounds_probe "$clang_bin" "$scratch/first" clang-negative-read \
    "native_m0_fn_${read_index}" '(-INT64_C(1))'
  compile_bounds_probe "$clang_bin" "$scratch/first" clang-negative-write \
    "native_m0_fn_${write_index}" '(-INT64_C(1))'
  for operation in 0 1 2; do
    compile_wrong_capability_probe "$clang_bin" "$scratch/first" \
      "clang-operation-$operation" "$operation"
  done
  for operation in 0 1 2 3; do
    compile_wrong_alignment_probe "$clang_bin" "$scratch/first" \
      "clang-operation-$operation" "$operation"
  done
  compile_wasm32_overflow_probe "$clang_bin" "$scratch/first" clang
fi

negative_length_output="$scratch/negative-length"
phase "negative length C17 build"
mkdir -p "$negative_length_output"
timeout -k 5s 60s "$repo/bin/beagle" build --materializer c17 \
  --out "$negative_length_output" "$here/negative_length.bgl" \
  >"$negative_length_output/build.log" 2>&1 || {
    sed -n '1,240p' "$negative_length_output/build.log" >&2
    exit 1
  }
negative_length_index="$(function_index 'allocate-length' \
  "$negative_length_output/report.txt")"
test -n "$negative_length_index"
compile_negative_length_probe gcc "$negative_length_output" gcc \
  "native_m0_fn_${negative_length_index}"
if [[ -n "$clang_bin" ]]; then
  compile_negative_length_probe "$clang_bin" "$negative_length_output" clang \
    "native_m0_fn_${negative_length_index}"
fi

holder_output="$scratch/holder"
phase "Holder C17 build"
mkdir -p "$holder_output"
timeout -k 5s 60s "$repo/bin/beagle" build --materializer c17 \
  --out "$holder_output" "$here/holder.bgl" \
  >"$holder_output/build.log" 2>&1 || {
    sed -n '1,240p' "$holder_output/build.log" >&2
    exit 1
  }
grep -qx 'result PASS' "$holder_output/report.txt"
grep -qx 'obligation-projection PASS closed-layouts' \
  "$holder_output/report.txt"
holder_index="$(function_index 'make-holder-buffer!' \
  "$holder_output/report.txt")"
test -n "$holder_index"
compile_holder_probe gcc "$holder_output" gcc-holder \
  "native_m0_fn_${holder_index}"
if [[ -n "$clang_bin" ]]; then
  compile_holder_probe "$clang_bin" "$holder_output" clang-holder \
    "native_m0_fn_${holder_index}"
fi

native_exe_output="$scratch/native-exe"
native_exe="$native_exe_output/buffer-entry"
phase "native-exe Buffer build"
mkdir -p "$native_exe_output"
timeout -k 5s 90s "$repo/bin/beagle-native-exe" \
  --out "$native_exe" \
  --artifacts "$native_exe_output/artifacts" \
  --entry 'native.buffer-executable/buffer-entry!' \
  --cc gcc "$here/native_exe.bgl" \
  >"$native_exe_output/build.log" 2>&1 || {
    sed -n '1,240p' "$native_exe_output/build.log" >&2
    exit 1
  }
grep -Fqx '  const native_capability capability = { UINT64_C(1) };' \
  "$native_exe_output/artifacts/entry.c"
grep -Fq \
  'return=Int abi=arena+capability' \
  "$native_exe_output/artifacts/native-exe.report.txt"
phase "native-exe Buffer execute"
timeout -k 2s 10s "$native_exe"

expect_native_refusal "$here/wrong_element.bgl" \
  'stage source-to-typed REJECTED' element
grep -Fq 'LOWER-BUFFER-ELEMENT-V0' \
  "$scratch/refusal-element/report.txt"
expect_source_refusal "$here/arity_double_array.bgl" \
  'call to double-array: expected 1 arg(s), got 0' arity-double-array
expect_source_refusal "$here/arity_alength.bgl" \
  'call to alength: expected 1 arg(s), got 2' arity-alength
expect_source_refusal "$here/arity_aget.bgl" \
  'call to aget: expected 2 arg(s), got 1' arity-aget
expect_source_refusal "$here/arity_aset_double.bgl" \
  'call to aset-double!: expected 3 arg(s), got 2' arity-aset-double
expect_source_refusal "$here/invariance.bgl" \
  'arg 1 expected (Buffer Any), got (Buffer Float)' invariance
expect_native_refusal "$here/value_semantics.bgl" \
  'TODO-NATIVE-BUFFER-VALUE-SEMANTICS-V0' value-semantics
expect_buffer_value_refusal "$here/record_value_semantics.bgl" record \
  'holder-equal?' holder-hash holder-compare
expect_buffer_value_refusal "$here/vector_value_semantics.bgl" vector \
  'buffers-equal?' buffers-hash buffers-compare
expect_buffer_value_refusal "$here/union_value_semantics.bgl" union \
  'buffer-or-int-equal?' buffer-or-int-hash buffer-or-int-compare
expect_qbe_refusal
expect_check_refusal "$here/purity_refusal.bgl" \
  'purity leak.*overwrite.*overwrite-buffer!' purity

echo "drive.sh: frozen IR typing/provenance, C17 Holder, checked bounds/capability/size, recursive refusals, QBE refusal, and ping-pong allocation proof pass"
