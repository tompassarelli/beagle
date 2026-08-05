#!/usr/bin/env bash
# Drive validation/slice-union/fixture.bclj through the native pipeline and run
# the coercion rule's own C probe: a tag inject, a checked extract that reads a
# record reference out of the Any union, a checked by-value record copy, and
# traps for a wrong tag or null record reference.
# fram.types guards every narrowing it performs, so only this fixture can fire
# the trap; the projection reuses slice-bodies' AST-to-facts step unchanged.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-$here}"
src="$here/fixture.bclj"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-union.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

"$repo/bin/beagle-ast" "$src" >"$scratch/fixture.ast.json"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  "$scratch/fixture.ast.json" \
  "$scratch/fixture.facts"
if [[ -f "$art/fixture.facts" ]] && ! cmp -s "$scratch/fixture.facts" "$art/fixture.facts"; then
  echo "drive.sh: regenerated projection differs from the committed fixture.facts" >&2
  exit 1
fi
cp "$scratch/fixture.facts" "$art/fixture.facts"
sha256sum "$src" | cut -d' ' -f1 >"$art/source.sha256"

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bgl" \
  "$repo/native-core/src/native/worlds.bgl" \
  "$repo/native-core/src/native/lower.bgl" \
  "$repo/native-core/src/native/obligations.bgl" \
  "$repo/native-core/src/native/c11.bgl" \
  "$repo/native-core/src/native/slice.bgl" \
  "$repo/native-core/src/native/fold_c17.bgl" \
  "$repo/native-core/src/native/body_c17.bgl" \
  "$repo/native-core/src/native/qbe.bgl" \
  "$repo/native-core/src/native/body_slice.bgl" \
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
  (native.body-slice/emit-dual-slice! \"$scratch/fixture.facts\" \"fixture.union\"
    \"native-core/validation/slice-union/fixture.bclj\" \"$art\"
    \"native-slice-union-v0\" \"numeric-int-double-less?\" 2))"

cat "$art/report.txt"

if [ -n "${NATIVE_SLICE_NO_COMPILE:-}" ]; then
  exit 0
fi

build="$scratch/c"
mkdir -p "$build"
cp "$art/module_0.h" "$art/module_0.c" "$art/main.c" "$build/"
cp "$repo/native-core/shim/native_shim.c" "$repo/native-core/shim/native_shim.h" "$build/"

any_type="$(sed -nE \
  's/^(native_m0_type_[0-9]+) native_m0_fn_1\(.*/\1/p' \
  "$art/module_0.h")"
nil_type="$(sed -nE \
  's/^(native_m0_type_[0-9]+) native_m0_fn_15\(.*/\1/p' \
  "$art/module_0.h")"
pair_type="$(sed -nE \
  's/^(native_m0_type_[0-9]+) native_m0_fn_7\(.*/\1/p' \
  "$art/module_0.h")"
if [[ -z "$any_type" || -z "$nil_type" || -z "$pair_type" ]]; then
  echo "drive.sh: could not resolve generated Any, Nil, and Pair types" >&2
  exit 1
fi
type_definitions=(
  "-DSLICE_ANY_TYPE=$any_type"
  "-DSLICE_NIL_TYPE=$nil_type"
  "-DSLICE_PAIR_TYPE=$pair_type")

strict=(-std=c17 -pedantic -Wall -Wextra -Werror)
( cd "$build" && gcc "${strict[@]}" "${type_definitions[@]}" \
    -o probe_gcc module_0.c native_shim.c main.c )
( cd "$build" && ./probe_gcc )
if ( cd "$build" && ulimit -c 0 && ./probe_gcc mismatch ) 2>/dev/null; then
  echo "drive.sh: the mismatched union tag did not trap" >&2
  exit 1
fi
if ( cd "$build" && ulimit -c 0 && ./probe_gcc null ) 2>/dev/null; then
  echo "drive.sh: the null record reference did not trap" >&2
  exit 1
fi
if ( cd "$build" && ulimit -c 0 && ./probe_gcc double ) 2>/dev/null; then
  echo "drive.sh: double accepted a non-numeric union tag" >&2
  exit 1
fi
echo "drive.sh: gcc $(gcc -dumpversion) strict compile + run + mismatch/null/double traps ok"

find_clang() {
  if command -v clang >/dev/null 2>&1; then command -v clang; return 0; fi
  local candidate
  candidate="$(ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null | sort -V | tail -1)"
  [ -n "$candidate" ] && printf '%s\n' "$candidate"
}

clang_bin="$(find_clang || true)"
if [ -n "$clang_bin" ]; then
  ( cd "$build" && "$clang_bin" "${strict[@]}" "${type_definitions[@]}" \
      -o probe_clang module_0.c native_shim.c main.c )
  ( cd "$build" && ./probe_clang )
  if ( cd "$build" && ulimit -c 0 && ./probe_clang mismatch ) 2>/dev/null; then
    echo "drive.sh: clang build did not trap on the mismatched union tag" >&2
    exit 1
  fi
  if ( cd "$build" && ulimit -c 0 && ./probe_clang null ) 2>/dev/null; then
    echo "drive.sh: clang build did not trap on the null record reference" >&2
    exit 1
  fi
  if ( cd "$build" && ulimit -c 0 && ./probe_clang double ) 2>/dev/null; then
    echo "drive.sh: clang build did not trap on an invalid double operand" >&2
    exit 1
  fi
  echo "drive.sh: clang $("$clang_bin" -dumpversion) compile + run + mismatch/null/double traps ok"
else
  echo "drive.sh: clang not found — second frontend NOT exercised" >&2
fi
