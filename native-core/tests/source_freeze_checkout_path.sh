#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
if [[ "${BEAGLE_NATIVE_COMPILER_BIN+x}" == x ]]; then
  exec "$repo/native-core/tests/source_freeze_native.sh"
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/native-source-freeze-path.XXXXXX")"
case_pids=()

cleanup() {
  local status=$?
  local pid
  trap - EXIT TERM INT
  set +e
  for pid in "${case_pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${case_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "${work:?}"
  exit "$status"
}

trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

run_case() {
  local label="$1"
  local cwd="$2"
  local case_dir="$work/$label"
  local scratch="$case_dir/scratch"
  local store_checkout
  local source
  mkdir -p "$case_dir/artifacts"
  printf 'source-freeze path case %s: START from %s\n' "$label" "$cwd"
  (
    cd "$cwd"
    store_checkout="$("$repo/native-core/validation/store-checkout.sh")"
    source="$store_checkout/src/store/types.bgl"
    mkdir -p "$scratch"
    "$repo/bin/beagle-facts" --module-root "store/src=$store_checkout/src" \
      "$source" >"$scratch/facts.raw"
    {
      printf '[\n'
      tail -n +2 "$scratch/facts.raw"
      printf ']\n'
    } >"$scratch/facts.edn"
    "$repo/bin/beagle-build-all" \
      "$repo/native-core/src/native/core.bclj" \
      "$repo/native-core/src/native/stages.bclj" \
      "$repo/native-core/src/native/lower.bclj" \
      "$repo/native-core/src/native/obligations.bclj" \
      "$repo/native-core/src/native/simd.bclj" \
      "$repo/native-core/src/native/c11.bclj" \
      "$repo/native-core/validation/slice-types/pipeline.bclj" \
      --out "$scratch/out" >"$case_dir/build.log" 2>&1
    bb -cp "$scratch/out" \
      "$repo/native-core/tests/source_freeze_probe.clj" \
      "$scratch/facts.edn" "$source" "$case_dir/artifacts/report.txt"
  )
  grep -Fx 'stage source-freeze ACCEPTED' "$case_dir/artifacts/report.txt"
  printf 'source-freeze path case %s: ACCEPTED from %s\n' "$label" "$cwd"
}

export -f run_case
export repo work

declare -A case_labels=()
unshare --user --map-current-user --pid --fork --kill-child \
  bash -c 'set -euo pipefail; run_case "$@"' source-freeze-case repo "$repo" &
case_pids+=("$!")
case_labels["$!"]=repo
unshare --user --map-current-user --pid --fork --kill-child \
  bash -c 'set -euo pipefail; run_case "$@"' source-freeze-case tmp /tmp &
case_pids+=("$!")
case_labels["$!"]=tmp

live_pids=("${case_pids[@]}")
for _ in repo tmp; do
  finished_pid=
  if wait -n -p finished_pid "${live_pids[@]}"; then
    :
  else
    status=$?
    printf 'source-freeze path case %s: FAILED exit %d\n' \
      "${case_labels[$finished_pid]}" "$status" >&2
    exit "$status"
  fi
  next_pids=()
  for pid in "${live_pids[@]}"; do
    if [[ "$pid" != "$finished_pid" ]]; then
      next_pids+=("$pid")
    fi
  done
  live_pids=("${next_pids[@]}")
done
