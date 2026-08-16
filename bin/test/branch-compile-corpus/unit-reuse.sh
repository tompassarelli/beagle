#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C
export TZ=UTC

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
build_root="${1:?usage: unit-reuse.sh BUILD_ROOT}"
compiled="$repo/.beagle/branch-compile-corpus/unit-reuse-compiled"
compile_log="$repo/.beagle/branch-compile-corpus/unit-reuse-compile.log"
compiler_commit="$(git -C "$repo" rev-parse HEAD)"

echo "branch-compile-corpus: unit reuse START"
timeout --foreground 180s "$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
  "$repo/native-core/src/native/simd.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
  "$repo/native-core/src/native/lower.bclj" \
  "$repo/native-core/src/native/c11.bclj" \
  "$repo/native-core/src/native/slice.bclj" \
  "$repo/native-core/src/native/unit_reuse.bclj" \
  "$repo/native-core/src/native/fold_c17.bclj" \
  "$repo/native-core/src/native/body_c17.bclj" \
  "$repo/native-core/src/native/qbe.bclj" \
  "$repo/native-core/src/native/body_slice.bclj" \
  --out "$compiled" >"$compile_log" 2>&1 || {
    tail -80 "$compile_log" >&2
    exit 1
  }
timeout --foreground 120s bb -cp "$compiled" "$here/unit_reuse_gate.clj" \
  "$build_root" "$compiler_commit"
echo "branch-compile-corpus: unit reuse END"
