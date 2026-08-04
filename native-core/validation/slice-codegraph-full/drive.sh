#!/usr/bin/env bash
# Projects the complete fram codegraph module without reducing its definitions.
# The source's imports remain exact; unavailable provider worlds stay explicit
# pending obligations instead of being replaced with host-side stubs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
artifacts="${NATIVE_SLICE_ARTIFACTS:-$here}"
source_file="${NATIVE_CODEGRAPH_SOURCE:-/home/tom/code/fram/main/codegraph/src/codegraph.bclj}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-codegraph-full.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "slice-codegraph-full: $*" >&2
  exit 1
}

for command in bb clojure cmp gcc jq rg sha256sum; do
  command -v "$command" >/dev/null 2>&1 \
    || die "required command is unavailable: $command"
done
[[ -f "$source_file" ]] || die "source is unavailable: $source_file"
mkdir -p "$artifacts" "$scratch/generated" "$scratch/out"

"$repo/bin/beagle-ast" "$source_file" >"$scratch/codegraph.ast.json"
jq -r '.forms[] | select(.node == "record" or .node == "defn" or .node == "def") | [.node, .name] | @tsv' \
  "$scratch/codegraph.ast.json" >"$scratch/generated/inventory.tsv"
jq -r '.requires[] | [.ns, (.alias // ""), (.refer | tostring)] | @tsv' \
  "$scratch/codegraph.ast.json" >"$scratch/generated/dependencies.tsv"

[[ "$(rg -c '^record\t' "$scratch/generated/inventory.tsv")" -eq 1 ]] \
  || die "source inventory must contain exactly one record"
[[ "$(rg -c '^defn\t' "$scratch/generated/inventory.tsv")" -eq 18 ]] \
  || die "source inventory must contain exactly eighteen functions"
if rg -n '^def\t' "$scratch/generated/inventory.tsv" >/dev/null; then
  die "source inventory unexpectedly contains top-level defs"
fi
[[ "$(wc -l <"$scratch/generated/dependencies.tsv")" -eq 4 ]] \
  || die "source dependency inventory must contain exactly four direct imports"

bb "$here/project.clj" \
  --input "$scratch/codegraph.ast.json=fram:codegraph/src/codegraph.bclj" \
  --output "$scratch/generated/codegraph.facts" \
  --manifest "$scratch/generated/projection.tsv" \
  --summary "$scratch/generated/projection.txt"

[[ "$(rg -c $'\tform-kind\tt\tdefn$' "$scratch/generated/codegraph.facts")" -eq 18 ]] \
  || die "fact projection omitted a source function"
[[ "$(rg -c $'\tform-kind\tt\trecord$' "$scratch/generated/codegraph.facts")" -eq 1 ]] \
  || die "fact projection omitted the Row record"
if rg -n $'\tform-kind\tt\tdef$' "$scratch/generated/codegraph.facts" >/dev/null; then
  die "fact projection introduced an unexpected top-level def"
fi

source_digest="$(sha256sum "$source_file" | cut -d' ' -f1)"
printf '%s  %s\n' "$source_digest" 'fram:codegraph/src/codegraph.bclj' \
  >"$scratch/generated/source.sha256"

for name in codegraph.facts dependencies.tsv inventory.tsv projection.tsv \
  projection.txt source.sha256; do
  if [[ -f "$artifacts/$name" && -z "${NATIVE_CODEGRAPH_UPDATE:-}" ]] \
    && ! cmp -s "$scratch/generated/$name" "$artifacts/$name"; then
    diff -u "$artifacts/$name" "$scratch/generated/$name" >&2 || true
    die "source-derived artifact drifted: $name"
  fi
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
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,240p' "$scratch/build.log" >&2
    exit 1
  }

