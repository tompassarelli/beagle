#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/relation-surface-v1.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "relation-surface-v1: $*" >&2
  exit 1
}

translator_sources=(
  "$repo/native-core/src/beagle/datum_reader.bgl"
  "$repo/native-core/src/beagle/language_capsule_v1.bgl"
  "$repo/native-core/src/beagle/language_container_cst.bgl"
  "$repo/native-core/src/beagle/language_reader_protocol_v1.bgl"
  "$repo/native-core/src/beagle/language_shared_datum_reader_v1.bgl"
  "$here/translator.bgl"
)

timeout --foreground 30s "$repo/bin/beagle" syntax "$here/translator.bgl"
timeout --foreground 30s "$repo/bin/beagle" check --agent \
  "${translator_sources[@]}"
timeout --foreground 120s "$repo/bin/beagle" native-exe \
  --out "$scratch/relation-surface-v1-translator" \
  --entry native.relation-surface-v1-translator/main \
  "${translator_sources[@]}"

timeout --foreground 10s "$scratch/relation-surface-v1-translator" \
  --probe-relabel \
  "$here/projection-symbols.brel" \
  "native-core/validation/relation-surface-v1/projection-symbols.brel" \
  || die "reader product could be relabeled onto a different logical path"

translate() {
  local physical="$1"
  local logical="$2"
  local core="$3"
  local receipt="$4"
  local source_map="$5"

  timeout --foreground 10s "$scratch/relation-surface-v1-translator" \
    "$physical" "$logical" "$core" "$receipt" "$source_map"
}

translate \
  "$here/projection-symbols.brel" \
  "native-core/validation/relation-surface-v1/projection-symbols.brel" \
  "$scratch/symbols.bgl" \
  "$scratch/symbols.receipt" \
  "$scratch/symbols.core-map.tsv"
translate \
  "$here/projection-words.brel" \
  "native-core/validation/relation-surface-v1/projection-words.brel" \
  "$scratch/words.bgl" \
  "$scratch/words.receipt" \
  "$scratch/words.core-map.tsv"
translate \
  "$here/projection-symbols.brel" \
  "native-core/validation/relation-surface-v1/projection-symbols.brel" \
  "$scratch/symbols-repeat.bgl" \
  "$scratch/symbols-repeat.receipt" \
  "$scratch/symbols-repeat.core-map.tsv"

cmp -s "$scratch/symbols.bgl" "$scratch/words.bgl" \
  || die "layout and aliases changed canonical Core bytes"
cmp -s "$scratch/symbols.bgl" "$scratch/symbols-repeat.bgl" \
  || die "repeat read changed canonical Core bytes"
cmp -s "$scratch/symbols.receipt" "$scratch/symbols-repeat.receipt" \
  || die "repeat read changed projection receipt bytes"
cmp -s "$scratch/symbols.core-map.tsv" "$scratch/symbols-repeat.core-map.tsv" \
  || die "repeat read changed Core source-map bytes"
if cmp -s "$scratch/symbols.receipt" "$scratch/words.receipt"; then
  die "different source projections produced identical receipts"
fi
if cmp -s "$scratch/symbols.core-map.tsv" "$scratch/words.core-map.tsv"; then
  die "different source projections produced identical Core source maps"
fi

receipt_value() {
  local field="$1"
  local receipt="$2"
  rg -N "^${field} " "$receipt" | cut -d' ' -f2-
}

symbols_core_expression_id="$(receipt_value core-expression-id "$scratch/symbols.receipt")"
words_core_expression_id="$(receipt_value core-expression-id "$scratch/words.receipt")"
symbols_module_id="$(receipt_value canonical-module-id "$scratch/symbols.receipt")"
words_module_id="$(receipt_value canonical-module-id "$scratch/words.receipt")"
symbols_projection_id="$(receipt_value projection-id "$scratch/symbols.receipt")"
words_projection_id="$(receipt_value projection-id "$scratch/words.receipt")"
symbols_reader_ir_id="$(receipt_value reader-ir-id "$scratch/symbols.receipt")"
words_reader_ir_id="$(receipt_value reader-ir-id "$scratch/words.receipt")"
symbols_provenance_id="$(receipt_value provenance-map-id "$scratch/symbols.receipt")"
words_provenance_id="$(receipt_value provenance-map-id "$scratch/words.receipt")"
symbols_map_id="$(receipt_value core-source-map-id "$scratch/symbols.receipt")"
words_map_id="$(receipt_value core-source-map-id "$scratch/words.receipt")"
symbols_logical_core="$(receipt_value logical-core-source-id "$scratch/symbols.receipt")"
words_logical_core="$(receipt_value logical-core-source-id "$scratch/words.receipt")"

