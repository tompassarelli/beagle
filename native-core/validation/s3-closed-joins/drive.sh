#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-s3-closed-joins.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "s3-closed-joins: $*" >&2
  exit 1
}

echo "s3-closed-joins: checking Core and hosted fixtures"
timeout --foreground 60s "$repo/bin/beagle" check --agent \
  "$here/fixture.bgl" \
  "$here/hosted_fixture.bclj" \
  "$here/hosted_fixture.bjs"

nix_project="$scratch/nix-project"
mkdir -p "$nix_project/.beagle-cache"
printf '[]\n' >"$nix_project/.beagle-cache/schema.json"
cp "$here/hosted_fixture.bnix" "$nix_project/fixture.bnix"

for target in clj js nix; do
  fixture="$here/hosted_fixture.b${target}"
  [[ "$target" == clj ]] && fixture="$here/hosted_fixture.bclj"
  [[ "$target" == nix ]] && fixture="$nix_project/fixture.bnix"
  echo "s3-closed-joins: building hosted $target fixture"
  timeout --foreground 60s "$repo/bin/beagle" build \
    --target "$target" "$fixture" "$scratch/hosted-$target"
done

echo "s3-closed-joins: materializing focused Native Core fixture"
base_compiled="${NATIVE_S3_BASE_COMPILED:-}"
if [[ -n "$base_compiled" ]]; then
  [[ -f "$base_compiled/native/core.clj" ]] \
    || die "base compiler projection omitted native/core.clj: $base_compiled"
  cp -a "$base_compiled" "$scratch/compiled"
  source "$repo/bin/_beagle-racket"
  mkdir -p "$scratch/lower"
  "$RACKET" "$repo/native-core/bin/run-bounded.rkt" 180 5 -- \
    "$repo/bin/beagle-build-all" \
    --module-root native-core/src="$repo/native-core/src" \
    "$repo/native-core/src/native/lower.bclj" \
    --out "$scratch/lower" >"$scratch/lower.log" 2>&1 \
    || { sed -n '1,240p' "$scratch/lower.log" >&2; exit 1; }
  cp "$scratch/lower/native/lower.clj" "$scratch/compiled/native/lower.clj"
  records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
    "$scratch/compiled/native/core.clj" | tr '\n' ' ')"
  generated="$scratch/compiled/native/lower.clj"
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$generated"
  awk -v import="(import '[native.core $records])" \
    '!seen && /^$/ { print import; seen = 1 } { print }' \
    "$generated" >"$generated.tmp"
  mv "$generated.tmp" "$generated"
  BEAGLE_CORE_COMPILED_OVERRIDE="$scratch/compiled" \
    timeout --foreground 600s "$repo/bin/beagle-native-exe" \
      --out "$scratch/s3-closed-joins-fixture" \
      --artifacts "$scratch/artifacts" \
      --entry native.s3-closed-joins/main \
      -- "$here/fixture.bgl"
else
  timeout --foreground 600s "$repo/bin/beagle-native-exe" \
    --out "$scratch/s3-closed-joins-fixture" \
    --artifacts "$scratch/artifacts" \
    --entry native.s3-closed-joins/main \
    -- "$here/fixture.bgl"
fi

"$scratch/s3-closed-joins-fixture" \
  || die "the widened and checked-extracted boundary values changed"

report="$scratch/artifacts/report.txt"
header="$scratch/artifacts/module_0.h"
[[ -f "$report" ]] || die "Native Core report is missing"
[[ -f "$header" ]] || die "C17 header is missing"

for expected in \
    'stage source-to-typed ACCEPTED' \
    'stage typed-to-native COMPLETE' \
    'materialize-c17 OK module_0.h module_0.c' \
    'result PASS'; do
  rg -Fx "$expected" "$report" >/dev/null \
    || die "report is missing: $expected"
done

for shape in \
    'TODO-NATIVE-MAP-LITERAL-ITEMS' \
    'TODO-NATIVE-WIDEN-TARGET' \
    'TODO-NATIVE-WIDEN-SOURCE'; do
  if rg -F "$shape" "$report" >/dev/null; then
    die "focused report retained S3 rejection: $shape"
  fi
done

function_index() {
  local function="$1"
  awk -v fn_name="$function" \
    '$1 == "lowered" && $2 ~ /^fn_[0-9]+$/ && $3 == fn_name {
       sub(/^fn_/, "", $2)
       print $2
       found = 1
       exit
     }
     END { exit !found }' \
    "$report"
}

return_type() {
  local function="$1"
  local index
  index="$(function_index "$function")" \
    || die "lowered function is missing: $function"
  sed -nE \
    "s/^(native_m0_type_[0-9]+) native_m0_fn_${index}\\(.*/\\1/p" \
    "$header"
}

int_first_type="$(return_type int-first)"
text_first_type="$(return_type text-first)"
[[ -n "$int_first_type" && -n "$text_first_type" ]] \
  || die "could not resolve mixed-branch return types"
[[ "$int_first_type" == "$text_first_type" ]] \
  || die "reversed finite-union members minted different native identities"

rg -q '^native-exe-c17 PASS ' \
  "$scratch/artifacts/native-exe.report.txt" \
  || die "Native executable report did not pass"

echo "s3-closed-joins: deterministic finite union, heterogeneous map, and bidirectional boundary coercion PASS"
