#!/usr/bin/env bash
# Accounts for every store.rt-core function at the Native lowering frontier.
# A pending whole-module result may report lowered functions, but it owns no
# executable and emits no artifact. A separate complete fixture proves C17
# execution without turning that frontier into a partial-program authority.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
artifacts="${NATIVE_SLICE_ARTIFACTS:-}"
native_repo="${NATIVE_RT_CORE_NATIVE_REPO:-$repo}"
store_checkout="$("$repo/native-core/validation/store-checkout.sh")"
source_file="$store_checkout/src/store/rt_core.bgl"
supported_probe="$here/supported_probe.bgl"
managed_out="$store_checkout/out"
native_shim="$native_repo/native-core/shim"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-rt-core.XXXXXX")"
generated="$scratch/generated"
[[ -n "$artifacts" ]] || artifacts="$scratch/artifacts"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "slice-rt-core: $*" >&2
  exit 1
}

for command in awk bb cut gcc jq pkg-config rg sed sha256sum sort; do
  command -v "$command" >/dev/null 2>&1 \
    || die "required command is unavailable: $command"
done
[[ -f "$source_file" ]] || die "source is unavailable: $source_file"
[[ -f "$supported_probe" ]] || die "supported probe is unavailable: $supported_probe"
[[ -f "$managed_out/store/rt_core.clj" ]] \
  || die "managed projection is unavailable: $managed_out/store/rt_core.clj"
[[ -d "$native_repo/native-core/src/native" ]] \
  || die "native source root is unavailable: $native_repo/native-core/src/native"
[[ -f "$native_shim/native_shim.c" &&
   -f "$native_shim/native_shim.h" &&
   -f "$native_shim/native_unicode15_data.h" ]] \
  || die "native shim is unavailable: $native_shim"
mkdir -p "$generated" "$artifacts"

