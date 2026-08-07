#!/usr/bin/env bash
# Regenerates the fram.fold Native Core C17 slice into NATIVE_SLICE_ARTIFACTS.
# Compilation stays in a temp dir so it never touches the byte-compared artifacts.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
artifacts="${NATIVE_SLICE_ARTIFACTS:-$here}"
module="${NATIVE_SLICE_MODULE:-fold}"
abi="${NATIVE_SLICE_ABI:-lp64}"

if [ "$module" != "fold" ]; then
  echo "drive.sh: this driver only serves NATIVE_SLICE_MODULE=fold (got: $module)" >&2
  exit 2
fi

command -v bb >/dev/null 2>&1 || { echo "drive.sh: babashka (bb) is required" >&2; exit 2; }

work="$(mktemp -d)"
cleanup() { rm -rf "${work:?}"; }
trap cleanup EXIT

mkdir -p "$work/src/native" "$artifacts"

# Native compiler modules are hosted Clojure Beagle sources.
for name in core stages obligations lower fold_c17 fold_slice_corpus; do
  cp "$repo/native-core/src/native/$name.bclj" "$work/src/native/$name.bclj"
done

BEAGLE_OUT="$work/out" "$repo/bin/beagle" build --target clj "$work"/src/native/*.bclj \
  > "$work/build.log" 2>&1 || { cat "$work/build.log" >&2; exit 1; }

bb -cp "$work/out" -e \
  "(require (quote native.fold-slice-corpus)) (native.fold-slice-corpus/emit-slice! \"$artifacts\" \"$abi\")"

echo "drive.sh: materialized $artifacts/module_0.h $artifacts/module_0.c $artifacts/main.c"

if [ -n "${NATIVE_SLICE_NO_COMPILE:-}" ]; then
  exit 0
fi

find_clang() {
  if command -v clang >/dev/null 2>&1; then command -v clang; return 0; fi
  local candidate
  candidate="$(ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null | sort -V | tail -1)"
  [ -n "$candidate" ] && printf '%s\n' "$candidate"
}

build="$work/c"
mkdir -p "$build"
cp "$artifacts/module_0.h" "$artifacts/module_0.c" "$artifacts/main.c" "$build/"
cp "$repo/native-core/shim/native_shim.c" "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$build/"

strict=(-std=c17 -pedantic -Wall -Wextra -Werror)
( cd "$build" && gcc "${strict[@]}" -o probe_gcc module_0.c native_shim.c main.c )
( cd "$build" && ./probe_gcc )
echo "drive.sh: gcc $(gcc -dumpversion) strict compile + run ok"

clang_bin="$(find_clang || true)"
if [ -n "$clang_bin" ]; then
  ( cd "$build" && "$clang_bin" "${strict[@]}" -o probe_clang module_0.c native_shim.c main.c )
  ( cd "$build" && ./probe_clang )
  echo "drive.sh: clang strict compile + run ok ($clang_bin)"
else
  echo "drive.sh: clang not found; C17 evidence is gcc-only" >&2
  exit 1
fi

( cd "$build" && gcc "${strict[@]}" -g -fsanitize=address,undefined \
    -fno-sanitize-recover=all -o probe_sanitized module_0.c native_shim.c main.c )
( cd "$build" && ./probe_sanitized )
echo "drive.sh: ASan+UBSan run ok"
