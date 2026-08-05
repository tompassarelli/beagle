#!/usr/bin/env bash
set -euo pipefail

types_root="$(git rev-parse --show-toplevel)"
types_source="/home/tom/code/fram/main/src/fram/types.bclj"
types_output="$types_root/native-core/validation/slice-types"
types_scratch="$(mktemp -d /tmp/native-slice-types.XXXXXX)"
types_clang_bin="$(command -v clang || true)"

if [[ -z "$types_clang_bin" ]]; then
  types_clang_bin="$(find /nix/store -maxdepth 3 -type f -path '*clang-wrapper*/bin/clang' | sort | tail -n 1)"
fi
if [[ -z "$types_clang_bin" ]]; then
  echo "clang is required" >&2
  exit 1
fi

"$types_root/bin/beagle-facts" "$types_source" >"$types_scratch/facts.raw"
{
  printf '[\n'
  tail -n +2 "$types_scratch/facts.raw"
  printf ']\n'
} >"$types_scratch/facts.edn"

"$types_root/bin/beagle-build-all" \
  "$types_root/native-core/src/native/core.bgl" \
  "$types_root/native-core/src/native/worlds.bgl" \
  "$types_root/native-core/src/native/lower.bgl" \
  "$types_root/native-core/src/native/obligations.bgl" \
  "$types_root/native-core/src/native/c11.bgl" \
  "$types_output/pipeline.bclj" \
  --out "$types_scratch/out" >"$types_scratch/build.log" 2>&1 || {
    sed -n '1,240p' "$types_scratch/build.log" >&2
    exit 1
  }

bb -cp "$types_scratch/out" -e \
  "(require 'native.slice-types-pipeline) (native.slice-types-pipeline/emit-slice! \"$types_scratch/facts.edn\" \"$types_source\" \"$types_output\")"

sha256sum "$types_source" | cut -d ' ' -f 1 >"$types_output/source.sha256"

gcc -std=c17 -Wall -Wextra -Werror \
  -I"$types_output" -I"$types_root/native-core/shim" \
  "$types_output/main.c" "$types_output/module_0.c" \
  "$types_root/native-core/shim/native_shim.c" \
  -o "$types_scratch/gcc-types"
"$types_scratch/gcc-types"
echo "GCC C17 PASS"

"$types_clang_bin" -std=c17 -Wall -Wextra -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I"$types_output" -I"$types_root/native-core/shim" \
  "$types_output/main.c" "$types_output/module_0.c" \
  "$types_root/native-core/shim/native_shim.c" \
  -o "$types_scratch/clang-types-sanitized"
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
  "$types_scratch/clang-types-sanitized"
echo "CLANG C17 ASAN UBSAN PASS"
