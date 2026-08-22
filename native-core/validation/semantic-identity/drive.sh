#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-semantic-identity.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

codec="$repo/native-core/src/beagle/semantic_identity.bgl"
fixture="$here/fixture.bgl"

timeout --foreground 30s "$repo/bin/beagle" syntax "$codec" "$fixture"
timeout --foreground 30s "$repo/bin/beagle" check --agent "$codec" "$fixture"
timeout --foreground 90s "$repo/bin/beagle-native-exe" \
  --out "$scratch/semantic-identity" \
  --artifacts "$scratch/artifacts" \
  --entry beagle.semantic-identity-fixture/main \
  -- "$codec" "$fixture"
timeout --foreground 10s "$scratch/semantic-identity"

echo "semantic-identity: framed typed identities and rejection boundaries PASS"
