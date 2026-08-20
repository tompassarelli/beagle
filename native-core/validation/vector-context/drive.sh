#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-vector-context.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "vector-context: $*" >&2
  exit 1
}

if "$repo/bin/beagle" check --agent \
    "$here/provider.bgl" "$here/incompatible.bgl" \
    >"$scratch/incompatible.out" 2>"$scratch/incompatible.err"; then
  die "incompatible vector element passed source checking"
fi
rg -q 'Vector elements must have compatible types' \
  "$scratch/incompatible.out" "$scratch/incompatible.err" \
  || die "incompatible vector element lacked the pointed checker rejection"

"$repo/bin/beagle" check --agent "$here/provider.bgl" "$here/fixture.bgl"
"$repo/bin/beagle" build --materializer c17 --out "$scratch/artifacts" \
  "$here/provider.bgl" "$here/fixture.bgl"

report="$scratch/artifacts/report.txt"
rg -qx 'stage typed-to-native COMPLETE' "$report" \
  || die "typed-to-native did not complete"
rg -qx 'result PASS' "$report" || die "Native build did not pass"
for function in accessor-values sealed-events empty-exact; do
  rg -q "^lowered fn_[0-9]+ ${function} " "$report" \
    || die "$function did not lower"
done
if rg -q 'TODO-NATIVE-(VECTOR-HOF-CALLBACK|VECTOR-LITERAL-ELEMENTS|EMPTY-VECTOR-LITERAL)' \
    "$report"; then
  die "a contextual vector rejection remains"
fi

echo "vector-context: accessor callback, sealed-union elements, exact empty context, and incompatible control PASS"
