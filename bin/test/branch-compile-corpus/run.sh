#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C
export TZ=UTC

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch_relative=".beagle/branch-compile-corpus"
scratch="$repo/$scratch_relative"
lock="$repo/.beagle/branch-compile-corpus.lock"
mode="${1:---check}"

case "$mode" in
  --check|--observe) ;;
  *) echo "usage: $0 [--check|--observe]" >&2; exit 2 ;;
esac

mkdir -p "$repo/.beagle"
exec 9>"$lock"
flock -x -w 10 9 || {
  echo "branch-compile-corpus: another oracle run holds $lock" >&2
  exit 2
}

rm -rf "${scratch:?}"
mkdir -p "$scratch/sources" "$scratch/build" "$scratch/bundles"
raw_identities="$scratch/identities.raw.tsv"
identities="$scratch/identities.tsv"
churn="$scratch/churn.tsv"
semantic_cones="$scratch/semantic-cones.tsv"
context="$scratch/context.tsv"
: >"$raw_identities"
: >"$context"

sources=(foundation.bgl feature.bgl independent.bgl app.bgl)
entries=(corpus.app/run-score corpus.app/run-stable corpus.app/run-independent)
artifacts=(source.facts module.native-program native.entry-map module_0.h module_0.c)

prepare_case() {
  local case_id="$1"
  local source
  for source in "${sources[@]}"; do
    cp "$here/corpus/$source" "$scratch/sources/$source"
  done
  case "$case_id" in
    baseline|baseline-repeat) ;;
    comment-layout)
      cp "$here/mutations/comment-layout/foundation.bgl" \
        "$scratch/sources/foundation.bgl"
      ;;
    private-implementation)
      cp "$here/mutations/private-implementation/foundation.bgl" \
        "$scratch/sources/foundation.bgl"
      ;;
    public-interface)
      cp "$here/mutations/public-interface/foundation.bgl" \
        "$scratch/sources/foundation.bgl"
      cp "$here/mutations/public-interface/feature.bgl" \
        "$scratch/sources/feature.bgl"
      ;;
    *) echo "branch-compile-corpus: unknown case $case_id" >&2; exit 2 ;;
  esac
}

bundle_case() {
  local case_id="$1"
  local request="$scratch/bundles/$case_id.request.json"
  local response="$scratch/bundles/$case_id.json"
  jq -n \
    --rawfile foundation "$scratch/sources/foundation.bgl" \
    --rawfile feature "$scratch/sources/feature.bgl" \
    --rawfile independent "$scratch/sources/independent.bgl" \
    --rawfile app "$scratch/sources/app.bgl" \
    '{kind:"beagle.checked-bundle.request",
      schemaVersion:4,
      entrySourceId:"corpus/app.bgl",
      sources:[
        {sourceId:"corpus/foundation.bgl",bytesBase64:($foundation|@base64),authority:"package"},
        {sourceId:"corpus/feature.bgl",bytesBase64:($feature|@base64),authority:"package"},
        {sourceId:"corpus/independent.bgl",bytesBase64:($independent|@base64),authority:"package"},
        {sourceId:"corpus/app.bgl",bytesBase64:($app|@base64),authority:"package"}]}' \
    >"$request"
  timeout --foreground 90s "$repo/bin/beagle" ast-bundle \
    <"$request" >"$response"
  jq -e '.kind == "beagle.checked-bundle" and
         .schemaVersion == 4 and (.modules | length == 4)' \
    "$response" >/dev/null
  jq -r --arg case_id "$case_id" '
    (.modules[] |
      ([$case_id,"module-source",.sourceId,.sourceSha256],
       [$case_id,"module-interface",.sourceId,.interfaceSha256]) | @tsv),
    ([$case_id,"bundle","source-closure",.sourceClosureSha256] | @tsv),
    ([$case_id,"bundle","checked-bundle",.checkedBundleSha256] | @tsv),
    ([$case_id,"bundle","entry-projection",.entryProjection.projectionSha256] | @tsv)
  ' "$response" >>"$raw_identities"
}

build_case() {
  local case_id="$1"
  local output="$scratch/build/$case_id"
  local log="$scratch/build/$case_id.log"
  local source_args=()
  local entry_args=()
  local source entry artifact digest
  for entry in "${entries[@]}"; do
    entry_args+=(--entry "$entry")
  done
  for source in "${sources[@]}"; do
    source_args+=("$scratch_relative/sources/$source")
  done
  (
    cd "$repo"
    BEAGLE_CORE_OVERALL_TIMEOUT_SECONDS=220 \
      timeout --foreground 240s ./bin/beagle build \
        --materializer c17 \
        --out "$output" \
        "${entry_args[@]}" "${source_args[@]}"
  ) >"$log" 2>&1
  grep -Fqx 'result PASS' "$output/report.txt"
  timeout --foreground 30s bb "$here/inspect.clj" \
    "$case_id" "$output/module.native-program" "$output/source.facts" \
    "$here/units.tsv" \
    >>"$raw_identities"
  awk -v case_id="$case_id" '
    $1 == "native-provenance-v0" {
      print case_id "\tstage\t" $2 "\t" $3
    }
  ' "$output/report.txt" >>"$raw_identities"
  for artifact in "${artifacts[@]}"; do
    digest="$(sha256sum "$output/$artifact" | awk '{print $1}')"
    printf '%s\tartifact\t%s\tsha256:%s\n' \
      "$case_id" "$artifact" "$digest" >>"$raw_identities"
  done
  printf '%s\tgeneration\tbuild.manifest\t%s\n' \
    "$case_id" "$(tr -d '\n' <"$output/build.manifest.sha256")" >>"$context"
  printf '%s\treceipt-file\tnative.receipts\tsha256:%s\n' \
    "$case_id" "$(sha256sum "$output/native.receipts" | awk '{print $1}')" \
    >>"$context"
}