[[ "$symbols_core_expression_id" == "$words_core_expression_id" ]] \
  || die "equivalent projections changed projected Core expression identity"
[[ "$symbols_module_id" == "$words_module_id" ]] \
  || die "equivalent projections changed canonical module identity"
[[ "$symbols_projection_id" != "$words_projection_id" ]] \
  || die "different paths and raw sources shared projection identity"
[[ "$symbols_reader_ir_id" != "$words_reader_ir_id" ]] \
  || die "operator aliases unexpectedly shared reader IR identity"
[[ "$symbols_provenance_id" != "$words_provenance_id" ]] \
  || die "different source projections shared reader provenance identity"
[[ "$symbols_map_id" != "$words_map_id" ]] \
  || die "different source projections shared Core source-map identity"
[[ "$symbols_logical_core" == "$words_logical_core" ]] \
  || die "equivalent Core modules received different logical source IDs"

validate_core_map() {
  local core="$1"
  local source_map="$2"
  local core_size
  core_size="$(wc -c < "$core")"
  awk -F $'\t' -v expected_size="$core_size" '
    NR == 1 {
      if ($1 != "relation-core-source-map-v1" || NF != 2) exit 1
      next
    }
    {
      if ($1 != cursor || $2 <= $1) exit 2
      if ($3 == "authored") {
        if ($4 < 0 || $5 < 0 || $6 < $5) exit 3
      } else if ($3 == "synthetic") {
        if ($4 != -1 || $5 != "-" || $6 != "-") exit 4
      } else {
        exit 5
      }
      cursor = $2
      rows += 1
    }
    END {
      if (rows == 0 || cursor != expected_size) exit 6
    }
  ' "$source_map" \
    || die "Core source map does not partition generated bytes"
}

validate_core_map "$scratch/symbols.bgl" "$scratch/symbols.core-map.tsv"
validate_core_map "$scratch/words.bgl" "$scratch/words.core-map.tsv"

rg -Fx '(ns native.relation-surface-v1-generated)' \
  "$scratch/symbols.bgl" >/dev/null \
  || die "canonical module namespace changed"
rg -Fx '  (= (+ 2 5) 7))' "$scratch/symbols.bgl" >/dev/null \
  || die "surface did not lower to ordinary Core equality and addition"
if rg -n 'plus|equals|\?x|Relation|Proposition|Constraint' \
  "$scratch/symbols.bgl" >/dev/null; then
  die "surface-only structure survived into generated Core"
fi

jq -n \
  --arg source_id "$symbols_logical_core" \
  --rawfile core "$scratch/symbols.bgl" \
  '{kind:"beagle.checked-bundle.request",
    schemaVersion:4,
    entrySourceId:$source_id,
    sources:[{sourceId:$source_id,
              bytesBase64:($core|@base64),
              authority:"package"}]}' \
  >"$scratch/symbols.bundle-request.json"
timeout --foreground 30s "$repo/bin/beagle" ast-bundle \
  <"$scratch/symbols.bundle-request.json" \
  >"$scratch/symbols.bundle.json"
jq -e --arg source_id "$symbols_logical_core" '
  .kind == "beagle.checked-bundle" and
  .schemaVersion == 4 and
  .entrySourceId == $source_id and
  (.modules | length) == 1 and
  .modules[0].sourceId == $source_id
' "$scratch/symbols.bundle.json" >/dev/null \
  || die "exact-byte checked bundle did not retain logical Core source identity"

timeout --foreground 30s "$repo/bin/beagle" syntax "$scratch/symbols.bgl"
timeout --foreground 30s "$repo/bin/beagle" check --agent "$scratch/symbols.bgl"
timeout --foreground 60s "$repo/bin/beagle" native-exe \
  --out "$scratch/relation-surface-v1-program" \
  --entry native.relation-surface-v1-generated/main \
  "$scratch/symbols.bgl"
timeout --foreground 10s "$scratch/relation-surface-v1-program"

translate \
  "$here/projection-type-error.brel" \
  "native-core/validation/relation-surface-v1/projection-type-error.brel" \
  "$scratch/type-error.bgl" \
  "$scratch/type-error.receipt" \
  "$scratch/type-error.core-map.tsv"
validate_core_map \
  "$scratch/type-error.bgl" \
  "$scratch/type-error.core-map.tsv"
