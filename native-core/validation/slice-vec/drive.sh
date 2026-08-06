#!/usr/bin/env bash
# Drive fram:src/fram/types.bgl + fram:src/fram/store.bgl BODIES through the
# native pipeline with the Vec vocabulary live:
#   beagle-ast -> source facts (signatures + bodies + vector literals)
#     -> sealed source world -> typed world -> native world -> 7 obligations
#     -> native.body-c17 -> gcc/clang -std=c17 -Werror -> run the probe main.
# The pair is projected together because store.bgl declares no record of its
# own: every (Vec T) in its signatures is a fram.types record vector.
# Re-runnable: the projection is rebuilt from live fram and must match the
# committed vec.facts byte for byte.
set -euo pipefail

abi="${NATIVE_SLICE_ABI:-lp64}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-$here}"
src="${FRAM_TYPES:-$HOME/code/fram/main/src/fram/types.bgl}"
dep="${FRAM_STORE:-$HOME/code/fram/main/src/fram/store.bgl}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-vec.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

banner=""
if [[ "${NATIVE_SLICE_COMMITTED_FACTS:-0}" == 1 ]]; then
  # Opt-in only, and it says so in the report: this mode proves the committed
  # projection still lowers, never that it still matches live fram.
  [[ -f "$art/vec.facts" ]] \
    || { echo "drive.sh: NATIVE_SLICE_COMMITTED_FACTS=1 but no committed $art/vec.facts" >&2; exit 1; }
  banner="MODE committed-facts: upstream fram source NOT read; this run does not prove the projection matches live fram"
  echo "drive.sh: $banner" >&2
  cp "$art/vec.facts" "$scratch/vec.facts"
else
  for upstream in "$src" "$dep"; do
    [[ -f "$upstream" ]] && continue
    echo "drive.sh: upstream fram source is missing: $upstream" >&2
    echo "drive.sh: point FRAM_TYPES/FRAM_STORE at the live sources, or set NATIVE_SLICE_COMMITTED_FACTS=1 to check only the committed projection" >&2
    exit 1
  done
  "$repo/bin/beagle-ast" "$src" >"$scratch/types.ast.json"
  "$repo/bin/beagle-ast" "$dep" >"$scratch/store.ast.json"
  "$repo/bin/beagle-ast" "$here/vec_probe.bclj" >"$scratch/probe.ast.json"
  bb "$here/ast-facts.clj" \
    "$scratch/types.ast.json=fram:src/fram/types.bgl" \
    "$scratch/store.ast.json=fram:src/fram/store.bgl" \
    "$scratch/probe.ast.json=beagle:native-core/validation/slice-vec/vec_probe.bclj" \
    "$scratch/vec.facts"
  if [[ -f "$art/vec.facts" && "${NATIVE_SLICE_UPDATE:-0}" != 1 ]] \
      && ! cmp -s "$scratch/vec.facts" "$art/vec.facts"; then
    echo "drive.sh: regenerated projection differs from the committed vec.facts" >&2
    exit 1
  fi
  cp "$scratch/vec.facts" "$art/vec.facts"
  { sha256sum "$src" | cut -d' ' -f1; sha256sum "$dep" | cut -d' ' -f1; } \
    >"$art/source.sha256"
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
  (native.body-slice/emit-slice! \"$scratch/vec.facts\" \"fram.store\"
    \"fram:src/fram/store.bgl\" \"$art\" \"native-slice-vec-v0\" \"$abi\"))"

if [[ -n "$banner" ]]; then
  sed -i "1i $banner" "$art/report.txt"
fi
cat "$art/report.txt"

if [ -n "${NATIVE_SLICE_NO_COMPILE:-}" ]; then
  exit 0
fi

build="$scratch/c"
mkdir -p "$build"
cp "$art/module_0.h" "$art/module_0.c" "$here/main.c" "$build/"
cp "$repo/native-core/shim/native_shim.c" "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$build/"

strict=(-std=c17 -pedantic -Wall -Wextra -Werror)
( cd "$build" && gcc "${strict[@]}" -o probe_gcc module_0.c native_shim.c main.c )
( cd "$build" && ./probe_gcc )
if ( cd "$build" && ulimit -c 0 && ./probe_gcc trap ) 2>/dev/null; then
  echo "drive.sh: the out-of-range nth did not trap" >&2
  exit 1
fi
if ( cd "$build" && ulimit -c 0 && ./probe_gcc overflow ) 2>/dev/null; then
  echo "drive.sh: inc INT64_MAX did not trap" >&2
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
  if ( cd "$build" && ulimit -c 0 && ./probe_clang trap ) 2>/dev/null; then
    echo "drive.sh: the out-of-range nth did not trap under clang" >&2
    exit 1
  fi
  if ( cd "$build" && ulimit -c 0 && ./probe_clang overflow ) 2>/dev/null; then
    echo "drive.sh: inc INT64_MAX did not trap under clang" >&2
    exit 1
  fi
  echo "drive.sh: clang $("$clang_bin" -dumpversion) compile + run + trap ok"
else
  echo "drive.sh: clang not found — second frontend NOT exercised" >&2
fi
