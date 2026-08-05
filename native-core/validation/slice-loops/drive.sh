#!/usr/bin/env bash
# Drive loop/recur through the native pipeline: beagle-ast -> source facts ->
# sealed source world -> typed world -> native world (one SSA header block per
# loop, one back-edge Jump per recur) -> 7 obligations -> native.body-c17 ->
# gcc/clang -std=c17 -> probe main.
# Two worlds: loops.bclj must pass all seven obligations; counted/ carries the
# fram counted shapes and refuses checked-arithmetic on its interim add-i64.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-loops.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

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

emit_slice() {
  local src="$1" art="$2" module="$3" annotation="${4:-}" pending="${5:-}"
  "$repo/bin/beagle-ast" "$src" >"$scratch/ast.json"
  # shellcheck disable=SC2086
  bb "$here/../slice-bodies/ast-facts.clj" "$scratch/ast.json" \
    "$scratch/loops.facts" $annotation
  if [[ -f "$art/loops.facts" ]] && ! cmp -s "$scratch/loops.facts" "$art/loops.facts"; then
    echo "drive.sh: regenerated projection differs from $art/loops.facts" >&2
    exit 1
  fi
  cp "$scratch/loops.facts" "$art/loops.facts"
  sha256sum "$src" | cut -d' ' -f1 >"$art/source.sha256"
  clojure -Sdeps "{:paths [\"$scratch/out\"]}" -M -e "
(require 'native.body-slice)
(spit \"$art/report.txt\"
  (native.body-slice/emit-slice! \"$scratch/loops.facts\" \"$module\"
    \"beagle:${src#"$repo"/}\" \"$art\" \"native-slice-loops-v0\"))"
  cat "$art/report.txt"
  if [ -z "$pending" ] && grep -q '^pending ' "$art/report.txt"; then
    echo "drive.sh: a loop fixture function did not lower" >&2
    exit 1
  fi
}

compile_and_run() {
  local art="$1" label="$2"
  local build="$scratch/c-$label"
  mkdir -p "$build"
  cp "$art/module_0.h" "$art/module_0.c" "$art/main.c" "$build/"
  cp "$repo/native-core/shim/native_shim.c" "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$build/"
  ( cd "$build" && gcc -std=c17 -pedantic -Wall -Wextra -Werror \
      -o probe_gcc module_0.c native_shim.c main.c )
  ( cd "$build" && ./probe_gcc )
  echo "drive.sh: $label gcc $(gcc -dumpversion) strict compile + run ok"
  local clang_bin
  clang_bin="$(command -v clang 2>/dev/null || ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null | sort -V | tail -1)"
  if [ -n "$clang_bin" ]; then
    ( cd "$build" && "$clang_bin" -std=c17 -Werror -o probe_clang module_0.c native_shim.c main.c )
    ( cd "$build" && ./probe_clang )
    echo "drive.sh: $label clang $("$clang_bin" -dumpversion) compile + run ok"
  else
    echo "drive.sh: clang not found — second frontend NOT exercised" >&2
  fi
}

emit_slice "$here/loops.bclj" "$here" "native.loops"
if grep -q '^obligation-projection FAIL' "$here/report.txt"; then
  echo "drive.sh: loops.bclj must discharge all seven obligations" >&2
  exit 1
fi

emit_slice "$here/counted/loops_counted.bclj" "$here/counted" \
  "native.loops-counted" "add-i64=checked-add-i64"
# the interim add-i64 primitive returns Int where the obligation wants an
# Outcome, so exactly this one refusal is expected until the arithmetic arm lands
expected_fail="obligation-projection FAIL checked-arithmetic"
if [ "$(grep -c '^obligation-projection FAIL' "$here/counted/report.txt")" != "1" ] ||
   ! grep -qx "$expected_fail" "$here/counted/report.txt"; then
  echo "drive.sh: counted/ obligations changed beyond the known checked-arithmetic refusal" >&2
  exit 1
fi

emit_slice "$here/refusals/refusals.bclj" "$here/refusals" "native.loops-refusals" \
  "" allow-pending
for expected in \
  'TODO-NATIVE-RECUR-NON-TAIL.*\[non-tail\]' \
  'TODO-NATIVE-RECUR-OUTSIDE-LOOP.*\[outside-loop\]' \
  'TODO-NATIVE-RECUR-ARITY.*\[wrong-arity\]' \
  'TODO-NATIVE-RECUR-TYPES.*\[wrong-types\]' \
  'TODO-NATIVE-RECUR-NON-TAIL.*\[non-tail-do\]' \
  'TODO-NATIVE-RECUR-NON-TAIL.*\[non-tail-cond-test\]' \
  'TODO-NATIVE-RECUR-NON-TAIL.*\[through-try\]' \
  'TODO-NATIVE-RECUR-NON-TAIL.*\[nested-init\]' \
  'TODO-NATIVE-RECUR-ARITY.*\[nested-wrong-target\]'; do
  grep -q "$expected" "$here/refusals/report.txt" ||
    { echo "drive.sh: refusals/ omitted expected evidence: $expected" >&2; exit 1; }
done
# every function refused, so the refusal world materializes nothing worth keeping
rm -f "$here/refusals/module_0.c" "$here/refusals/module_0.h"

if [ -n "${NATIVE_SLICE_NO_COMPILE:-}" ]; then
  exit 0
fi

compile_and_run "$here" loops
compile_and_run "$here/counted" counted
