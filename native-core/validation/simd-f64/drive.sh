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
  # A deadline catches a HANG; it is not a speed limit. Honest cold cost is
  # 175.4s / 186.3s / 189.6s (loads 11.5-23.3) and 162.3s in the cd07b761
  # measurement table, 70s once the core build cache and bytecode are warm
  # (load 7.7-9.1, 24 cores). The old 180s bound sat INSIDE that band, so it
  # breached on a quiet box too — load was never the cause. 600s is ~3.2x the
  # slowest honest run and still lands inside the 900s tier-runner phase
  # deadline, so this supervisor keeps owning the subtree reap.
  if BEAGLE_SIMD_F64_BOUNDED=1 \
      BEAGLE_BOUNDED_COMPLETION_RECEIPT="$receipt" \
      "$RACKET" "$supervisor" 600 5 -- "$0"; then
    rc=0
  else
    rc=$?
  fi
  # The supervisor writes ONE of two receipts, and they mean different things:
  # `timeout status=124` is a deadline breach (the machine), `exit status=N` is
  # the fixture's own verdict (the code). Accepting only the second turned every
  # breach into exit 125 "supervisor did not reap its subtree" — a harness
  # contract failure — and destroyed the distinction the supervisor exists to
  # draw. Every sibling driver here already reads both forms.
  outcome="$(<"$receipt")"
  if [[ "$outcome" == "subtree-reaped-v0 timeout status=124" && "$rc" -eq 124 ]]; then
    echo "simd-f64 fixture: TIMEOUT status=124 (deadline exceeded, not a defect)" >&2
    exit 124
  fi
  [[ "$outcome" == "subtree-reaped-v0 exit status=$rc" ]] || {
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
gcc -std=c17 -O2 -fno-tree-vectorize -pedantic -Wall -Wextra -Werror \
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
