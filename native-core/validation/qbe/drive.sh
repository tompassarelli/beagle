#!/usr/bin/env bash
# Regenerates the QBE IL slice into NATIVE_QBE_ARTIFACTS and proves the
# emission is byte-identical across two independent runs.
# Installs nothing: qbe itself is used only when already on PATH (or when
# NATIVE_QBE_NIX=1 explicitly authorizes `nix shell nixpkgs#qbe`).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_QBE_REPO:-$(cd "$here/../../.." && pwd)}"
artifacts="${NATIVE_QBE_ARTIFACTS:-$here}"

command -v bb >/dev/null 2>&1 || { echo "drive.sh: babashka (bb) is required" >&2; exit 2; }

work="$(mktemp -d)"
cleanup() { rm -rf "${work:?}"; }
trap cleanup EXIT

mkdir -p "$work/src/native" "$work/run-a" "$work/run-b" "$artifacts"

# native-core modules are target-neutral .bgl; the clj target needs the header.
for name in core qbe qbe_validation_corpus; do
  { printf '#lang beagle\n'; cat "$repo/native-core/src/native/$name.bgl"; } \
    > "$work/src/native/$name.bclj"
done

BEAGLE_OUT="$work/out" "$repo/bin/beagle" build --target clj "$work"/src/native/*.bclj \
  > "$work/build.log" 2>&1 || { cat "$work/build.log" >&2; exit 1; }

# The clj target resolves a cross-module record pattern only when the provider's
# classes are referred and imported; same rewrite as validation/slice-types/run.sh.
core_records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' "$work/out/native/core.clj" | tr '\n' ' ')"
qbe_records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' "$work/out/native/qbe.clj" | tr '\n' ' ')"

for name in qbe qbe_validation_corpus; do
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$work/out/native/$name.clj"
done
sed -i 's/\[native\.qbe :as qbe\]/[native.qbe :as qbe :refer :all]/' \
  "$work/out/native/qbe_validation_corpus.clj"
sed -i "3i(import '[native.core $core_records])" "$work/out/native/qbe.clj"
sed -i "4i(import '[native.core $core_records])\n(import '[native.qbe $qbe_records])" \
  "$work/out/native/qbe_validation_corpus.clj"

emit() {
  bb -cp "$work/out" -e \
    "(require (quote native.qbe-validation-corpus)) (native.qbe-validation-corpus/emit-fixture! \"$1\")"
}

emit "$work/run-a"
emit "$work/run-b"

for name in module_0.ssa module_1.ssa module_2.ssa qbe_main.c; do
  cmp -s "$work/run-a/$name" "$work/run-b/$name" \
    || { echo "drive.sh: re-emission is not byte-identical for $name" >&2; exit 1; }
  cp "$work/run-a/$name" "$artifacts/$name"
done

( cd "$artifacts" && sha256sum module_0.ssa module_1.ssa module_2.ssa > determinism.txt )
cat > "$artifacts/provenance.txt" <<'PROV'
module_0.ssa  native.qbe over the native.c11-validation-corpus fixture world (module 0)
module_1.ssa  native.qbe over the native.qbe-validation-corpus slice world (module 1)
module_2.ssa  native.qbe over the native.qbe-validation-corpus vector concat world (module 2)
qbe_main.c    C driver for modules 0 and 2; links by the native_shim ABI only
determinism   two independent emitter runs compared byte-for-byte, plus a
              permuted-world equality assertion inside the corpus
PROV
echo "drive.sh: emitted $artifacts/module_0.ssa $artifacts/module_1.ssa $artifacts/module_2.ssa (two runs, byte-identical)"
cat "$artifacts/determinism.txt"

qbe_bin=""
if command -v qbe >/dev/null 2>&1; then
  qbe_bin="$(command -v qbe)"
elif [ "${NATIVE_QBE_NIX:-0}" = "1" ]; then
  qbe_bin="nix-shell-qbe"
fi

if [ -z "$qbe_bin" ]; then
  echo "drive.sh: qbe not installed; assembly step skipped. To run it:" >&2
  echo "  nix shell nixpkgs#qbe --command qbe $artifacts/module_0.ssa > $artifacts/module_0.s" >&2
  echo "  (or re-run with NATIVE_QBE_NIX=1)" >&2
  exit 0
fi

run_qbe() {
  if [ "$qbe_bin" = "nix-shell-qbe" ]; then
    nix shell nixpkgs#qbe --command qbe "$1"
  else
    "$qbe_bin" "$1"
  fi
}

build="$work/c"
mkdir -p "$build"
run_qbe "$artifacts/module_0.ssa" > "$build/module_0.s"
run_qbe "$artifacts/module_1.ssa" > "$build/module_1.s"
run_qbe "$artifacts/module_2.ssa" > "$build/module_2.s"
cp "$artifacts/qbe_main.c" "$build/"
cp "$repo/native-core/shim/native_shim.c" "$repo/native-core/shim/native_shim.h" "$build/"

( cd "$build" && cc -std=c17 -Wall -Wextra -Werror -c native_shim.c -o native_shim.o )
( cd "$build" && cc -std=c17 -Wall -Wextra -Werror -c qbe_main.c -o qbe_main.o )
( cd "$build" && cc module_0.s module_1.s module_2.s qbe_main.o native_shim.o -o probe_qbe )
( cd "$build" && ./probe_qbe )
echo "drive.sh: qbe assemble + link + run ok"
