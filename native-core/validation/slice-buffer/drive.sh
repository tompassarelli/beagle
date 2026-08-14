#!/usr/bin/env bash
# Freeze, lower, materialize, and execute the root-owned F64 Buffer slice.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-buffer.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT
source "$repo/bin/_beagle-racket"
supervisor="$repo/native-core/bin/run-bounded.rkt"
[[ -f "$supervisor" ]] || {
  echo "drive.sh: bounded subtree supervisor is unavailable: $supervisor" >&2
  exit 2
}
command -v unshare >/dev/null 2>&1 || {
  echo "drive.sh: util-linux unshare is unavailable" >&2
  exit 2
}

phase() {
  printf 'drive.sh: %s\n' "$1"
}

bounded_outcome='uninitialized'
bounded_status=125

# The shared supervisor runs as PID 1 in a private namespace, owns the deadline,
# and does not return until every descendant is gone. Its completion receipt is
# checked per invocation so a stale success cannot masquerade as this outcome.
run_bounded() {
  local label="$1" seconds="$2" kill_grace="$3"
  shift 3
  local receipt receipt_line rc
  bounded_outcome='harness'
  bounded_status=125
  receipt="$(mktemp "$scratch/bounded-receipt.XXXXXX")"
  printf 'drive.sh: %s bounded START deadline=%ss kill-grace=%ss\n' \
    "$label" "$seconds" "$kill_grace" >&2
  if BEAGLE_BOUNDED_COMPLETION_RECEIPT="$receipt" \
      unshare --user --map-current-user --pid --fork --kill-child \
        --forward-signals "$RACKET" "$supervisor" \
        "$seconds" "$kill_grace" -- "$@"; then
    rc=0
  else
    rc=$?
  fi
  bounded_status=$rc
  if [[ -f "$receipt" ]]; then
    receipt_line="$(<"$receipt")"
  else
    receipt_line=''
  fi
  case "$receipt_line" in
    "subtree-reaped-v0 exit status=$rc")
      bounded_outcome='exit'
      ;;
    'subtree-reaped-v0 timeout status=124')
      if [[ "$rc" == "124" ]]; then
        bounded_outcome='timeout'
      else
        bounded_status=125
      fi
      ;;
  esac
  if [[ "$bounded_outcome" == 'harness' ]]; then
    printf 'drive.sh: %s HARNESS-FAIL missing completion receipt status=%s\n' \
      "$label" "$rc" >&2
    if [[ "$rc" == "0" ]]; then
      bounded_status=125
    fi
    return "$bounded_status"
  fi
  if [[ "$bounded_outcome" == 'timeout' ]]; then
    printf 'drive.sh: %s TIMEOUT status=124\n' "$label" >&2
  else
    printf 'drive.sh: %s bounded END status=%s\n' "$label" "$rc" >&2
  fi
  return "$rc"
}

run_bounded_logged() {
  local label="$1" seconds="$2" kill_grace="$3" log="$4"
  shift 4
  local rc
  if run_bounded "$label" "$seconds" "$kill_grace" "$@" \
      >"$log" 2>&1; then
    return 0
  else
    rc=$?
  fi
  sed -n '1,240p' "$log" >&2
  return "$rc"
}

expect_bounded_rejection() {
  local label="$1" seconds="$2" kill_grace="$3"
  shift 3
  local rc
  if run_bounded "$label" "$seconds" "$kill_grace" "$@"; then
    return 1
  else
    rc=$?
  fi
  if [[ "$bounded_outcome" == 'exit' ]]; then
    printf 'drive.sh: %s EXPECTED-REJECTION status=%s\n' "$label" "$rc" >&2
    return 0
  fi
  return "$rc"
}

expect_bounded_rejection_logged() {
  local label="$1" seconds="$2" kill_grace="$3" log="$4"
  shift 4
  local rc
  if expect_bounded_rejection "$label" "$seconds" "$kill_grace" "$@" \
      >"$log" 2>&1; then
    return 0
  else
    rc=$?
  fi
  sed -n '1,240p' "$log" >&2
  printf 'drive.sh: %s REJECTION-FAIL status=%s\n' "$label" "$rc" >&2
  return "$rc"
}