# Generated Clojure currently needs provider union records explicitly imported.
records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in worlds lower obligations c11 slice fold_c17 body_c17 body_slice qbe; do
  [[ -f "$scratch/out/native/$module.clj" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$scratch/out/native/$module.clj"
  awk -v import_line="(import '[native.core $records])" \
    '!seen && /^$/ { print import_line; seen = 1 } { print }' \
    "$scratch/out/native/$module.clj" >"$scratch/out/native/$module.clj.tmp"
  mv "$scratch/out/native/$module.clj.tmp" "$scratch/out/native/$module.clj"
done

clojure -Sdeps "{:paths [\"$scratch/out\"]}" -M "$here/pipeline.clj" \
  "$scratch/generated/codegraph.facts" \
  "$scratch/generated" \
  "$scratch/generated/report.txt"

for name in codegraph.facts dependencies.tsv inventory.tsv projection.tsv \
  projection.txt report.txt source.sha256; do
  cp "$scratch/generated/$name" "$artifacts/$name"
done
for name in module_0.h module_0.c module_0.ssa; do
  [[ -f "$scratch/generated/$name" ]] && cp "$scratch/generated/$name" "$artifacts/$name"
done

cat "$artifacts/report.txt"

if ! rg -Fx 'stage typed-to-native COMPLETE' "$artifacts/report.txt" >/dev/null; then
  [[ -n "${NATIVE_CODEGRAPH_ALLOW_PENDING:-}" ]] && exit 0
  die "the exact codegraph world is not complete; rerun with NATIVE_CODEGRAPH_ALLOW_PENDING=1 to refresh the checkpoint"
fi
[[ "$(rg -c '^lowered fn_[0-9]+ ' "$artifacts/report.txt")" -eq 18 ]] \
  || die "the complete world did not lower all eighteen source functions"
[[ "$(rg -c '^obligation-world PASS ' "$artifacts/report.txt")" -eq 7 ]] \
  || die "the complete world did not pass all seven world obligations"
[[ "$(rg -c '^obligation-projection PASS ' "$artifacts/report.txt")" -eq 7 ]] \
  || die "the executable projection did not pass all seven obligations"
if rg -n '^pending ' "$artifacts/report.txt" >/dev/null; then
  die "the complete world retained a pending obligation"
fi

if rg -Fx 'c17 OK module_0.h module_0.c' "$artifacts/report.txt" >/dev/null; then
  build="$scratch/c17"
  mkdir -p "$build"
  cp "$scratch/generated/module_0.h" "$scratch/generated/module_0.c" \
    "$here/main.c" "$repo/native-core/shim/native_shim.c" \
    "$repo/native-core/shim/native_shim.h" "$build/"
  (cd "$build" && gcc -std=c17 -pedantic -Wall -Wextra -Werror \
    module_0.c native_shim.c main.c -o probe_c17)
  "$build/probe_c17"
else
  die "the complete world did not produce the restricted C17 projection"
fi

if rg -Fx 'qbe OK module_0.ssa' "$artifacts/report.txt" >/dev/null; then
  qbe_build="$scratch/qbe"
  mkdir -p "$qbe_build"
  cp "$scratch/generated/module_0.ssa" "$here/qbe_main.c" \
    "$repo/native-core/shim/native_shim.c" \
    "$repo/native-core/shim/native_shim.h" "$qbe_build/"
  if command -v qbe >/dev/null 2>&1; then
    qbe "$qbe_build/module_0.ssa" >"$qbe_build/module_0.s"
  elif command -v direnv >/dev/null 2>&1; then
    direnv exec "$repo" qbe "$qbe_build/module_0.ssa" >"$qbe_build/module_0.s"
  else
    die "QBE accepted the world but no pinned qbe executable is reachable"
  fi
  (cd "$qbe_build" && gcc -std=c17 -pedantic -Wall -Wextra -Werror \
    module_0.s native_shim.c qbe_main.c -o probe_qbe)
  "$qbe_build/probe_qbe"
else
  rg -n '^qbe REFUSED ' "$artifacts/report.txt" \
    || die "the QBE support state was not recorded"
fi
