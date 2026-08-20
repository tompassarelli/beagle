#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/region-decl-v1.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

echo "region-decl-v1: checking typed graph contract"
timeout --foreground 30s "$repo/bin/beagle" check --agent \
  "$repo/native-core/src/beagle/region_decl_v1.bgl" \
  "$here/fixture.bgl"

echo "region-decl-v1: building direct Native fixture"
timeout --foreground 30s "$repo/bin/beagle" native-exe \
  --out "$scratch/region-decl-v1-fixture" \
  --entry native.region-decl-v1-fixture/main \
  "$repo/native-core/src/beagle/region_decl_v1.bgl" \
  "$here/fixture.bgl"

echo "region-decl-v1: running direct graph contract"
timeout --foreground 10s "$scratch/region-decl-v1-fixture"

echo "region-decl-v1: typed validation, stable scheduling, cycles, and identities PASS"
