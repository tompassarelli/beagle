#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"

if [[ "${BEAGLE_PARALLEL_RUNTIME_BOUNDED:-0}" != "1" ]]; then
  source "$repo/bin/_beagle-racket"
  supervisor="$repo/native-core/bin/run-bounded.rkt"
  [[ -f "$supervisor" ]] || {
    echo "parallel-runtime fixture: shared bounded supervisor is unavailable" >&2
    exit 2
  }
  receipt="$(mktemp "${TMPDIR:-/tmp}/parallel-runtime-receipt.XXXXXX")"
  trap 'rm -f -- "$receipt"' EXIT
  if BEAGLE_PARALLEL_RUNTIME_BOUNDED=1 \
      BEAGLE_BOUNDED_COMPLETION_RECEIPT="$receipt" \
      "$RACKET" "$supervisor" 90 5 -- "$0"; then
    rc=0
  else
    rc=$?
  fi
  grep -Fqx "subtree-reaped-v0 exit status=$rc" "$receipt" || {
    echo "parallel-runtime fixture: supervisor did not reap its subtree" >&2
    exit 125
  }
  exit "$rc"
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-parallel-runtime.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT
source_file="$here/parallel.bgl"

echo "parallel-runtime fixture: source C17 build START"
mkdir -p "$scratch/c17-workers-1" "$scratch/c17-workers-8"
NATIVE_PARALLEL_WORKERS=1 "$repo/bin/beagle" build --materializer c17 \
  --out "$scratch/c17-workers-1" "$source_file"
NATIVE_PARALLEL_WORKERS=8 "$repo/bin/beagle" build --materializer c17 \
  --out "$scratch/c17-workers-8" "$source_file"

for artifact in module.native-program module.native-program.sha256 module_0.h module_0.c; do
  cmp "$scratch/c17-workers-1/$artifact" "$scratch/c17-workers-8/$artifact"
done
test -s "$scratch/c17-workers-1/build.manifest.sha256"
grep -Fq 'native_parallel.h' "$scratch/c17-workers-1/build.manifest"
grep -Fq 'native_parallel.c' "$scratch/c17-workers-1/build.manifest"
report="$scratch/c17-workers-1/report.txt"
test "$(head -n 1 "$report")" = "beagle-native-report/v1"
test "$(grep -Fxc 'beagle-native-report/v1' "$report")" = 1
test "$(tail -n 1 "$report")" = "result PASS"
grep -Fqx "program-functions 2" "$report"
grep -Fqx "program-abis 1" "$report"
grep -Fqx "parallel-kernel advect-tile!" "$report"
grep -Fqx "parallel-boundary periodic" "$report"
grep -Fqx "parallel-reduction f64-adjacent-pairwise-v0" "$report"
grep -Fqx "parallel-worker-count excluded-from-program-identity" "$report"
grep -Fqx "obligation-projection PASS deterministic-parallelism" "$report"
grep -Fqx \
  "c11-parallel REFUSED C11 deterministic parallel F64 instructions are unsupported" \
  "$report"
test "$(grep -c '^obligation-projection PASS ' "$report")" = 10
if grep -Fq "native_m0_fn_0" "$scratch/c17-workers-1/module_0.h"; then
  echo "parallel-runtime fixture: tile kernel escaped through the public ABI" >&2
  exit 1
fi
grep -Eq '^static native_m0_type_[0-9]+ native_m0_fn_0\(' \
  "$scratch/c17-workers-1/module_0.c"

echo "parallel-runtime fixture: source C17 execute START"
gcc -std=c17 -pedantic -Wall -Wextra -Werror -pthread -ffp-contract=off \
  -I "$scratch/c17-workers-1" \
  "$scratch/c17-workers-1/native_shim.c" \
  "$scratch/c17-workers-1/native_parallel.c" \
  "$scratch/c17-workers-1/module_0.c" \
  "$here/source_main.c" -o "$scratch/source-parallel"
"$scratch/source-parallel"

echo "parallel-runtime fixture: QBE refusal START"
mkdir -p "$scratch/qbe"
if "$repo/bin/beagle" build --materializer qbe --out "$scratch/qbe" \
    "$source_file" >"$scratch/qbe.log" 2>&1; then
  echo "parallel-runtime fixture: QBE accepted parallel instructions" >&2
  exit 1
fi
grep -Fqx \
  "qbe-parallel REFUSED QBE deterministic parallel F64 instructions are unsupported" \
  "$scratch/qbe.log"
test "$(grep -Fxc 'beagle-native-report/v1' "$scratch/qbe.log")" = 1
sed -n '/^beagle-native-report\/v1$/,/^result FAIL materialization$/p' \
  "$scratch/qbe.log" >"$scratch/qbe-report.txt"
test "$(head -n 1 "$scratch/qbe-report.txt")" = "beagle-native-report/v1"
test "$(tail -n 1 "$scratch/qbe-report.txt")" = "result FAIL materialization"
test ! -e "$scratch/qbe/report.txt"
if [[ -e "$scratch/qbe/module_0.ssa" ]]; then
  echo "parallel-runtime fixture: refused QBE build emitted module_0.ssa" >&2
  exit 1
fi

echo "parallel-runtime fixture: Wasm refusal START"
mkdir -p "$scratch/wasm"
if "$repo/bin/beagle" build --materializer c17 --abi wasm32 \
    --out "$scratch/wasm" "$source_file" >"$scratch/wasm.log" 2>&1; then
  echo "parallel-runtime fixture: Wasm accepted parallel instructions" >&2
  exit 1
fi
grep -Fqx \
  "wasm-parallel REFUSED shared-memory-worker-host-envelope-unavailable" \
  "$scratch/wasm.log"
test ! -e "$scratch/wasm/report.txt"
for artifact in module_0.h module_0.c native_parallel.h native_parallel.c; do
  if [[ -e "$scratch/wasm/$artifact" ]]; then
    echo "parallel-runtime fixture: refused Wasm build emitted $artifact" >&2
    exit 1
  fi
done

echo "parallel-runtime fixture: compile START"
gcc -std=c17 -pedantic -Wall -Wextra -Werror -pthread -ffp-contract=off \
  -I "$repo/native-core/shim" \
  "$repo/native-core/shim/native_shim.c" \
  "$repo/native-core/shim/native_parallel.c" \
  "$here/main.c" -o "$scratch/parallel-runtime"
echo "parallel-runtime fixture: execute START"
"$scratch/parallel-runtime"
