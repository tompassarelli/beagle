#!/usr/bin/env bash
# Drive fram:src/fram/store.bgl through the whole native pipeline and emit the
# C17 projection of the record ABI its signatures close over.
#
#   beagle-ast -> source facts -> frozen source program -> typed program
#     -> native program -> 7 obligations -> native.c11 emitters
#
# store.bgl declares no record of its own: every type in its signatures comes
# from fram.types, so both ASTs are projected into one source program.
#
# Env: NATIVE_SLICE_REPO, NATIVE_SLICE_ARTIFACTS, FRAM_STORE, FRAM_TYPES,
#      NATIVE_SLICE_COMMITTED_FACTS.
set -euo pipefail

abi="${NATIVE_SLICE_ABI:-lp64}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-$here}"
src="${FRAM_STORE:-$HOME/code/fram/main/src/fram/store.bgl}"
dep="${FRAM_TYPES:-$HOME/code/fram/main/src/fram/types.bgl}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-store.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

banner=""
if [[ "${NATIVE_SLICE_COMMITTED_FACTS:-0}" == 1 ]]; then
  # Opt-in only, and it says so in the report: this mode proves the committed
  # projection still lowers, never that it still matches live fram.
  [[ -f "$art/store.facts" ]] \
    || { echo "drive.sh: NATIVE_SLICE_COMMITTED_FACTS=1 but no committed $art/store.facts" >&2; exit 1; }
  banner="MODE committed-facts: upstream fram source NOT read; this run does not prove the projection matches live fram"
  echo "drive.sh: $banner" >&2
  cp "$art/store.facts" "$scratch/store.facts"
else
  for upstream in "$dep" "$src"; do
    [[ -f "$upstream" ]] && continue
    echo "drive.sh: upstream fram source is missing: $upstream" >&2
    echo "drive.sh: point FRAM_TYPES/FRAM_STORE at the live sources, or set NATIVE_SLICE_COMMITTED_FACTS=1 to check only the committed projection" >&2
    exit 1
  done
  "$repo/bin/beagle-ast" "$dep" >"$scratch/types.ast.json"
  "$repo/bin/beagle-ast" "$src" >"$scratch/store.ast.json"
  bb "$here/ast-facts.clj" "$scratch/types.ast.json" "$scratch/store.ast.json" \
    "$scratch/store.facts"
  if [[ -f "$art/store.facts" ]] && ! cmp -s "$scratch/store.facts" "$art/store.facts"; then
    echo "drive.sh: regenerated projection differs from the committed store.facts" >&2
    exit 1
  fi
  cp "$scratch/store.facts" "$art/store.facts"
  { sha256sum "$dep"; sha256sum "$src"; } | cut -d' ' -f1 >"$art/source.sha256"
fi

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
  "$repo/native-core/src/native/lower.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
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

# The lowering passes rebuild the fact index on every lookup, so a 3000-fact
# module needs a compiling runtime, not the interpreter.
clojure -J-Xmx4g -Sdeps "{:paths [\"$scratch/out\"]}" -M -e "
(require 'native.slice)
(spit \"$art/report.txt\"
  (native.slice/emit-slice! \"$scratch/store.facts\" \"fram.store\"
    \"fram:src/fram/store.bgl\" \"$art\" \"native-slice-store-v0\" \"$abi\"))"

if [[ -n "$banner" ]]; then
  sed -i "1i $banner" "$art/report.txt"
fi
cat "$art/report.txt"

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
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I"$art" -I"$repo/native-core/shim" \
  "$art/main.c" "$art/module_0.c" "$repo/native-core/shim/native_shim.c" \
  -o "$scratch/clang-store-sanitized"
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 "$scratch/clang-store-sanitized"

cat >"$art/checks.txt" <<'EOF'
gcc   -std=c17 -Wall -Wextra -Werror                                  compile+link+run PASS
clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined     compile+link+run PASS
EOF
cat "$art/checks.txt"
