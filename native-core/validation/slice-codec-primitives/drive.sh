#!/usr/bin/env bash
set -euo pipefail

abi="${NATIVE_SLICE_ABI:-lp64}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-}"
src="$here/fixture.bgl"
managed_src="$here/managed_fixture.bclj"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-codec-primitives.XXXXXX")"
[[ -n "$art" ]] || art="$scratch/artifacts"
trap 'rm -rf "${scratch:?}"' EXIT
mkdir -p "$art"

"$repo/bin/beagle-ast" \
  --interface-sha256-out "$scratch/fixture.interface.sha256" \
  "$src" >"$scratch/fixture.ast.json"
fixture_interface_sha256="$(<"$scratch/fixture.interface.sha256")"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  --input "$scratch/fixture.ast.json=native-core/validation/slice-codec-primitives/fixture.bgl" \
  --interface-sha256 \
  "native-core/validation/slice-codec-primitives/fixture.bgl=$fixture_interface_sha256" \
  --output "$art/fixture.facts"
{
  sha256sum "$src" | cut -d' ' -f1
  sha256sum "$managed_src" | cut -d' ' -f1
} | sha256sum | cut -d' ' -f1 >"$art/source.sha256"

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
  "$repo/native-core/src/native/lower.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
  "$repo/native-core/src/native/simd.bclj" \
  "$repo/native-core/src/native/c11.bclj" \
  "$repo/native-core/src/native/slice.bclj" \
  "$repo/native-core/src/native/fold_c17.bclj" \
  "$repo/native-core/src/native/body_c17.bclj" \
  "$repo/native-core/src/native/body_slice.bclj" \
  "$repo/native-core/src/native/qbe.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 \
  || { sed -n '1,240p' "$scratch/build.log" >&2; exit 1; }

records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in stages lower obligations simd c11 slice fold_c17 body_c17 body_slice qbe; do
  [[ -f "$scratch/out/native/$module.clj" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$scratch/out/native/$module.clj"
  awk -v imp="(import '[native.core $records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' \
    "$scratch/out/native/$module.clj" >"$scratch/out/native/$module.clj.tmp"
  mv "$scratch/out/native/$module.clj.tmp" "$scratch/out/native/$module.clj"
done

bb -cp "$scratch/out" -e "
(require 'native.body-slice)
(spit \"$art/report.txt\"
  (native.body-slice/emit-manifest-slice! \"$art/fixture.facts\"
    \"native.codec-primitives\"
    \"native-core/validation/slice-codec-primitives/fixture.bgl\"
    \"$art\" \"native-slice-codec-primitives-v0\" \"$abi\"))"
cat "$art/report.txt"
grep -q '^materialize OK ' "$art/report.txt"
if grep -q '^obligation-projection FAIL' "$art/report.txt"; then
  echo "drive.sh: codec projection failed a Native obligation" >&2
  exit 1
fi

bb -cp "$scratch/out" \
  "$here/qbe-refusal.clj" "$art/fixture.facts" \
  "native.codec-primitives" \
  "native-core/validation/slice-codec-primitives/fixture.bgl" \
  "native-slice-codec-primitives-v0"

mkdir -p "$scratch/managed/native"
"$repo/bin/beagle-build" "$managed_src" \
  "$scratch/managed/native/codec_primitives_managed.clj" >/dev/null
bb -cp "$scratch/managed" -e "
(require 'native.codec-primitives-managed)
(assert (= \"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\"
           (native.codec-primitives-managed/digest-bytes [])))
(assert (= \"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"
           (native.codec-primitives-managed/digest-bytes [97 98 99])))
(try
  (native.codec-primitives-managed/digest-bytes [256])
  (throw (ex-info \"managed sha256 accepted an invalid byte\" {}))
  (catch clojure.lang.ExceptionInfo error
    (when (= \"managed sha256 accepted an invalid byte\" (ex-message error))
      (throw error))))"

build="$scratch/c"
mkdir -p "$build"
cp "$art/module_0.h" "$art/module_0.c" "$here/main.c" "$build/"
cp "$repo/native-core/shim/native_shim.c" "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$build/"
strict=(-std=c17 -pedantic -Wall -Wextra -Werror)
(cd "$build" && gcc "${strict[@]}" -o probe module_0.c native_shim.c main.c -lm)
(cd "$build" && ./probe)
if (cd "$build" && ulimit -c 0 && ./probe invalid-utf8) 2>/dev/null; then
  echo "drive.sh: invalid UTF-8 did not trap" >&2
  exit 1
fi
if (cd "$build" && ulimit -c 0 && ./probe invalid-sha) 2>/dev/null; then
  echo "drive.sh: invalid SHA-256 byte did not trap" >&2
  exit 1
fi

empty="$scratch/empty"
large="$scratch/eight-mib-zero"
seed="$repo/native-core/bootstrap/trusted-seed/lp64-c17/bin/beagle"
: >"$empty"
dd if=/dev/zero of="$large" bs=1048576 count=8 status=none
[[ "$(wc -c <"$seed")" -eq 486256 ]] || {
  echo "drive.sh: trusted seed byte count changed" >&2
  exit 1
}

probe_byte_source() {
  local source="$1"
  local expected
  expected="$(sha256sum "$source" | cut -d' ' -f1)"
  (cd "$build" && ./probe byte-source "$source" "$expected")
}

empty_report="$(probe_byte_source "$empty")"
seed_report="$(probe_byte_source "$seed")"
large_report="$(probe_byte_source "$large")"
read -r empty_length empty_offset empty_allocations <<<"$empty_report"
read -r seed_length seed_offset seed_allocations <<<"$seed_report"
read -r large_length large_offset large_allocations <<<"$large_report"
[[ "$empty_length" -eq 0 && "$seed_length" -eq 486256 &&
   "$large_length" -eq 8388608 ]] || {
  echo "drive.sh: ByteSource SHA-256 probe lengths differ" >&2
  exit 1
}
[[ "$empty_offset" -eq "$seed_offset" &&
   "$empty_offset" -eq "$large_offset" &&
   "$empty_allocations" -eq "$seed_allocations" &&
   "$empty_allocations" -eq "$large_allocations" ]] || {
  echo "drive.sh: ByteSource SHA-256 allocated in proportion to input" >&2
  exit 1
}
printf 'drive.sh: ByteSource SHA-256 bytes=0/486256/8388608 arena-offset=%s allocations=%s\n' \
  "$empty_offset" "$empty_allocations"
echo "drive.sh: managed/C17 codec, SHA-256, bitcast, and refusal checks ok"
