#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-js-materializer.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

sources=(
  "$repo/native-core/src/beagle/frontend_facts.bgl"
  "$repo/native-core/src/beagle/checker.bgl"
  "$repo/native-core/src/beagle/datum_reader.bgl"
  "$repo/native-core/src/beagle/js_materializer.bgl"
  "$here/fixture.bgl"
)

timeout --foreground 30s "$repo/bin/beagle" check --agent "${sources[@]}"
echo "native JavaScript materializer: source/type gate PASS"
