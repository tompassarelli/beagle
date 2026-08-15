#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-json-codec.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

"$repo/bin/beagle" check --agent \
  "$repo/native-core/src/native/json.bgl" \
  "$here/json_codec_test.bgl"

"$repo/bin/beagle-native-exe" \
  --out "$scratch/json-codec-test" \
  --artifacts "$scratch/artifacts" \
  --entry native.json-codec-test/cli-main \
  -- "$repo/native-core/src/native/json.bgl" "$here/json_codec_test.bgl"

expect_output() {
  local expected="$1"
  shift
  local actual
  actual="$($scratch/json-codec-test "$@")"
  [[ "$actual" == "$expected" ]] || {
    printf 'expected: %s\nactual:   %s\n' "$expected" "$actual" >&2
    return 1
  }
}

expect_output '{"a":[1,true,null,"x\n☺"],"b":-12.5e+2}' \
  roundtrip ' { "a" : [ 1, true, null, "x\n\u263a" ], "b" : -12.5e+2 } '
expect_output '"😀/"' roundtrip '"\uD83D\uDE00\/"'
expect_output '{"empty":{},"array":[]}' roundtrip '{"empty":{},"array":[]}'

"$scratch/json-codec-test" contract \
  '{"key":["value",-12.5e+2,true,null]}'

expect_output '5:expected a JSON value' diagnose '{"a":}'
expect_output '1:high surrogate is not followed by a low surrogate' \
  diagnose '"\uD800"'
expect_output '2:leading zero is not allowed in a number' diagnose '[01]'
expect_output '4:invalid token after true' diagnose 'truex'
expect_output '3:expected a JSON value' diagnose '[1,]'
expect_output '7:object key must be a string' diagnose '{"a":1,}'
expect_output '2:unexpected object end event' invalid-encode

first="$($scratch/json-codec-test roundtrip \
  '{"repeat":["same",0,false,null]}')"
second="$($scratch/json-codec-test roundtrip \
  '{"repeat":["same",0,false,null]}')"
[[ "$first" == "$second" ]]

rg -q '^native-exe-c17 PASS ' \
  "$scratch/artifacts/native-exe.report.txt"

echo "json-codec: typed events, exact byte diagnostics, Unicode escapes, grammar, and deterministic native encoding PASS"
