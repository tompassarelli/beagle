#!/usr/bin/env bash
# Create the committed G0 package and its canonical native rebuild bundle.
# This is the sole hosted trust boundary; normal rebuild-next never calls it.

set -euo pipefail
export LC_ALL=C
export TZ=UTC

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
trusted="$here/trusted-seed/lp64-c17"
published_bundle="$here/native-compiler.bundle"

die() {
  printf 'native-cold-genesis: %s\n' "$*" >&2
  exit 2
}

[[ $# -eq 1 && "$1" == "--accept-hosted-cold-genesis" ]] ||
  die 'usage: cold-genesis.sh --accept-hosted-cold-genesis'
[[ -z "$(git -C "$repo" status --short --untracked-files=no)" ]] ||
  die 'tracked worktree must be clean before cold genesis'

for command in git sha256sum wc dd awk readelf ldd rg install realpath cc; do
  command -v "$command" >/dev/null 2>&1 || die "required command is absent: $command"
done
[[ -x "$repo/native-core/bin/run-bounded" ]] ||
  die 'native Rust supervisor is absent'
[[ -x "$repo/bin/beagle-native-exe" ]] ||
  die 'hosted cold-genesis driver is absent'

scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-native-cold-genesis.XXXXXX")"
cleanup() {
  local status=$?
  rm -rf "${scratch:?}"
  return "$status"
}
trap cleanup EXIT

stage="$scratch/package"
artifacts="$scratch/artifacts"
mkdir -p "$stage/bin" "$artifacts"

printf 'native-cold-genesis: building G0 through the explicit hosted boundary\n' >&2
set +e
BEAGLE_NATIVE_EXE_CACHE="$scratch/native-exe-cache" \
BEAGLE_DEV_FACT_REUSE=0 \
  "$repo/native-core/bin/run-bounded" 180 5 -- \
  "$repo/bin/beagle-native-exe" \
    --out "$stage/bin/beagle" \
    --artifacts "$artifacts" \
    --entry beagle.cli/main! \
    --module-root "native-core/src=$repo/native-core/src" \
    --module-root "store/src=$repo/store/src" \
    -- "$repo/native-core/src/beagle/cli.bgl" \
    >"$scratch/cold-build.log" 2>&1
build_status=$?
set -e
if [[ $build_status -ne 0 ]]; then
  tail -n 160 "$scratch/cold-build.log" >&2
  die "hosted cold-genesis build failed with status $build_status"
fi

readelf -h "$stage/bin/beagle" >/dev/null 2>&1 ||
  die 'cold genesis did not produce an ELF executable'
if ldd "$stage/bin/beagle" 2>/dev/null | rg -qi \
  'racket|raco|python|pypy|babashka|clojure|java|graal|node|deno|bun'; then
  die 'hosted runtime dependency leaked into G0'
fi

"$stage/bin/beagle" bootstrap-contract >"$scratch/bootstrap-contract"
expected_usage='usage: beagle rebuild-next --bundle MANIFEST --out OUT --parent-lineage FILE'
actual_usage="$($stage/bin/beagle rebuild-next --help 2>&1)" ||
  die 'G0 does not expose rebuild-next'
[[ "$actual_usage" == "$expected_usage" ]] ||
  die 'G0 rebuild-next usage differs from the contract'

contract_field() {
  local key="$1"
  local contract="$scratch/bootstrap-contract"
  local count value
  count="$(awk -v key="$key" '$1 == key && NF == 2 {count += 1} END {print count + 0}' "$contract")"
  [[ "$count" == 1 ]] || die "bootstrap contract field is not unique: $key"
  value="$(awk -v key="$key" '$1 == key && NF == 2 {print $2}' "$contract")"
  printf '%s' "$value"
}

content_id_file() {
  printf 'sha256:%s' "$(sha256sum "$1" | awk '{print $1}')"
}

source_facts_id="$(content_id_file "$artifacts/source.facts")"
native_program_id="$(content_id_file "$artifacts/module.native-program")"
printf '%s' "$source_facts_id" >"$scratch/source.facts.content-id"
printf '%s' "$native_program_id" >"$scratch/module.native-program.content-id"

context_id="$(contract_field compiler-context-content-id)"
schema_id="$(contract_field schema-content-id)"
rule_set_id="$(contract_field rule-set-content-id)"
datum_reader_id="$(contract_field datum-reader-content-id)"
store_evaluator_id="$(contract_field store-evaluator-content-id)"
rule_scheduler_id="$(contract_field rule-scheduler-content-id)"
materializer_id="$(contract_field materializer-content-id)"
target_id="$(contract_field target-id)"
[[ "$target_id" == c17 ]] || die 'bootstrap contract target is not c17'

for content_id in \
  "$source_facts_id" "$native_program_id" "$context_id" "$schema_id" \
  "$rule_set_id" "$datum_reader_id" "$store_evaluator_id" \
  "$rule_scheduler_id" "$materializer_id"; do
  [[ "$content_id" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "malformed content ID: $content_id"
done

semantic_payload="beagle-native-rebuild-semantic/v1|$context_id|$schema_id|$rule_set_id|$source_facts_id|$native_program_id"
semantic_id="sha256:$(printf '%s' "$semantic_payload" | sha256sum | awk '{print $1}')"
encoding='beagle-native-rebuild-c17/v1|cc|module_0.c,native_shim.c,entry.c'
encoding_id="sha256:$(printf '%s' "$encoding" | sha256sum | awk '{print $1}')"

required_artifacts=(
  module_0.h
  module_0.c
  native_shim.h
  native_shim.c
  native_unicode15_data.h
  entry.c
)
for name in "${required_artifacts[@]}"; do
  [[ -f "$artifacts/$name" ]] || die "cold build omitted artifact: $name"
done
[[ ! -e "$artifacts/native_parallel.c" ]] ||
  die 'parallel compiler artifacts require a distinct linker contract'

artifact_names=(
  source.facts.content-id
  module.native-program.content-id
  module_0.h
  module_0.c
  native_shim.h
  native_shim.c
  native_unicode15_data.h
  entry.c
)
artifact_paths=(
  "$scratch/source.facts.content-id"
  "$scratch/module.native-program.content-id"
  "$artifacts/module_0.h"
  "$artifacts/module_0.c"
  "$artifacts/native_shim.h"
  "$artifacts/native_shim.c"
  "$artifacts/native_unicode15_data.h"
  "$artifacts/entry.c"
)

envelope="$scratch/artifact-envelope"
: >"$envelope"
append_literal() {
  local value="$1"
  local byte_count
  byte_count="$(printf '%s' "$value" | wc -c | awk '{print $1}')"
  printf '%s:%s' "$byte_count" "$value" >>"$envelope"
}
append_file_payload() {
  local path="$1"
  local byte_count
  byte_count="$(wc -c <"$path" | awk '{print $1}')"
  printf '%s:' "$byte_count" >>"$envelope"
  dd if="$path" of="$envelope" oflag=append conv=notrunc status=none
}

append_literal 'beagle-target-artifact-v1'
append_literal 'c17'
append_literal "$encoding"
append_literal "$encoding_id"
append_literal "${#artifact_names[@]}"
for index in "${!artifact_names[@]}"; do
  name="${artifact_names[$index]}"
  path="${artifact_paths[$index]}"
  file_id="$(content_id_file "$path")"
  byte_count="$(wc -c <"$path" | awk '{print $1}')"
  append_literal "$name"
  append_file_payload "$path"
  append_literal "$file_id"
  append_literal "$byte_count"
  append_literal "$file_id"
done

materialization_id="$(content_id_file "$envelope")"
bundle="$scratch/native-compiler.bundle"
{
  printf 'beagle-native-rebuild-bundle/v1\n'
  printf 'semantic-content-id %s\n' "$semantic_id"
  printf 'materialization-content-id %s\n' "$materialization_id"
  printf 'artifact-envelope\n'
} >"$bundle"
dd if="$envelope" of="$bundle" oflag=append conv=notrunc status=none

executable_id="$(content_id_file "$stage/bin/beagle")"
manifest="$stage/beagle-native-artifact.manifest"
{
  printf 'beagle-native-seed-artifact/v2\n'
  printf 'semantic-content-id %s\n' "$semantic_id"
  printf 'materialization-content-id %s\n' "$materialization_id"
  printf 'executable-content-id %s\n' "$executable_id"
  printf 'compiler-context-content-id %s\n' "$context_id"
  printf 'schema-content-id %s\n' "$schema_id"
  printf 'rule-set-content-id %s\n' "$rule_set_id"
  printf 'target-id c17\n'
  printf 'datum-reader-content-id %s\n' "$datum_reader_id"
  printf 'store-evaluator-content-id %s\n' "$store_evaluator_id"
  printf 'rule-scheduler-content-id %s\n' "$rule_scheduler_id"
  printf 'materializer-content-id %s\n' "$materializer_id"
  printf 'entry-command rebuild-next\n'
  printf 'hosted-runtime-required false\n'
} >"$manifest"

lineage="$stage/beagle-native-lineage.edn"
printf '{:compiler-context-id "%s" :executable-content-id "%s" :format "beagle-native-compiler-lineage/v2" :generation 0 :materialization-content-id "%s" :parent-executable-content-id nil :parent-lineage-content-id nil :rule-set-content-id "%s" :schema-content-id "%s" :semantic-content-id "%s" :target-id "c17"}\n' \
  "$context_id" "$executable_id" "$materialization_id" "$rule_set_id" \
  "$schema_id" "$semantic_id" >"$lineage"

source_commit="$(git -C "$repo" rev-parse HEAD)"
driver_id="$(content_id_file "$repo/bin/beagle-native-exe")"
cc_path="$(realpath "$(command -v cc)")"
cc_id="$(content_id_file "$cc_path")"
receipt="$stage/TRUSTED-COLD-GENESIS"
{
  printf 'beagle-native-cold-genesis/v1\n'
  printf 'source-commit %s\n' "$source_commit"
  printf 'trusted-boundary bin/beagle-native-exe\n'
  printf 'hosted-driver-content-id %s\n' "$driver_id"
  printf 'c17-compiler-content-id %s\n' "$cc_id"
  printf 'semantic-content-id %s\n' "$semantic_id"
  printf 'materialization-content-id %s\n' "$materialization_id"
  printf 'executable-content-id %s\n' "$executable_id"
  printf 'normal-hosted-runtime-required false\n'
} >"$receipt"

mkdir -p "$trusted/bin"
install -m 0755 "$stage/bin/beagle" "$trusted/bin/beagle"
install -m 0444 "$manifest" "$trusted/beagle-native-artifact.manifest"
install -m 0444 "$lineage" "$trusted/beagle-native-lineage.edn"
install -m 0444 "$receipt" "$trusted/TRUSTED-COLD-GENESIS"
install -m 0444 "$bundle" "$published_bundle"

printf 'native-cold-genesis: PASS source=%s semantic=%s materialization=%s executable=%s\n' \
  "$source_commit" "$semantic_id" "$materialization_id" "$executable_id"
