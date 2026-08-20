#!/usr/bin/env bash
# Validate epoch materialization.
#
#   1  the six epoch fixture modules materialize, and the corpus' own
#      obligation gate is green — including the old-to-young case, which
#      obligation 8 must refuse, and the same program with promote, which it
#      must accept;
#   2  the emitted C compiles under gcc and clang at -std=c17 -pedantic -Wall
#      -Wextra -Werror and runs clean under ASan + UBSan;
#   3  the loop watermark: the root arena's high-water mark does not move with
#      the iteration count under derived assignment, and does under identity —
#      measured both for an epoch a function opens for itself and for one it
#      opens on a callee's behalf.
#
# Self-contained: reads no upstream source, so it is re-runnable anywhere the
# repo is.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-}"

command -v bb >/dev/null 2>&1 || { echo "drive.sh: babashka (bb) is required" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-epoch.XXXXXX")"
[[ -n "$art" ]] || art="$work/artifacts"
trap 'rm -rf "${work:?}"' EXIT

mkdir -p "$work/src/native" "$work/run-a" "$work/run-b" "$art"

modules=(core stages lower obligations c11 fold_c17 body_c17
         epoch_validation_corpus)
for name in "${modules[@]}"; do
  cp "$repo/native-core/src/native/$name.bclj" "$work/src/native/$name.bclj"
done

BEAGLE_OUT="$work/out" "$repo/bin/beagle" build "$work"/src/native/*.bclj \
  > "$work/build.log" 2>&1 || { sed -n '1,200p' "$work/build.log" >&2; exit 1; }

# See native-core/validation/slice-fold/drive.sh: a cross-module `match` on an
# imported union emits an unqualified variant name, so every consumer module
# re-exports native.core's records as the repo's standing workaround.
records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' "$work/out/native/core.clj" | tr '\n' ' ')"
for m in "${modules[@]}"; do
  [ "$m" = core ] && continue
  file="$work/out/native/$m.clj"
  [ -f "$file" ] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' "$file"
  awk -v imp="(import '[native.core $records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
done

emit() {
  bb -cp "$work/out" -e "
(require 'native.epoch-validation-corpus)
(def ns (find-ns 'native.epoch-validation-corpus))
((deref (ns-resolve ns 'emit-fixtures!)) \"$1\")
(when-not (deref (ns-resolve ns 'gate-passes?))
  (println (deref (ns-resolve ns 'report-text)))
  (throw (ex-info \"epoch fixture obligation gate failed\" {})))
"
}

emit "$work/run-a"
emit "$work/run-b"

generated=(module_0.h module_0.c module_1.h module_1.c
           module_2.h module_2.c module_3.h module_3.c
           module_4.h module_4.c module_5.h module_5.c report.txt)
for name in "${generated[@]}"; do
  cmp -s "$work/run-a/$name" "$work/run-b/$name" \
    || { echo "drive.sh: re-emission is not byte-identical for $name" >&2; exit 1; }
  cp "$work/run-a/$name" "$art/$name"
done
cat "$art/report.txt"

if [ -n "${NATIVE_SLICE_NO_COMPILE:-}" ]; then
  exit 0
fi

build="$work/c"
mkdir -p "$build"
cp "$art"/module_*.h "$art"/module_*.c "$here/main.c" "$build/"
cp "$repo/native-core/shim/native_shim.c" "$repo/native-core/shim/native_shim.h" \
   "$repo/native-core/shim/native_unicode15_data.h" "$build/"

sources=(module_0.c module_1.c module_2.c module_3.c module_4.c module_5.c
         native_shim.c main.c)
strict=(-std=c17 -pedantic -Wall -Wextra -Werror)

( cd "$build" && gcc "${strict[@]}" -o probe_gcc "${sources[@]}" )
( cd "$build" && ./probe_gcc > "$work/run-gcc.txt" )
cat "$work/run-gcc.txt"
echo "drive.sh: gcc $(gcc -dumpversion) strict compile + run ok"

find_clang() {
  if command -v clang >/dev/null 2>&1; then command -v clang; return 0; fi
  local candidate
  candidate="$(ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null | sort -V | tail -1)"
  [ -n "$candidate" ] && printf '%s\n' "$candidate"
}

clang_bin="$(find_clang || true)"

# The sanitizers are the point of this driver, not an optional extra: an epoch
# close is a free(), so a value that outlived its epoch is a use-after-free and
# nothing but ASan sees it.
sanitize=(-fsanitize=address,undefined -fno-sanitize-recover=all
          -g)

( cd "$build" && gcc "${strict[@]}" "${sanitize[@]}" -o probe_gcc_san "${sources[@]}" )
( cd "$build" && ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=print_stacktrace=1 \
    ./probe_gcc_san > "$work/run-gcc-san.txt" )
cat "$work/run-gcc-san.txt"
echo "drive.sh: gcc ASan+UBSan (leak detection on) clean"

if [ -n "$clang_bin" ]; then
  ( cd "$build" && "$clang_bin" -std=c17 -Werror -o probe_clang "${sources[@]}" )
  ( cd "$build" && ./probe_clang > /dev/null )
  ( cd "$build" && "$clang_bin" -std=c17 -Werror "${sanitize[@]}" \
      -o probe_clang_san "${sources[@]}" )
  ( cd "$build" && ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=print_stacktrace=1 \
      ./probe_clang_san > /dev/null )
  echo "drive.sh: clang $("$clang_bin" -dumpversion) compile + run + ASan/UBSan clean"
else
  echo "drive.sh: clang not found — second frontend NOT exercised" >&2
fi

# The watermark assertion main.c already enforces, restated here so the numbers
# land in the driver's own output rather than only in an exit code.
derived_small="$(awk '$1=="watermark" && $2=="derived" && $3==64    {print $4}' "$work/run-gcc.txt")"
derived_large="$(awk '$1=="watermark" && $2=="derived" && $3==65536 {print $4}' "$work/run-gcc.txt")"
identity_small="$(awk '$1=="watermark" && $2=="identity" && $3==64    {print $4}' "$work/run-gcc.txt")"
identity_large="$(awk '$1=="watermark" && $2=="identity" && $3==65536 {print $4}' "$work/run-gcc.txt")"
[ "$derived_small" = "$derived_large" ] \
  || { echo "drive.sh: derived watermark moved: $derived_small -> $derived_large" >&2; exit 1; }
[ "$identity_large" -gt "$identity_small" ] \
  || { echo "drive.sh: identity watermark did not move" >&2; exit 1; }
caller_derived_small="$(awk '$1=="watermark" && $2=="caller-derived" && $3==64 {print $4}' "$work/run-gcc.txt")"
caller_derived_large="$(awk '$1=="watermark" && $2=="caller-derived" && $3==65536 {print $4}' "$work/run-gcc.txt")"
caller_identity_small="$(awk '$1=="watermark" && $2=="caller-identity" && $3==64 {print $4}' "$work/run-gcc.txt")"
caller_identity_large="$(awk '$1=="watermark" && $2=="caller-identity" && $3==65536 {print $4}' "$work/run-gcc.txt")"
[ "$caller_derived_small" = "$caller_derived_large" ] \
  || { echo "drive.sh: caller-derived watermark moved" >&2; exit 1; }
[ "$caller_identity_large" -gt "$caller_identity_small" ] \
  || { echo "drive.sh: caller-identity watermark did not move" >&2; exit 1; }
{
  echo "derived          64 iterations: ${derived_small} reserved root bytes"
  echo "derived       65536 iterations: ${derived_large} reserved root bytes"
  echo "identity         64 iterations: ${identity_small} reserved root bytes"
  echo "identity      65536 iterations: ${identity_large} reserved root bytes"
  echo "caller-derived      64 iterations: ${caller_derived_small} reserved root bytes"
  echo "caller-derived   65536 iterations: ${caller_derived_large} reserved root bytes"
  echo "caller-identity     64 iterations: ${caller_identity_small} reserved root bytes"
  echo "caller-identity  65536 iterations: ${caller_identity_large} reserved root bytes"
} > "$art/watermark.txt"
cat "$art/watermark.txt"
echo "drive.sh: loop watermark bounded under derived assignment"
