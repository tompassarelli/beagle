#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/language-shared-datum-reader-v1.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

sources=(
  "$repo/native-core/src/beagle/datum_reader.bgl"
  "$repo/native-core/src/beagle/language_capsule_v1.bgl"
  "$repo/native-core/src/beagle/language_container_cst.bgl"
  "$repo/native-core/src/beagle/language_reader_protocol_v1.bgl"
  "$repo/native-core/src/beagle/language_shared_datum_reader_v1.bgl"
  "$here/fixture.bgl"
)

timeout --foreground 30s "$repo/bin/beagle" check --agent "${sources[@]}"

if [[ ${BEAGLE_SHARED_DATUM_NATIVE_EXE:-0} == 1 ]]; then
  timeout --foreground 30s "$repo/bin/beagle" native-exe \
    --out "$scratch/language-shared-datum-reader-v1" \
    --entry native.language-shared-datum-reader-v1-fixture/main \
    "${sources[@]}"
  timeout --foreground 10s "$scratch/language-shared-datum-reader-v1"
fi

echo "language-shared-datum-reader-v1: bounded shared datums, malformed diagnostics, semantic/provenance separation, and source-map containment PASS"
