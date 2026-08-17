#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build and exercise the deployment-shaped Worker. The memory row is stricter
# than production in one important way: the 128 MiB cgroup contains the whole
# workerd runtime subtree, not only one Worker isolate.
set -euo pipefail
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
client="$(cd "$here/.." && pwd)"
repo="$(cd "$client/../.." && pwd)"
plan="${BEAGLE_STORE_CF_CAPACITY_PLAN:-free}"
output="${1:-$here/out}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/store-cloudflare-capacity.XXXXXXXX")"
uid="$(id -u)"
cgroup_parent="/sys/fs/cgroup/user.slice/user-${uid}.slice/user@${uid}.service/app.slice"
limit_bytes=134217728

is_owned_cgroup_path() {
  local candidate="$1"
  local suffix
  [[ "$candidate" == "$cgroup_parent"/store-cloudflare-workerd-* ]] || return 1
  suffix="${candidate#"$cgroup_parent"/store-cloudflare-workerd-}"
  [[ "$suffix" =~ ^[0-9]+$ ]]
}

process_start_time() {
  local pid="$1"
  local stat tail
  local -a fields
  [[ -r "/proc/$pid/stat" ]] || return 0
  stat="$(<"/proc/$pid/stat")" || return 0
  tail="${stat##*) }"
  read -r -a fields <<<"$tail"
  [[ "${fields[19]:-}" =~ ^[0-9]+$ ]] || return 0
  printf '%s\n' "${fields[19]}"
}

cleanup() {
  if [[ -s "$scratch/cgroup.inventory" ]]; then
    while read -r _owned_pid _owned_start candidate_cgroup extra; do
      [[ -z "${extra:-}" ]] || continue
      is_owned_cgroup_path "$candidate_cgroup" || continue
      [[ -d "$candidate_cgroup" ]] || continue
      if [[ -f "$candidate_cgroup/cgroup.kill" ]]; then
        printf '1\n' >"$candidate_cgroup/cgroup.kill" 2>/dev/null || true
      else
        while read -r process; do
          [[ -n "$process" ]] && kill -TERM "$process" 2>/dev/null || true
        done <"$candidate_cgroup/cgroup.procs"
      fi
      for _ in $(seq 1 50); do
        [[ ! -s "$candidate_cgroup/cgroup.procs" ]] && break
        sleep 0.1
      done
      rmdir "$candidate_cgroup" 2>/dev/null || true
    done <"$scratch/cgroup.inventory"
  fi
  rm -rf "${scratch:?}"
}
trap cleanup EXIT

die() {
  echo "capacity-gate: $*" >&2
  exit 2
}

assert_source_unchanged() {
  [[ "$(git -C "$repo" rev-parse 'HEAD^{commit}')" == "$source_commit" ]] ||
    die "the source commit changed during the capacity run"
  [[ -z "$(git -C "$repo" status --porcelain --untracked-files=all)" ]] ||
    die "the source tree changed during the capacity run"
}

case "$plan" in
  free|paid) ;;
  *) die "BEAGLE_STORE_CF_CAPACITY_PLAN must be free or paid" ;;
esac
[[ -z "${BEAGLE_STORE_DO_WASM_ARTIFACT:-}" ]] ||
  die "the certifying gate refuses BEAGLE_STORE_DO_WASM_ARTIFACT; build current source"
[[ -z "$(git -C "$repo" status --porcelain --untracked-files=all)" ]] ||
  die "the certifying gate requires a clean source tree"
source_commit="$(git -C "$repo" rev-parse 'HEAD^{commit}')"
[[ -f /sys/fs/cgroup/cgroup.controllers ]] ||
  die "cgroup v2 is required for the enforced memory row"
[[ -w "$cgroup_parent/cgroup.procs" ]] ||
  die "the user cgroup app.slice must delegate cgroup creation"

mkdir -p "$output" "$scratch/corpus" "$scratch/bundle"
output="$(realpath -m "$output")"
bun_binary="$(command -v bun)"

cd "$client"
bun install --frozen-lockfile
"$client/scripts/build-wasm.sh"
assert_source_unchanged
provenance_source="$(
  "$bun_binary" -e '
    const provenance = await Bun.file(process.argv[1]).json();
    process.stdout.write(provenance.sourceCommit ?? "");
  ' "$client/lib/provenance.json"
)"
[[ "$provenance_source" == "$source_commit" ]] ||
  die "wasm provenance does not identify the gated source commit"
