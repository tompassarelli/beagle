#!/usr/bin/env bash
set -euo pipefail

sequence_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sequence_repo="${NATIVE_SLICE_REPO:-$(cd "$sequence_here/../../.." && pwd)}"
sequence_scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-sequence-primitives.XXXXXX")"
trap 'rm -rf "${sequence_scratch:?}"' EXIT

"$sequence_repo/bin/beagle-ast" "$sequence_here/fixture.bclj" \
  >"$sequence_scratch/fixture.ast.json"
bb "$sequence_repo/native-core/validation/slice-vec/ast-facts.clj" \
  "$sequence_scratch/fixture.ast.json=beagle:native-core/validation/slice-sequence-primitives/fixture.bclj" \
  "$sequence_scratch/fixture.facts"

"$sequence_repo/bin/beagle-build-all" \
  "$sequence_repo/native-core/src/native/core.bgl" \
  "$sequence_repo/native-core/src/native/worlds.bgl" \
  "$sequence_repo/native-core/src/native/lower.bgl" \
  "$sequence_repo/native-core/src/native/obligations.bgl" \
  "$sequence_repo/native-core/src/native/c11.bgl" \
  "$sequence_repo/native-core/src/native/slice.bgl" \
  "$sequence_repo/native-core/src/native/fold_c17.bgl" \
  "$sequence_repo/native-core/src/native/body_c17.bgl" \
  "$sequence_repo/native-core/src/native/qbe.bgl" \
  "$sequence_repo/native-core/src/native/body_slice.bgl" \
  --out "$sequence_scratch/out" >"$sequence_scratch/build.log" 2>&1 || {
    sed -n '1,240p' "$sequence_scratch/build.log" >&2
    exit 1
  }

records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
  "$sequence_scratch/out/native/core.clj" | tr '\n' ' ')"
for module in worlds lower obligations c11 slice fold_c17 body_c17 qbe body_slice; do
  module_path="$sequence_scratch/out/native/$module.clj"
  test -f "$module_path" || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$module_path"
  awk -v import_form="(import '[native.core $records])" \
    '!seen && /^$/ { print import_form; seen = 1 } { print }' \
    "$module_path" >"$module_path.tmp"
  mv "$module_path.tmp" "$module_path"
done

for pass in one two; do
  artifacts="$sequence_scratch/artifacts-$pass"
  mkdir -p "$artifacts"
  clojure -Sdeps "{:paths [\"$sequence_scratch/out\"]}" -M -e "
(require 'native.body-slice)
(spit \"$artifacts/report.txt\"
  (native.body-slice/emit-dual-slice!
    \"$sequence_scratch/fixture.facts\"
    \"fram.sequence-probe\"
    \"beagle:native-core/validation/slice-sequence-primitives/fixture.bclj\"
    \"$artifacts\"
    \"sequence-primitives-v0\"
    \"sort-texts\"
    0))"
done

report="$sequence_scratch/artifacts-one/report.txt"
cat "$report"
grep -Fxq "stage typed-to-native COMPLETE" "$report"
grep -Fxq "materialize OK module_0.h module_0.c" "$report"
grep -Fq "lowered fn_0 first-value " "$report"
grep -Fq "lowered fn_1 last-value " "$report"
grep -Fq "lowered fn_2 peek-value " "$report"
grep -Fq "lowered fn_3 take-values " "$report"
grep -Fq "lowered fn_4 drop-values " "$report"
grep -Fq "lowered fn_5 sort-values " "$report"
grep -Fq "lowered fn_6 sort-texts " "$report"
grep -Fxq "qbe-materialize REFUSED QBE vector sort is unsupported: sealed value descriptors have no QBE data representation" \
  "$report"
if grep -Fq "pending TODO-NATIVE" "$report"; then
  echo "drive.sh: the sequence fixture retained a native lowering TODO" >&2
  exit 1
fi

grep -Fq "native_vec_at" "$sequence_scratch/artifacts-one/module_0.c"
grep -Fq "native_vec_slice" "$sequence_scratch/artifacts-one/module_0.c"
grep -Fq "native_vec_sort" "$sequence_scratch/artifacts-one/module_0.c"
cmp "$sequence_scratch/artifacts-one/module_0.h" \
  "$sequence_scratch/artifacts-two/module_0.h"
cmp "$sequence_scratch/artifacts-one/module_0.c" \
  "$sequence_scratch/artifacts-two/module_0.c"
cmp "$sequence_scratch/artifacts-one/report.txt" \
  "$sequence_scratch/artifacts-two/report.txt"

build="$sequence_scratch/c"
mkdir -p "$build"
cp "$sequence_scratch/artifacts-one/module_0.h" \
  "$sequence_scratch/artifacts-one/module_0.c" \
  "$sequence_here/main.c" \
  "$sequence_repo/native-core/shim/native_shim.c" \
  "$sequence_repo/native-core/shim/native_shim.h" \
  "$build/"

strict=(-std=c17 -pedantic -Wall -Wextra -Werror)
(cd "$build" && gcc "${strict[@]}" -o sequence-gcc \
  module_0.c native_shim.c main.c)
(cd "$build" && ./sequence-gcc)
for edge in first last peek; do
  if (cd "$build" && ulimit -c 0 && ./sequence-gcc "$edge") 2>/dev/null; then
    echo "drive.sh: empty $edge returned instead of trapping" >&2
    exit 1
  fi
done
echo "drive.sh: gcc $(gcc -dumpversion) strict C17 + edge traps ok"

find_clang() {
  if command -v clang >/dev/null 2>&1; then
    command -v clang
    return 0
  fi
  local candidate
  candidate="$(find /nix/store -maxdepth 3 -path '*/bin/clang' -type f 2>/dev/null | \
    sort -V | tail -1)"
  test -n "$candidate" && printf '%s\n' "$candidate"
}

clang_bin="$(find_clang || true)"
if test -n "$clang_bin"; then
  (cd "$build" && "$clang_bin" -std=c17 -Werror -o sequence-clang \
    module_0.c native_shim.c main.c)
  (cd "$build" && ./sequence-clang)
  for edge in first last peek; do
    if (cd "$build" && ulimit -c 0 && ./sequence-clang "$edge") 2>/dev/null; then
      echo "drive.sh: empty $edge returned under clang instead of trapping" >&2
      exit 1
    fi
  done
  echo "drive.sh: clang $("$clang_bin" -dumpversion) C17 + edge traps ok"
else
  echo "drive.sh: clang unavailable; second frontend not exercised" >&2
fi

echo "drive.sh: sequence primitives PASS"
