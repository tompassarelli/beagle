#!/usr/bin/env bash
set -euo pipefail

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
  "$here/translator.bgl"
)

timeout --foreground 30s "$repo/bin/beagle" syntax "$here/translator.bgl"
timeout --foreground 30s "$repo/bin/beagle" check --agent \
  "${translator_sources[@]}"
timeout --foreground 60s "$repo/bin/beagle" native-exe \
  --out "$scratch/relation-surface-v1-translator" \
  --entry native.relation-surface-v1-translator/main \
  "${translator_sources[@]}"

translate() {
  local physical="$1"
  local logical="$2"
  local core="$3"
  local receipt="$4"

  timeout --foreground 10s "$scratch/relation-surface-v1-translator" \
    "$physical" "$logical" "$core" "$receipt"
}

translate \
  "$here/projection-symbols.brel" \
  "native-core/validation/relation-surface-v1/projection-symbols.brel" \
  "$scratch/symbols.bgl" \
  "$scratch/symbols.receipt"
translate \
  "$here/projection-words.brel" \
  "native-core/validation/relation-surface-v1/projection-words.brel" \
  "$scratch/words.bgl" \
  "$scratch/words.receipt"
translate \
  "$here/projection-symbols.brel" \
  "native-core/validation/relation-surface-v1/projection-symbols.brel" \
  "$scratch/symbols-repeat.bgl" \
  "$scratch/symbols-repeat.receipt"

cmp -s "$scratch/symbols.bgl" "$scratch/words.bgl" \
  || die "layout and aliases changed canonical Core bytes"
cmp -s "$scratch/symbols.bgl" "$scratch/symbols-repeat.bgl" \
  || die "repeat read changed canonical Core bytes"
cmp -s "$scratch/symbols.receipt" "$scratch/symbols-repeat.receipt" \
  || die "repeat read changed projection receipt bytes"
if cmp -s "$scratch/symbols.receipt" "$scratch/words.receipt"; then
  die "different source projections produced identical receipts"
fi

receipt_value() {
  local field="$1"
  local receipt="$2"
  rg -N "^${field} " "$receipt" | cut -d' ' -f2-
}

symbols_semantic_id="$(receipt_value semantic-id "$scratch/symbols.receipt")"
words_semantic_id="$(receipt_value semantic-id "$scratch/words.receipt")"
symbols_module_id="$(receipt_value canonical-module-id "$scratch/symbols.receipt")"
words_module_id="$(receipt_value canonical-module-id "$scratch/words.receipt")"
symbols_projection_id="$(receipt_value projection-id "$scratch/symbols.receipt")"
words_projection_id="$(receipt_value projection-id "$scratch/words.receipt")"

[[ "$symbols_semantic_id" == "$words_semantic_id" ]] \
  || die "equivalent projections changed semantic identity"
[[ "$symbols_module_id" == "$words_module_id" ]] \
  || die "equivalent projections changed canonical module identity"
[[ "$symbols_projection_id" != "$words_projection_id" ]] \
  || die "different paths and raw sources shared projection identity"

rg -Fx '(ns native.relation-surface-v1-generated)' \
  "$scratch/symbols.bgl" >/dev/null \
  || die "canonical module namespace changed"
rg -Fx '  (= (+ 2 5) 7))' "$scratch/symbols.bgl" >/dev/null \
  || die "surface did not lower to ordinary Core equality and addition"
if rg -n 'plus|equals|\?x|Relation|Proposition|Constraint' \
  "$scratch/symbols.bgl" >/dev/null; then
  die "surface-only structure survived into generated Core"
fi

timeout --foreground 30s "$repo/bin/beagle" syntax "$scratch/symbols.bgl"
timeout --foreground 30s "$repo/bin/beagle" check --agent "$scratch/symbols.bgl"
timeout --foreground 60s "$repo/bin/beagle" native-exe \
  --out "$scratch/relation-surface-v1-program" \
  --entry native.relation-surface-v1-generated/main \
  "$scratch/symbols.bgl"
timeout --foreground 10s "$scratch/relation-surface-v1-program"

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

  set +e
  diagnostic="$(timeout --foreground 10s \
    "$scratch/relation-surface-v1-translator" \
    "$here/refusals/$name.brel" \
    "native-core/validation/relation-surface-v1/refusals/$name.brel" \
    "$core" "$receipt" 2>&1)"
  status=$?
  set -e

  [[ $status -eq 65 ]] \
    || die "$name refusal exited $status instead of 65: $diagnostic"
  [[ "$diagnostic" == "relation-surface-v1: rejected $code" ]] \
    || die "$name refusal reported an unexpected diagnostic: $diagnostic"
  [[ ! -e "$core" && ! -e "$receipt" ]] \
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

echo "relation-surface-v1: source projections, ordinary Core lowering, identity separation, refusals, and Native execution PASS"
