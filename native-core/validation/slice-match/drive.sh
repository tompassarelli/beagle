#!/usr/bin/env bash
# Exercises closed Native match lowering and its named fail-closed boundaries.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-match.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

for command in gcc rg sed; do
  command -v "$command" >/dev/null || {
    echo "drive.sh: required command is unavailable: $command" >&2
    exit 1
  }
done

accepted="$scratch/accepted"
"$repo/bin/beagle" build --materializer c17 --out "$accepted" "$here/fixture.bgl"
report="$accepted/report.txt"

for expected in \
  'stage typed-to-native COMPLETE' \
  'native-lowering-result NativeLoweringCompleteV0' \
  'lowered fn_[0-9]+ classify-tag ' \
  'lowered fn_[0-9]+ unpack-value ' \
  'obligation-projection PASS valid-ssa' \
  'obligation-projection PASS exhaustive-matches' \
  'materialize-c17 OK module_0.h module_0.c' \
  'result PASS'; do
  rg -q "$expected" "$report" || {
    echo "drive.sh: accepted report omitted evidence: $expected" >&2
    exit 1
  }
done
if rg -q 'unsupported-match|TODO-NATIVE-MATCH' "$report" "$accepted/source.facts"; then
  echo "drive.sh: accepted match remained opaque or pending" >&2
  exit 1
fi

classify_index="$(sed -nE 's/^lowered fn_([0-9]+) classify-tag .*/\1/p' "$report")"
unpack_index="$(sed -nE 's/^lowered fn_([0-9]+) unpack-value .*/\1/p' "$report")"
classify_type="$(sed -nE "s/^.* native_m0_fn_${classify_index}\\((native_m0_type_[0-9]+) .*/\\1/p" "$accepted/module_0.h")"
unpack_type="$(sed -nE "s/^.* native_m0_fn_${unpack_index}\\((native_m0_type_[0-9]+) .*/\\1/p" "$accepted/module_0.h")"
if [[ -z "$classify_index" || -z "$unpack_index" ||
      -z "$classify_type" || -z "$unpack_type" ]]; then
  echo "drive.sh: could not resolve generated match entry points" >&2
  exit 1
fi

gcc -std=c17 -pedantic -Wall -Wextra -Werror \
  -DCLASSIFY_TAG_FN="native_m0_fn_${classify_index}" \
  -DCLASSIFY_TAG_TYPE="$classify_type" \
  -DUNPACK_VALUE_FN="native_m0_fn_${unpack_index}" \
  -DUNPACK_VALUE_TYPE="$unpack_type" \
  -I"$accepted" -o "$scratch/probe" \
  "$accepted/module_0.c" "$accepted/native_shim.c" "$here/main.c"
"$scratch/probe"

refused="$scratch/refused"
if "$repo/bin/beagle" build --materializer c17 --out "$refused" \
    "$here/refusals.bgl" >"$scratch/refused.log" 2>&1; then
  echo "drive.sh: unsupported matches unexpectedly lowered" >&2
  exit 1
fi

for expected in \
  'TODO-NATIVE-MATCH-NONEXHAUSTIVE: patterns do not cover the sealed target type \[nonexhaustive\]' \
  'TODO-NATIVE-MATCH-PATTERN: no native lowering for or \[unsupported-or\]'; do
  rg -q "$expected" "$refused/report.txt" || {
    echo "drive.sh: refusal report omitted evidence: $expected" >&2
    exit 1
  }
done
if rg -q 'TODO-NATIVE-FORM-unsupported-match' "$refused/report.txt"; then
  echo "drive.sh: refusal fell back to the opaque match diagnostic" >&2
  exit 1
fi

cat "$report"
cat "$refused/report.txt"
echo "slice-match: closed-union literals/records, strict C runtime, and named refusals PASS"
