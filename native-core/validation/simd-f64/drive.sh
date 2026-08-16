#!/usr/bin/env bash
# This gate proves deterministic eligibility and scalar semantics. Its C build
# disables compiler vectorization, so machine-vector evidence remains unclaimed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SIMD_REPO:-$(cd "$here/../../.." && pwd)}"

if [[ "${BEAGLE_SIMD_F64_BOUNDED:-0}" != "1" ]]; then
  source "$repo/bin/_beagle-racket"
  supervisor="$repo/native-core/bin/run-bounded.rkt"
  [[ -f "$supervisor" ]] || {
    echo "simd-f64 fixture: shared bounded supervisor is unavailable" >&2
    exit 2
  }
  receipt="$(mktemp "${TMPDIR:-/tmp}/simd-f64-receipt.XXXXXX")"
  trap 'rm -f -- "$receipt"' EXIT
  if BEAGLE_SIMD_F64_BOUNDED=1 \
      BEAGLE_BOUNDED_COMPLETION_RECEIPT="$receipt" \
      "$RACKET" "$supervisor" 180 5 -- "$0"; then
    rc=0
  else
    rc=$?
  fi
  grep -Fqx "subtree-reaped-v0 exit status=$rc" "$receipt" || {
    echo "simd-f64 fixture: supervisor did not reap its subtree" >&2
    exit 125
  }
  exit "$rc"
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-simd-f64.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT
source_file="$here/kernels.bgl"

command -v gcc >/dev/null 2>&1 || {
  echo "simd-f64 fixture: gcc is required" >&2
  exit 2
}

echo "simd-f64 fixture: deterministic C17 builds START"
mkdir -p "$scratch/c17-a" "$scratch/c17-b"
"$repo/bin/beagle" build --materializer c17 --simd \
  --out "$scratch/c17-a" "$source_file" >"$scratch/c17-a.log" 2>&1
"$repo/bin/beagle" build --materializer c17 --simd \
  --out "$scratch/c17-b" "$source_file" >"$scratch/c17-b.log" 2>&1

for artifact in module.native-program module.native-program.sha256 \
                module.simd-plan-v0 module.simd-plan-v0.sha256 \
                module_0.h module_0.c c17.receipt report.txt \
                build.manifest build.manifest.sha256; do
  cmp "$scratch/c17-a/$artifact" "$scratch/c17-b/$artifact"
done
expected_plan_digest="$(<"$scratch/c17-a/module.simd-plan-v0.sha256")"
actual_plan_digest="$(sha256sum "$scratch/c17-a/module.simd-plan-v0" | \
  awk '{print $1}')"
[[ "$actual_plan_digest" == "$expected_plan_digest" ]]

report="$scratch/c17-a/report.txt"
test "$(grep -c '^simd-loop ELIGIBLE ' "$report")" = 4
test "$(grep -c '^simd-loop REFUSED ' "$report")" = 2
for function_name in 'copy!' 'add!' 'subtract!' 'multiply!'; do
  grep -Eq "^simd-loop ELIGIBLE function=${function_name} .*reason=eligible-elementwise-f64-v0 .*tail=increasing-scalar$" \
    "$report"
done
grep -Eq '^simd-loop REFUSED function=multiply-add! .*reason=refused-expression-not-single-op .*tail=increasing-scalar$' \
  "$report"
grep -Eq '^simd-loop REFUSED function=reverse-copy! .*reason=refused-loop-carried-dependence .*tail=increasing-scalar$' \
  "$report"
grep -Fqx \
  'materialize-c17 OK module_0.h module_0.c SIMD-ELIGIBLE actual-vectorization=pending-compiler-evidence' \
  "$report"

generated="$scratch/c17-a/module_0.c"
test "$(grep -c 'const int64_t native_simd_start' "$generated")" = 4
test "$(grep -Ec 'native_s_[0-9]+ = native_simd_limit;' "$generated")" = 4
test "$(grep -c 'native_simd_end - native_simd_start >= ' "$generated")" = 4

function_index() {
  local name="$1"
  sed -nE "s/^lowered fn_([0-9]+) ${name} .*/\1/p" "$report"
}

copy_index="$(function_index 'copy!')"
add_index="$(function_index 'add!')"
refused_index="$(function_index 'reverse-copy!')"
[[ "$copy_index" =~ ^[0-9]+$ && "$add_index" =~ ^[0-9]+$ &&
   "$refused_index" =~ ^[0-9]+$ ]]

echo "simd-f64 fixture: scalar-prefix, tail, fallback execute START"
gcc -std=c17 -O0 -fno-tree-vectorize -pedantic -Wall -Wextra -Werror \
  -DNATIVE_SIMD_F64_LANES=4 \
  "-DSIMD_COPY_FN=native_m0_fn_${copy_index}" \
  "-DSIMD_ADD_FN=native_m0_fn_${add_index}" \
  "-DSIMD_REFUSED_FN=native_m0_fn_${refused_index}" \
  -I "$scratch/c17-a" \
  "$scratch/c17-a/module_0.c" "$scratch/c17-a/native_shim.c" \
  "$here/main.c" -o "$scratch/simd-f64"
"$scratch/simd-f64"

echo "simd-f64 fixture: demanded backend refusals START"
mkdir -p "$scratch/qbe" "$scratch/wasm32"
set +e
"$repo/bin/beagle" build --materializer qbe --simd \
  --out "$scratch/qbe" "$source_file" >"$scratch/qbe.log" 2>&1
qbe_status=$?
"$repo/bin/beagle" build --materializer c17 --abi wasm32 --simd \
  --out "$scratch/wasm32" "$source_file" >"$scratch/wasm32.log" 2>&1
wasm32_status=$?
set -e
[[ "$qbe_status" == 1 && "$wasm32_status" == 1 ]]
grep -Fq \
  'materialize-qbe REFUSED refused-backend-no-simd: qbe has no validated SimdPlanV0 materializer' \
  "$scratch/qbe.log"
grep -Fq \
  'materialize-c17 REFUSED refused-backend-no-simd: wasm has no validated SimdPlanV0 materializer' \
  "$scratch/wasm32.log"
grep -Fq 'result FAIL materialization' "$scratch/qbe.log"
grep -Fq 'result FAIL materialization' "$scratch/wasm32.log"
[[ ! -e "$scratch/qbe/module_0.ssa" && ! -e "$scratch/wasm32/module_0.c" ]]

echo "simd-f64 fixture: PASS"
