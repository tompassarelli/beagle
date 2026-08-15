#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-process-capability.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "process-capability: $*" >&2
  exit 1
}

for command in cc rg cmp; do
  command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done
mkdir -p "$scratch/source-c17" "$scratch/source-qbe" "$scratch/exe-artifacts"

"$repo/bin/beagle" check --agent "$here/process_probe.bgl"
"$repo/bin/beagle" build --materializer c17 \
  --out "$scratch/source-c17" \
  "$here/process_probe.bgl" >"$scratch/source-c17.log"

report="$scratch/source-c17/report.txt"
rg -Fx 'stage typed-to-native COMPLETE' "$report" >/dev/null \
  || die "canonical process probe did not lower"
[[ "$(rg -c '^obligation-projection PASS ' "$report")" == "10" ]] \
  || die "canonical process probe failed native obligations"
rg -Fx 'materialize-c17 OK module_0.h module_0.c' "$report" >/dev/null \
  || die "canonical process probe did not materialize as C17"
rg -F 'native_host_process_run_inherit_v0' \
  "$scratch/source-c17/module_0.c" >/dev/null \
  || die "missing C17 process import"

set +e
"$repo/bin/beagle" build --materializer qbe \
  --out "$scratch/source-qbe" \
  "$here/process_probe.bgl" >"$scratch/source-qbe.log" 2>&1
qbe_status=$?
set -e
[[ $qbe_status -ne 0 ]] || die "QBE unexpectedly accepted the process effect"
rg -Fx \
  'materialize-qbe REFUSED QBE process extern ABI is unsupported: inherited process execution has no QBE call representation' \
  "$scratch/source-qbe.log" >/dev/null \
  || die "QBE process refusal changed"

cc -std=c17 -Wall -Wextra -Werror -pedantic \
  -I"$repo/native-core/shim" -I"$scratch/source-c17" \
  -c "$scratch/source-c17/module_0.c" -o "$scratch/module_0.o"
cc -std=c17 -Wall -Wextra -Werror -pedantic \
  "$here/child.c" -o "$scratch/child"
cc -std=c17 -Wall -Wextra -Werror -pedantic \
  -I"$repo/native-core/shim" \
  "$here/shim_contract.c" "$repo/native-core/shim/native_shim.c" \
  -pthread -lm -o "$scratch/shim-contract"
"$scratch/shim-contract" "$scratch/child" >"$scratch/shim.out"
rg -Fx 'process capability shim fixture: ok' "$scratch/shim.out" >/dev/null \
  || die "process shim contract failed"

"$repo/bin/beagle-native-exe" \
  --out "$scratch/process-probe" \
  --artifacts "$scratch/exe-artifacts" \
  --entry native.process-probe/run \
  -- "$here/process_probe.bgl" >"$scratch/native-exe.log"

set +e
BEAGLE_PROCESS_FIXTURE='exact environment' \
  "$scratch/process-probe" "$scratch/child" 'alpha beta' 'literal;$HOME' \
  >"$scratch/runtime.stdout" 2>"$scratch/runtime.stderr"
runtime_status=$?
set -e
[[ $runtime_status -eq 23 ]] \
  || die "native process returned $runtime_status instead of 23"
printf '%s\n' \
  'argv[1]=<alpha beta>' \
  'argv[2]=<literal;$HOME>' \
  'env=<exact environment>' >"$scratch/expected.stdout"
printf '%s\n' 'child-stderr=<inherited>' >"$scratch/expected.stderr"
cmp "$scratch/expected.stdout" "$scratch/runtime.stdout" \
  || die "stdout or argv bytes changed"
cmp "$scratch/expected.stderr" "$scratch/runtime.stderr" \
  || die "stderr inheritance changed"

cat "$report"
cat "$scratch/shim.out"
echo "process capability fixture: exact argv, environment, stdio, exit, signal, and failures pass"
