#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/language-custom-reader-worker-v1.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

sources=(
  "$repo/native-core/src/beagle/language_capsule_v1.bgl"
  "$repo/native-core/src/beagle/language_reader_protocol_v1.bgl"
  "$repo/native-core/src/beagle/language_custom_reader_worker_v1.bgl"
  "$here/fixture.bgl"
)

accept_calls="$(rg -c 'reader/accept-reader-product-v1' \
  "$repo/native-core/src/beagle/language_custom_reader_worker_v1.bgl")"
if [[ "$accept_calls" != 1 ]]; then
  echo "language-custom-reader-worker-v1: expected exactly one public candidate acceptance path, found $accept_calls" >&2
  exit 1
fi

timeout --foreground 30s "$repo/bin/beagle" check --agent "${sources[@]}"

if [[ ${BEAGLE_CUSTOM_READER_NATIVE_EXE:-0} == 1 ]]; then
  timeout --foreground 30s "$repo/bin/beagle" native-exe \
    --out "$scratch/language-custom-reader-worker-v1" \
    --entry native.language-custom-reader-worker-v1-fixture/main \
    "${sources[@]}"
  timeout --foreground 10s "$scratch/language-custom-reader-worker-v1"
fi

echo "language-custom-reader-worker-v1: opaque empty-capability acceptance, identity/grant/limit/protocol/supervisor rejection, deterministic receipt, and one candidate path PASS"
