#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-transient-vec.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

fixture="$here/fixture.bgl"
artifacts="$scratch/c17"
build_log="$scratch/c17-build.log"

die() {
  echo "slice-transient-vec/drive.sh: $*" >&2
  exit 1
}

for command in awk gcc rg timeout; do
  command -v "$command" >/dev/null 2>&1 \
    || die "required command is unavailable: $command"
done

if ! timeout --foreground --kill-after=10s 180s \
    "$repo/bin/beagle" build --materializer c17 --out "$artifacts" \
    "$fixture" >"$build_log" 2>&1; then
  sed -n '1,240p' "$build_log" >&2
  die "C17 build failed or exceeded 180s"
fi

report="$artifacts/report.txt"
for expected in \
  'stage source-to-typed ACCEPTED' \
  'stage typed-to-native COMPLETE' \
  'native-lowering-result NativeLoweringCompleteV0' \
  'materialize-c17 OK module_0.h module_0.c' \
  'result PASS'; do
  rg -Fx "$expected" "$report" >/dev/null \
    || die "build report is missing: $expected"
done
[[ "$(rg -c '^obligation-projection PASS ' "$report")" -eq 10 ]] \
  || die "Native program did not pass all ten obligations"
if rg -q '^pending ' "$report"; then
  rg '^pending ' "$report" >&2
  die "fixture left a Native lowering root"
fi

function_index() {
  local name="$1"
  awk -v name="$name" \
    '$1 == "lowered" && $3 == name { sub(/^fn_/, "", $2); print $2 }' \
    "$report"
}

build_index="$(function_index 'build-ordered!')"
copy_index="$(function_index 'copy-nonempty!')"
[[ "$build_index" =~ ^[0-9]+$ ]] \
  || die "build-ordered! function index is unresolved"
[[ "$copy_index" =~ ^[0-9]+$ ]] \
  || die "copy-nonempty! function index is unresolved"

gcc -std=c17 -pedantic -Wall -Wextra -Werror \
  -DBUILD_ORDERED_FN="native_m0_fn_$build_index" \
  -DCOPY_NONEMPTY_FN="native_m0_fn_$copy_index" \
  -I "$artifacts" "$artifacts/module_0.c" "$artifacts/native_shim.c" \
  "$here/main.c" -lm -o "$scratch/probe"
timeout --foreground --kill-after=2s 20s "$scratch/probe"

qbe_out="$scratch/qbe"
qbe_log="$scratch/qbe-build.log"
set +e
timeout --foreground --kill-after=5s 60s \
  "$repo/bin/beagle" build --materializer qbe --out "$qbe_out" \
  "$fixture" >"$qbe_log" 2>&1
qbe_status=$?
set -e
[[ $qbe_status -ne 0 && $qbe_status -ne 124 ]] \
  || die "QBE did not fail closed for TransientVec"
rg -E 'REFUSED .*QBE.*(TransientVec|transient vector)|QBE.*(TransientVec|transient vector).*unsupported' \
  "$qbe_log" >/dev/null \
  || die "QBE refusal did not identify unsupported TransientVec materialization"
[[ ! -e "$qbe_out/report.txt" && ! -e "$qbe_out/module_0.ssa" ]] \
  || die "refused QBE build published materialization artifacts"

echo "slice-transient-vec/drive.sh: C17 builder and QBE refusal checks passed"
