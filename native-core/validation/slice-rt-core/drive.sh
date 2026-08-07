#!/usr/bin/env bash
# Projects the complete fram.rt-core module through the native program pipeline.
# Pending semantics remain a named frontier; the normal gate accepts only all
# 25 functions, all seven obligations, and an executable C17 materialization.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
artifacts="${NATIVE_SLICE_ARTIFACTS:-$here}"
native_repo="${NATIVE_RT_CORE_NATIVE_REPO:-$repo}"
source_file="${FRAM_RT_CORE:-/home/tom/code/fram/main/src/fram/rt_core.bclj}"
managed_out="${FRAM_MANAGED_OUT:-/home/tom/code/fram/main/out}"
native_shim="$native_repo/native-core/shim"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-rt-core.XXXXXX")"
generated="$scratch/generated"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "slice-rt-core: $*" >&2
  exit 1
}

for command in awk bb clojure cmp cut gcc pkg-config rg sed sha256sum sort; do
  command -v "$command" >/dev/null 2>&1 \
    || die "required command is unavailable: $command"
done
[[ -f "$source_file" ]] || die "source is unavailable: $source_file"
[[ -f "$managed_out/fram/rt_core.clj" ]] \
  || die "managed projection is unavailable: $managed_out/fram/rt_core.clj"
[[ -d "$native_repo/native-core/src/native" ]] \
  || die "native source root is unavailable: $native_repo/native-core/src/native"
[[ -f "$native_shim/native_shim.c" &&
   -f "$native_shim/native_shim.h" &&
   -f "$native_shim/native_unicode15_data.h" ]] \
  || die "native shim is unavailable: $native_shim"
mkdir -p "$generated" "$artifacts"

modules=(core stages lower obligations c11 slice fold_c17 body_c17 body_slice qbe)
native_sources=()
for module in "${modules[@]}"; do
  source="$native_repo/native-core/src/native/$module.bclj"
  [[ -f "$source" ]] || die "native module is unavailable: $source"
  native_sources+=("$source")
done

semantic_digest="$({
  for source in "${native_sources[@]}"; do
    sha256sum "$source" | cut -d' ' -f1
  done
} | sha256sum | cut -d' ' -f1)"
compiler_commit="native-rt-core-projection-v0:$semantic_digest"

"$repo/bin/beagle-ast" "$source_file" >"$scratch/rt_core.ast.json"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  --input "$scratch/rt_core.ast.json=fram:src/fram/rt_core.bclj" \
  --output "$generated/rt_core.facts" \
  --include-defs
bb "$here/inventory.clj" "$scratch/rt_core.ast.json" "$generated/inventory.txt"

"$repo/bin/beagle-build-all" "${native_sources[@]}" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,240p' "$scratch/build.log" >&2
    exit 1
  }

