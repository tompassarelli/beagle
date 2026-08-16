#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-clock-capability.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "clock-capability: $*" >&2
  exit 1
}

for command in cc rg; do
  command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done
mkdir -p \
  "$scratch/source-c17" \
  "$scratch/source-qbe" \
  "$scratch/exe-artifacts"

"$repo/bin/beagle" check --agent "$here/clock_probe.bgl"
"$repo/bin/beagle" build --materializer c17 \
  --out "$scratch/source-c17" \
  "$here/clock_probe.bgl" >"$scratch/source-c17.log"

report="$scratch/source-c17/report.txt"
rg -Fx 'stage typed-to-native COMPLETE' "$report" >/dev/null \
  || die "canonical clock probe did not lower"
[[ "$(rg -c '^obligation-projection PASS ' "$report")" == "10" ]] \
  || die "canonical clock probe failed native obligations"
rg -Fx 'materialize-c17 OK module_0.h module_0.c' "$report" >/dev/null \
  || die "canonical clock probe did not materialize as C17"
for symbol in \
  native_host_clock_wall_nanoseconds_v0 \
  native_host_clock_format_iso8601_v0; do
  rg -F "$symbol" "$scratch/source-c17/module_0.c" >/dev/null \
    || die "missing C17 import: $symbol"
done

set +e
"$repo/bin/beagle" build --materializer qbe \
  --out "$scratch/source-qbe" \
  "$here/clock_probe.bgl" >"$scratch/source-qbe.log" 2>&1
qbe_status=$?
set -e
[[ $qbe_status -ne 0 ]] || die "QBE unexpectedly accepted the clock effect"
rg -Fx \
  'materialize-qbe REFUSED QBE monotonic clock extern ABI is unsupported: host clock reads have no QBE call representation' \
  "$scratch/source-qbe.log" >/dev/null \
  || die "QBE clock refusal changed"

cc -std=c17 -Wall -Wextra -Werror -pedantic \
  -I"$repo/native-core/shim" -I"$scratch/source-c17" \
  -c "$scratch/source-c17/module_0.c" -o "$scratch/module_0.o"

"$repo/bin/beagle-native-exe" \
  --out "$scratch/clock-probe" \
  --artifacts "$scratch/exe-artifacts" \
  --entry native.clock-probe/probe \
  -- "$here/clock_probe.bgl" >"$scratch/native-exe.log"
set +e
"$scratch/clock-probe" \
  >"$scratch/source-runtime.out" 2>"$scratch/source-runtime.err"
source_status=$?
set -e
[[ $source_status -eq 0 ]] \
  || die "typed source clock probe returned $source_status"

cc -std=c17 -Wall -Wextra -Werror -pedantic \
  -I"$repo/native-core/shim" \
  "$here/main.c" "$repo/native-core/shim/native_shim.c" \
  -o "$scratch/clock-capability"
"$scratch/clock-capability" >"$scratch/runtime.out"
rg -Fx 'clock capability shim fixture: ok' "$scratch/runtime.out" >/dev/null \
  || die "runtime clock contract failed"

cat "$report"
cat "$scratch/runtime.out"
echo "clock capability fixture: typed wall clock and exact ISO-8601 formatting pass"
