#!/usr/bin/env bash
# Drive fram:src/fram/types.bgl function BODIES through the native pipeline:
#   beagle-ast -> source facts (signatures + bodies) -> frozen source program
#     -> typed program -> native program with lowered blocks -> 7 obligations
#     -> native.body-c17 -> gcc/clang -std=c17 -Werror -> run the probe main.
# Re-runnable: the projection and tracked artifacts are rebuilt from the
# current vendored Fram source.
set -euo pipefail

abi="${NATIVE_SLICE_ABI:-lp64}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-$here}"
# Upstream fram sources are vendored under native-core/validation/upstream/fram
# (its MANIFEST records the fram revision and digests); a FRAM_* override still
# points a run at a live checkout. The default is beagle-only ON PURPOSE: a gate
# must not be a function of another repository's working tree.
src="${FRAM_TYPES:-$repo/native-core/validation/upstream/fram/src/fram/types.bgl}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-bodies.XXXXXX")"
generated="$scratch/generated"
trap 'rm -rf "${scratch:?}"' EXIT
mkdir -p "$generated"

logical=""
if [[ ! -f "$src" ]]; then
  echo "drive.sh: upstream fram source is missing: $src" >&2
  echo "drive.sh: restore native-core/validation/upstream/fram or point FRAM_TYPES at the current Fram source" >&2
  exit 1
fi
"$repo/bin/beagle-ast" "$src" >"$scratch/types.ast.json"
logical="$(jq -er '.sourceId | select(type == "string" and length > 0)' \
  "$scratch/types.ast.json")"
bb "$here/ast-facts.clj" \
  "$scratch/types.ast.json=$logical" \
  "$generated/types.facts" \
  --include-defs
sha256sum "$src" | cut -d' ' -f1 >"$generated/source.sha256"

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
  "$repo/native-core/src/native/lower.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
  "$repo/native-core/src/native/simd.bclj" \
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
for m in stages lower obligations simd c11 slice fold_c17 body_c17 qbe body_slice; do
  [ -f "$scratch/out/native/$m.clj" ] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' "$scratch/out/native/$m.clj"
  awk -v imp="(import '[native.core $records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' \
    "$scratch/out/native/$m.clj" >"$scratch/out/native/$m.clj.tmp"
  mv "$scratch/out/native/$m.clj.tmp" "$scratch/out/native/$m.clj"
done

bb -cp "$scratch/out" -e "
(require 'native.body-slice)
(spit \"$generated/report.txt\"
  (native.body-slice/emit-slice! \"$generated/types.facts\" \"fram.types\"
    \"$logical\"
    \"$generated\" \"native-slice-bodies-v0\" \"$abi\"))"

cat "$generated/report.txt"

if [[ "${NATIVE_SLICE_SOURCE_ID_PROOF:-0}" == 1 ]]; then
  rg -Fx 'stage source-freeze ACCEPTED' "$generated/report.txt" >/dev/null
  printf 'slice-bodies: source-id proof PASS logical=%s\n' "$logical"
  exit 0
fi

publish_results() {
  local -a names=(types.facts report.txt module_0.h module_0.c)
  [[ -f "$generated/source.sha256" ]] && names+=(source.sha256)
  local name
  mkdir -p "$art"
  for name in "${names[@]}"; do
    cp -- "$generated/$name" "$art/$name"
  done
}

if [ -n "${NATIVE_SLICE_NO_COMPILE:-}" ]; then
  publish_results
  exit 0
fi

build="$scratch/c"
mkdir -p "$build"
cp "$generated/module_0.h" "$generated/module_0.c" "$here/main.c" "$build/"
cp "$repo/native-core/shim/native_shim.c" "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$build/"

# The emitter numbers its type table in collection order, so the probe names
# every generated type through a macro resolved here instead of spelling an
# ordinal that an unrelated fram.types change silently repoints.
return_type_of() { # <fn-index>
  sed -nE "s/^(native_m0_type_[0-9]+) native_m0_fn_$1\(.*/\1/p" "$generated/module_0.h"
}
value_param_of() { # <fn-index> — first parameter that is a generated type
  sed -nE "s/^native_m0_type_[0-9]+ native_m0_fn_$1\((.*)\);$/\1/p" "$generated/module_0.h" \
    | tr ',' '\n' | sed -nE 's/^ *(native_m0_type_[0-9]+) .*/\1/p' | head -1
}
defines=(
  "-DSLICE_ANY_TYPE=$(value_param_of 0)"          # instant? [v: Any]
  "-DSLICE_TRIPLE_TYPE=$(return_type_of 21)"      # triple -> Triple
  "-DSLICE_TERM_TYPE=$(value_param_of 21)"        # triple [t1: Term …]
  "-DSLICE_PAGE_REQUEST_TYPE=$(value_param_of 11)" # …cursor-value [r: RpcPageRequest]
  "-DSLICE_INSTANT_TYPE=$(return_type_of 1)"      # instant -> Instant
)
for define in "${defines[@]}"; do
  [[ "$define" == *=native_m0_type_* ]] \
    || { echo "drive.sh: could not resolve a generated type: $define" >&2; exit 1; }
done

strict=(-std=c17 -pedantic -Wall -Wextra -Werror "${defines[@]}")
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
  ( cd "$build" && "$clang_bin" -std=c17 -Werror "${defines[@]}" -o probe_clang module_0.c native_shim.c main.c )
  ( cd "$build" && ./probe_clang )
  if ( cd "$build" && ulimit -c 0 && ./probe_clang overflow ) 2>/dev/null; then
    echo "drive.sh: clang: INT64_MAX + 1 did not trap" >&2
    exit 1
  fi
  echo "drive.sh: clang $("$clang_bin" -dumpversion) compile + run ok"
else
  echo "drive.sh: clang not found — second frontend NOT exercised" >&2
fi

publish_results
