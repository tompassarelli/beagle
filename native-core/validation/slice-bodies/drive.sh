#!/usr/bin/env bash
# Drive fram:src/fram/types.bclj function BODIES through the native pipeline:
#   beagle-ast -> source facts (signatures + bodies) -> sealed source world
#     -> typed world -> native world with lowered blocks -> 7 obligations
#     -> native.body-c17 -> gcc/clang -std=c17 -Werror -> run the probe main.
# Re-runnable: the projection is rebuilt from the source file when fram is
# checked out here, and must match the committed types.facts byte for byte.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-$here}"
src="${FRAM_TYPES:-$HOME/code/fram/main/src/fram/types.bclj}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-bodies.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

if [[ -f "$src" ]]; then
  "$repo/bin/beagle-ast" "$src" >"$scratch/types.ast.json"
  bb "$here/ast-facts.clj" \
    "$scratch/types.ast.json=fram:src/fram/types.bclj" "$scratch/types.facts" \
    --include-defs
  if [[ -f "$art/types.facts" ]] && ! cmp -s "$scratch/types.facts" "$art/types.facts"; then
    echo "drive.sh: regenerated projection differs from the committed types.facts" >&2
    exit 1
  fi
  cp "$scratch/types.facts" "$art/types.facts"
  sha256sum "$src" | cut -d' ' -f1 >"$art/source.sha256"
elif [[ -f "$art/types.facts" ]]; then
  cp "$art/types.facts" "$scratch/types.facts"
else
  echo "drive.sh: no $src and no committed types.facts" >&2
  exit 1
fi

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/worlds.bclj" \
  "$repo/native-core/src/native/lower.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
  "$repo/native-core/src/native/c11.bclj" \
  "$repo/native-core/src/native/slice.bclj" \
  "$repo/native-core/src/native/fold_c17.bclj" \
  "$repo/native-core/src/native/body_c17.bclj" \
  "$repo/native-core/src/native/qbe.bclj" \
  "$repo/native-core/src/native/body_slice.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || { sed -n '1,200p' "$scratch/build.log" >&2; exit 1; }

# A cross-module `match` on an imported union emits an unqualified variant name;
# re-exporting native.core's records into each consumer namespace is the repo's
# standing workaround until the emitter qualifies them.
records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' "$scratch/out/native/core.clj" | tr '\n' ' ')"
for m in worlds lower obligations c11 slice fold_c17 body_c17 qbe body_slice; do
  [ -f "$scratch/out/native/$m.clj" ] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' "$scratch/out/native/$m.clj"
  awk -v imp="(import '[native.core $records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' \
    "$scratch/out/native/$m.clj" >"$scratch/out/native/$m.clj.tmp"
  mv "$scratch/out/native/$m.clj.tmp" "$scratch/out/native/$m.clj"
done

clojure -Sdeps "{:paths [\"$scratch/out\"]}" -M -e "
(require 'native.body-slice)
(spit \"$art/report.txt\"
  (native.body-slice/emit-slice! \"$scratch/types.facts\" \"fram.types\"
    \"fram:src/fram/types.bclj\" \"$art\" \"native-slice-bodies-v0\"))"

cat "$art/report.txt"

if [ -n "${NATIVE_SLICE_NO_COMPILE:-}" ]; then
  exit 0
fi

build="$scratch/c"
mkdir -p "$build"
cp "$art/module_0.h" "$art/module_0.c" "$art/main.c" "$build/"
cp "$repo/native-core/shim/native_shim.c" "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$build/"

strict=(-std=c17 -pedantic -Wall -Wextra -Werror)
( cd "$build" && gcc "${strict[@]}" -o probe_gcc module_0.c native_shim.c main.c )
( cd "$build" && ./probe_gcc )
if ( cd "$build" && ulimit -c 0 && ./probe_gcc trap ) 2>/dev/null; then
  echo "drive.sh: the out-of-range instant did not trap" >&2
  exit 1
fi
if ( cd "$build" && ulimit -c 0 && ./probe_gcc overflow ) 2>/dev/null; then
  echo "drive.sh: INT64_MAX + 1 did not trap — a wrapped value escaped" >&2
  exit 1
fi
echo "drive.sh: gcc $(gcc -dumpversion) strict compile + run + trap ok"

find_clang() {
  if command -v clang >/dev/null 2>&1; then command -v clang; return 0; fi
  local candidate
  candidate="$(ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null | sort -V | tail -1)"
  [ -n "$candidate" ] && printf '%s\n' "$candidate"
}

clang_bin="$(find_clang || true)"
if [ -n "$clang_bin" ]; then
  ( cd "$build" && "$clang_bin" -std=c17 -Werror -o probe_clang module_0.c native_shim.c main.c )
  ( cd "$build" && ./probe_clang )
  if ( cd "$build" && ulimit -c 0 && ./probe_clang overflow ) 2>/dev/null; then
    echo "drive.sh: clang: INT64_MAX + 1 did not trap" >&2
    exit 1
  fi
  echo "drive.sh: clang $("$clang_bin" -dumpversion) compile + run ok"
else
  echo "drive.sh: clang not found — second frontend NOT exercised" >&2
fi
