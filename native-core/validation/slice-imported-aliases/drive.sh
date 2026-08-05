#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-imported-aliases.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

"$repo/bin/beagle" check --agent "$here/provider.bclj" "$here/consumer.bclj"
"$repo/bin/beagle" native-module \
  --out "$scratch/artifacts" \
  --entry consumer/echo-term \
  --entry consumer/echo-term-maybe \
  --entry consumer/imported-label \
  "$here/provider.bclj" \
  "$here/consumer.bclj"

rg -q $'\tname\tt\tprovider/Item$' "$scratch/artifacts/source.facts"
rg -q '^stage source-to-typed ACCEPTED$' "$scratch/artifacts/report.txt"
rg -q '^stage typed-to-native COMPLETE$' "$scratch/artifacts/report.txt"
rg -q '^lowered .* echo-term ' "$scratch/artifacts/report.txt"
rg -q '^lowered .* echo-term-maybe ' "$scratch/artifacts/report.txt"
rg -q '^lowered .* imported-label ' "$scratch/artifacts/report.txt"

echo "drive.sh: imported types and lexical globals retained provider ownership through Native projection"
