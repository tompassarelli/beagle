#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-selfhost-runtime-capability.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "selfhost-runtime-capability: $*" >&2
  exit 1
}

for command in cc rg cmp touch; do
  command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

source_file="$here/selfhost_runtime_probe.bgl"
mkdir -p "$scratch/c17" "$scratch/qbe" "$scratch/exe-artifacts"
touch "$scratch/existing.txt"

"$repo/bin/beagle" check --agent "$source_file"
"$repo/bin/beagle" native-exe \
  --out "$scratch/selfhost-runtime-probe" \
  --artifacts "$scratch/exe-artifacts" \
  --entry native.selfhost-runtime-probe/-main \
  --cc cc \
  "$source_file" >"$scratch/native-exe.log"

report="$scratch/exe-artifacts/report.txt"
[[ -f "$report" ]] || report="$scratch/exe-artifacts/native-exe.report.txt"
rg -Fx 'stage typed-to-native COMPLETE' "$report" >/dev/null \
  || die "self-host runtime probe did not lower"
[[ "$(rg -c '^obligation-projection PASS ' "$report")" == "10" ]] \
  || die "self-host runtime probe failed native obligations"
for symbol in \
  native_host_environment_lookup_v0 \
  native_host_stderr_write_v0 \
  native_host_filesystem_file_exists_v0 \
  native_host_filesystem_abs_path_v0; do
  rg -F "$symbol" "$scratch/exe-artifacts/module_0.c" >/dev/null \
    || die "missing C17 import: $symbol"
done

cc -std=c17 -Wall -Wextra -Werror -pedantic \
  -I"$repo/native-core/shim" -I"$scratch/exe-artifacts" \
  -c "$scratch/exe-artifacts/module_0.c" -o "$scratch/module_0.o"

set +e
env -i BEAGLE_S8_MARKER=native-core-s8 \
  "$scratch/selfhost-runtime-probe" \
  "$scratch/existing.txt" \
  "$scratch/existing.txt" \
  "$scratch/missing.txt" \
  >"$scratch/stdout" 2>"$scratch/stderr"
status=$?
set -e
[[ $status -eq 0 ]] || die "frozen self-host runtime returned $status"
cmp -s "$scratch/stdout" <(true) || die "runtime wrote unexpected stdout"
cmp -s "$scratch/stderr" <(printf 's8-selfhost-runtime\n') \
  || die "runtime stderr bytes changed"

set +e
"$repo/bin/beagle" build --materializer qbe \
  --out "$scratch/qbe" "$source_file" >"$scratch/qbe.log" 2>&1
qbe_status=$?
set -e
[[ $qbe_status -ne 0 ]] || die "QBE unexpectedly accepted self-host filesystem adapters"
rg -Fx \
  'materialize-qbe REFUSED QBE filesystem extern ABI is unsupported: typed host outcomes have no QBE call representation' \
  "$scratch/qbe.log" >/dev/null \
  || die "QBE filesystem refusal changed"

cat "$report"
echo "selfhost-runtime-capability: typed self-host stderr, environment, and filesystem adapters pass"
