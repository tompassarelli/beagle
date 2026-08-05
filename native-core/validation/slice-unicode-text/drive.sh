#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-unicode-text.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

for command in awk bb clojure gcc pkg-config rg; do
  command -v "$command" >/dev/null || {
    echo "drive.sh: required command is unavailable: $command" >&2
    exit 1
  }
done
pkg-config --exact-version=72.1 icu-uc || {
  echo "drive.sh: exact icu-uc version 72.1 is required" >&2
  exit 1
}

find_clang() {
  if command -v clang >/dev/null 2>&1; then
    command -v clang
    return 0
  fi
  local candidate
  candidate="$(ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null | sort -V | tail -1)"
  [[ -n "$candidate" ]] && printf '%s\n' "$candidate"
}

clang_bin="$(find_clang || true)"
if [[ -z "$clang_bin" ]]; then
  echo "drive.sh: required command is unavailable: clang" >&2
  exit 1
fi

"$repo/bin/beagle-ast" "$here/fixture.bclj" >"$scratch/fixture.ast.json"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  "$scratch/fixture.ast.json=beagle:native-core/validation/slice-unicode-text/fixture.bclj" \
  "$scratch/fixture.facts"

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bgl" \
  "$repo/native-core/src/native/worlds.bgl" \
  "$repo/native-core/src/native/lower.bgl" \
  "$repo/native-core/src/native/obligations.bgl" \
  "$repo/native-core/src/native/c11.bgl" \
  "$repo/native-core/src/native/slice.bgl" \
  "$repo/native-core/src/native/fold_c17.bgl" \
  "$repo/native-core/src/native/body_c17.bgl" \
  "$repo/native-core/src/native/body_slice.bgl" \
  "$repo/native-core/src/native/qbe.bgl" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,240p' "$scratch/build.log" >&2
    exit 1
  }

records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
  "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in worlds lower obligations c11 slice fold_c17 body_c17 body_slice qbe; do
  target="$scratch/out/native/$module.clj"
  [[ -f "$target" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' "$target"
  awk -v import="(import '[native.core $records])" \
    '!seen && /^$/ { print import; seen = 1 } { print }' \
    "$target" >"$target.tmp"
  mv "$target.tmp" "$target"
done

clojure -Sdeps "{:paths [\"$scratch/out\"]}" -M -e "
(require 'native.body-slice)
(spit \"$scratch/report.txt\"
  (native.body-slice/emit-dual-slice! \"$scratch/fixture.facts\"
    \"native.unicode-text\"
    \"beagle:native-core/validation/slice-unicode-text/fixture.bclj\"
    \"$scratch\" \"native-unicode-text-v0\" \"letter-decimal-runs\" 0))"

cat "$scratch/report.txt"
rg -q '^stage typed-to-native COMPLETE$' "$scratch/report.txt"
rg -q '^materialize OK module_0.h module_0.c$' "$scratch/report.txt"
rg -q '^qbe-materialize REFUSED QBE Unicode text primitive is unsupported: letter-decimal-runs$' \
  "$scratch/report.txt"
rg -Fxq '/* native-link-requirement icu-uc=72.1 */' "$scratch/module_0.c"
if rg -q '^obligation-projection FAIL' "$scratch/report.txt"; then
  echo "drive.sh: Unicode text projection failed a Native obligation" >&2
  exit 1
fi

function_index() {
  local name="$1"
  awk -v name="$name" \
    '$1 == "lowered" && $3 == name { sub(/^fn_/, "", $2); print $2 }' \
    "$scratch/report.txt"
}

lower_index="$(function_index lower-root)"
runs_index="$(function_index letter-decimal-runs)"
if [[ -z "$lower_index" || -z "$runs_index" ]]; then
  echo "drive.sh: failed to resolve Unicode text function indices" >&2
  exit 1
fi

clojure -M -e "
(load-file \"$here/managed_oracle.clj\")
(require 'native.unicode-text-oracle)
(assert (= \"straße i̇ σος café 𐐨\"
  (native.unicode-text-oracle/lower-root \"Straße İ ΣΟΣ CAFÉ 𐐀\")))
(assert (= [\"Café\" \"東京\" \"१२३\" \"e\" \"𐐀\"]
  (vec (native.unicode-text-oracle/letter-decimal-runs
    \"Café_東京-१२३ é Ⅻ ² 𐐀\"))))
(assert (= (native.unicode-text-oracle/age-boundary-runs)
  (vec (native.unicode-text-oracle/letter-decimal-runs
    (native.unicode-text-oracle/age-boundary-source)))))"

cp "$here/main.c" "$repo/native-core/shim/native_shim.c" \
  "$repo/native-core/shim/native_shim.h" "$scratch/"
definitions=(
  "-DLOWER_FN=native_m0_fn_$lower_index"
  "-DRUNS_FN=native_m0_fn_$runs_index"
  -DNATIVE_UNICODE_ICU
)
read -r -a icu_cflags <<<"$(pkg-config --cflags icu-uc)"
read -r -a icu_libs <<<"$(pkg-config --libs icu-uc)"
strict=(-std=c17 -pedantic -Wall -Wextra -Werror)

run_compiler() {
  local compiler="$1"
  local output="$2"
  (
    cd "$scratch"
    "$compiler" "${strict[@]}" "${definitions[@]}" "${icu_cflags[@]}" \
      -o "$output" module_0.c native_shim.c main.c "${icu_libs[@]}"
    "./$output"
  )
}

run_compiler gcc probe_gcc
run_compiler "$clang_bin" probe_clang

"$repo/bin/beagle-native-exe" \
  --out "$scratch/native-entry" \
  --artifacts "$scratch/native-entry.artifacts" \
  --entry native.unicode-text/native-entry \
  -- "$here/fixture.bclj" >"$scratch/native-exe.out"
"$scratch/native-entry"
[[ "$(wc -l <"$scratch/native-entry.artifacts/native-exe.report.txt")" -eq 2 ]]
rg -q '^native-exe-c17 PASS .* dependency=icu-uc@72.1$' \
  "$scratch/native-entry.artifacts/native-exe.report.txt"

echo "unicode-text: Locale.ROOT lowercasing, Unicode L*/Nd runs, Native obligations, strict GCC+Clang, and deterministic QBE refusal PASS"
