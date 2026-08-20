#!/usr/bin/env bash
# Validate the promote surface form.
#
#   1  the surface path: `beagle check` types `bgl/promote`, and
#      `beagle build --materializer c17` lowers and materializes the probe;
#   2  the epoch stage over the SAME source: the derived assignment mints one
#      epoch, keeps exactly the one promote whose source lives in it, and
#      collapses the promote whose source is already the caller's; the
#      identity assignment mints none and collapses every promote;
#   3  the emitted C compiles under gcc and clang at -std=c17 -pedantic -Wall
#      -Wextra -Werror and runs clean under ASan + UBSan — reading the promoted
#      Text after its epoch was destroyed is a use-after-free unless promote
#      really copied;
#   4  re-emission is byte-identical;
#   5  hosted identity: the same bodies in `#lang beagle/clj` emit Clojure
#      byte-identical to the same source with every `(bgl/promote …)` erased,
#      run to the same answers, and `identical?` says the promoted value is
#      the value that went in.
#
# Self-contained: reads no upstream source, so it is re-runnable anywhere the
# repo is.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-}"
probe="$here/promote_probe.bgl"

command -v bb >/dev/null 2>&1 || { echo "drive.sh: babashka (bb) is required" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-promote.XXXXXX")"
[[ -n "$art" ]] || art="$work/artifacts"
trap 'rm -rf "${work:?}"' EXIT

mkdir -p "$work/src/native" "$work/run-a" "$work/run-b" "$work/core" "$art"

"$repo/bin/beagle" check --agent --profile 3 "$probe" "$here/promote_hosted.bclj"

# --- Clause 5: hosted identity. Both variants are built from the SAME path so
# the emitted :file/:line metadata is identical and `cmp` is exact.
hosted="$work/hosted"
mkdir -p "$hosted"
bb "$here/erase-promote.clj" "$here/promote_hosted.bclj" "$hosted/erased.bclj"
grep -qF '(bgl/promote ' "$here/promote_hosted.bclj" \
  || { echo "drive.sh: hosted source no longer uses the form" >&2; exit 1; }
! grep -qF 'bgl/promote' "$hosted/erased.bclj" \
  || { echo "drive.sh: erasure left a promote behind" >&2; exit 1; }
[ "$(wc -l < "$here/promote_hosted.bclj")" = "$(wc -l < "$hosted/erased.bclj")" ] \
  || { echo "drive.sh: erasure moved a line" >&2; exit 1; }

cp "$here/promote_hosted.bclj" "$hosted/subject.bclj"
"$repo/bin/beagle" build --target clj "$hosted/subject.bclj" "$hosted/with.clj"
cp "$hosted/erased.bclj" "$hosted/subject.bclj"
"$repo/bin/beagle" build --target clj "$hosted/subject.bclj" "$hosted/without.clj"
cmp -s "$hosted/with.clj" "$hosted/without.clj" \
  || { diff "$hosted/with.clj" "$hosted/without.clj" >&2
       echo "drive.sh: hosted emission is not identity" >&2; exit 1; }
echo "drive.sh: hosted clj emission byte-identical with and without the form"

cp "$here/promote_hosted.bclj" "$hosted/subject.bjs"
"$repo/bin/beagle" build --target js "$hosted/subject.bjs" "$hosted/with.js"
cp "$hosted/erased.bclj" "$hosted/subject.bjs"
"$repo/bin/beagle" build --target js "$hosted/subject.bjs" "$hosted/without.js"
cmp -s "$hosted/with.js" "$hosted/without.js" \
  || { diff "$hosted/with.js" "$hosted/without.js" >&2
       echo "drive.sh: hosted js emission is not identity" >&2; exit 1; }
echo "drive.sh: hosted js emission byte-identical with and without the form"

hosted_report="$(bb -cp "$hosted" -e "
(load-file \"$hosted/with.clj\")
(print (native.promote-hosted/report))")"
[ "$hosted_report" = "epoch-tail 42 -tail true" ] \
  || { echo "drive.sh: hosted run disagreed: $hosted_report" >&2; exit 1; }
echo "drive.sh: hosted run '$hosted_report' — promote returned the same object"

# The canonical surface path. It also leaves behind the complete module source
# facts the epoch fixture below re-reads, so both clauses are about one program.
# These are parameterized library functions; `--entry` is reserved for an
# executable zero-argument entry contract.
"$repo/bin/beagle" build --materializer c17 --out "$work/core" \
  "$probe" > "$work/core-build.log" 2>&1 || {
    sed -n '1,200p' "$work/core-build.log" >&2
    exit 1
  }
grep -qx 'result PASS' "$work/core/report.txt" \
  || { cat "$work/core/report.txt" >&2; echo "drive.sh: surface build did not pass" >&2; exit 1; }
[ "$(grep -c '^obligation-projection PASS ' "$work/core/report.txt")" = 10 ] \
  || { echo "drive.sh: surface build did not clear ten obligations" >&2; exit 1; }
# The surface path crosses the derived epoch stage, so the probe's four
# functions are the whole promote taxonomy in one C file:
#   promoted-text       interior concatenation -> minted epoch + a real promote
#   promoted-parameter  source already outlives the destination -> collapsed
#   promoted-count      epoch-free Int -> a register move, never a promote
#   escaping-text       no form, nothing interior -> no epoch at all
grep -qx 'stage native-to-epoch COMPLETE' "$work/core/report.txt" \
  || { echo "drive.sh: surface build did not cross the epoch stage" >&2; exit 1; }
[ "$(awk '$1 == "epoch-regions-minted" { print $2 }' "$work/core/report.txt")" = 1 ] \
  || { echo "drive.sh: surface build minted the wrong epoch count" >&2; exit 1; }
grep -q 'native_value_promote' "$work/core/module_0.c" \
  || { echo "drive.sh: surface build lost the handle-carrying promote" >&2; exit 1; }
[ "$(grep -c 'native_value_promote' "$work/core/module_0.c")" = 1 ] \
  || { echo "drive.sh: surface build promote count moved" >&2; exit 1; }
[ "$(grep -c 'native_arena native_epoch_' "$work/core/module_0.c")" = 1 ] \
  || { echo "drive.sh: surface build emitted no minted epoch arena" >&2; exit 1; }
grep -q 'native_arena_destroy' "$work/core/module_0.c" \
  || { echo "drive.sh: surface build left the minted epoch open" >&2; exit 1; }
cp "$work/core/source.facts" "$work/promote.facts"

modules=(core stages lower obligations simd c11 fold_c17 body_c17 qbe slice
         body_slice promote_validation_corpus)
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
(require 'native.promote-validation-corpus)
(def ns (find-ns 'native.promote-validation-corpus))
(when-not ((deref (ns-resolve ns 'emit-fixtures!)) \"$work/promote.facts\" \"$1\")
  (println (slurp (str \"$1\" \"/report.txt\")))
  (throw (ex-info \"promote fixture gate failed\" {})))
"
}

emit "$work/run-a"
emit "$work/run-b"

generated=(module_0.h module_0.c module_1.h module_1.c report.txt)
for name in "${generated[@]}"; do
  cmp -s "$work/run-a/$name" "$work/run-b/$name" \
    || { echo "drive.sh: re-emission is not byte-identical for $name" >&2; exit 1; }
done
cat "$work/run-a/report.txt"

publish_results() {
  local name
  mkdir -p "$art"
  for name in "${generated[@]}"; do
    cp -- "$work/run-a/$name" "$art/$name"
  done
}

if [ -n "${NATIVE_SLICE_NO_COMPILE:-}" ]; then
  publish_results
  exit 0
fi

build="$work/c"
mkdir -p "$build"
cp "$work/run-a"/module_*.h "$work/run-a"/module_*.c "$here/main.c" "$build/"
cp "$repo/native-core/shim/native_shim.c" "$repo/native-core/shim/native_shim.h" \
   "$repo/native-core/shim/native_unicode15_data.h" "$build/"

sources=(module_0.c module_1.c native_shim.c main.c)
strict=(-std=c17 -pedantic -Wall -Wextra -Werror)

( cd "$build" && gcc "${strict[@]}" -o probe_gcc "${sources[@]}" )
( cd "$build" && ./probe_gcc > "$work/run-gcc.txt" )
cat "$work/run-gcc.txt"
echo "drive.sh: gcc $(gcc -dumpversion) strict compile + run ok"

# The sanitizers are the point of this driver: the promoted Text is read after
# its epoch was destroyed, which is a use-after-free unless promote copied.
sanitize=(-fsanitize=address,undefined -fno-sanitize-recover=all
          -g)

( cd "$build" && gcc "${strict[@]}" "${sanitize[@]}" -o probe_gcc_san "${sources[@]}" )
( cd "$build" && ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=print_stacktrace=1 \
    ./probe_gcc_san > "$work/run-gcc-san.txt" )
cat "$work/run-gcc-san.txt"
echo "drive.sh: gcc ASan+UBSan (leak detection on) clean"

find_clang() {
  if command -v clang >/dev/null 2>&1; then command -v clang; return 0; fi
  local candidate
  candidate="$(ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null | sort -V | tail -1)"
  [ -n "$candidate" ] && printf '%s\n' "$candidate"
}

clang_bin="$(find_clang || true)"
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

echo "drive.sh: promote surface form G5 PASS"
publish_results
