#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/store-branch-revision.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

codec="$repo/native-core/src/beagle/semantic_identity.bgl"
slots="$repo/store/src/store/slots.bgl"
types="$repo/store/src/store/types.bgl"
store="$repo/store/src/store/store.bgl"
limits="$repo/store/src/store/rpc_limits.bgl"
wire="$repo/store/src/store/native_wire_codec.bgl"
rules="$repo/store/src/store/chain_rules.bgl"
log="$repo/store/src/store/log_codec.bgl"
revision="$repo/store/src/store/revision_identity.bgl"
fixture="$here/fixture.bgl"

timeout --foreground 30s "$repo/bin/beagle" syntax \
  "$revision" "$fixture"
timeout --foreground 30s "$repo/bin/beagle" check --agent \
  "$codec" "$slots" "$types" "$store" "$limits" "$wire" "$rules" \
  "$log" "$revision" "$fixture"
timeout --foreground 110s "$repo/bin/beagle-native-exe" \
  --out "$scratch/branch-revision" \
  --artifacts "$scratch/artifacts" \
  --entry store.branch-revision-identity-fixture/main \
  -- "$codec" "$slots" "$types" "$store" "$limits" "$wire" "$rules" \
  "$log" "$revision" "$fixture"
timeout --foreground 10s "$scratch/branch-revision"

rg -qx 'stage typed-to-native COMPLETE' "$scratch/artifacts/report.txt"
rg -qx 'result PASS' "$scratch/artifacts/report.txt"

echo "branch-revision-identity: exact ordered history identity PASS"
