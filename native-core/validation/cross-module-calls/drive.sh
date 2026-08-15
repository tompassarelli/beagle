#!/usr/bin/env bash
# Multi-module Native Core composition: qualified cross-module calls lower
# like same-module calls across a three-module chain. Covers the alias-
# qualified call (bridge -> kernel), the transparent ref re-export
# (driver -> bridge/relay -> kernel/advance), and the fully-qualified call
# with no :require (driver -> native.kernel/scale), then proves the chain by
# executing the linked C17 program.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-cross-module.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "cross-module-calls: $*" >&2
  exit 1
}

compiler="$(command -v cc || command -v gcc)" || die "no C compiler available"

"$repo/bin/beagle" check --agent \
  "$here/kernel.bgl" "$here/bridge.bgl" "$here/driver.bgl"

mkdir -p "$scratch/artifacts"
"$repo/bin/beagle" native-exe \
  --out "$scratch/driver" \
  --entry native.driver/main \
  --cc "$compiler" \
  --artifacts "$scratch/artifacts" \
  "$here/kernel.bgl" "$here/bridge.bgl" "$here/driver.bgl" \
  >"$scratch/build.log"

"$scratch/driver" || die "driver executable rejected the cross-module results"

rg -qx 'stage typed-to-native COMPLETE' "$scratch/artifacts/report.txt" \
  || die "native lowering did not complete"
rg -qx 'source-modules 3' "$scratch/artifacts/report.txt" \
  || die "the three-module source set changed shape"
rg -q '^lowered .* advance ' "$scratch/artifacts/report.txt" \
  || die "kernel/advance did not lower"
rg -q '^lowered .* scale ' "$scratch/artifacts/report.txt" \
  || die "kernel/scale did not lower"
rg -q '^lowered .* doubled ' "$scratch/artifacts/report.txt" \
  || die "bridge/doubled did not lower"
rg -q '^lowered .* main ' "$scratch/artifacts/report.txt" \
  || die "driver/main did not lower"
rg -q 'TODO-NATIVE-CALL' "$scratch/artifacts/report.txt" \
  && die "a qualified cross-module call failed to lower"

echo "drive.sh: qualified cross-module calls lowered and executed across the three-module chain"
