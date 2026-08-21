#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/recur-short-circuit.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "recur-short-circuit: $*" >&2
  exit 1
}

timeout --foreground 30s "$repo/bin/beagle" syntax \
  "$here/accepted.bgl" "$here/refusals.bgl"
timeout --foreground 30s "$repo/bin/beagle" check --agent \
  "$here/accepted.bgl" "$here/refusals.bgl"

timeout --foreground 120s "$repo/bin/beagle" native-exe \
  --out "$scratch/accepted" \
  --artifacts "$scratch/accepted-artifacts" \
  --entry native.recur-short-circuit/main \
  "$here/accepted.bgl" >"$scratch/accepted.log" 2>&1 \
  || { sed -n '1,240p' "$scratch/accepted.log" >&2; exit 1; }

rg -Fx 'stage typed-to-native COMPLETE' "$scratch/accepted.log" >/dev/null \
  || die "accepted build did not complete typed-to-native lowering"
rg -Fx 'result PASS' "$scratch/accepted.log" >/dev/null \
  || die "accepted build did not report PASS"
timeout --foreground 10s "$scratch/accepted"

diagnostic='TODO-NATIVE-RECUR-NON-TAIL: recur is not in tail position of its loop'
for entry in and-earlier or-earlier; do
  log="$scratch/$entry.log"
  executable="$scratch/$entry"
  artifacts="$scratch/$entry-artifacts"

  set +e
  timeout --foreground 120s "$repo/bin/beagle" native-exe \
    --out "$executable" \
    --artifacts "$artifacts" \
    --entry "native.recur-short-circuit-refusals/$entry" \
    "$here/refusals.bgl" >"$log" 2>&1
  status=$?
  set -e

  [[ $status -ne 0 ]] \
    || die "$entry unexpectedly materialized despite non-tail recur"
  [[ ! -e "$executable" ]] \
    || die "$entry refusal left an executable"
  [[ "$(rg -F -c "$diagnostic" "$log")" -eq 1 ]] \
    || { sed -n '1,240p' "$log" >&2; die "$entry did not report exactly one non-tail diagnostic"; }
done

if ldd "$scratch/accepted" | rg -qi 'racket|clojure|babashka|java'; then
  die "hosted runtime leaked into accepted Native executable"
fi

echo "recur-short-circuit: final operands execute; earlier operands remain non-tail PASS"