run_case() {
  local case_id="$1"
  echo "branch-compile-corpus: $case_id START"
  prepare_case "$case_id"
  bundle_case "$case_id"
  build_case "$case_id"
  echo "branch-compile-corpus: $case_id END"
}

for case_id in baseline baseline-repeat comment-layout private-implementation public-interface; do
  run_case "$case_id"
done

sort -t $'\t' -k1,1 -k2,2 -k3,3 "$raw_identities" >"$scratch/identities.with-repeat.tsv"
awk -F '\t' '$1 == "baseline"' "$scratch/identities.with-repeat.tsv" \
  >"$scratch/baseline.tsv"
awk -F '\t' 'BEGIN {OFS="\t"} $1 == "baseline-repeat" {$1="baseline"; print}' \
  "$scratch/identities.with-repeat.tsv" >"$scratch/baseline-repeat.tsv"
if ! diff -u "$scratch/baseline.tsv" "$scratch/baseline-repeat.tsv"; then
  echo "branch-compile-corpus: identical clean baseline builds diverged" >&2
  exit 1
fi
awk -F '\t' '$1 != "baseline-repeat"' "$scratch/identities.with-repeat.tsv" \
  >"$identities"

awk -F '\t' '
  BEGIN {OFS="\t"}
  NR == FNR {
    if ($1 == "baseline") baseline[$2 SUBSEP $3] = $4
    next
  }
  $1 != "baseline" && $1 != "baseline-repeat" {
    key = $2 SUBSEP $3
    if (!(key in baseline)) print $1, $2, $3, "added"
    else if (baseline[key] != $4) print $1, $2, $3, "changed"
  }
' "$identities" "$identities" | sort -t $'\t' -k1,1 -k2,2 -k3,3 >"$churn"

awk -F '\t' 'BEGIN {OFS="\t"}
  ($2 == "module-source" || $2 == "module-interface") {
    print $1, $2, $3
  }
' "$churn" >"$scratch/boundaries.tsv"
grep -v '^#' "$here/expected-boundaries.tsv" >"$scratch/expected-boundaries.tsv"
if ! diff -u "$scratch/expected-boundaries.tsv" "$scratch/boundaries.tsv"; then
  echo "branch-compile-corpus: a controlled mutation crossed the wrong source/interface boundary" >&2
  exit 1
fi

if awk -F '\t' '$2 == "semantic-unit-id" {found = 1} END {exit found ? 0 : 1}' \
  "$churn"; then
  echo "branch-compile-corpus: a semantic unit identity changed across mutations" >&2
  exit 1
fi

: >"$semantic_cones"
for case_id in comment-layout private-implementation public-interface; do
  mapfile -t changed_units < <(
    awk -F '\t' -v case_id="$case_id" '
      $1 == "baseline" && $2 == "semantic-unit-content" {
        baseline[$3] = $4
      }
      $1 == case_id && $2 == "semantic-unit-content" && baseline[$3] != $4 {
        print $3
      }
    ' "$identities" | sort
  )
  if ((${#changed_units[@]} == 0)); then
    changed="-"
  else
    changed="$(IFS=,; echo "${changed_units[*]}")"
  fi
  printf '%s\t%s\n' "$case_id" "$changed" >>"$semantic_cones"
done

for stage in typed-unit native-unit; do
  awk -F '\t' -v stage="$stage" 'BEGIN {OFS="\t"}
    $1 !~ /^#/ && $2 == stage {print $1, $3}
  ' "$here/expected-cones.tsv" >"$scratch/expected-$stage.tsv"
  if ! diff -u "$scratch/expected-$stage.tsv" "$semantic_cones"; then
    echo "branch-compile-corpus: semantic content changes differ from the expected $stage cone" >&2
    exit 1
  fi
done

printf 'compiler-commit\t%s\n' "$(git -C "$repo" rev-parse HEAD)" \
  >"$scratch/context.head.tsv"
cat "$context" >>"$scratch/context.head.tsv"
mv "$scratch/context.head.tsv" "$context"

if [[ "$mode" == "--check" ]]; then
  for oracle in identities churn; do
    if ! diff -u "$here/oracle/$oracle.tsv" "$scratch/$oracle.tsv"; then
      echo "branch-compile-corpus: current full-build $oracle drifted" >&2
      exit 1
    fi
  done
fi

echo "branch-compile-corpus: PASS clean full builds are deterministic"
echo "branch-compile-corpus: identities $identities"
echo "branch-compile-corpus: churn $churn"
echo "branch-compile-corpus: semantic cones $semantic_cones"
echo "branch-compile-corpus: run context $context"
