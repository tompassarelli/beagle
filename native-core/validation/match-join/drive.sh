#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-match-join.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "match-join: $*" >&2
  exit 1
}

echo "match-join: checking typed provider and consumer"
timeout --foreground 30s "$repo/bin/beagle" check --agent \
  "$here/provider.bgl" "$here/consumer.bgl"

echo "match-join: building focused Native executable"
timeout --foreground 180s "$repo/bin/beagle-native-exe" \
  --out "$scratch/match-join-fixture" \
  --artifacts "$scratch/artifacts" \
  --entry native.match-join-consumer/main \
  -- "$here/provider.bgl" "$here/consumer.bgl"

echo "match-join: running both optional-result match arms"
runtime_stdout=""
if ! runtime_stdout="$(timeout --foreground 10s \
  "$scratch/match-join-fixture")"; then
  die "Native executable rejected an optional-result match arm"
fi
[[ "$runtime_stdout" == "missing" ]] \
  || die "first Nil arm did not preserve its side effect"

rg -qx 'stage typed-to-native COMPLETE' "$scratch/artifacts/report.txt" \
  || die "native lowering did not complete"
rg -qx 'source-modules 2' "$scratch/artifacts/report.txt" \
  || die "provider/consumer source set changed shape"
rg -q '^lowered .* loaded ' "$scratch/artifacts/report.txt" \
  || die "imported vector optional-result match did not lower"
rg -q '^lowered .* choose ' "$scratch/artifacts/report.txt" \
  || die "local String optional-result match did not lower"
if rg -q 'TODO-NATIVE-WIDEN-SOURCE' "$scratch/artifacts/report.txt"; then
  die "a match arm still widened to the first live arm"
fi
rg -q '^native-exe-c17 PASS ' \
  "$scratch/artifacts/native-exe.report.txt" \
  || die "Native executable report did not pass"

echo "match-join: heterogeneous match arms joined to optional results PASS"