modules=(core stages lower obligations simd c11 slice fold_c17 body_c17 body_slice qbe)
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
source_logical="$(jq -er '.sourceId | select(type == "string" and length > 0)' \
  "$scratch/rt_core.ast.json")"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  --input "$scratch/rt_core.ast.json=$source_logical" \
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
for module in stages lower obligations simd c11 slice fold_c17 body_c17 body_slice qbe; do
  target="$scratch/out/native/$module.clj"
  [[ -f "$target" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' "$target"
  awk -v import="(import '[native.core $records])" \
    '!seen && /^$/ { print import; seen = 1 } { print }' \
    "$target" >"$target.tmp"
  mv "$target.tmp" "$target"
done

bb -cp "$scratch/out" \
  "$here/native_runner.clj" \
  "$generated/rt_core.facts" "$source_logical" "$generated" "$compiler_commit" \
  "$generated/report.txt"

bb -cp "$managed_out" \
  "$here/managed_runner.clj" >"$generated/managed.out"

[[ "$(awk -F '\t' '$1 == "rt-core" { print $2 }' "$generated/managed.out" \
        | sort -u | wc -l | tr -d ' ')" -eq 25 ]] \
  || die "managed execution did not exercise exactly 25 functions"
[[ "$(awk -F '\t' '$1 == "rt-core-def" { print $2 }' "$generated/managed.out" \
        | sort -u | wc -l | tr -d ' ')" -eq 12 ]] \
  || die "managed execution did not observe exactly 12 immutable definitions"
[[ "$(awk -F '\t' '$1 == "rt-core-error" { print $2 }' "$generated/managed.out" \
        | sort -u | wc -l | tr -d ' ')" -eq 1 ]] \
  || die "managed execution did not observe the error declaration"

bb "$here/frontier.clj" "$generated/inventory.txt" "$generated/report.txt" \
  "$generated/frontier.txt"
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
  || die "managed execution does not cover every materialized function"

digest_line() {
  local path="$1"
  local logical="$2"
  printf '%s  %s\n' "$(sha256sum "$path" | cut -d' ' -f1)" "$logical"
}

{
  digest_line "$source_file" "$source_logical"
  digest_line "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
    'beagle:native-core/validation/slice-bodies/ast-facts.clj'
  digest_line "$repo/native-core/bin/source-facts.clj" \
    'beagle:native-core/bin/source-facts.clj'
  digest_line "$repo/native-core/bin/checked-program.clj" \
    'beagle:native-core/bin/checked-program.clj'
  digest_line "$here/inventory.clj" \
    'beagle:native-core/validation/slice-rt-core/inventory.clj'
  digest_line "$here/frontier.clj" \
    'beagle:native-core/validation/slice-rt-core/frontier.clj'
  digest_line "$here/managed_runner.clj" \
    'beagle:native-core/validation/slice-rt-core/managed_runner.clj'
  digest_line "$here/native_runner.clj" \
    'beagle:native-core/validation/slice-rt-core/native_runner.clj'
  digest_line "$supported_probe" \
    'native-core/validation/slice-rt-core/supported_probe.bgl'
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
  report.txt frontier.txt source.sha256)
{
  for name in "${artifact_names[@]}"; do
    digest_line "$generated/$name" "beagle:native-core/validation/slice-rt-core/$name"
  done
} >"$generated/artifacts.sha256"
artifact_names+=(artifacts.sha256)

publish() {
  local name="$1"
  cp "$generated/$name" "$artifacts/$name"
}

pending='pending TODO-NATIVE-FUNCTION-BODY: TODO-NATIVE-EQUALITY-UNION-VALUE-SEMANTICS: equality union contains a value without structural semantics [server-status-response]'
frontier_pending='function server-status-response PENDING - TODO-NATIVE-FUNCTION-BODY: TODO-NATIVE-EQUALITY-UNION-VALUE-SEMANTICS: equality union contains a value without structural semantics'
for line in \
  'projection-scope supported-functions-only' \
  'stage typed-to-native PENDING' \
  "$pending" \
  'materialize REFUSED native lowering incomplete' \
  'qbe-materialize REFUSED native lowering incomplete'; do
  rg -Fx "$line" "$generated/report.txt" >/dev/null \
    || die "projection report is missing: $line"
done
[[ "$(rg -c '^pending ' "$generated/report.txt")" -eq 1 ]] \
  || die "projection report did not retain exactly one pending function"
[[ "$(rg -c '^obligation-projection ' "$generated/report.txt" || true)" -eq 0 ]] \
  || die "pending lowering claimed executable projection obligations"
for artifact in module_0.h module_0.c module_0.ssa; do
  [[ ! -e "$generated/$artifact" ]] \
    || die "pending Native lowering emitted $artifact"
done
for line in \
  'source-functions 25' \
  'lowered-functions 24' \
  'pending-functions 1' \
  "$frontier_pending" \
  'frontier-accounting PASS accounted=25'; do
  rg -Fx "$line" "$generated/frontier.txt" >/dev/null \
    || die "frontier report is missing: $line"
done
[[ "$(rg -c '^function .* LOWERED-NONEXECUTABLE ' "$generated/frontier.txt")" -eq 24 ]] \
  || die "frontier did not account for exactly 24 lowered non-executable functions"
[[ "$(awk -F '\t' '{ print $2 }' "$generated/lowered-managed.out" \
      | sort -u | wc -l | tr -d ' ')" -eq 24 ]] \
  || die "managed execution did not cover exactly the supported 24-function set"

find_clang() {
  if command -v clang >/dev/null 2>&1; then
    command -v clang
    return 0
  fi
  local candidate
  candidate="$(compgen -G '/nix/store/*-clang-wrapper-*/bin/clang' \
    | sort -V | tail -1)"
  [[ -n "$candidate" ]] && printf '%s\n' "$candidate"
}

run_supported_probe() {
  local label="$1"
  local compiler="$2"
  local build="$scratch/supported-$label"
  local executable="$build/probe"
  mkdir -p "$build/artifacts"
  "$repo/bin/beagle" native-exe \
    --out "$executable" \
    --entry native.rt-core-supported-probe/probe \
    --cc "$compiler" \
    --artifacts "$build/artifacts" \
    "$supported_probe" >"$build/build.log"
  "$executable"
  rg -Fx 'stage typed-to-native COMPLETE' "$build/artifacts/report.txt" >/dev/null \
    || die "$label supported fixture did not complete native lowering"
  rg -Fx 'program-functions 3' "$build/artifacts/report.txt" >/dev/null \
    || die "$label supported fixture function set changed"
  rg -F 'native-exe-entry PASS name=native.rt-core-supported-probe/probe ' \
    "$build/artifacts/native-exe.report.txt" >/dev/null \
    || die "$label supported fixture entry mapping was not recorded"
  echo "slice-rt-core: $label supported fixture compile/link/run PASS"
}

clang_bin="$(find_clang || true)"
[[ -n "$clang_bin" ]] || die "Clang is required for the second C17 frontend"
run_supported_probe gcc "$(command -v gcc)"
run_supported_probe clang "$clang_bin"

for name in "${artifact_names[@]}"; do
  publish "$name"
done

cat "$generated/report.txt"
cat "$generated/frontier.txt"
