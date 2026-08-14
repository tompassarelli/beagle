#!/usr/bin/env bash
# Run the epoch analysis over the stage/emitter modules and require
# >= 90% of allocating sites epoch-assigned, every refusal TODO-EPOCH-coded,
# zero unexplained sites. Prints the per-module assignment table.
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

command -v bb >/dev/null 2>&1 || { echo "epoch_stage_gate.sh: babashka (bb) is required" >&2; exit 2; }

modules=(native.body-c17 native.fold-c17 native.c11 native.qbe native.stages)

work="$(mktemp -d)"
cleanup() { rm -rf "${work:?}"; }
trap cleanup EXIT

"$epoch/run-epoch-stage.sh" --out "$work" "${modules[@]}" > "$work/drive.log" 2>&1 \
  || { cat "$work/drive.log" >&2; exit 1; }

maps=()
for mod in "${modules[@]}"; do
  maps+=("$work/$mod.epoch-map.json")
done

bb "$epoch/g1-gate.clj" "${maps[@]}"
