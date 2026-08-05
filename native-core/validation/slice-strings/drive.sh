#!/usr/bin/env bash
# Drive the text corpus and a real FRI replay slice through the native pipeline:
#   beagle-ast -> source facts -> sealed source world -> typed world
#     -> native world with lowered blocks -> 7 obligations
#     -> native.body-c17 -> gcc/clang -std=c17 -Werror -> run the probe main.
#
# Two projections: text_ops.facts (this directory's corpus) and
# replay_text.facts (an unmodified fram.fri-replay helper slice). Both generated
# modules are compiled and run. Set FRAM_REPLAY to re-derive the replay facts and
# fail on drift.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-$here}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-strings.XXXXXX")"
replay_art="${NATIVE_REPLAY_ARTIFACTS:-$scratch/replay}"
trap 'rm -rf "${scratch:?}"' EXIT
mkdir -p "$replay_art"

facts_of() { # facts_of <source> <relative-path> <out.facts>
  "$repo/bin/beagle-ast" "$1" >"$scratch/ast.json"
  bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
    "$scratch/ast.json=$2" "$3" --include-defs
}

# --- corpus projection: the source is in this repo, so always regenerate ----
facts_of "$here/text_ops.bclj" \
  "beagle:native-core/validation/slice-strings/text_ops.bclj" \
  "$scratch/text_ops.facts"
if [[ -f "$art/text_ops.facts" ]] \
   && ! cmp -s "$scratch/text_ops.facts" "$art/text_ops.facts"; then
  echo "drive.sh: regenerated projection differs from the committed text_ops.facts" >&2
  exit 1
fi
cp "$scratch/text_ops.facts" "$art/text_ops.facts"

# --- replay projection: real fram source, re-derived only on request -------
replay_forms=(digit-table no-strings char-at split-on index-of last-index-of
  "trim-character?" trim-line join-strings IntParse digit-value parse-int strip-at
  line-version line-assert line-retract line-batch line-invalid ParsedFact ParsedOp
  no-facts invalid-fact invalid-op parse-fact parse-facts "facts-parsed?"
  parse-mutation parse-batch parse-line act-assert act-retract ModelTriple Model
  Action ReplayCommit no-triples no-actions no-commits initial-model find-exact
  find-group remove-at "single-predicate?" subject-predicate-count "collapses?"
  "declaration-collapse?" GroupRemoval remove-group ApplyResult apply-assert
  apply-retract apply-action kind-version kind-ok kind-reject
  reason-invalid-request reason-conflict reason-cardinality-collapse Outcome
  MutationResult no-outcomes reject op-actions "any-local-base?" apply-actions
  mutate ReplayFrame ReplayResult no-frames replay)
if [[ -n "${FRAM_REPLAY:-}" ]]; then
  "$repo/bin/beagle-ast" "$FRAM_REPLAY" >"$scratch/replay.json"
  bb "$here/select-forms.clj" "$scratch/replay.json" "$scratch/replay-sel.json" \
    "${replay_forms[@]}"
  bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
    "$scratch/replay-sel.json=fram:src/fram/fri_replay.bclj" \
    "$scratch/replay_text.facts" --include-defs
  if [[ -f "$art/replay_text.facts" ]] \
     && ! cmp -s "$scratch/replay_text.facts" "$art/replay_text.facts"; then
    echo "drive.sh: fram.fri-replay slice drifted from the committed projection" >&2
    exit 1
  fi
  cp "$scratch/replay_text.facts" "$art/replay_text.facts"
  sha256sum "$FRAM_REPLAY" | cut -d' ' -f1 >"$art/replay_text.source.sha256"
fi

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bgl" \
  "$repo/native-core/src/native/worlds.bgl" \
  "$repo/native-core/src/native/lower.bgl" \
  "$repo/native-core/src/native/obligations.bgl" \
  "$repo/native-core/src/native/c11.bgl" \
  "$repo/native-core/src/native/slice.bgl" \
  "$repo/native-core/src/native/fold_c17.bgl" \
  "$repo/native-core/src/native/body_c17.bgl" \
  "$repo/native-core/src/native/qbe.bgl" \
  "$repo/native-core/src/native/body_slice.bgl" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 \
  || { sed -n '1,200p' "$scratch/build.log" >&2; exit 1; }

# A cross-module `match` on an imported union emits an unqualified variant name;
# re-exporting native.core's records into each consumer namespace is the repo's
# standing workaround until the emitter qualifies them.
records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' "$scratch/out/native/core.clj" | tr '\n' ' ')"
for m in worlds lower obligations c11 slice fold_c17 body_c17 qbe body_slice; do
  [ -f "$scratch/out/native/$m.clj" ] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' "$scratch/out/native/$m.clj"
  awk -v imp="(import '[native.core $records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' \
    "$scratch/out/native/$m.clj" >"$scratch/out/native/$m.clj.tmp"
  mv "$scratch/out/native/$m.clj.tmp" "$scratch/out/native/$m.clj"
done

clojure -Sdeps "{:paths [\"$scratch/out\"]}" -M -e "
(require 'native.body-slice)
(spit \"$art/report.txt\"
  (native.body-slice/emit-slice! \"$art/text_ops.facts\" \"native.text-ops\"
    \"native-core/validation/slice-strings/text_ops.bclj\" \"$art\"
    \"native-slice-strings-v0\"))
(spit \"$art/replay-report.txt\"
  (native.body-slice/emit-slice! \"$art/replay_text.facts\" \"fram.fri-replay\"
    \"fram:src/fram/fri_replay.bclj\" \"$replay_art\"
    \"native-slice-strings-v0\"))"

cat "$art/report.txt"
echo "-- fram.fri-replay native slice --"
cat "$art/replay-report.txt"

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

replay_build="$scratch/replay-c"
mkdir -p "$replay_build"
cp "$replay_art/module_0.h" "$replay_art/module_0.c" "$here/replay_main.c" \
  "$replay_build/"
cp "$repo/native-core/shim/native_shim.c" "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" \
  "$replay_build/"
( cd "$replay_build" && gcc "${strict[@]}" -o replay_gcc \
    module_0.c native_shim.c replay_main.c )
( cd "$replay_build" && ./replay_gcc )
echo "drive.sh: replay helpers gcc strict compile + run ok"

if [ -n "$clang_bin" ]; then
  ( cd "$replay_build" && "$clang_bin" -std=c17 -Werror -o replay_clang \
      module_0.c native_shim.c replay_main.c )
  ( cd "$replay_build" && ./replay_clang )
  echo "drive.sh: replay helpers clang compile + run ok"
fi
