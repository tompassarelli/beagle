#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-whole-input.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

for command in cc rg; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "whole-input: missing $command" >&2
    exit 1
  }
done

cc -std=c17 -Wall -Wextra -Werror -pedantic \
  -I"$repo/native-core/shim" \
  "$here/whole_input_probe.c" "$repo/native-core/shim/native_shim.c" \
  -o "$scratch/whole-input"

"$scratch/whole-input" "$scratch" >"$scratch/pass.out"
rg -Fx 'whole-input fixture: EOF empty non-ASCII PASS' "$scratch/pass.out" >/dev/null

set +e
"$scratch/whole-input" "$scratch" overflow >"$scratch/overflow.out" \
  2>"$scratch/overflow.err"
status=$?
set -e
[[ $status -ne 0 ]] || {
  echo "whole-input: overflow unexpectedly returned success" >&2
  exit 1
}
rg -Fx \
  "native-host-input-diagnostic code=HOST-INPUT-BOUND-EXCEEDED input=$scratch/overflow.txt observed-size=4 limit=3" \
  "$scratch/overflow.err" >/dev/null || {
  echo "whole-input: overflow diagnostic missing or malformed" >&2
  cat "$scratch/overflow.err" >&2
  exit 1
}

cat "$scratch/pass.out"
echo "whole-input fixture: bound overflow PASS"
