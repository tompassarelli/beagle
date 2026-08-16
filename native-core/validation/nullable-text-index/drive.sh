#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-nullable-text-index.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "nullable-text-index: $*" >&2
  exit 1
}

if rg -Fq 'Int?' "$here/fixture.bgl"; then
  die "fixture must not declare the hidden nullable index type"
fi

echo "nullable-text-index: checking typed source"
timeout --foreground 30s "$repo/bin/beagle" check --agent \
  "$here/fixture.bgl"

echo "nullable-text-index: building focused Native executable"
timeout --foreground 180s "$repo/bin/beagle-native-exe" \
  --out "$scratch/nullable-text-index-fixture" \
  --artifacts "$scratch/artifacts" \
  --entry native.nullable-text-index-fixture/main \
  -- "$here/fixture.bgl"

echo "nullable-text-index: running found/not-found contract"
timeout --foreground 10s "$scratch/nullable-text-index-fixture"

rg -q '^native-exe-c17 PASS ' \
  "$scratch/artifacts/native-exe.report.txt" \
  || die "Native executable report did not pass"

echo "nullable-text-index: implicit nullable Int closure and found/not-found behavior PASS"
