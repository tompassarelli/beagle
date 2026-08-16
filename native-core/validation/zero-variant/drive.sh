#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-zero-variant.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  printf 'zero-variant: %s\n' "$*" >&2
  exit 1
}

source "$repo/bin/_beagle-racket"

"$repo/bin/beagle" check --agent "$here/action.bgl" "$here/fixture.bgl"
"$repo/bin/beagle" native-exe \
  --out "$scratch/zero-variant" \
  --entry native.zero-variant-fixture/-main \
  --artifacts "$scratch/artifacts" \
  "$here/action.bgl" "$here/fixture.bgl" \
  >"$scratch/build.log"

run_status() {
  local expected="$1"
  shift
  local observed
  set +e
  "$scratch/zero-variant" "$@"
  observed=$?
  set -e
  [[ $observed -eq $expected ]] \
    || die "expected status $expected, observed $observed"
}

run_status 17
run_status 23 stop

rg -F 'native-lowering-result NativeLoweringCompleteV0' \
  "$scratch/artifacts/report.txt" >/dev/null \
  || die "native lowering did not complete"
[[ "$(rg -c '^obligation-projection PASS ' \
  "$scratch/artifacts/report.txt")" == "10" ]] \
  || die "native obligations did not pass"
if ldd "$scratch/zero-variant" | rg -qi 'racket|clojure|babashka|java'; then
  die "hosted runtime leaked into native executable"
fi

printf 'zero-variant: tag-only construction and exhaustive match passed\n'
