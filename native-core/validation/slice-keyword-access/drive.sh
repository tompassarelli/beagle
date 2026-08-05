#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-$here}"
src="$here/fixture.bclj"
provider="$here/provider.bclj"
collision="$here/collision.bclj"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-keyword-access.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

"$repo/bin/beagle-ast" "$src" >"$scratch/fixture.ast.json"
"$repo/bin/beagle-ast" "$provider" >"$scratch/provider.ast.json"
"$repo/bin/beagle-ast" "$collision" >"$scratch/collision.ast.json"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  --input "$scratch/fixture.ast.json=native-core/validation/slice-keyword-access/fixture.bclj" \
  --input "$scratch/provider.ast.json=native-core/validation/slice-keyword-access/provider.bclj" \
  --output "$scratch/fixture.facts"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  --input "$scratch/fixture.ast.json=native-core/validation/slice-keyword-access/fixture.bclj" \
  --input "$scratch/provider.ast.json=native-core/validation/slice-keyword-access/provider.bclj" \
  --input "$scratch/collision.ast.json=native-core/validation/slice-keyword-access/collision.bclj" \
  --output "$scratch/collision.facts"
if [[ -f "$art/fixture.facts" ]] && ! cmp -s "$scratch/fixture.facts" "$art/fixture.facts"; then
  echo "drive.sh: regenerated projection differs from the committed fixture.facts" >&2
  exit 1
fi
cp "$scratch/fixture.facts" "$art/fixture.facts"
sha256sum "$src" "$provider" | sed "s#  $here/#  #" >"$art/source.sha256"

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
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || { sed -n '1,200p' "$scratch/build.log" >&2; exit 1; }

records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in worlds lower obligations c11 slice fold_c17 body_c17 body_slice qbe; do
  [[ -f "$scratch/out/native/$module.clj" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$scratch/out/native/$module.clj"
  awk -v imp="(import '[native.core $records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' \
    "$scratch/out/native/$module.clj" >"$scratch/out/native/$module.clj.tmp"
  mv "$scratch/out/native/$module.clj.tmp" "$scratch/out/native/$module.clj"
done

clojure -Sdeps "{:paths [\"$scratch/out\"]}" -M -e "
(require 'native.body-slice)
(spit \"$art/report.txt\"
  (native.body-slice/emit-slice! \"$scratch/fixture.facts\"
    \"native.keyword-access\"
    \"native-core/validation/slice-keyword-access/fixture.bclj\"
    \"$art\" \"native-slice-keyword-access-v0\"))"
cat "$art/report.txt"

clojure -Sdeps "{:paths [\"$scratch/out\"]}" -M -e "
(require '[native.core :as core]
         '[native.lower :as lower]
         '[native.slice :as slice])
(let [rows (slice/parse-facts (slurp \"$scratch/collision.facts\"))
      world (slice/source-world rows \"native.keyword-access\"
              \"native-core/validation/slice-keyword-access/fixture.bclj\")
      configuration [\"profile=3\"]
      sealed (lower/sourcesealacceptedv0-sealed
               (lower/seal-source-world world \"native-record-identity-v0\"
                 configuration))
      result (lower/lower-typed-world sealed \"native-record-identity-v0\"
               configuration)]
  (when-not (instance? native.lower.TypingRejectedV0 result)
    (throw (ex-info \"same-module record shape collision was accepted\" {})))
  (let [diagnostics (core/passreceiptv0-diagnostics
                      (lower/typingrejectedv0-receipt result))]
    (when-not (some #(= \"LOWER-RECORD-ID-SHAPE-COLLISION\"
                         (core/diagnosticv0-code %)) diagnostics)
      (throw (ex-info \"record collision rejection omitted its diagnostic\" {})))
    (spit \"$art/collision-report.txt\"
      \"same-module different-shape record identity REJECTED LOWER-RECORD-ID-SHAPE-COLLISION\n\")))"

grep -q '^materialize OK ' "$art/report.txt"
grep -q 'TODO-NATIVE-KEYWORD-MAP-KEY' "$art/report.txt"
grep -q 'TODO-NATIVE-KEYWORD-ACCESS-TARGET' "$art/report.txt"
for function in map-code-value map-code-value-cond map-code-value-equal \
    map-version-value optional-map-branch map-reject-count \
    map-other-after-code-check map-code-from-other-source \
    map-code-false-arm imported-pair-value imported-pair-roundtrip \
    imported-pair-refined imported-optional-pair-value; do
  grep -Eq "^lowered [^ ]+ ${function} " "$art/report.txt"
done
grep -Fx 'source-modules 2' "$art/report.txt"
grep -Fx 'same-module different-shape record identity REJECTED LOWER-RECORD-ID-SHAPE-COLLISION' \
  "$art/collision-report.txt"
if grep -q '^obligation-projection FAIL' "$art/report.txt"; then
  echo "drive.sh: keyword-access projection failed a Native obligation" >&2
  exit 1
fi

clojure -Sdeps "{:paths [\"$scratch/out\"]}" -M \
  "$here/qbe-refusal.clj" "$scratch/fixture.facts" \
  "native.keyword-access" \
  "native-core/validation/slice-keyword-access/fixture.bclj" \
  "native-slice-keyword-access-v0"

if [[ -n "${NATIVE_SLICE_NO_COMPILE:-}" ]]; then
  exit 0
fi

build="$scratch/c"
mkdir -p "$build"
cp "$art/module_0.h" "$art/module_0.c" "$art/main.c" "$build/"
cp "$repo/native-core/shim/native_shim.c" "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$build/"

strict=(-std=c17 -pedantic -Wall -Wextra -Werror)
( cd "$build" && gcc "${strict[@]}" -o probe_gcc module_0.c native_shim.c main.c )
( cd "$build" && ./probe_gcc )
echo "drive.sh: gcc $(gcc -dumpversion) strict compile + run ok"

clang_bin="$(command -v clang 2>/dev/null || ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null | sort -V | tail -1)"
if [[ -z "$clang_bin" ]]; then
  echo "drive.sh: clang not found — second frontend NOT exercised" >&2
  exit 1
fi
( cd "$build" && "$clang_bin" "${strict[@]}" -o probe_clang module_0.c native_shim.c main.c )
( cd "$build" && ./probe_clang )
echo "drive.sh: clang $("$clang_bin" -dumpversion) strict compile + run ok"
