#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-real-path.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "real-path: $*" >&2
  exit 1
}

for command in cc ln mkdir rg touch; do
  command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

mkdir -p "$scratch/artifacts" "$scratch/qbe" "$scratch/root/target"
touch "$scratch/root/target/value.txt"
ln -s "target/value.txt" "$scratch/root/link.txt"

"$repo/bin/beagle" native-exe \
  --out "$scratch/real-path-probe" \
  --artifacts "$scratch/artifacts" \
  --entry native.real-path-probe/probe \
  --cc cc \
  "$here/real_path_probe.bgl" >"$scratch/native-exe.log"

rg -F 'native_host_filesystem_real_path_v0' \
  "$scratch/artifacts/module_0.c" >/dev/null \
  || die "C17 real-path import is missing"

"$scratch/real-path-probe" \
  "$scratch/root/link.txt" \
  "$scratch/root/target/value.txt" \
  "$scratch/root/missing.txt" \
  || die "typed real-path source probe failed"

set +e
"$repo/bin/beagle" build --materializer qbe \
  --out "$scratch/qbe" "$here/real_path_probe.bgl" \
  >"$scratch/qbe.log" 2>&1
qbe_status=$?
set -e
[[ $qbe_status -ne 0 ]] || die "QBE unexpectedly accepted real-path"
rg -Fx \
  'materialize-qbe REFUSED QBE filesystem extern ABI is unsupported: typed host outcomes have no QBE call representation' \
  "$scratch/qbe.log" >/dev/null \
  || die "QBE filesystem refusal changed"

cc -std=c17 -Wall -Wextra -Werror -pedantic -D__wasi__ \
  -I"$repo/native-core/shim" \
  "$here/wasi_contract.c" "$repo/native-core/shim/native_shim.c" \
  -pthread -lm -o "$scratch/wasi-contract"
"$scratch/wasi-contract" || die "WASI real-path refusal changed"

echo "real-path: typed symlink canonicalization, missing-path errno, C17 import, QBE refusal, and WASI ENOTSUP pass"
