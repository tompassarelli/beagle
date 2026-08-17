#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/revision-generation.XXXXXX")"
trap 'rm -rf "${work:?}"' EXIT

source_file="$repo/branch-core/src/fram/revision_generation.bgl"
driver="$repo/branch-core/native/revision_generation_driver.c"
generated="$work/generated"
mkdir -p "$generated"

"$repo/bin/beagle" build --materializer c17 --out "$generated" \
  "$source_file" >"$work/build.log" 2>&1 || {
  sed -n '1,240p' "$work/build.log" >&2
  exit 1
}

grep -qx 'result PASS' "$generated/report.txt"
grep -qx 'epoch-regions-minted 1' "$generated/report.txt"
grep -qx 'lowered fn_7 hydrate-generation 6 blocks' \
  "$generated/native.entry-map"
[[ "$(grep -c 'native_value_promote' "$generated/module_0.c")" == 1 ]]
[[ "$(grep -c 'native_arena native_epoch_' "$generated/module_0.c")" == 1 ]]
grep -q 'native_arena_destroy' "$generated/module_0.c"

cc_bin="${CC:-cc}"
command -v "$cc_bin" >/dev/null 2>&1 || {
  echo "revision generation: C compiler is required" >&2
  exit 2
}

strict=(-std=c17 -pedantic -Wall -Wextra -Werror)
sources=("$generated/module_0.c" "$generated/native_shim.c" "$driver")
"$cc_bin" "${strict[@]}" -I"$generated" "${sources[@]}" \
  -o "$work/revision-generation"

sanitize=(-fsanitize=address,undefined -fno-sanitize-recover=all
          -fno-omit-frame-pointer -g)
"$cc_bin" "${strict[@]}" "${sanitize[@]}" -I"$generated" \
  "${sources[@]}" -o "$work/revision-generation-sanitized"

ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
  "$work/revision-generation-sanitized" acceptance \
  | tee "$work/sanitized-acceptance.txt"
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
  "$work/revision-generation-sanitized" managed 64 4096 \
  >"$work/sanitized-managed.txt"

iterations=512
payload_bytes=65536
"$work/revision-generation" baseline "$iterations" "$payload_bytes" \
  | tee "$work/baseline.txt"
"$work/revision-generation" managed "$iterations" "$payload_bytes" \
  | tee "$work/managed.txt"

field() {
  local path="$1"
  local name="$2"
  awk -v name="$name" '{
    for (i = 1; i <= NF; i++) {
      if ($i == name) {
        print $(i + 1)
        exit
      }
    }
  }' "$path"
}

baseline_epochs="$(field "$work/baseline.txt" store-epoch-count)"
managed_epochs="$(field "$work/managed.txt" store-epoch-count)"
baseline_promotions="$(field "$work/baseline.txt" promotion-count)"
managed_promotions="$(field "$work/managed.txt" promotion-count)"
managed_reclaimed="$(field "$work/managed.txt" bytes-reclaimed)"
baseline_steady="$(field "$work/baseline.txt" steady-arena-bytes)"
managed_steady="$(field "$work/managed.txt" steady-arena-bytes)"

[[ "$baseline_epochs" == 1 ]]
[[ "$managed_epochs" == "$iterations" ]]
[[ "$baseline_promotions" == "$iterations" ]]
[[ "$managed_promotions" == "$iterations" ]]
(( managed_reclaimed > 0 ))
(( managed_steady < baseline_steady ))

echo "revision generation sanitizer: ASan+UBSan clean"
echo "revision generation churn: managed reclaimed $managed_reclaimed bytes; " \
     "steady arena $managed_steady vs baseline $baseline_steady bytes"
echo "revision generation materialization: 1 epoch region, 1 promote site, " \
     "10/10 obligations PASS"
