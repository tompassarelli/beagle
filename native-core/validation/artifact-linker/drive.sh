#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-artifact-linker.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

linker="$repo/native-core/src/beagle/artifact_linker.bgl"
fixture="$here/fixture.bgl"

mkdir -p "$scratch/build-artifacts" "$scratch/runtime/artifacts"

timeout --foreground 30s "$repo/bin/beagle" syntax "$linker" "$fixture"
timeout --foreground 30s "$repo/bin/beagle" check --agent "$linker" "$fixture"
timeout --foreground 180s "$repo/bin/beagle-native-exe" \
  --out "$scratch/artifact-linker-fixture" \
  --artifacts "$scratch/build-artifacts" \
  --entry native.artifact-linker-fixture/probe \
  -- "$linker" "$fixture"

timeout --foreground 10s "$scratch/artifact-linker-fixture" \
  "$scratch/runtime/artifacts" "$scratch/runtime/executable"

[[ ! -e "$scratch/runtime/escaped.c" ]] \
  || { echo "artifact-linker: forged wrapper escaped the artifact directory" >&2; exit 1; }
[[ ! -e "$scratch/runtime/artifacts/written-before-invalid.c" ]] \
  || { echo "artifact-linker: valid prefix was written before rejection" >&2; exit 1; }
[[ ! -e "$scratch/runtime/executable" ]] \
  || { echo "artifact-linker: forged wrapper reached the compiler" >&2; exit 1; }

echo "artifact-linker: public wrapper cannot bypass file validation PASS"
