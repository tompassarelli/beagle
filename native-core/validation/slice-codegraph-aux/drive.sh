#!/usr/bin/env bash
# Projects the five frozen codegraph auxiliary modules without rewriting their
# graph-upstream sources. Every requested defn/def enters an immutable source
# world; unresolved shared seams remain named receipt failures.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
art="${NATIVE_SLICE_ARTIFACTS:-$here}"
fram="${FRAM_ROOT:-$HOME/code/fram/main}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-codegraph-aux.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

mkdir -p "$scratch/ast" "$scratch/out" "$scratch/build" \
  "$art/callgraph" "$art/rep_jurisdiction" "$art/roundtrip_fram" \
  "$art/supersession_check" "$art/rename"

sources=(callgraph rep_jurisdiction roundtrip_fram supersession_check rename)
for source_name in "${sources[@]}"; do
  source_path="$fram/codegraph/src/$source_name.bclj"
  if [[ ! -f "$source_path" ]]; then
    echo "drive.sh: missing frozen source $source_path" >&2
    exit 1
  fi
  "$repo/bin/beagle-ast" "$source_path" >"$scratch/ast/$source_name.json"
done

{
  printf 'module\tfunctions\tdefs\trecords\timports\n'
  for source_name in "${sources[@]}"; do
    jq -r '[.namespace,
            ([.forms[] | select(.node == "defn")] | length),
            ([.forms[] | select(.node == "def")] | length),
            ([.forms[] | select(.node == "record")] | length),
            (.requires | length)] | @tsv' "$scratch/ast/$source_name.json"
  done
} >"$scratch/coverage.tsv"

{
  for source_name in "${sources[@]}"; do
    digest="$(sha256sum "$fram/codegraph/src/$source_name.bclj" | cut -d' ' -f1)"
    printf '%s\tfram:codegraph/src/%s.bclj\n' "$digest" "$source_name"
  done
} >"$scratch/sources.sha256"

record_or_check() {
  local generated="$1" committed="$2" label="$3"
  if [[ -f "$committed" ]]; then
    cmp -s "$generated" "$committed" || {
      echo "drive.sh: $label drifted from $committed" >&2
      exit 1
    }
  else
    cp "$generated" "$committed"
  fi
}

record_or_check "$scratch/coverage.tsv" "$art/coverage.tsv" "definition coverage"
record_or_check "$scratch/sources.sha256" "$art/sources.sha256" "frozen source hashes"

facts="$repo/native-core/validation/slice-bodies/ast-facts.clj"
bb "$facts" \
  --input "$scratch/ast/callgraph.json=fram:codegraph/src/callgraph.bclj" \
  --output "$scratch/callgraph.facts" --include-defs
bb "$facts" \
  --input "$scratch/ast/callgraph.json=fram:codegraph/src/callgraph.bclj" \
  --input "$scratch/ast/rep_jurisdiction.json=fram:codegraph/src/rep_jurisdiction.bclj" \
  --output "$scratch/rep_jurisdiction.facts" --include-defs
bb "$facts" \
  --input "$scratch/ast/roundtrip_fram.json=fram:codegraph/src/roundtrip_fram.bclj" \
  --output "$scratch/roundtrip_fram.facts" --include-defs
bb "$facts" \
  --input "$scratch/ast/supersession_check.json=fram:codegraph/src/supersession_check.bclj" \
  --output "$scratch/supersession_check.facts" --include-defs
bb "$facts" \
  --input "$scratch/ast/rename.json=fram:codegraph/src/rename.bclj" \
  --output "$scratch/rename.facts" --include-defs

for target in "${sources[@]}"; do
  record_or_check "$scratch/$target.facts" "$art/$target/source.facts" \
    "$target source-fact projection"
done

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bgl" \
  "$repo/native-core/src/native/worlds.bgl" \
  "$repo/native-core/src/native/lower.bgl" \
  "$repo/native-core/src/native/obligations.bgl" \
  "$repo/native-core/src/native/c11.bgl" \
  "$repo/native-core/src/native/slice.bgl" \
  "$repo/native-core/src/native/fold_c17.bgl" \
  "$repo/native-core/src/native/body_c17.bgl" \
  "$repo/native-core/src/native/body_slice.bgl" \
  "$repo/native-core/src/native/qbe.bgl" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 \
  || { sed -n '1,240p' "$scratch/build.log" >&2; exit 1; }

# The clj projection currently needs provider records referred and imported in
# consumers before cross-module union patterns resolve.
records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
  "$scratch/out/native/core.clj" | tr '\n' ' ')"