direnv exec "$repo" bb -cp "$repo/out" \
  "$here/generate-wiki-corpus.clj" "$scratch/corpus" "$here/corpus.json"

set +e
bunx --bun wrangler deploy --dry-run \
  --config "$here/wrangler.toml" \
  --outdir "$scratch/bundle" \
  --metafile "$scratch/wrangler-metafile.json" \
  >"$scratch/wrangler.log" 2>&1
wrangler_status=$?
set -e
if [[ "$wrangler_status" != 0 ]]; then
  cp "$scratch/wrangler.log" "$output/wrangler.log"
  die "Wrangler dry-run failed; see $output/wrangler.log"
fi

# Wrangler resolves --outdir relative to the config directory. Normalize the
# actual emitted directory from its metafile rather than guessing that base.
bundle_directory="$(
  "$bun_binary" -e '
    import { readFileSync } from "node:fs";
    import { dirname, resolve } from "node:path";
    const meta = JSON.parse(readFileSync(process.argv[1], "utf8"));
    const outputs = Object.keys(meta.outputs ?? {});
    if (outputs.length === 0) throw new Error("Wrangler metafile has no outputs");
    process.stdout.write(resolve(dirname(outputs[0])));
  ' "$scratch/wrangler-metafile.json"
)"
[[ -d "$bundle_directory" ]] || die "Wrangler emitted no bundle directory"

real_workerd="$client/node_modules/workerd/bin/workerd"
[[ -x "$real_workerd" ]] || die "the pinned workerd executable is absent"
set +e
MINIFLARE_WORKERD_PATH="$here/workerd-cgroup-wrapper.sh" \
BEAGLE_STORE_CF_REAL_WORKERD="$real_workerd" \
BEAGLE_STORE_CF_CGROUP_LOCATOR="$scratch/cgroup.locator" \
BEAGLE_STORE_CF_CGROUP_INVENTORY="$scratch/cgroup.inventory" \
timeout 600 "$bun_binary" "$here/run-workerd.mjs" \
  "$bundle_directory" "$scratch/corpus" \
  "$scratch/functional.json" "$scratch/progress.json" \
  >"$scratch/workerd.log" 2>&1
functional_status=$?
set -e
[[ -s "$scratch/cgroup.inventory" ]] ||
  die "the workerd cgroup wrapper emitted no runtime inventory"
mapfile -t runtime_rows <"$scratch/cgroup.inventory"
runtime_count="${#runtime_rows[@]}"
declare -A seen_runtime_identities=()
declare -A seen_cgroups=()
peak=0
load_peak=0
reopen_peak=0
oom_kills=0
remaining_processes=0
owned_pids_exited=1
runtime_limits_exact=1
runtime_index=0
for runtime_row in "${runtime_rows[@]}"; do
  read -r owned_pid owned_start candidate_cgroup extra <<<"$runtime_row"
  [[ -z "${extra:-}" ]] || die "the workerd cgroup inventory row is not closed"
  [[ "$owned_pid" =~ ^[0-9]+$ && "$owned_start" =~ ^[0-9]+$ ]] ||
    die "the workerd cgroup inventory has an invalid process identity"
  is_owned_cgroup_path "$candidate_cgroup" ||
    die "the workerd cgroup inventory escaped its delegated parent"
  runtime_identity="$owned_pid:$owned_start"
  [[ -z "${seen_runtime_identities[$runtime_identity]+present}" ]] ||
    die "the workerd cgroup inventory repeated a process identity"
  [[ -z "${seen_cgroups[$candidate_cgroup]+present}" ]] ||
    die "the workerd cgroup inventory repeated a cgroup"
  seen_runtime_identities[$runtime_identity]=1
  seen_cgroups[$candidate_cgroup]=1
  [[ -d "$candidate_cgroup" ]] ||
    die "a workerd cgroup disappeared before measurement"
  runtime_peak="$(<"$candidate_cgroup/memory.peak")"
  runtime_oom_kills="$(awk '$1 == "oom_kill" { print $2 }' \
    "$candidate_cgroup/memory.events")"
  runtime_remaining="$(awk 'NF { count += 1 } END { print count + 0 }' \
    "$candidate_cgroup/cgroup.procs")"
  runtime_memory_max="$(<"$candidate_cgroup/memory.max")"
  runtime_swap_max="$(<"$candidate_cgroup/memory.swap.max")"
  if (( runtime_peak > peak )); then
    peak="$runtime_peak"
  fi
  oom_kills=$((oom_kills + runtime_oom_kills))
  remaining_processes=$((remaining_processes + runtime_remaining))
  if [[ "$runtime_memory_max" != "$limit_bytes" || "$runtime_swap_max" != 0 ]]; then
    runtime_limits_exact=0
  fi
  if [[ "$runtime_index" == 0 ]]; then
    load_peak="$runtime_peak"
  elif [[ "$runtime_index" == 1 ]]; then
    reopen_peak="$runtime_peak"
  fi
  current_start="$(process_start_time "$owned_pid")"
  [[ "$current_start" != "$owned_start" ]] || owned_pids_exited=0
  runtime_index=$((runtime_index + 1))
