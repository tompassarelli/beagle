#!/usr/bin/env bash
set -euo pipefail

abi="${NATIVE_SLICE_ABI:-lp64}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-unicode-text.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

for command in awk bb clojure cmp gcc readelf rg strings; do
  command -v "$command" >/dev/null || {
    echo "drive.sh: required command is unavailable: $command" >&2
    exit 1
  }
done

unicode_data="${NATIVE_UNICODE_DATA15:-}"
special_casing="${NATIVE_SPECIAL_CASING15:-}"
derived_core_properties="${NATIVE_DERIVED_CORE_PROPERTIES15:-}"
musl_cc="${NATIVE_MUSL_CC:-}"
for source in "$unicode_data" "$special_casing" "$derived_core_properties"; do
  [[ -f "$source" ]] || {
    echo "drive.sh: enter the pinned flake dev shell to provide Unicode 15 inputs" >&2
    exit 1
  }
done
[[ -x "$musl_cc" ]] || {
  echo "drive.sh: enter the pinned flake dev shell to provide NATIVE_MUSL_CC" >&2
  exit 1
}

runtime_version="$(clojure -M -e '(print (System/getProperty "java.runtime.version"))')"
[[ "$runtime_version" == 21.0.12+2* ]] || {
  echo "drive.sh: exact OpenJDK 21.0.12+2 oracle is required, found $runtime_version" >&2
  exit 1
}

clojure -M "$repo/native-core/bin/generate-unicode15-tables.clj" \
  "$unicode_data" "$special_casing" "$derived_core_properties" \
  "$scratch/native_unicode15_data.generated.h"
cmp "$repo/native-core/shim/native_unicode15_data.h" \
  "$scratch/native_unicode15_data.generated.h"

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
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
  "$repo/native-core/src/native/lower.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
  "$repo/native-core/src/native/c11.bclj" \
  "$repo/native-core/src/native/slice.bclj" \
  "$repo/native-core/src/native/fold_c17.bclj" \
  "$repo/native-core/src/native/body_c17.bclj" \
  "$repo/native-core/src/native/body_slice.bclj" \
  "$repo/native-core/src/native/qbe.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,240p' "$scratch/build.log" >&2
    exit 1
  }

records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
  "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in stages lower obligations c11 slice fold_c17 body_c17 body_slice qbe; do
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
    \"$scratch\" \"native-unicode-text-v0\" \"letter-decimal-runs\" 0 \"$abi\"))"

cat "$scratch/report.txt"
rg -q '^stage typed-to-native COMPLETE$' "$scratch/report.txt"
rg -q '^materialize OK module_0.h module_0.c$' "$scratch/report.txt"
rg -q '^qbe-materialize REFUSED QBE Unicode text primitive is unsupported: letter-decimal-runs$' \
  "$scratch/report.txt"
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
(assert (= [\"aς:b\" \"aσ.b\" \"aς’b\" \"aσ-b\"
            \"aς1:b\" \"aσ1.2b\" \"aς東京b\" \"aσ́b\"]
  (mapv native.unicode-text-oracle/lower-root
    [\"AΣ:B\" \"AΣ.B\" \"AΣ’B\" \"AΣ-B\"
     \"AΣ1:B\" \"AΣ1.2B\" \"AΣ東京B\" \"AΣ́B\"])))
(assert (= \"straße i̇ σος café 𐐨\"
  (native.unicode-text-oracle/lower-root \"Straße İ ΣΟΣ CAFÉ 𐐀\")))
(assert (= [\"Café\" \"東京\" \"१२३\" \"e\" \"𐐀\"]
  (vec (native.unicode-text-oracle/letter-decimal-runs
    \"Café_東京-१२३ éͅ Ⅻ ² 𐐀\"))))
(assert (= (native.unicode-text-oracle/age-boundary-runs)
  (vec (native.unicode-text-oracle/letter-decimal-runs
    (native.unicode-text-oracle/age-boundary-source)))))"

cp "$here/main.c" "$repo/native-core/shim/native_shim.c" \
  "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$scratch/"
definitions=(
  "-DLOWER_FN=native_m0_fn_$lower_index"
  "-DRUNS_FN=native_m0_fn_$runs_index"
)
strict=(-std=c17 -pedantic -Wall -Wextra -Werror)

run_compiler() {
  local compiler="$1"
  local output="$2"
  (
    cd "$scratch"
    "$compiler" "${strict[@]}" "${definitions[@]}" \
      -o "$output" module_0.c native_shim.c main.c
    "./$output"
  )
}

run_compiler gcc probe_gcc
run_compiler "$clang_bin" probe_clang

cp "$here/exhaustive.c" "$scratch/"
gcc "${strict[@]}" -I "$scratch" -o "$scratch/exhaustive" \
  "$scratch/native_shim.c" "$scratch/exhaustive.c"
clojure -M "$here/exhaustive_oracle.clj" >"$scratch/exhaustive-managed.bin"
"$scratch/exhaustive" >"$scratch/exhaustive-native.bin"
cmp "$scratch/exhaustive-managed.bin" "$scratch/exhaustive-native.bin"

"$repo/bin/beagle-native-exe" \
  --cc "$musl_cc" \
  --static \
  --out "$scratch/native-entry" \
  --artifacts "$scratch/native-entry.artifacts" \
  --entry native.unicode-text/native-entry \
  -- "$here/fixture.bclj" >"$scratch/native-exe.out"
"$scratch/native-entry"
[[ "$(wc -l <"$scratch/native-entry.artifacts/native-exe.report.txt")" -eq 2 ]]
rg -q '^native-exe-c17 PASS .* output=.*native-entry$' \
  "$scratch/native-entry.artifacts/native-exe.report.txt"

if readelf -l "$scratch/native-entry" | rg -q 'INTERP'; then
  echo "drive.sh: musl artifact has a program interpreter" >&2
  exit 1
fi
if readelf -d "$scratch/native-entry" | rg -q 'NEEDED'; then
  echo "drive.sh: musl artifact has a dynamic dependency" >&2
  exit 1
fi
if strings "$scratch/native-entry" | rg -q '/nix/store/'; then
  echo "drive.sh: musl artifact embeds a Nix store path" >&2
  exit 1
fi

echo "unicode-text: exact OpenJDK 21 Unicode 15 parity, deterministic tables, strict GCC+Clang, static musl, Native obligations, and deterministic QBE refusal PASS"
