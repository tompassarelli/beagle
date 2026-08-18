#!/usr/bin/env bash
# Native primary for the full Store types-stage validation.
set -euo pipefail

abi="${NATIVE_SLICE_ABI:-lp64}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
source "$repo/native-core/validation/native-compiler-route.sh"

art="${NATIVE_SLICE_ARTIFACTS:-}"
store_checkout="$("$repo/native-core/validation/store-checkout.sh")"
src="$store_checkout/src/fram/types.bgl"
module_root="store/src=$store_checkout/src"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-types-full-selected.XXXXXX")"
[[ -n "$art" ]] || art="$scratch/artifacts"
trap 'rm -rf "${scratch:?}"' EXIT
mkdir -p "$art"

native_bin=""
native_validation_select_binary native_bin || exit $?
[[ -f "$src" ]] || {
  echo "drive-native.sh: upstream Beagle Store source is missing: $src" >&2
  exit 1
}

workers="${BEAGLE_NATIVE_VALIDATION_EMIT_WORKERS:-16}"
native_validation_positive_seconds "$workers" emit-workers
compiler_deadline="${BEAGLE_NATIVE_VALIDATION_COMPILER_DEADLINE_SECONDS:-120}"
native_out="$scratch/native-out"
receipts="${BEAGLE_NATIVE_VALIDATION_RECEIPT_DIR:-$scratch/receipts}"
native_validation_run_phase types-full-compiler "$compiler_deadline" "$receipts" \
  env -u BEAGLE_NATIVE_COMPILER_BIN "$native_bin" \
    --materializer c17 --abi "$abi" --emit-workers "$workers" \
    --module-root "$module_root" --out "$native_out" "$src"

for required in source.facts report.txt module_0.h module_0.c; do
  [[ -f "$native_out/$required" ]] || {
    echo "drive-native.sh: native compiler omitted $required" >&2
    exit 1
  }
done
grep -Fx 'stage source-freeze ACCEPTED' "$native_out/report.txt" >/dev/null
grep -Fx 'stage source-to-typed ACCEPTED' "$native_out/report.txt" >/dev/null
grep -Fx 'stage typed-to-native COMPLETE' "$native_out/report.txt" >/dev/null

cp "$native_out/source.facts" "$art/types.facts"
cp "$native_out/report.txt" "$native_out/module_0.h" "$native_out/module_0.c" "$art/"
sha256sum "$src" | cut -d' ' -f1 >"$art/source.sha256"
cat "$art/report.txt"