done
memory_result=not-oom-killed
if [[ "${oom_kills:-0}" != 0 ]]; then
  memory_result=oom-kill
fi
printf '%s\n' \
  "Scope=workerd-process-tree-only" \
  "Lifecycle=process-replacement" \
  "RuntimeCount=$runtime_count" \
  "OwnedPidsExited=$owned_pids_exited" \
  "RuntimeLimitsExact=$runtime_limits_exact" \
  "MemoryResult=$memory_result" \
  "MemoryOomKills=${oom_kills:-0}" \
  "ControllerExitStatus=$functional_status" \
  "ProcessesRemainingAfterController=$remaining_processes" \
  "MemoryPeak=$peak" \
  "LoadMemoryPeak=$load_peak" \
  "ReopenMemoryPeak=$reopen_peak" \
  "MemoryMax=$limit_bytes" \
  "MemorySwapMax=0" \
  >"$scratch/cgroup.properties"
for runtime_row in "${runtime_rows[@]}"; do
  read -r _owned_pid _owned_start candidate_cgroup _extra <<<"$runtime_row"
  if [[ -s "$candidate_cgroup/cgroup.procs" ]]; then
    if [[ -f "$candidate_cgroup/cgroup.kill" ]]; then
      printf '1\n' >"$candidate_cgroup/cgroup.kill"
    else
      while read -r process; do
        [[ -n "$process" ]] && kill -TERM "$process" 2>/dev/null || true
      done <"$candidate_cgroup/cgroup.procs"
    fi
    for _ in $(seq 1 50); do
      [[ ! -s "$candidate_cgroup/cgroup.procs" ]] && break
      sleep 0.1
    done
    [[ ! -s "$candidate_cgroup/cgroup.procs" ]] ||
      die "an owned workerd process survived capacity cleanup"
  fi
  rmdir "$candidate_cgroup"
done

if [[ ! -s "$scratch/functional.json" ]]; then
  "$bun_binary" "$here/write-functional-failure.mjs" \
    "$scratch/corpus/profile.json" \
    "$scratch/cgroup.properties" \
    "$scratch/progress.json" \
    "$scratch/functional.json"
fi

assert_source_unchanged

set +e
"$bun_binary" "$here/assemble-receipt.mjs" \
  "--plan=$plan" \
  "--bundle=$bundle_directory" \
  "--wrangler-log=$scratch/wrangler.log" \
  "--functional=$scratch/functional.json" \
  "--cgroup=$scratch/cgroup.properties" \
  "--wasm-provenance=$client/lib/provenance.json" \
  "--output=$scratch/receipt.json"
receipt_status=$?
set -e

cp "$scratch/receipt.json" "$output/receipt.json"
cp "$scratch/functional.json" "$output/functional.json"
cp "$scratch/cgroup.properties" "$output/cgroup.properties"
cp "$scratch/cgroup.inventory" "$output/cgroup.inventory"
cp "$scratch/progress.json" "$output/progress.json"
cp "$scratch/wrangler.log" "$output/wrangler.log"
cp "$scratch/workerd.log" "$output/workerd.log"
cp "$scratch/wrangler-metafile.json" "$output/wrangler-metafile.json"

if [[ "$receipt_status" != 0 ]]; then
  die "capacity receipt failed; see $output/receipt.json"
fi
[[ "$functional_status" == 0 ]] ||
  die "workerd failed with exit $functional_status despite a passing receipt"
echo "capacity-gate: PASS $output/receipt.json"
