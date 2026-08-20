#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-stdin-bounded.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "stdin-bounded: $*" >&2
  exit 1
}

for command in cc rg; do
  command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

mkdir -p "$scratch/source-c17" "$scratch/source-qbe" "$scratch/artifacts"

"$repo/bin/beagle" check --agent "$here/stdin_probe.bgl"
"$repo/bin/beagle" build --materializer c17 \
  --out "$scratch/source-c17" \
  "$here/stdin_probe.bgl" >"$scratch/source-c17.log"
rg -F 'native_host_stdin_read_text_bounded_v0' \
  "$scratch/source-c17/module_0.c" >/dev/null \
  || die "missing C17 stdin import"

set +e
"$repo/bin/beagle" build --materializer qbe \
  --out "$scratch/source-qbe" \
  "$here/stdin_probe.bgl" >"$scratch/source-qbe.log" 2>&1
qbe_status=$?
set -e
[[ $qbe_status -ne 0 ]] || die "QBE unexpectedly accepted the stdin effect"
rg -F 'QBE filesystem extern ABI is unsupported' "$scratch/source-qbe.log" \
  >/dev/null || die "QBE stdin refusal changed"

cc -std=c17 -Wall -Wextra -Werror -pedantic \
  -I"$repo/native-core/shim" -I"$scratch/source-c17" \
  -c "$scratch/source-c17/module_0.c" -o "$scratch/module_0.o"

"$repo/bin/beagle-native-exe" \
  --out "$scratch/stdin-probe" \
  --artifacts "$scratch/artifacts" \
  --entry native.stdin-bounded-probe/probe \
  -- "$here/stdin_probe.bgl" >"$scratch/native-exe.log"

printf 'alpha\n' | "$scratch/stdin-probe" success
printf 'abcd' | "$scratch/stdin-probe" overflow
printf '' | "$scratch/stdin-probe" negative

echo "stdin bounded fixture: success overflow negative-bound PASS"
