#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_C17_I64_LITERAL_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-c17-i64-literals.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "c17-i64-literals/drive.sh: $*" >&2
  exit 1
}

for command in awk gcc rg timeout; do
  command -v "$command" >/dev/null 2>&1 \
    || die "required command is unavailable: $command"
done

artifacts="$scratch/artifacts"
timeout --foreground --kill-after=10s 180s "$repo/bin/beagle" build \
  --materializer c17 --out "$artifacts" "$here/fixture.bgl" \
  >"$scratch/build.log" 2>&1 \
  || { sed -n '1,240p' "$scratch/build.log" >&2
       die "Native build failed or exceeded 180s"; }

report="$artifacts/report.txt"
source="$artifacts/module_0.c"
for expected in \
  'stage source-to-typed ACCEPTED' \
  'stage typed-to-native COMPLETE' \
  'materialize-c17 OK module_0.h module_0.c' \
  'result PASS'; do
  rg -Fx "$expected" "$report" >/dev/null \
    || die "build report is missing: $expected"
done

minimum_index="$(awk '$1 == "lowered" && $3 == "minimum" {
  sub(/^fn_/, "", $2); print $2
}' "$report")"
nearby_index="$(awk '$1 == "lowered" && $3 == "nearby-negative" {
  sub(/^fn_/, "", $2); print $2
}' "$report")"
[[ "$minimum_index" =~ ^[0-9]+$ ]] || die "minimum function index is absent"
[[ "$nearby_index" =~ ^[0-9]+$ ]] \
  || die "nearby-negative function index is absent"

if rg -F 'INT64_C(-9223372036854775808)' "$source" >/dev/null; then
  die "minimum Int retained the oversized positive preprocessing token"
fi
rg -F '= INT64_MIN;' "$source" >/dev/null \
  || die "minimum Int did not use INT64_MIN"
rg -F '= INT64_C(-7);' "$source" >/dev/null \
  || die "ordinary negative Int spelling changed"

cp "$artifacts/module_0.h" "$source" "$here/main.c" \
  "$repo/native-core/shim/native_shim.c" \
  "$repo/native-core/shim/native_shim.h" \
  "$repo/native-core/shim/native_unicode15_data.h" "$scratch/"

(
  cd "$scratch"
  gcc -std=c17 -pedantic -Wall -Wextra -Werror \
    "-DMINIMUM_FN=native_m0_fn_${minimum_index}" \
    "-DNEARBY_NEGATIVE_FN=native_m0_fn_${nearby_index}" \
    -o probe module_0.c native_shim.c main.c
  ./probe
)

echo "c17-i64-literals: INT64_MIN and ordinary negative strict compile + run PASS"
