#!/usr/bin/env bash
# Fast consumer-facing native checks. This runs after the source test suite so
# the gate proves the route a real consumer uses, not only Beagle's internals.
set -euo pipefail
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
terrain_source="$here/qualified-terrain.bgl"
generation_source="$here/terrain-generation.bgl"
store_fixture="$here/store-atoms.bgl"
cache_root="${BEAGLE_CONSUMER_SMOKE_CACHE:-$repo/.beagle-out/consumer-smoke-cache}"
beagle_cli="${BEAGLE_CONSUMER_SMOKE_BEAGLE:-$repo/bin/beagle}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-consumer-smoke.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT INT TERM

die() {
  echo "consumer smoke: FAIL: $*" >&2
  exit 1
}

find_store_native_build() {
  local candidate
  while IFS= read -r candidate; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find "$repo" -type f -path '*/bin/beagle-store-native-build' -print \
    -not -path '*/.git/*' | LC_ALL=C sort)
  return 1
}

native_builder="$(find_store_native_build)" ||
  die "could not discover the consumer native builder"

mkdir -p "$cache_root"
core_cache_root="$cache_root/core-build"
mkdir -p "$core_cache_root"
legacy_semantic_read_store="$core_cache_root/semantic-read.storelog"
printf '%s' '__Store transaction log_MAGIC__' >"$legacy_semantic_read_store"
legacy_semantic_read_store_digest="$(
  sha256sum "$legacy_semantic_read_store" | awk '{print $1}'
)"
legacy_source_fact_root="$core_cache_root/source-facts"
mkdir -p "$legacy_source_fact_root"
legacy_source_fact_store="$legacy_source_fact_root/legacy.storelog"
printf '%s' '__Store transaction log_MAGIC__' >"$legacy_source_fact_store"
legacy_source_fact_store_digest="$(
  sha256sum "$legacy_source_fact_store" | awk '{print $1}'
)"
export BEAGLE_CORE_BUILD_CACHE="$core_cache_root"

# The Atom cell is intentionally outside QBE's current frontier. Keep that
# expected, diagnostic refusal local to this smoke fixture; the C17 report is
# still required to prove complete native lowering.
qbe_ledger="$scratch/qbe-frontier.ledger"
printf '%s\n' '# consumer-smoke fixture frontier' >"$qbe_ledger"
printf 'store.consumer-smoke/atom-count\tshape-outside-slice\t-\n' \
  >>"$qbe_ledger"

qualified_artifacts="$scratch/qualified"
"$beagle_cli" build --materializer c17 \
  --out "$qualified_artifacts" \
  --entry native.terrain-generation/brick-index \
  "$terrain_source" "$generation_source" \
  >"$scratch/qualified.log" 2>&1 || {
    sed -n '1,160p' "$scratch/qualified.log" >&2
    die "qualified terrain fixture did not build through Native Core"
  }

grep -Fqx 'stage typed-to-native COMPLETE' "$qualified_artifacts/report.txt" ||
  die "qualified terrain fixture did not complete Native lowering"
grep -Fqx 'native-lowering-result NativeLoweringCompleteV0' \
  "$qualified_artifacts/report.txt" ||
  die "qualified terrain fixture omitted NativeLoweringCompleteV0"
grep -Fq $'\tqualifier\tt\tterrain' "$qualified_artifacts/source.facts" ||
  die "qualified terrain fixture lost the terrain qualifier"
grep -Fq $'\tname\tt\tbrick-edge' "$qualified_artifacts/source.facts" ||
  die "qualified terrain fixture lost brick-edge"
grep -Fq 'brick-index' "$qualified_artifacts/report.txt" ||
  die "qualified terrain fixture did not lower its consumer entry"
[[ "$(sha256sum "$legacy_semantic_read_store" | awk '{print $1}')" == \
  "$legacy_semantic_read_store_digest" ]] ||
  die "qualified terrain build mutated the incompatible unkeyed semantic cache"
mapfile -t semantic_read_stores < <(
  find "$core_cache_root" -maxdepth 1 -type f \
    -name 'semantic-read-????????????????????????????????????????????????????????????????.storelog' \
    -print | LC_ALL=C sort
)
(( ${#semantic_read_stores[@]} >= 1 )) ||
  die "qualified terrain build did not select a keyed semantic cache cohort"
[[ "$(sha256sum "$legacy_source_fact_store" | awk '{print $1}')" == \
  "$legacy_source_fact_store_digest" ]] ||
  die "qualified terrain build mutated the incompatible source-fact cache"
mapfile -t source_fact_stores < <(
  find "$core_cache_root" -mindepth 2 -maxdepth 2 -type f \
    -path "$core_cache_root/source-facts-????????????????????????????????????????????????????????????????/*.storelog" \
    -print | LC_ALL=C sort
)
(( ${#source_fact_stores[@]} >= 1 )) ||
  die "qualified terrain build did not select a keyed source-fact cache cohort"
printf 'consumer smoke: qualified terrain native symbol table ok\n'

store_artifact="$(BEAGLE_STORE_BEAGLE="$beagle_cli" \
  BEAGLE_STORE_ALLOW_UNPINNED_BEAGLE=1 \
  BEAGLE_STORE_NATIVE_CACHE="$cache_root" \
  BEAGLE_STORE_QBE_FRONTIER_LEDGER="$qbe_ledger" \
  "$native_builder" --host program \
    --entry store.consumer-smoke/atom-count \
    "$store_fixture")" ||
  die "Store-shaped Atom fixture failed NativeLoweringCompleteV0"

[[ -f "$store_artifact/report.txt" ]] ||
  die "Store-shaped Atom fixture omitted its native report"
grep -Fqx 'native-lowering-result NativeLoweringCompleteV0' \
  "$store_artifact/report.txt" ||
  die "Store-shaped Atom fixture omitted NativeLoweringCompleteV0"
grep -Fqx 'stage typed-to-native COMPLETE' "$store_artifact/report.txt" ||
  die "Store-shaped Atom fixture did not complete Native lowering"
grep -Fqx 'result PASS' "$store_artifact/report.txt" ||
  die "Store-shaped Atom fixture native report did not pass"
printf 'consumer smoke: Store-shaped Atom native completeness ok\n'

# Two consumers building the same thing at once is the ordinary case, not an
# exotic one, and the Core result cache lock is what decides whether the second
# one waits for the first build's whole compile. This runs here because the
# cache above is already warm: the gate needs a real compile to probe, not a
# multi-minute compiler projection.
BEAGLE_CORE_LOCK_GATE_BEAGLE="$beagle_cli" \
  "$repo/native-core/tests/core_result_lock_gate.sh" "$cache_root" ||
  die "concurrent Core builds contend on the result cache lock"

echo "consumer smoke: PASS"
