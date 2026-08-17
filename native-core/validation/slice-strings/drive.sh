#!/usr/bin/env bash
# Drive the text corpus through the native pipeline:
#   beagle-ast -> source facts -> frozen source program -> typed program
#     -> native program with lowered blocks -> 7 obligations
#     -> native.body-c17 -> gcc/clang -std=c17 -Werror -> run the probe main.
set -euo pipefail

abi="${NATIVE_SLICE_ABI:-lp64}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-strings.XXXXXX")"
[[ -n "$art" ]] || art="$scratch/artifacts"
trap 'rm -rf "${scratch:?}"' EXIT
mkdir -p "$art"

facts_of() { # facts_of <source> <relative-path> <out.facts>
  "$repo/bin/beagle-ast" "$1" >"$scratch/ast.json"
  bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
    --input "$scratch/ast.json=$2" --output "$3" --include-defs
}

# --- corpus projection: the source is in this repo, so always regenerate ----
facts_of "$here/text_ops.bgl" \
  "native-core/validation/slice-strings/text_ops.bgl" \
  "$scratch/text_ops.facts"
cp "$scratch/text_ops.facts" "$art/text_ops.facts"

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
  "$repo/native-core/src/native/qbe.bclj" \
  "$repo/native-core/src/native/body_slice.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 \
  || { sed -n '1,200p' "$scratch/build.log" >&2; exit 1; }

# A cross-module `match` on an imported union emits an unqualified variant name;
# re-exporting native.core's records into each consumer namespace is the repo's
# standing workaround until the emitter qualifies them.
records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' "$scratch/out/native/core.clj" | tr '\n' ' ')"
for m in stages lower obligations simd c11 slice fold_c17 body_c17 qbe body_slice; do
  [ -f "$scratch/out/native/$m.clj" ] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' "$scratch/out/native/$m.clj"
  awk -v imp="(import '[native.core $records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' \
    "$scratch/out/native/$m.clj" >"$scratch/out/native/$m.clj.tmp"
  mv "$scratch/out/native/$m.clj.tmp" "$scratch/out/native/$m.clj"
done

bb -cp "$scratch/out" -e "
(require 'native.body-slice)
(spit \"$art/report.txt\"
  (native.body-slice/emit-slice! \"$art/text_ops.facts\" \"native.text-ops\"
    \"native-core/validation/slice-strings/text_ops.bgl\" \"$art\"
    \"native-slice-strings-v0\" \"$abi\"))"

cat "$art/report.txt"

if [ -n "${NATIVE_SLICE_NO_COMPILE:-}" ]; then
  exit 0
fi

build="$scratch/c"
mkdir -p "$build"
cp "$art/module_0.h" "$art/module_0.c" "$art/main.c" "$build/"
cp "$repo/native-core/shim/native_shim.c" "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$build/"

strict=(-std=c17 -pedantic -Wall -Wextra -Werror)
( cd "$build" && gcc "${strict[@]}" -o probe_gcc module_0.c native_shim.c main.c )
( cd "$build" && ./probe_gcc )
if ( cd "$build" && ulimit -c 0 && ./probe_gcc trap ) 2>/dev/null; then
  echo "drive.sh: the out-of-range subs did not trap" >&2
  exit 1
fi
if ( cd "$build" && ulimit -c 0 && ./probe_gcc cycle ) 2>/dev/null; then
  echo "drive.sh: cyclic value descriptor was not refused" >&2
  exit 1
fi
if ( cd "$build" && ulimit -c 0 && ./probe_gcc reference ) 2>/dev/null; then
  echo "drive.sh: reference value descriptor was not refused" >&2
  exit 1
fi
echo "drive.sh: gcc $(gcc -dumpversion) strict compile + run + refusal traps ok"

# store.text-ops is the one corpus module whose escape closure leaves an
# interior allocation, so its C opens and destroys a real epoch arena. An
# epoch close is a free(), which only a sanitizer can hold to account: the
# clean (non-refusal) run therefore also runs under ASan + UBSan.
sanitize=(-fsanitize=address,undefined -fno-sanitize-recover=all
          -fno-omit-frame-pointer -g)
( cd "$build" && gcc "${strict[@]}" "${sanitize[@]}" -o probe_gcc_san \
    module_0.c native_shim.c main.c )
( cd "$build" && ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=print_stacktrace=1 \
    ./probe_gcc_san )
echo "drive.sh: gcc ASan+UBSan clean over the epoch-carrying slice"

find_clang() {
  if command -v clang >/dev/null 2>&1; then command -v clang; return 0; fi
  local candidate
  candidate="$(ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null | sort -V | tail -1)"
  [ -n "$candidate" ] && printf '%s\n' "$candidate"
}

clang_bin="$(find_clang || true)"
if [ -n "$clang_bin" ]; then
  ( cd "$build" && "$clang_bin" -std=c17 -Werror -o probe_clang module_0.c native_shim.c main.c )
  ( cd "$build" && ./probe_clang )
  for refusal in trap cycle reference; do
    if ( cd "$build" && ulimit -c 0 && ./probe_clang "$refusal" ) 2>/dev/null; then
      echo "drive.sh: clang build did not trap for $refusal" >&2
      exit 1
    fi
  done
  echo "drive.sh: clang $("$clang_bin" -dumpversion) compile + run + refusal traps ok"
else
  echo "drive.sh: clang not found — second frontend NOT exercised" >&2
fi
