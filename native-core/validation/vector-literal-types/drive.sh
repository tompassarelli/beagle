#!/usr/bin/env bash
# Vector literals name their own element type: a literal of scalar literals
# lowers in a module that never spells (Vec T) in any annotation (argument
# position, count receiver, and a Bool typed binding), and a literal in
# return position keeps lowering under its return annotation. Both programs
# execute to prove the minted vector types materialize correctly.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-vector-literal.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "vector-literal-types: $*" >&2
  exit 1
}

compiler="$(command -v cc || command -v gcc)" || die "no C compiler available"

run_case() {
  local name="$1" entry="$2" source="$3"
  local build="$scratch/$name"
  mkdir -p "$build/artifacts"
  "$repo/bin/beagle" check --agent "$source"
  "$repo/bin/beagle" native-exe \
    --out "$build/case" \
    --entry "$entry" \
    --cc "$compiler" \
    --artifacts "$build/artifacts" \
    "$source" >"$build/build.log"
  "$build/case" || die "$name executable rejected the literal results"
  rg -qx 'stage typed-to-native COMPLETE' "$build/artifacts/report.txt" \
    || die "$name did not complete native lowering"
  rg -q 'TODO-NATIVE-VECTOR-LITERAL-TYPE' "$build/artifacts/report.txt" \
    && die "$name still demands a declared vector of the element type"
  echo "vector-literal-types: $name PASS"
}

run_case annotation-free native.vector-literal-types/main "$here/fixture.bgl"
run_case return-position native.vector-literal-return/main "$here/return_position.bgl"

echo "drive.sh: scalar-literal vectors lower without a decoy (Vec T) declaration"
