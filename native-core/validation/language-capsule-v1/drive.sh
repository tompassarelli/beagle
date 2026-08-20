#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/language-capsule-v1.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

timeout --foreground 30s "$repo/bin/beagle" syntax \
  "$repo/native-core/src/beagle/language_capsule_v1.bgl"
timeout --foreground 30s "$repo/bin/beagle" syntax "$here/fixture.bgl"
timeout --foreground 30s "$repo/bin/beagle" check --agent \
  "$repo/native-core/src/beagle/language_capsule_v1.bgl" \
  "$here/fixture.bgl"
timeout --foreground 30s "$repo/bin/beagle-native-exe" \
  --out "$scratch/language-capsule-v1-fixture" \
  --artifacts "$scratch/artifacts" \
  --entry native.language-capsule-v1-fixture/main \
  -- "$repo/native-core/src/beagle/language_capsule_v1.bgl" \
  "$here/fixture.bgl"
timeout --foreground 10s "$scratch/language-capsule-v1-fixture"

echo "language-capsule-v1: semantic, provenance, grant, and receipt separation PASS"
