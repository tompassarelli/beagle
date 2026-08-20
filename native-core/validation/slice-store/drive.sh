#!/usr/bin/env bash
# Drive store:src/store/store.bgl through the whole native pipeline and emit the
# C17 projection of the record ABI its signatures close over.
#
#   beagle-ast -> source facts -> frozen source program -> typed program
#     -> native program -> Native obligations -> native.c11 emitters
#
# store.bgl declares no record of its own: every type in its signatures comes
# from store.types, whose slot-table alias closes over store.slots. The compiler
# resolves that complete source closure before the two explicit ASTs are
# projected into one source program.
#
# Env: NATIVE_SLICE_REPO, NATIVE_SLICE_ARTIFACTS.
set -euo pipefail

abi="${NATIVE_SLICE_ABI:-lp64}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
if [[ "${BEAGLE_NATIVE_COMPILER_BIN+x}" == x ]]; then
  exec "$here/drive-native.sh"
fi
art="${NATIVE_SLICE_ARTIFACTS:-}"
store_checkout="$repo/store"
src="$store_checkout/src/store/store.bgl"
dep="$store_checkout/src/store/types.bgl"
slots="$store_checkout/src/store/slots.bgl"
module_root="store/src=$store_checkout/src"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-store.XXXXXX")"
[[ -n "$art" ]] || art="$scratch/artifacts"
trap 'rm -rf "${scratch:?}"' EXIT
mkdir -p "$art"

for upstream in "$slots" "$dep" "$src"; do
  [[ -f "$upstream" ]] && continue
  echo "drive.sh: upstream Beagle Store source is missing: $upstream" >&2
  exit 1
done
"$repo/bin/beagle-ast" --module-root "$module_root" \
  --interface-sha256-out "$scratch/types.interface.sha256" \
  "$dep" >"$scratch/types.ast.json"
"$repo/bin/beagle-ast" --module-root "$module_root" \
  --interface-sha256-out "$scratch/store.interface.sha256" \
  "$src" >"$scratch/store.ast.json"
store_logical="$(jq -er '.sourceId | select(type == "string" and length > 0)' \
  "$scratch/store.ast.json")"
types_logical="$(jq -er '.sourceId | select(type == "string" and length > 0)' \
  "$scratch/types.ast.json")"
bb "$here/ast-facts.clj" \
  "$scratch/types.ast.json=$types_logical=$scratch/types.interface.sha256" \
  "$scratch/store.ast.json=$store_logical=$scratch/store.interface.sha256" \
  "$scratch/store.facts"
cp "$scratch/store.facts" "$art/store.facts"
{ sha256sum "$slots"; sha256sum "$dep"; sha256sum "$src"; } \
  | cut -d' ' -f1 >"$art/source.sha256"

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
  "$repo/native-core/src/native/lower.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
  "$repo/native-core/src/native/simd.bclj" \
  "$repo/native-core/src/native/c11.bclj" \
  "$repo/native-core/src/native/slice.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || { sed -n '1,200p' "$scratch/build.log" >&2; exit 1; }

# A cross-module `match` on an imported union emits an unqualified variant name;
# re-exporting native.core's records into each consumer namespace is the repo's
# standing workaround until the emitter qualifies them.
records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' "$scratch/out/native/core.clj" | tr '\n' ' ')"
for m in stages lower obligations c11 slice; do
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' "$scratch/out/native/$m.clj"
done
for m in stages lower obligations c11 slice; do
  awk -v imp="(import '[native.core $records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' \
    "$scratch/out/native/$m.clj" >"$scratch/out/native/$m.clj.tmp"
  mv "$scratch/out/native/$m.clj.tmp" "$scratch/out/native/$m.clj"
done

# The lowering passes rebuild the fact index on every lookup, so this
# 3000-fact module is the sweep's heaviest projection and gets explicit heap
# headroom. The heap is the constraint, not the runtime: it lowers under bb.
bb -Xmx4g -cp "$scratch/out" -e "
(require 'native.slice)
(spit \"$art/report.txt\"
  (native.slice/emit-slice! \"$scratch/store.facts\" \"store.store\"
    \"$store_logical\" \"$art\" \"native-slice-store-v0\" \"$abi\"))"

cat "$art/report.txt"
cp "$here/main.c" "$art/main.c"

# The driver is fail-closed on its own C: a projection that no longer compiles
# under both frontends must not leave a stale passing artifact behind.
clang_bin="$(command -v clang || true)"
if [[ -z "$clang_bin" ]]; then
  # Glob, never `find /nix/store`: a concurrent nix build leaves a root-owned
  # 0700 .drv.chroot there, and the resulting permission error kills the driver
  # under `set -e`. Same form as slice-vec's find_clang.
  clang_bin="$(ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null | sort -V | tail -n1 || true)"
fi
[[ -n "$clang_bin" ]] || { echo "drive.sh: clang is required" >&2; exit 1; }

gcc -std=c17 -Wall -Wextra -Werror \
  -I"$art" -I"$repo/native-core/shim" \
  "$art/main.c" "$art/module_0.c" "$repo/native-core/shim/native_shim.c" \
  -o "$scratch/gcc-store"
"$scratch/gcc-store"

"$clang_bin" -std=c17 -Wall -Wextra -Werror \
  -fsanitize=address,undefined \
  -I"$art" -I"$repo/native-core/shim" \
  "$art/main.c" "$art/module_0.c" "$repo/native-core/shim/native_shim.c" \
  -o "$scratch/clang-store-sanitized"
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 "$scratch/clang-store-sanitized"

cat >"$art/checks.txt" <<'EOF'
gcc   -std=c17 -Wall -Wextra -Werror                                  compile+link+run PASS
clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined     compile+link+run PASS
EOF
cat "$art/checks.txt"