run_bounded_protocol_self_test() {
  local rc
  phase "bounded supervisor receipt protocol"
  expect_bounded_rejection "receipt child exit 2" 5 1 /bin/sh -c 'exit 2'
  [[ "$bounded_outcome" == 'exit' && "$bounded_status" == '2' ]]
  expect_bounded_rejection "receipt child exit 124" 5 1 /bin/sh -c 'exit 124'
  [[ "$bounded_outcome" == 'exit' && "$bounded_status" == '124' ]]
  if expect_bounded_rejection "receipt deadline" 1 1 /bin/sh -c \
      'trap "" TERM; sleep 30 & wait "$!"'; then
    return 91
  else
    rc=$?
  fi
  [[ "$rc" == '124' && "$bounded_outcome" == 'timeout' &&
      "$bounded_status" == '124' ]]
  if expect_bounded_rejection "receipt setup failure" 5 1 \
      "$scratch/command-that-does-not-exist"; then
    return 92
  else
    rc=$?
  fi
  [[ "$rc" == '2' && "$bounded_outcome" == 'harness' &&
      "$bounded_status" == '2' ]]
}

if [[ "${1:-}" == '--bounded-self-test' ]]; then
  run_bounded_protocol_self_test
  echo "drive.sh: bounded supervisor receipt protocol pass"
  exit 0
