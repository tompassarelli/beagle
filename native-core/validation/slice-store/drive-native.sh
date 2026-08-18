#!/usr/bin/env bash
# Native primary for the Store closure validation.
set -euo pipefail

abi="${NATIVE_SLICE_ABI:-lp64}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
source "$repo/native-core/validation/native-compiler-route.sh"

art="${NATIVE_SLICE_ARTIFACTS:-}"
store_checkout="$repo/store"
src="$store_checkout/src/store/store.bgl"
dep="$store_checkout/src/store/types.bgl"
slots="$store_checkout/src/store/slots.bgl"
module_root="store/src=$store_checkout/src"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-store-selected.XXXXXX")"
[[ -n "$art" ]] || art="$scratch/artifacts"
trap 'rm -rf "${scratch:?}"' EXIT
mkdir -p "$art"

native_bin=""
native_validation_select_binary native_bin || exit $?
for upstream in "$slots" "$dep" "$src"; do
  [[ -f "$upstream" ]] && continue
  echo "drive-native.sh: upstream Beagle Store source is missing: $upstream" >&2
  exit 1
done

workers="${BEAGLE_NATIVE_VALIDATION_EMIT_WORKERS:-16}"
native_validation_positive_seconds "$workers" emit-workers
compiler_deadline="${BEAGLE_NATIVE_VALIDATION_COMPILER_DEADLINE_SECONDS:-120}"
native_out="$scratch/native-out"
receipts="${BEAGLE_NATIVE_VALIDATION_RECEIPT_DIR:-$scratch/receipts}"
native_validation_run_phase store-compiler "$compiler_deadline" "$receipts" \
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

cp "$native_out/source.facts" "$art/store.facts"
cp "$native_out/report.txt" "$native_out/module_0.h" "$native_out/module_0.c" "$art/"
{ sha256sum "$slots"; sha256sum "$dep"; sha256sum "$src"; } \
  | cut -d' ' -f1 >"$art/source.sha256"
cat "$art/report.txt"
cp "$here/main.c" "$art/main.c"

clang_bin="$(command -v clang || true)"
if [[ -z "$clang_bin" ]]; then
  # Nix store names cannot contain whitespace.
  # shellcheck disable=SC2012
  clang_bin="$(ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null | sort -V | tail -n1 || true)"
fi
[[ -n "$clang_bin" ]] || { echo "drive-native.sh: clang is required" >&2; exit 1; }

compile_deadline="${BEAGLE_NATIVE_VALIDATION_C_COMPILE_DEADLINE_SECONDS:-30}"
run_deadline="${BEAGLE_NATIVE_VALIDATION_C_RUN_DEADLINE_SECONDS:-15}"
native_validation_run_phase store-gcc-compile "$compile_deadline" "$receipts" \
  gcc -std=c17 -Wall -Wextra -Werror \
    -I"$art" -I"$repo/native-core/shim" \
    "$art/main.c" "$art/module_0.c" "$repo/native-core/shim/native_shim.c" \
    -o "$scratch/gcc-store"
native_validation_run_phase store-gcc-run "$run_deadline" "$receipts" \
  "$scratch/gcc-store"

native_validation_run_phase store-clang-compile "$compile_deadline" "$receipts" \
  "$clang_bin" -std=c17 -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -I"$art" -I"$repo/native-core/shim" \
    "$art/main.c" "$art/module_0.c" "$repo/native-core/shim/native_shim.c" \
    -o "$scratch/clang-store-sanitized"
native_validation_run_phase store-clang-sanitized-run "$run_deadline" "$receipts" \
  env ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
    "$scratch/clang-store-sanitized"

cat >"$art/checks.txt" <<'EOF'
gcc   -std=c17 -Wall -Wextra -Werror                                  compile+link+run PASS
clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined     compile+link+run PASS
EOF
cat "$art/checks.txt"
