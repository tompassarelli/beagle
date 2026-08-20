#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-edn-codec.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "edn-codec: $*" >&2
  exit 1
}

for command in cc rg; do
  command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done
mkdir -p "$scratch/exe-artifacts"

sources=(
  "$repo/native-core/src/beagle/datum_reader.bgl"
  "$repo/native-core/src/native/edn.bgl"
  "$here/edn_codec_test.bgl"
)

"$repo/bin/beagle" check --agent "${sources[@]}"
"$repo/bin/beagle-native-exe" \
  --out "$scratch/edn-codec-test" \
  --artifacts "$scratch/exe-artifacts" \
  --entry native.edn-codec-test/cli-main \
  -- "${sources[@]}" >"$scratch/native-exe.log"

report="$scratch/exe-artifacts/report.txt"
rg -Fx 'stage typed-to-native COMPLETE' "$report" >/dev/null \
  || die "semantic EDN fixture did not lower"
[[ "$(rg -c '^obligation-projection PASS ' "$report")" == "10" ]] \
  || die "semantic EDN fixture failed native obligations"
rg -Fx 'materialize-c17 OK module_0.h module_0.c' "$report" >/dev/null \
  || die "semantic EDN fixture did not materialize as C17"

representative='{:tx 1, :op "assert", :values [true nil -2], :title "line\n☺"}'
"$scratch/edn-codec-test" contract "$representative"

actual="$($scratch/edn-codec-test roundtrip \
  ' { :tx 1 :op "assert" :l "@mark-a" :p "window" :r "@w42" :record "wm-mark" :ts "1970-01-01T00:00:00Z" } ')"
expected='{:tx 1, :op "assert", :l "@mark-a", :p "window", :r "@w42", :record "wm-mark", :ts "1970-01-01T00:00:00Z"}'
[[ "$actual" == "$expected" ]] || die "canonical marks line changed"

[[ "$($scratch/edn-codec-test diagnose '{:a}')" == \
  '3:map requires an even number of forms' ]] \
  || die "odd map diagnostic changed"
[[ "$($scratch/edn-codec-test invalid-encode)" == \
  '2:unexpected map end event' ]] \
  || die "invalid event diagnostic changed"

if ldd "$scratch/edn-codec-test" | rg -qi 'racket|clojure|babashka|java'; then
  die "hosted runtime leaked into native executable"
fi

cat "$report"
echo "edn-codec: typed semantic events, canonical marks/facts lines, diagnostics, and native runtime pass"