elif [[ $# -ne 0 ]]; then
  echo "drive.sh: unknown argument: $1" >&2
  exit 2
fi

build_once() {
  local output="$1"
  phase "C17 build $(basename "$output")"
  mkdir -p "$output"
  run_bounded_logged "C17 build $(basename "$output")" 60 5 \
    "$output/build.log" \
    "$repo/bin/beagle" build --materializer c17 --out "$output" \
    "$here/buffer.bgl"
  grep -qx 'result PASS' "$output/report.txt"
  grep -qx 'stage typed-to-native COMPLETE' "$output/report.txt"
  grep -qx 'stage native-to-epoch COMPLETE' "$output/report.txt"
  grep -qx 'epoch-regions-minted 0' "$output/report.txt"
  test "$(grep -c '^obligation-projection PASS ' "$output/report.txt")" = 10
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
  run_bounded "$suffix kernel compile" 60 5 \
    "$compiler" -std=c17 -Wall -Wextra -Werror "$@" -I "$output" \
    "$output/module_0.c" "$output/native_shim.c" \
    "$here/main.c" -o "$scratch/probe-$suffix"
  phase "$suffix kernel execute"
  run_bounded "$suffix kernel execute" 10 2 "$scratch/probe-$suffix"
}

compile_bounds_probe() {
  local compiler="$1" output="$2" suffix="$3" function="$4" index="$5"
  phase "$suffix bounds compile"
  run_bounded "$suffix bounds compile" 60 5 \
    "$compiler" -std=c17 -Wall -Wextra -Werror \
    "-DBUFFER_BOUND_FN=$function" -I "$output" \
    "-DBUFFER_BOUND_INDEX=$index" \
    "$output/module_0.c" "$output/native_shim.c" \
    "$here/bounds_main.c" -o "$scratch/bounds-$suffix"
  phase "$suffix bounds execute"
  local observed
  observed="$(run_bounded "$suffix bounds execute" 10 2 \
    "$scratch/bounds-$suffix")"
  [[ "$observed" == 'bounds-trap: out-of-range' ]]
}

compile_negative_length_probe() {
  local compiler="$1" output="$2" suffix="$3" function="$4"
  phase "$suffix negative length compile"
  run_bounded "$suffix negative length compile" 60 5 \
    "$compiler" -std=c17 -Wall -Wextra -Werror \
    "-DBUFFER_ALLOCATE_FN=$function" -I "$output" \
    "$output/module_0.c" "$output/native_shim.c" \
    "$here/negative_length_main.c" -o "$scratch/negative-length-$suffix"
  phase "$suffix negative length execute"
  local observed
  observed="$(run_bounded "$suffix negative length execute" 10 2 \
    "$scratch/negative-length-$suffix")"
  [[ "$observed" == 'length-trap: invalid-argument' ]]
}

compile_wrong_capability_probe() {
  local compiler="$1" output="$2" suffix="$3" operation="$4"
  phase "$suffix wrong capability compile"
  run_bounded "$suffix wrong capability compile" 60 5 \
    "$compiler" -std=c17 -Wall -Wextra -Werror \
    "-DBUFFER_CAPABILITY_OP=$operation" -I "$output" \
    "$output/native_shim.c" "$here/wrong_capability_main.c" \
    -o "$scratch/wrong-capability-$suffix"
  phase "$suffix wrong capability execute"
  local observed
  observed="$(run_bounded "$suffix wrong capability execute" 10 2 \
    "$scratch/wrong-capability-$suffix")"
  [[ "$observed" == 'capability-trap: invalid-argument' ]]
}

compile_wrong_alignment_probe() {
  local compiler="$1" output="$2" suffix="$3" operation="$4"
  phase "$suffix wrong alignment compile"
  run_bounded "$suffix wrong alignment compile" 60 5 \
    "$compiler" -std=c17 -Wall -Wextra -Werror \
    "-DBUFFER_ALIGNMENT_OP=$operation" -I "$output" \
    "$output/native_shim.c" "$here/wrong_alignment_main.c" \
    -o "$scratch/wrong-alignment-$suffix"
  phase "$suffix wrong alignment execute"
  local observed
  observed="$(run_bounded "$suffix wrong alignment execute" 10 2 \
    "$scratch/wrong-alignment-$suffix")"
  [[ "$observed" == 'alignment-trap: invalid-argument' ]]
}

compile_ownership_probe() {
  local compiler="$1" output="$2" suffix="$3" operation="$4"
  phase "$suffix ownership operation $operation compile"
  run_bounded "$suffix ownership operation $operation compile" 60 5 \
    "$compiler" -std=c17 -Wall -Wextra -Werror \
    "-DBUFFER_OWNERSHIP_OP=$operation" -I "$output" \
    "$output/native_shim.c" "$here/ownership_main.c" \
    -o "$scratch/ownership-$suffix"
  phase "$suffix ownership operation $operation execute"
  local observed
  observed="$(run_bounded "$suffix ownership operation $operation execute" \
    10 2 "$scratch/ownership-$suffix")"
  [[ "$observed" == 'ownership-trap: invalid-argument' ]]
}

compile_wasm32_overflow_probe() {
  local compiler="$1" output="$2" suffix="$3"
  phase "$suffix wasm32-sized overflow compile"
  run_bounded "$suffix wasm32-sized overflow compile" 60 5 \
    "$compiler" -std=c17 -Wall -Wextra -Werror \
    -DNATIVE_DENSE_SIZE_MAX=UINT32_MAX -I "$output" \
    "$output/native_shim.c" "$here/wasm32_overflow_main.c" \
    -o "$scratch/wasm32-overflow-$suffix"
  phase "$suffix wasm32-sized overflow execute"
  local observed
  observed="$(run_bounded "$suffix wasm32-sized overflow execute" 10 2 \
    "$scratch/wasm32-overflow-$suffix")"
  [[ "$observed" == 'wasm32-size-trap: overflow' ]]
}

run_frozen_ir_corpus() {
  local output="$scratch/frozen-ir-corpus"
  phase "frozen IR Buffer typing/provenance corpus"
  mkdir -p "$output"
  run_bounded_logged "frozen IR corpus build" 90 5 "$output/build.log" \
    "$repo/bin/beagle-build-all" \
    "$repo/native-core/src/native/core.bclj" \
    "$repo/native-core/src/native/validation_corpus.bclj" \
    "$repo/native-core/src/native/obligations.bclj" \
    --out "$output"
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
  phase "frozen IR Buffer corpus execute"
  run_bounded "frozen IR corpus execute" 30 5 bb -cp "$output" -e \
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
  run_bounded "$suffix Holder compile" 60 5 \
    "$compiler" -std=c17 -Wall -Wextra -Werror \
    "-DBUFFER_HOLDER_FN=$function" -I "$output" \
    "$output/module_0.c" "$output/native_shim.c" \
    "$here/holder_main.c" -o "$scratch/holder-$suffix"
  phase "$suffix Holder execute"
  run_bounded "$suffix Holder execute" 10 2 "$scratch/holder-$suffix"
}

expect_native_refusal() {
  local source="$1" pattern="$2" label="$3"
  local output="$scratch/refusal-$label"
  phase "$label refusal build"
  mkdir -p "$output"
  expect_bounded_rejection_logged "$label refusal build" 60 5 \
    "$output/build.log" "$repo/bin/beagle" build --materializer c17 \
    --out "$output" "$source"
  rg -q "$pattern" "$output/build.log"
  test ! -e "$output/report.txt"
}

expect_source_refusal() {
  local source="$1" pattern="$2" label="$3"
  local output="$scratch/source-refusal-$label"
  phase "$label source refusal"
  mkdir -p "$output"
  expect_bounded_rejection_logged "$label source refusal" 60 5 \
    "$output/check.log" "$repo/bin/beagle" check --agent "$source"
  grep -Fq "$pattern" "$output/check.log"
}

expect_check_refusal() {
  local source="$1" pattern="$2" label="$3"
  local output="$scratch/refusal-$label"
  phase "$label refusal check"
  mkdir -p "$output"
  expect_bounded_rejection_logged "$label refusal check" 60 5 \
    "$output/check.log" "$repo/bin/beagle" check --agent "$source"
  rg -q "$pattern" "$output/check.log"
}

expect_buffer_value_refusal() {
  local source="$1" label="$2"; shift 2
  local output="$scratch/refusal-$label"
  phase "$label recursive value-semantics refusal build"
  mkdir -p "$output"
  expect_bounded_rejection_logged "$label value-semantics refusal build" 60 5 \
    "$output/build.log" "$repo/bin/beagle" build --materializer c17 \
    --out "$output" "$source"
  test "$(grep -c 'TODO-NATIVE-BUFFER-VALUE-SEMANTICS-V0' \
    "$output/build.log")" = 3
  local function
  for function in "$@"; do
    grep -Fq "[$function]" "$output/build.log"
  done
  test ! -e "$output/report.txt"
}

expect_qbe_refusal() {
  local output="$scratch/refusal-qbe"
  phase "QBE Buffer refusal build"
  mkdir -p "$output"
  expect_bounded_rejection_logged "QBE Buffer refusal build" 60 5 \
    "$output/build.log" "$repo/bin/beagle" build --materializer qbe \
    --out "$output" "$here/buffer.bgl"
  grep -Fqx \
    'materialize-qbe REFUSED QBE Buffer v0 is unsupported: mutable region-owned storage has no QBE runtime representation' \
    "$output/build.log"
  test ! -e "$output/report.txt"
  test ! -e "$output/module_0.ssa"
}

run_bounded_protocol_self_test
phase "source API check"
run_bounded "source API check" 60 5 "$repo/bin/beagle" check --agent \
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
# performs one raw arena allocation for its element span; durable checked
# handles live outside resettable arena storage. Neither loop allocates.
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
for operation in {0..9}; do
  compile_ownership_probe gcc "$scratch/first" \
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
  for operation in {0..9}; do
    compile_ownership_probe "$clang_bin" "$scratch/first" \
      "clang-operation-$operation" "$operation"
  done
  compile_wasm32_overflow_probe "$clang_bin" "$scratch/first" clang
fi

negative_length_output="$scratch/negative-length"
phase "negative length C17 build"
mkdir -p "$negative_length_output"
run_bounded_logged "negative length C17 build" 60 5 \
  "$negative_length_output/build.log" "$repo/bin/beagle" build \
  --materializer c17 --out "$negative_length_output" \
  "$here/negative_length.bgl"
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
run_bounded_logged "Holder C17 build" 60 5 "$holder_output/build.log" \
  "$repo/bin/beagle" build --materializer c17 --out "$holder_output" \
  "$here/holder.bgl"
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
run_bounded_logged "native-exe Buffer build" 90 5 \
  "$native_exe_output/build.log" "$repo/bin/beagle-native-exe" \
  --out "$native_exe" \
  --artifacts "$native_exe_output/artifacts" \
  --entry 'native.buffer-executable/buffer-entry!' \
  --cc gcc "$here/native_exe.bgl"
grep -Fqx '  const native_capability capability = { UINT64_C(1) };' \
  "$native_exe_output/artifacts/entry.c"
grep -Fq \
  'return=Int abi=arena+capability' \
  "$native_exe_output/artifacts/native-exe.report.txt"
phase "native-exe Buffer execute"
run_bounded "native-exe Buffer execute" 10 2 "$native_exe"

expect_native_refusal "$here/wrong_element.bgl" \
  'stage source-to-typed REJECTED' element
grep -Fq 'LOWER-BUFFER-ELEMENT-V0' \
  "$scratch/refusal-element/build.log"
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

echo "drive.sh: frozen IR typing/provenance, C17 Holder, checked bounds/capability/arena-generation/size, recursive refusals, QBE refusal, and ping-pong allocation proof pass"
