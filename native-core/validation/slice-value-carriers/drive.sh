#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-value-carriers.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "slice-value-carriers: $*" >&2
  exit 1
}

for command in rg; do
  command -v "$command" >/dev/null 2>&1 \
    || die "required command is unavailable: $command"
done

"$repo/bin/beagle" check --agent "$here/fixture.bgl"
"$repo/bin/beagle" build --materializer c17 \
  --out "$scratch/artifacts" "$here/fixture.bgl"

report="$scratch/artifacts/report.txt"
for expected in \
  'stage source-to-typed ACCEPTED' \
  'stage typed-to-native COMPLETE' \
  'materialize-c17 OK module_0.h module_0.c' \
  'result PASS'; do
  rg -Fx "$expected" "$report" >/dev/null \
    || die "report is missing: $expected"
done

for function in \
  empty-vector-any vector-any empty-map-any map-any empty-set-any set-any \
  parsed-float-any; do
  rg -q "^lowered fn_[0-9]+ ${function} " "$report" \
    || die "lowered function is missing: $function"
done

rejection_shapes=(
  'TODO-NATIVE-EMPTY-VECTOR-LITERAL: an empty literal names no element type'
  'TODO-NATIVE-EMPTY-VECTOR-LITERAL: the contextual type is not an exact native vector type'
  'TODO-NATIVE-EMPTY-MAP-LITERAL: an empty literal names no key or value type'
  'TODO-NATIVE-EMPTY-MAP-LITERAL: the contextual type is not an exact native map type'
  'TODO-NATIVE-VECTOR-LITERAL-TYPE: the module declares no vector of this element type'
  'TODO-NATIVE-SET-LITERAL-TYPE: the module declares no set of this element type'
  'TODO-NATIVE-PARSE-F64-TYPE: parse-double needs a nullable Float in the source program'
)
for shape in "${rejection_shapes[@]}"; do
  if rg -F "$shape" "$report" >/dev/null; then
    die "report retained S1 rejection: $shape"
  fi
done

cat "$report"
echo "slice-value-carriers: recursive Vec/Map/Set Any carriers and nullable Float PASS"
