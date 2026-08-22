#!/usr/bin/env bash
# One closed native program exercises immutable record assoc end to end: core
# validation negatives, C17 arena-copy emission, QBE refusal, and two C fronts.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_RECORD_ASSOC_REPO:-$(cd "$here/../../.." && pwd)}"
artifacts="${NATIVE_RECORD_ASSOC_ARTIFACTS:-}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-record-assoc.XXXXXX")"
[[ -n "$artifacts" ]] || artifacts="$scratch/artifacts"
trap 'rm -rf "${scratch:?}"' EXIT

mkdir -p "$scratch/out" "$scratch/c" "$artifacts"

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
  "$repo/native-core/src/native/simd.bclj" \
  "$repo/native-core/src/native/fold_c17.bclj" \
  "$repo/native-core/src/native/body_c17.bclj" \
  "$repo/native-core/src/native/qbe.bclj" \
  "$repo/native-core/src/native/validation_corpus.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,200p' "$scratch/build.log" >&2
    exit 1
  }

# Imported union variants need the provider records referred and imported in
# the emitted Clojure target until cross-module match qualification lands.
core_records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
  "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in stages obligations simd fold_c17 body_c17 qbe validation_corpus; do
  generated="$scratch/out/native/$module.clj"
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$generated"
  awk -v import="(import '[native.core $core_records])" \
    '!seen && /^$/ { print import; seen = 1 } { print }' \
    "$generated" >"$generated.tmp"
  mv "$generated.tmp" "$generated"
done

bb -cp "$scratch/out" -e "
(require 'native.validation-corpus 'native.body-c17 'native.qbe)
(let [program native.validation-corpus/record-assoc-program
      body-result (native.body-c17/materialize-program program 0)
      qbe-result (native.qbe/materialize-program program 0 \"lp64\")
      qbe-detail \"native program uses a shape outside the QBE materializer's slice\"]
  (when-not native.validation-corpus/record-assoc-corpus-passes?
    (throw (ex-info \"record assoc validation corpus failed\" {})))
  (when-not (native.body-c17/materialization-ok? body-result)
    (throw (ex-info (native.body-c17/materialization-detail body-result) {})))
  (when-not (and (instance? native.qbe.QbeFailure qbe-result)
                 (= qbe-detail (native.qbe/qbefailure-detail qbe-result)))
    (throw (ex-info \"QBE did not explicitly refuse record assoc\" {})))
  (let [artifact (native.body-c17/materialization-artifact body-result)]
    (spit (str \"$artifacts/\" (native.body-c17/bodyartifactv0-header-name artifact))
      (native.body-c17/bodyartifactv0-header-text artifact))
    (spit (str \"$artifacts/\" (native.body-c17/bodyartifactv0-source-name artifact))
      (native.body-c17/bodyartifactv0-source-text artifact)))
  (spit \"$artifacts/report.txt\"
    (str \"valid-record-assoc ACCEPTED\\n\"
         \"foreign-field REJECTED\\n\"
         \"wrong-field-type REJECTED\\n\"
         \"non-arena-handle REJECTED\\n\"
         \"wrong-source-record REJECTED\\n\"
         \"qbe-record-assoc EXPLICIT-REFUSAL\\n\")))"

cp "$artifacts/module_0.h" "$artifacts/module_0.c" "$here/main.c" "$scratch/c/"
cp "$repo/native-core/shim/native_shim.c" \
  "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$scratch/c/"

pair_type="$(sed -nE 's/^(native_m0_type_[0-9]+) native_m0_fn_0\(.*/\1/p' \
  "$artifacts/module_0.h")"
[[ -n "$pair_type" ]] || {
  echo "drive.sh: could not resolve record-assoc result type" >&2
  exit 1
}

strict=(-std=c17 -pedantic -Wall -Wextra -Werror)
(cd "$scratch/c" && gcc "${strict[@]}" -DASSOC_PAIR_TYPE="$pair_type" \
  -o probe_gcc module_0.c native_shim.c main.c)
"$scratch/c/probe_gcc"

clang_bin="$(command -v clang 2>/dev/null || true)"
if [[ -z "$clang_bin" ]]; then
  clang_bin="$(find /nix/store -maxdepth 3 -type f \
    -path '*-clang-wrapper-*/bin/clang' -print | sort -V | tail -1)"
fi
[[ -n "$clang_bin" ]] || {
  echo "drive.sh: clang is required for the second C17 frontend" >&2
  exit 1
}
(cd "$scratch/c" && "$clang_bin" "${strict[@]}" \
  -DASSOC_PAIR_TYPE="$pair_type" \
  -o probe_clang module_0.c native_shim.c main.c)
"$scratch/c/probe_clang"

cat >"$artifacts/checks.txt" <<EOF
gcc $(gcc -dumpversion) -std=c17 -pedantic -Wall -Wextra -Werror compile+run PASS
clang $("$clang_bin" -dumpversion) -std=c17 -pedantic -Wall -Wextra -Werror compile+run PASS
EOF
cat "$artifacts/report.txt" "$artifacts/checks.txt"
