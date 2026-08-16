#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-filesystem-capability.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "filesystem-capability: $*" >&2
  exit 1
}

for command in cc rg cmp; do
  command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done
mkdir -p \
  "$scratch/source-c17" \
  "$scratch/source-qbe" \
  "$scratch/exe-artifacts" \
  "$scratch/source-fs" \
  "$scratch/shim-fs"

"$repo/bin/beagle" check --agent "$here/filesystem_probe.bgl"
"$repo/bin/beagle" build --materializer c17 \
  --out "$scratch/source-c17" \
  "$here/filesystem_probe.bgl" >"$scratch/source-c17.log"

report="$scratch/source-c17/report.txt"
rg -Fx 'stage typed-to-native COMPLETE' "$report" >/dev/null \
  || die "canonical filesystem probe did not lower"
[[ "$(rg -c '^obligation-projection PASS ' "$report")" == "10" ]] \
  || die "canonical filesystem probe failed native obligations"
rg -Fx 'materialize-c17 OK module_0.h module_0.c' "$report" >/dev/null \
  || die "canonical filesystem probe did not materialize as C17"
for symbol in \
  native_host_filesystem_read_text_bounded_v0 \
  native_host_filesystem_list_directory_bounded_v0 \
  native_host_filesystem_path_kind_v0 \
  native_host_filesystem_write_text_atomic_v0 \
  native_host_filesystem_make_parent_directories_v0 \
  native_host_filesystem_append_text_v0; do
  rg -F "$symbol" "$scratch/source-c17/module_0.c" >/dev/null \
    || die "missing C17 import: $symbol"
done

set +e
"$repo/bin/beagle" build --materializer qbe \
  --out "$scratch/source-qbe" \
  "$here/filesystem_probe.bgl" >"$scratch/source-qbe.log" 2>&1
qbe_status=$?
set -e
[[ $qbe_status -ne 0 ]] || die "QBE unexpectedly accepted the filesystem effect"
rg -Fx \
  'materialize-qbe REFUSED QBE filesystem extern ABI is unsupported: typed host outcomes have no QBE call representation' \
  "$scratch/source-qbe.log" >/dev/null \
  || die "QBE filesystem refusal changed"

cc -std=c17 -Wall -Wextra -Werror -pedantic \
  -I"$repo/native-core/shim" -I"$scratch/source-c17" \
  -c "$scratch/source-c17/module_0.c" -o "$scratch/module_0.o"

"$repo/bin/beagle-native-exe" \
  --out "$scratch/filesystem-probe" \
  --artifacts "$scratch/exe-artifacts" \
  --entry native.filesystem-probe/probe \
  -- "$here/filesystem_probe.bgl" >"$scratch/native-exe.log"
set +e
"$scratch/filesystem-probe" \
  "$scratch/source-fs" \
  "$scratch/source-fs/probe.txt" \
  "$scratch/source-fs/missing.txt" \
  "$scratch/source-nested/a/b/marks.log" \
  "$scratch/source-append.log" \
  >"$scratch/source-runtime.out" 2>"$scratch/source-runtime.err"
source_status=$?
set -e
[[ $source_status -eq 0 ]] \
  || die "typed source filesystem probe returned $source_status"
printf '%s\n' alpha bravo >"$scratch/source-append.expected"
cmp "$scratch/source-append.expected" "$scratch/source-append.log" \
  || die "typed append bytes changed"
[[ -d "$scratch/source-nested/a/b" ]] \
  || die "typed parent-directory creation failed"

cc -std=c17 -Wall -Wextra -Werror -pedantic \
  -I"$repo/native-core/shim" \
  "$here/main.c" "$repo/native-core/shim/native_shim.c" \
  -o "$scratch/filesystem-capability"
"$scratch/filesystem-capability" "$scratch/shim-fs" >"$scratch/runtime.out"
rg -Fx 'filesystem capability fixture: ok' "$scratch/runtime.out" >/dev/null \
  || die "runtime filesystem contract failed"

cat "$report"
cat "$scratch/runtime.out"
echo "filesystem capability fixture: typed source results pass"
