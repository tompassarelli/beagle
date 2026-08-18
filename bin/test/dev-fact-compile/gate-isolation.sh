#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

entrypoints=(
  bin/beagle-test
  bin/beagle-test-facts
  bin/beagle-test-tag
  bin/beagle-ci
  bin/beagle-downstream
  bin/beagle-remint
  bin/beagle-certify-facts-roundtrip
  bin/beagle-fuzz-nightly
  bin/beagle-nix-oracle
  bin/beagle-validate
  bin/test/branch-compile-corpus/run.sh
  bin/test/release-gates/run.sh
  self-host/verify-selfhost.sh
  self-host/native/verify-native.sh
)

for relative in "${entrypoints[@]}"; do
  rg -q '_beagle-cold-authority' "$repo/$relative" || {
    echo "dev-fact gate isolation: $relative does not force cold authority" >&2
    exit 1
  }
done

BEAGLE_DEV_FACT_REUSE=1
source "$repo/bin/_beagle-cold-authority"
[[ -z "${BEAGLE_DEV_FACT_REUSE+x}" ]] || {
  echo "dev-fact gate isolation: development flag survived cold preamble" >&2
  exit 1
}
[[ "${BEAGLE_FACT_REUSE_FORBIDDEN:-0}" == 1 ]] || {
  echo "dev-fact gate isolation: cold preamble omitted the hard guard" >&2
  exit 1
}

rg -q 'BEAGLE_FACT_REUSE_FORBIDDEN' "$repo/bin/beagle-build-core" || {
  echo "dev-fact gate isolation: Core build does not enforce the hard guard" >&2
  exit 1
}

echo "dev-fact gate isolation: PASS ${#entrypoints[@]} entrypoints force cold authority"