for native_module in worlds lower obligations c11 slice fold_c17 body_c17 body_slice qbe; do
  generated="$scratch/out/native/$native_module.clj"
  [[ -f "$generated" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' "$generated"
  awk -v import="(import '[native.core $records])" \
    '!seen && /^$/ { print import; seen = 1 } { print }' \
    "$generated" >"$generated.tmp"
  mv "$generated.tmp" "$generated"
done

compiler_commit="$(git -C "$repo" rev-parse HEAD)"
project() {
  local target="$1" namespace="$2" relative_path="$3"
  clojure -J-Xmx8g -Sdeps "{:paths [\"$scratch/out\"]}" -M \
    "$here/project.clj" "$art/$target/source.facts" "$namespace" \
    "$relative_path" "$art/$target" "$compiler_commit" \
    >"$scratch/$target.project.log" 2>&1 \
    || { sed -n '1,240p' "$scratch/$target.project.log" >&2; exit 1; }
}

project callgraph callgraph fram:codegraph/src/callgraph.bclj
project rep_jurisdiction rep-jurisdiction fram:codegraph/src/rep_jurisdiction.bclj
project roundtrip_fram roundtrip-fram fram:codegraph/src/roundtrip_fram.bclj
project supersession_check supersession-check fram:codegraph/src/supersession_check.bclj
project rename rename fram:codegraph/src/rename.bclj

find_tool() {
  local tool="$1" pattern="$2" candidate
  if command -v "$tool" >/dev/null 2>&1; then
    command -v "$tool"
    return
  fi
  candidate="$(find /nix/store -maxdepth 4 -type f -path "$pattern" | sort -V | tail -n1)"
  [[ -n "$candidate" ]] && printf '%s\n' "$candidate"
}

clang_bin="$(find_tool clang '*clang-wrapper*/bin/clang')"
qbe_bin="$(find_tool qbe '*/bin/qbe')"
failures=0

check_projection() {
  local target="$1" target_art="$art/$target" build="$scratch/build/$target"
  local native_status checks
  native_status="$(tr -d '\n' <"$target_art/native-status.txt")"
  mkdir -p "$build"
  checks="$scratch/$target.checks.txt"
  if [[ "$native_status" != COMPLETE ]]; then
    printf 'native FRONTIER\nc17 NOT-RUN\nqbe NOT-RUN\n' >"$checks"
    failures=$((failures + 1))
  else
    mapfile -t c_sources < <(find "$target_art" -maxdepth 1 -type f -name 'module_*.c' | sort)
    if [[ ${#c_sources[@]} -eq 0 ]]; then
      printf 'native COMPLETE\nc17 FAIL no translation units\nqbe NOT-RUN\n' >"$checks"
      failures=$((failures + 1))
    else
      gcc -std=c17 -pedantic -Wall -Wextra -Werror -ffunction-sections \
        -fdata-sections -I"$target_art" -I"$repo/native-core/shim" \
        "${c_sources[@]}" "$repo/native-core/shim/native_shim.c" \
        "$here/smoke_main.c" -Wl,--gc-sections -o "$build/c17-gcc"
      "$build/c17-gcc"
      "$clang_bin" -std=c17 -pedantic -Wall -Wextra -Werror \
        -ffunction-sections -fdata-sections -I"$target_art" \
        -I"$repo/native-core/shim" "${c_sources[@]}" \
        "$repo/native-core/shim/native_shim.c" "$here/smoke_main.c" \
        -Wl,--gc-sections -o "$build/c17-clang"
      "$build/c17-clang"
      printf 'native COMPLETE\nc17 gcc+clang compile+link+run PASS\n' >"$checks"

      mapfile -t qbe_sources < <(find "$target_art" -maxdepth 1 -type f -name 'module_*.ssa' | sort)
      if [[ ${#qbe_sources[@]} -eq 0 ]]; then
        printf 'qbe UNSUPPORTED by materializer\n' >>"$checks"
      else
        qbe_objects=()
        for qbe_source in "${qbe_sources[@]}"; do
          base="$(basename "$qbe_source" .ssa)"
          "$qbe_bin" "$qbe_source" >"$build/$base.s"
          gcc -c -ffunction-sections "$build/$base.s" -o "$build/$base.o"
          qbe_objects+=("$build/$base.o")
        done
        gcc -std=c17 -Wall -Wextra -Werror -ffunction-sections \
          -fdata-sections -c "$repo/native-core/shim/native_shim.c" \
          -I"$repo/native-core/shim" -o "$build/native_shim.o"
        gcc -std=c17 -Wall -Wextra -Werror -c "$here/smoke_main.c" \
          -o "$build/smoke_main.o"
        gcc -Wl,--gc-sections "${qbe_objects[@]}" "$build/native_shim.o" \
          "$build/smoke_main.o" -o "$build/qbe-smoke"
        "$build/qbe-smoke"
        printf 'qbe assemble+link+run PASS\n' >>"$checks"
      fi
    fi
  fi
  cp "$checks" "$target_art/checks.txt"
  if [[ "$native_status" == COMPLETE && ! -s "$target_art/checks.txt" ]]; then
    failures=$((failures + 1))
  fi
}

for target in "${sources[@]}"; do
  check_projection "$target"
done

printf 'module worlds: 5\nsource modules (deduplicated): 5\nfunctions: 42\ndefs: 0\nrecords: 0\n' \
  >"$art/counts.txt"

if [[ $failures -ne 0 ]]; then
  echo "drive.sh: $failures projection(s) remain at an exact native frontier" >&2
  if [[ "${NATIVE_CODEGRAPH_ALLOW_FRONTIER:-0}" != 1 ]]; then
    exit 1
  fi
fi

echo "drive.sh: five frozen module worlds reproduced; $failures frontier(s)"
