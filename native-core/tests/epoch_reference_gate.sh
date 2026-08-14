#!/usr/bin/env bash
# Run the epoch analysis over the compiler-shaped reference
# programs — the compiler's own modules and the validation corpus's
# program-constructing modules — and require
#
#   * >= 90% of allocating sites epoch-assigned in aggregate;
#   * every refusal TODO-EPOCH-coded, and the fold total per module;
#   * every escape (a caller-owned site: the region's own product) retaining
#     either a type the compiler declares or a bare scalar/text shape — zero
#     retaining a type no compiler module owns — with the stage-product share
#     of the TYPED escapes floored at 90%.
#
# epoch_stage_gate.sh is the same instrument over the five emitter modules
# only; this is the wider population. Sixteen modules with
# their require closures: expect several minutes.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
epoch="$repo/native-core/analysis/epoch"

# Cached gate: the run is traced and its green result keyed on the full input
# closure (bin/_gate-cache-run); an unchanged closure replays as cached-green.
# BEAGLE_GATE_NO_CACHE=1 forces the full run.
if [[ -z "${BEAGLE_GATE_CACHE_INNER:-}" && -x "$repo/bin/_gate-cache-run" ]]; then
  exec "$repo/bin/_gate-cache-run" --domain native-gates \
    --id "$(basename "$0")${1:+ $*}" -- "$0" "$@"
fi

command -v bb >/dev/null 2>&1 || { echo "epoch_reference_gate.sh: babashka (bb) is required" >&2; exit 2; }

modules=(native.core native.stages native.lower native.obligations
         native.slice native.body-slice
         native.body-c17 native.fold-c17 native.c11 native.qbe
         native.validation-corpus native.c11-validation-corpus
         native.qbe-validation-corpus native.epoch-validation-corpus
         native.promote-validation-corpus native.fold-slice-corpus)

work="$(mktemp -d)"
cleanup() { rm -rf "${work:?}"; }
trap cleanup EXIT

"$epoch/run-epoch-stage.sh" --out "$work" "${modules[@]}" > "$work/drive.log" 2>&1 \
  || { cat "$work/drive.log" >&2; exit 1; }

maps=()
for mod in "${modules[@]}"; do
  maps+=("$work/$mod.epoch-map.json")
done

bb "$epoch/g6-gate.clj" --sources "$repo/native-core/src/native" "${maps[@]}"
