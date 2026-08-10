#!/usr/bin/env bash
# Gate G1 for the Phase-2 S1 epoch analysis (native-core/analysis/epoch/,
# report-only): run the analysis over the stage/emitter modules and require
# >= 90% of allocating sites epoch-assigned, every refusal TODO-EPOCH-coded,
# zero unexplained sites. Prints the per-module assignment table.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
epoch="$repo/native-core/analysis/epoch"

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