# Generated Clojure needs provider record classes visible until imported union
# patterns are emitted with their defining namespace.
records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
  "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in stages lower obligations c11 slice fold_c17 body_c17 body_slice qbe; do
  target="$scratch/out/native/$module.clj"
  [[ -f "$target" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' "$target"
  awk -v import="(import '[native.core $records])" \
    '!seen && /^$/ { print import; seen = 1 } { print }' \
    "$target" >"$target.tmp"
  mv "$target.tmp" "$target"
done

clojure -Sdeps "{:paths [\"$scratch/out\"]}" -M \
  "$here/native_runner.clj" \
  "$generated/rt_core.facts" "$generated" "$compiler_commit" \
  "$generated/report.txt"

clojure -Sdeps "{:paths [\"$managed_out\"]}" -M \
  "$here/managed_runner.clj" >"$generated/managed.out"

[[ "$(awk -F '\t' '$1 == "rt-core" { print $2 }' "$generated/managed.out" \
        | sort -u | wc -l | tr -d ' ')" -eq 25 ]] \
  || die "managed oracle did not exercise exactly 25 functions"
[[ "$(awk -F '\t' '$1 == "rt-core-def" { print $2 }' "$generated/managed.out" \
        | sort -u | wc -l | tr -d ' ')" -eq 12 ]] \
  || die "managed oracle did not observe exactly 12 immutable definitions"
[[ "$(awk -F '\t' '$1 == "rt-core-error" { print $2 }' "$generated/managed.out" \
        | sort -u | wc -l | tr -d ' ')" -eq 1 ]] \
  || die "managed oracle did not observe the error declaration"

bb "$here/frontier.clj" "$generated/inventory.txt" "$generated/report.txt" \
  "$generated/frontier.txt"
bb "$here/function_map.clj" "$generated/report.txt" "$generated/function_map.h"
awk 'FNR == NR {
       if (($1 == "function") && ($3 == "LOWERED")) lowered[$2] = 1
       next
     }
     ($1 == "rt-core") && ($2 in lowered) { print $0 }' \
  "$generated/frontier.txt" "$generated/managed.out" \
  >"$generated/lowered-managed.out"
[[ "$(awk -F '\t' '{ print $2 }' "$generated/lowered-managed.out" \
        | sort -u | wc -l | tr -d ' ')" \
      -eq "$(rg -c '^lowered fn_[0-9]+ ' "$generated/report.txt")" ]] \
  || die "lowered managed oracle does not cover every materialized function"

digest_line() {
  local path="$1"
  local logical="$2"
  printf '%s  %s\n' "$(sha256sum "$path" | cut -d' ' -f1)" "$logical"
}

{
  digest_line "$source_file" 'fram:src/fram/rt_core.bclj'
  digest_line "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
    'beagle:native-core/validation/slice-bodies/ast-facts.clj'
  digest_line "$here/inventory.clj" \
    'beagle:native-core/validation/slice-rt-core/inventory.clj'
  digest_line "$here/frontier.clj" \
    'beagle:native-core/validation/slice-rt-core/frontier.clj'
  digest_line "$here/managed_runner.clj" \
    'beagle:native-core/validation/slice-rt-core/managed_runner.clj'
  digest_line "$here/native_runner.clj" \
    'beagle:native-core/validation/slice-rt-core/native_runner.clj'
  digest_line "$here/function_map.clj" \
    'beagle:native-core/validation/slice-rt-core/function_map.clj'
  digest_line "$here/main.c" \
    'beagle:native-core/validation/slice-rt-core/main.c'
  digest_line "$here/drive.sh" \
    'beagle:native-core/validation/slice-rt-core/drive.sh'
  for index in "${!modules[@]}"; do
    digest_line "${native_sources[$index]}" \
      "beagle:native-core/src/native/${modules[$index]}.bclj"
  done
  digest_line "$native_shim/native_shim.c" \
    'beagle:native-core/shim/native_shim.c'
  digest_line "$native_shim/native_shim.h" \
    'beagle:native-core/shim/native_shim.h'
  digest_line "$native_shim/native_unicode15_data.h" \
    'beagle:native-core/shim/native_unicode15_data.h'
} >"$generated/source.sha256"

artifact_names=(rt_core.facts inventory.txt managed.out lowered-managed.out
  report.txt frontier.txt function_map.h source.sha256)
for name in module_0.h module_0.c module_0.ssa; do
  [[ -f "$generated/$name" ]] && artifact_names+=("$name")
done
{
  for name in "${artifact_names[@]}"; do
    digest_line "$generated/$name" "beagle:native-core/validation/slice-rt-core/$name"
  done
} >"$generated/artifacts.sha256"
artifact_names+=(artifacts.sha256)

publish() {
  local name="$1"
  if [[ -f "$here/$name" ]] && ! cmp -s "$generated/$name" "$here/$name"; then
    if [[ "${NATIVE_RT_CORE_UPDATE:-0}" != 1 ]]; then
      diff -u "$here/$name" "$generated/$name" >&2 || true
      die "generated artifact drifted: $name"
    fi
  fi
  cp "$generated/$name" "$artifacts/$name"
}

for name in "${artifact_names[@]}"; do
  publish "$name"
done

for name in module_0.h module_0.c module_0.ssa; do
  if [[ -f "$here/$name" && ! -f "$generated/$name" ]]; then
    die "materializer stopped producing committed artifact: $name"
  fi
done

complete=1
rg -Fx 'stage typed-to-native COMPLETE' "$generated/report.txt" >/dev/null \
  || complete=0
rg -Fx 'program-functions 25' "$generated/report.txt" >/dev/null || complete=0
rg -Fx 'program-abis 25' "$generated/report.txt" >/dev/null || complete=0
[[ "$(rg -c '^obligation-projection PASS ' "$generated/report.txt")" -eq 7 ]] \
  || complete=0
if rg -n '^pending ' "$generated/report.txt" >/dev/null; then
  complete=0
fi
rg -q '^materialize OK module_0.h module_0.c$' "$generated/report.txt" \
  || complete=0

strict=(-std=c17 -pedantic -Wall -Wextra -Werror)
if rg -q '^materialize OK module_0.h module_0.c$' "$generated/report.txt"; then
  build="$scratch/c"
  mkdir -p "$build"
  cp "$generated/module_0.h" "$generated/module_0.c" \
    "$generated/function_map.h" "$here/main.c" "$build/"
  cp "$native_shim/native_shim.c" "$native_shim/native_shim.h" "$native_shim/native_unicode15_data.h" "$build/"

  (cd "$build" && gcc "${strict[@]}" -o probe_gcc \
    module_0.c native_shim.c main.c)
  "$build/probe_gcc" >"$scratch/gcc.out"
  clang_bin="$(command -v clang || true)"
  if [[ -z "$clang_bin" ]]; then
    clang_bin="$(ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null \
      | sort -V | tail -1 || true)"
  fi
  [[ -n "$clang_bin" ]] || die "Clang is required for the second C17 frontend"
  (cd "$build" && "$clang_bin" "${strict[@]}" \
    -o probe_clang module_0.c native_shim.c main.c)
  "$build/probe_clang" >"$scratch/clang.out"
  cmp -s "$scratch/gcc.out" "$generated/lowered-managed.out" \
    || die "GCC C17 probe differs from the lowered managed oracle"
  cmp -s "$scratch/clang.out" "$generated/lowered-managed.out" \
    || die "Clang C17 probe differs from the lowered managed oracle"
  echo "slice-rt-core: GCC and Clang strict C17 compile/link/run PASS"
fi

if rg -q '^qbe-materialize OK module_0.ssa$' "$generated/report.txt"; then
  command -v qbe >/dev/null 2>&1 || die "QBE accepted the program but qbe is unavailable"
  [[ -f "$here/qbe_main.c" ]] \
    || die "QBE accepted the program but qbe_main.c is unavailable"
  qbe "$generated/module_0.ssa" >"$scratch/module_0.s"
  gcc "${strict[@]}" -o "$scratch/qbe_probe" "$scratch/module_0.s" \
    "$native_shim/native_shim.c" "$here/qbe_main.c"
  "$scratch/qbe_probe" >"$scratch/qbe.out"
  cmp -s "$scratch/qbe.out" "$generated/lowered-managed.out" \
    || die "QBE probe differs from the lowered managed oracle"
  echo "slice-rt-core: QBE assemble/link/run PASS"
elif rg -q '^qbe-materialize REFUSED ' "$generated/report.txt"; then
  rg '^qbe-materialize REFUSED ' "$generated/report.txt"
  echo "slice-rt-core: QBE execution is outside the materializer's declared slice"
else
  if [[ "$complete" -eq 1 ]]; then
    die "QBE materialization neither succeeded nor gave a deterministic refusal"
  fi
  rg '^qbe-materialize ' "$generated/report.txt" || true
fi

if [[ "$complete" -ne 1 ]]; then
  cat "$generated/frontier.txt"
  if [[ "${NATIVE_RT_CORE_ALLOW_PENDING:-0}" == 1 ]]; then
    echo "slice-rt-core: pending frontier recorded (ALLOW_PENDING=1)"
    exit 0
  fi
  die "full rt_core native program is not complete"
fi

cat "$generated/report.txt"
