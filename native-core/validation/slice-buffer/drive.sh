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
  local compiler="$1" output="$2" suffix="$3" function="$4"
  phase "$suffix bounds compile"
  timeout -k 5s 60s "$compiler" -std=c17 -Wall -Wextra -Werror \
    "-DBUFFER_BOUND_FN=$function" -I "$output" \
    "$output/module_0.c" "$output/native_shim.c" \
    "$here/bounds_main.c" -o "$scratch/bounds-$suffix"
  phase "$suffix bounds execute"
  local observed
  observed="$(timeout -k 2s 10s "$scratch/bounds-$suffix")"
  [[ "$observed" == 'bounds-trap: out-of-range' ]]
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

phase "source API check"
timeout -k 5s 60s "$repo/bin/beagle" check --agent "$here/buffer.bgl"
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

# There are two syntactic allocation sites and the runtime counter remains two
# after 6 time steps over 8 cells: allocation is outside both cell/time loops.
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
  "native_m0_fn_${read_index}"
compile_bounds_probe gcc "$scratch/first" gcc-write \
  "native_m0_fn_${write_index}"

clang_bin="$(command -v clang 2>/dev/null || \
  ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null | sort -V | tail -1)"
if [[ -n "$clang_bin" ]]; then
  compile_probe "$clang_bin" "$scratch/first" clang \
    "-DBUFFER_RUN_FN=native_m0_fn_${run_index}" \
    "-DBUFFER_FILL_FN=native_m0_fn_${fill_index}" \
    "-DBUFFER_STENCIL_FN=native_m0_fn_${stencil_index}"
  compile_bounds_probe "$clang_bin" "$scratch/first" clang-read \
    "native_m0_fn_${read_index}"
  compile_bounds_probe "$clang_bin" "$scratch/first" clang-write \
    "native_m0_fn_${write_index}"
fi

expect_native_refusal "$here/wrong_element.bgl" \
  'stage source-to-typed REJECTED' element
expect_native_refusal "$here/value_semantics.bgl" \
  'TODO-NATIVE-BUFFER-VALUE-SEMANTICS-V0' value-semantics
expect_check_refusal "$here/purity_refusal.bgl" \
  'purity leak.*overwrite.*overwrite-buffer!' purity

echo "drive.sh: frozen IR, C17, checked bounds, refusals, and ping-pong allocation proof pass"
