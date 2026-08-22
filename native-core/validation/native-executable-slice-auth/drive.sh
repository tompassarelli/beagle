#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-executable-slice-auth.XXXXXX")"
generated="$scratch/generated"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "native-executable-slice-auth: $*" >&2
  exit 1
}

for command in bb gcc rg; do
  command -v "$command" >/dev/null 2>&1 \
    || die "required command is unavailable: $command"
done
mkdir -p "$generated"

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
  "$here/fixture.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,260p' "$scratch/build.log" >&2
    exit 1
  }

records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
  "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in stages lower obligations simd c11 slice fold_c17 body_c17 qbe; do
  [[ -f "$scratch/out/native/$module.clj" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$scratch/out/native/$module.clj"
  awk -v imp="(import '[native.core $records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' \
    "$scratch/out/native/$module.clj" >"$scratch/out/native/$module.clj.tmp"
  mv "$scratch/out/native/$module.clj.tmp" "$scratch/out/native/$module.clj"
done

module="native_executable_slice_auth_fixture"
awk -v imp="(import '[native.core $records])" \
  '!seen && /^$/ { print imp; seen = 1 } { print }' \
  "$scratch/out/native/$module.clj" >"$scratch/out/native/$module.clj.tmp"
mv "$scratch/out/native/$module.clj.tmp" "$scratch/out/native/$module.clj"

bb -cp "$scratch/out" -e "
(require 'native.native-executable-slice-auth-fixture)
(print
  (native.native-executable-slice-auth-fixture/emit-slice-auth! \"$generated\"))" \
  >"$scratch/run.log"

report="$generated/report.txt"
[[ -f "$generated/module_0.h" ]] || die "C header was not materialized"
[[ -f "$generated/module_0.c" ]] || die "C source was not materialized"
[[ -f "$report" ]] || die "slice report was not materialized"

for line in \
  'native-executable-slice-auth: PASS' \
  'input-kind typed-compatibility-v0' \
  'changed-slice reminted' \
  'invalid-frozen-stage rejected' \
  'top-level-permutation stable' \
  'noncanonical-top-level rejected' \
  'duplicate-keyed-declaration rejected' \
  'representative-field-mutations distinct' \
  'optional-id-sentinels distinct' \
  'prepared-sentinel-forgery rejected' \
  'frozen-stage-payload-tamper rejected' \
  'content-id-helper reminted' \
  'derived-projection identity reminted' \
  'pending executable carrier absent' \
  'pending output digest absent' \
  'deterministic-identity true' \
  'materialize module_0.h module_0.c'; do
  rg -Fx "$line" "$report" >/dev/null \
    || { cat "$report" >&2; die "report is missing: $line"; }
done
[[ "$(rg -c '^input-digest sha256:[0-9a-f]{64}$' "$report")" -eq 1 ]] \
  || die "actual slice input digest is missing or malformed"
[[ "$(rg -c '^changed-input-digest sha256:[0-9a-f]{64}$' "$report")" -eq 1 ]] \
  || die "changed slice input digest is missing or malformed"
if rg -n 'OrientedPlan|FrozenOriented|freeze-oriented|CheckedFactClosure' \
    "$report" "$here/fixture.bclj" \
    "$repo/native-core/src/native/lower.bclj" >/dev/null; then
  die "slice authentication claims unverified plan provenance"
fi
if rg -n --glob '*.bclj' --glob '*.clj' \
    'nativeloweringpendingv0-frozen|slice/native-frozen' \
    "$repo/native-core/src" "$repo/native-core/validation" >/dev/null; then
  die "incomplete Native lowering still exposes executable content"
fi

build="$scratch/c"
mkdir -p "$build"
cp "$generated/module_0.h" "$generated/module_0.c" "$here/main.c" "$build/"
cp "$repo/native-core/shim/native_shim.c" \
  "$repo/native-core/shim/native_shim.h" \
  "$repo/native-core/shim/native_unicode15_data.h" "$build/"

(cd "$build" && gcc -std=c17 -pedantic -Wall -Wextra -Werror \
  -o native_slice_probe module_0.c native_shim.c main.c)
(cd "$build" && ./native_slice_probe)

cat "$report"
echo "native-executable-slice-auth: gcc $(gcc -dumpversion) strict C17 compile + run PASS"
