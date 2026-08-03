#!/usr/bin/env bash
# Drive fram:src/fram/types.bclj through the whole native pipeline and emit the
# C17 projection of its record ABI.
#
#   beagle-ast -> source facts -> sealed source world -> typed world
#     -> native world -> 7 obligations -> native.c11 emitters
#
# Re-runnable and byte-stable: every input is regenerated from the source file
# (or from the committed projection when fram is not checked out here).
#
# Env: NATIVE_SLICE_REPO, NATIVE_SLICE_ARTIFACTS, FRAM_TYPES.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-$here}"
src="${FRAM_TYPES:-$HOME/code/fram/main/src/fram/types.bclj}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-types-full.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

# The committed projection is the fallback input, so the driver still runs when
# the fram checkout is absent; when it is present the projection is rebuilt and
# must match byte for byte.
if [[ -f "$src" ]]; then
  "$repo/bin/beagle-ast" "$src" >"$scratch/types.ast.json"
  bb "$here/ast-facts.clj" "$scratch/types.ast.json" "$scratch/types.facts"
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
  "$repo/native-core/src/native/core.bgl" \
  "$repo/native-core/src/native/worlds.bgl" \
  "$repo/native-core/src/native/lower.bgl" \
  "$repo/native-core/src/native/obligations.bgl" \
  "$repo/native-core/src/native/c11.bgl" \
  "$repo/native-core/src/native/slice.bgl" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || { sed -n '1,200p' "$scratch/build.log" >&2; exit 1; }

# The lowering passes rebuild the fact index on every lookup, so a 1300-fact
# module needs a compiling runtime, not the interpreter.
clojure -Sdeps "{:paths [\"$scratch/out\"]}" -M -e "
(require 'native.slice)
(spit \"$art/report.txt\"
  (native.slice/emit-slice! \"$scratch/types.facts\" \"fram.types\"
    \"fram:src/fram/types.bclj\" \"$art\" \"native-slice-types-full-v0\"))"

cat "$art/report.txt"