rg -Fx '  (= (+ 2 true) 7))' "$scratch/type-error.bgl" >/dev/null \
  || die "projectable type-error source changed generated Core"
timeout --foreground 30s "$repo/bin/beagle" syntax "$scratch/type-error.bgl"

set +e
timeout --foreground 30s \
  "$repo/bin/beagle" check --json-v2 "$scratch/type-error.bgl" \
  >"$scratch/type-error.check.out" \
  2>"$scratch/type-error.check.err"
type_check_status=$?
set -e
[[ $type_check_status -eq 1 ]] \
  || die "projectable type error exited $type_check_status instead of 1"

mapfile -t type_diagnostics \
  < <(rg -N '^\{.*\}$' "$scratch/type-error.check.err")
[[ ${#type_diagnostics[@]} -eq 1 ]] \
  || die "projectable type error did not emit exactly one V2 diagnostic"
type_diagnostic="${type_diagnostics[0]}"
printf '%s\n' "$type_diagnostic" \
  | jq -e '
      .kind == "BeagleDiagnosticV2" and
      .code == "E002" and
      .typedPayload.function == "+" and
      .typedPayload."arg-position" == 2 and
      .typedPayload."arg-expr" == "true" and
      .typedPayload.expected == "Number" and
      .typedPayload.actual == "Bool" and
      (.sourceAnchors | length) == 1 and
      (.sourceAnchors[0].position | type) == "number" and
      (.sourceAnchors[0].span | type) == "number"
    ' >/dev/null \
  || die "projectable type error changed its checked V2 diagnostic"

anchor_position="$(jq -r '.sourceAnchors[0].position' <<<"$type_diagnostic")"
anchor_span="$(jq -r '.sourceAnchors[0].span' <<<"$type_diagnostic")"
generated_start=$((anchor_position - 1))
generated_end=$((generated_start + anchor_span))
core_size="$(wc -c < "$scratch/type-error.bgl")"
(( generated_start >= 0 && generated_end <= core_size && generated_start < generated_end )) \
  || die "checked V2 anchor fell outside generated Core bytes"

awk -F $'\t' \
  -v start="$generated_start" \
  -v end="$generated_end" '
    NR > 1 && $1 < end && start < $2 { print }
  ' "$scratch/type-error.core-map.tsv" \
  >"$scratch/type-error.overlaps.tsv"
[[ "$(wc -l < "$scratch/type-error.overlaps.tsv")" == 7 ]] \
  || die "checked V2 anchor did not preserve every overlapping Core origin"

mapped_authored="$(awk -F $'\t' '$3 == "authored" {
  print $4 "\t" $5 "\t" $6
}' "$scratch/type-error.overlaps.tsv" | sort -t $'\t' -k2,2n -k3,3n)"
expected_authored=$'0\t0\t1\n1\t1\t2\n2\t3\t4\n3\t5\t9\n4\t9\t10'
[[ "$mapped_authored" == "$expected_authored" ]] \
  || die "checked V2 anchor did not map to the exact authored addition spans"
[[ "$(awk -F $'\t' '$3 == "synthetic" { count += 1 } END {
  print count + 0
}' "$scratch/type-error.overlaps.tsv")" == 2 ]] \
  || die "checked V2 anchor lost its synthetic-space overlap"

type_error_source_path="$(receipt_value source-path "$scratch/type-error.receipt")"
type_error_map_id="$(receipt_value core-source-map-id "$scratch/type-error.receipt")"
[[ "$type_error_source_path" == \
   "native-core/validation/relation-surface-v1/projection-type-error.brel" ]] \
  || die "mapped diagnostic lost its first-class authored path"

mapped_spans_json="$(awk -F $'\t' '$3 == "authored" {
  print $4 "\t" $5 "\t" $6
}' "$scratch/type-error.overlaps.tsv" \
  | sort -t $'\t' -k2,2n -k3,3n \
  | jq -Rn '[inputs | split("\t") | {
      eventIndex: (.[0] | tonumber),
      startByte: (.[1] | tonumber),
      endByte: (.[2] | tonumber)
    }]')"
jq -n \
  --argjson generated "$type_diagnostic" \
  --arg source_path "$type_error_source_path" \
  --arg core_source_map_id "$type_error_map_id" \
  --argjson original_spans "$mapped_spans_json" '
    {kind: "relation-surface-authored-diagnostic-v1",
     generatedDiagnosticSemanticFactId: $generated.semanticFactId,
     generatedSourceAnchor: $generated.sourceAnchors[0],
     coreSourceMapId: $core_source_map_id,
     sourcePath: $source_path,
     originalSpans: $original_spans,
     syntheticOverlap: true}
  ' >"$scratch/type-error.authored-diagnostic.json"
jq -e \
  --arg source_path "$type_error_source_path" \
  --arg core_source_map_id "$type_error_map_id" '
    .kind == "relation-surface-authored-diagnostic-v1" and
    .sourcePath == $source_path and
    .coreSourceMapId == $core_source_map_id and
    .syntheticOverlap == true and
    any(.originalSpans[];
      .eventIndex == 3 and .startByte == 5 and .endByte == 9)
  ' "$scratch/type-error.authored-diagnostic.json" >/dev/null \
  || die "authored diagnostic projection lost the true span [5,9)"

synthetic_row="$(awk -F $'\t' '
  NR > 1 && $1 <= 1 && 1 < $2 { print; exit }
' "$scratch/type-error.core-map.tsv")"
IFS=$'\t' read -r _synthetic_start _synthetic_end synthetic_origin \
  _synthetic_event _synthetic_original_start _synthetic_original_end \
  synthetic_label <<<"$synthetic_row"
[[ "$synthetic_origin" == synthetic && \
   "$synthetic_label" == :module-prefix ]] \
  || die "generated module bytes were falsely attributed to authored source"

set +e
timeout --foreground 30s "$repo/bin/beagle" native-exe \
  --out "$scratch/type-error-program" \
  --artifacts "$scratch/type-error.artifacts" \
  --entry native.relation-surface-v1-generated/main \
  "$scratch/type-error.bgl" \
  >"$scratch/type-error.native.log" 2>&1
type_native_status=$?
set -e
[[ $type_native_status -eq 2 ]] \
  || die "ill-typed Core native refusal exited $type_native_status instead of 2"
rg -F 'call to +: arg 2 expected Number, got Bool' \
  "$scratch/type-error.native.log" >/dev/null \
  || die "ill-typed Core native refusal lost checker evidence"
[[ ! -e "$scratch/type-error-program" ]] \
  || die "ill-typed Core published a Native executable"
if [[ -d "$scratch/type-error.artifacts" ]] &&
   find "$scratch/type-error.artifacts" -type f -print -quit \
     | rg -q .; then
  die "ill-typed Core published Native artifacts"
fi

refusal_names=(
  open-variable
  query
  solve
  assert
  fact
  law
  rule
  goal
  invalid-integer
  negative-zero
  overflow
  underflow
  unsupported-shape
)
refusal_codes=(
  :surface/open-variable
  :surface/reserved-semantic-form
  :surface/reserved-semantic-form
  :surface/reserved-semantic-form
  :surface/reserved-semantic-form
  :surface/reserved-semantic-form
  :surface/reserved-semantic-form
  :surface/reserved-semantic-form
  :surface/invalid-integer
  :surface/invalid-integer
  :surface/invalid-integer
  :surface/invalid-integer
  :surface/unsupported-shape
)

for index in "${!refusal_names[@]}"; do
  name="${refusal_names[$index]}"
  code="${refusal_codes[$index]}"
  core="$scratch/refusal-$name.bgl"
  receipt="$scratch/refusal-$name.receipt"
  source_map="$scratch/refusal-$name.core-map.tsv"

  set +e
  diagnostic="$(timeout --foreground 10s \
    "$scratch/relation-surface-v1-translator" \
    "$here/refusals/$name.brel" \
    "native-core/validation/relation-surface-v1/refusals/$name.brel" \
    "$core" "$receipt" "$source_map" 2>&1)"
  status=$?
  set -e

  [[ $status -eq 65 ]] \
    || die "$name refusal exited $status instead of 65: $diagnostic"
  [[ "$diagnostic" == "relation-surface-v1: rejected $code" ]] \
    || die "$name refusal reported an unexpected diagnostic: $diagnostic"
  [[ ! -e "$core" && ! -e "$receipt" && ! -e "$source_map" ]] \
    || die "$name refusal materialized output"
done

if ldd "$scratch/relation-surface-v1-translator" \
  | rg -qi 'racket|clojure|babashka|java'; then
  die "hosted runtime leaked into the typed Native translator"
fi
if ldd "$scratch/relation-surface-v1-program" \
  | rg -qi 'racket|clojure|babashka|java'; then
  die "hosted runtime leaked into the generated Native program"
fi

echo "relation-surface-v1: accepted ReaderProducts, projected Core, identity separation, composed diagnostics, refusals, and Native execution PASS"
