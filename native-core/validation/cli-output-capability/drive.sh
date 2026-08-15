#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-cli-output.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "cli-output-capability: $*" >&2
  exit 1
}

for command in cmp gcc rg; do
  command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

source_file="$here/output_fixture.bgl"
executable="$scratch/cli-output"
mkdir -p "$scratch/c17" "$scratch/qbe"

"$repo/bin/beagle" check --agent "$source_file"
"$repo/bin/beagle" native-exe \
  --out "$executable" \
  --entry native.cli-output-capability/-main \
  --cc gcc \
  --artifacts "$scratch/c17" \
  "$source_file" >"$scratch/c17/build.log"

for symbol in \
  native_host_stdout_write_v0 \
  native_host_stdout_write_line_v0 \
  native_host_stderr_write_v0 \
  native_host_stderr_write_line_v0; do
  rg -F "$symbol" "$scratch/c17/module_0.c" >/dev/null \
    || die "missing C17 import: $symbol"
done
[[ "$(rg -c '^obligation-projection PASS ' "$scratch/c17/report.txt")" == "10" ]] \
  || die "native obligations did not pass"

set +e
env -i "$executable" >"$scratch/stdout" 2>"$scratch/stderr"
status=$?
set -e
[[ $status -eq 19 ]] || die "executable returned $status, expected 19"
cmp -s "$scratch/stdout" <(printf 'stdout-line\n') \
  || die "stdout bytes changed"
cmp -s "$scratch/stderr" <(printf 'stderr-line\n') \
  || die "stderr bytes changed"

set +e
"$repo/bin/beagle" build --materializer qbe \
  --out "$scratch/qbe" \
  --entry native.cli-output-capability/-main \
  "$source_file" >"$scratch/qbe.log" 2>&1
qbe_status=$?
set -e
[[ $qbe_status -ne 0 ]] || die "QBE unexpectedly accepted CLI output"
rg -Fx \
  'materialize-qbe REFUSED QBE stderr extern ABI is unsupported: Text handles have no QBE call representation' \
  "$scratch/qbe.log" >/dev/null \
  || die "QBE stderr refusal changed"

printf 'cli-output-capability: exact stdout/stderr bytes and status ok\n'
