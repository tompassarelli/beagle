#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-s7-pure-primitives.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "s7-pure-primitives: $*" >&2
  exit 1
}

timeout --foreground 30s "$repo/bin/beagle" check --agent "$here/fixture.bgl"

for target in clj js nix; do
  fixture="$here/hosted_fixture.b${target}"
  if [[ "$target" == clj ]]; then
    fixture="$here/hosted_fixture.bclj"
  fi
  timeout --foreground 60s "$repo/bin/beagle" build \
    --target "$target" "$fixture" "$scratch/$target"
done

timeout --foreground 180s "$repo/bin/beagle-native-exe" \
  --out "$scratch/s7-pure-primitives-fixture" \
  --artifacts "$scratch/artifacts" \
  --entry native.s7-pure-primitives/main \
  -- "$here/fixture.bgl"

timeout --foreground 10s "$scratch/s7-pure-primitives-fixture"
rg -q '^native-exe-c17 PASS ' \
  "$scratch/artifacts/native-exe.report.txt" \
  || die "Native executable report did not pass"

echo "s7-pure-primitives: last-index-of, double?, and ASCII/non-ASCII char round-trip PASS"
