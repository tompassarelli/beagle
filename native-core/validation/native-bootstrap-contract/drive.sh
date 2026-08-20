#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-bootstrap-contract.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

echo "native-bootstrap-contract: checking typed sources"
timeout --foreground 30s "$repo/bin/beagle" check --agent \
  "$repo/native-core/src/beagle/artifact_linker.bgl" \
  "$repo/native-core/src/beagle/checker.bgl" \
  "$repo/native-core/src/beagle/frontend_facts.bgl" \
  "$repo/native-core/src/beagle/datum_reader.bgl" \
  "$repo/native-core/src/beagle/parser.bgl" \
  "$repo/native-core/src/beagle/parser_reader.bgl" \
  "$repo/native-core/src/beagle/syntax_semantics.bgl" \
  "$repo/native-core/src/beagle/compiler_driver.bgl" \
  "$repo/native-core/src/beagle/rule_scheduler.bgl" \
  "$repo/native-core/src/beagle/bootstrap_contract.bgl" \
  "$repo/native-core/src/beagle/bootstrap_query.bgl" \
  "$here/fixture.bgl"

echo "native-bootstrap-contract: building focused Native executable"
timeout --foreground 180s "$repo/bin/beagle" native-exe \
  --out "$scratch/bootstrap-contract-fixture" \
  --entry native.bootstrap-contract-fixture/main \
  "$repo/native-core/src/beagle/rule_scheduler.bgl" \
  "$repo/native-core/src/beagle/bootstrap_contract.bgl" \
  "$here/fixture.bgl"

echo "native-bootstrap-contract: invoking seed contract"
timeout --foreground 10s "$scratch/bootstrap-contract-fixture"

if ldd "$scratch/bootstrap-contract-fixture" | rg -qi \
  'racket|raco|clojure|babashka|java|graal'; then
  echo "native-bootstrap-contract: hosted runtime leaked into native executable" >&2
  exit 1
fi

echo "native-bootstrap-contract: bundle query, artifact layout, and lineage PASS"
