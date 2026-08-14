#!/usr/bin/env bash
# Re-materializes each native-core validation slice twice, byte-compares
# every output, and fails loudly with the differing paths on divergence.
# Usage: determinism_gate.sh [--module slice-types-full|slice-fold|slice-types|slice-store|slice-vec|slice-kernel-classify] [--quick]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
validation="$repo/native-core/validation"

# Cached gate: the run is traced and its green result keyed on the full input
# closure (bin/_gate-cache-run); an unchanged closure replays as cached-green.
# BEAGLE_GATE_NO_CACHE=1 forces the full run.
#
# The all-modules run fans out through per-module invocations so each
# materialization is its own cache unit: slice-types and slice-store execute
# LeakSanitizer-built binaries, which refuse to run under ptrace, so those two
# always run direct (flagged untraceable) — fanning out keeps the other
# modules cacheable instead of poisoning one whole-gate identity.
if [[ $# -eq 0 && -z "${BEAGLE_GATE_CACHE_INNER:-}" && -x "$repo/bin/_gate-cache-run" ]]; then
  overall=0
  for m in slice-fold slice-types-full slice-types slice-store slice-vec slice-kernel-classify; do
    "$0" --module "$m" || overall=1
  done
  exit "$overall"
fi
if [[ -z "${BEAGLE_GATE_CACHE_INNER:-}" && -x "$repo/bin/_gate-cache-run" ]]; then
  exec "$repo/bin/_gate-cache-run" --domain native-gates \
    --id "$(basename "$0")${1:+ $*}" -- "$0" "$@"
fi

module=""
quick=0
while [ $# -gt 0 ]; do
  case "$1" in
    --module) module="$2"; shift 2 ;;
    --quick) quick=1; shift ;;
    *) echo "determinism_gate.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

work="$(mktemp -d)"
cleanup() { rm -rf "${work:?}"; }
trap cleanup EXIT

status=0

# Materializes twice via a driver that honors NATIVE_SLICE_ARTIFACTS, then
# byte-compares the two resulting directory trees.
run_env_artifacts_slice() {
  local name="$1" driver="$2"; shift 2
  local run1="$work/$name/run1" run2="$work/$name/run2"
  mkdir -p "$run1" "$run2"
  echo "--- $name (materialization 1/2) ---"
  NATIVE_SLICE_REPO="$repo" NATIVE_SLICE_ARTIFACTS="$run1" "$@" bash "$driver" \
    || { echo "determinism_gate.sh: $name materialization 1 failed" >&2; status=1; return; }
  echo "--- $name (materialization 2/2) ---"
  NATIVE_SLICE_REPO="$repo" NATIVE_SLICE_ARTIFACTS="$run2" "$@" bash "$driver" \
    || { echo "determinism_gate.sh: $name materialization 2 failed" >&2; status=1; return; }
  if diff -rq "$run1" "$run2" >"$work/$name/diff.txt"; then
    echo "PASS  $name: byte-identical across two materializations"
  else
    echo "FAIL  $name: diverged — differing paths:" >&2
    sed 's/^/    /' "$work/$name/diff.txt" >&2
    status=1
  fi
}

run_slice_fold() {
  # NATIVE_SLICE_NO_COMPILE: byte-compare source, not compiler behavior.
  run_env_artifacts_slice slice-fold "$validation/slice-fold/drive.sh" \
    env NATIVE_SLICE_NO_COMPILE=1
}

run_slice_types_full() {
  run_env_artifacts_slice slice-types-full "$validation/slice-types-full/drive.sh" env
}

run_slice_vec() {
  run_env_artifacts_slice slice-vec "$validation/slice-vec/drive.sh" \
    env NATIVE_SLICE_NO_COMPILE=1
}

run_slice_kernel_classify() {
  run_env_artifacts_slice slice-kernel-classify \
    "$validation/slice-kernel-classify/drive.sh" \
    env NATIVE_SLICE_NO_COMPILE=1
}

run_slice_types() {
  run_env_artifacts_slice slice-types "$validation/slice-types/run.sh" env
}

run_slice_store() {
  local dir="$validation/slice-store"
  if [ ! -e "$dir/drive.sh" ] && [ ! -e "$dir/run.sh" ]; then
    echo "SKIP  slice-store: no driver landed under $dir yet (nat-store not merged)"
    return
  fi
  if [ -e "$dir/drive.sh" ]; then
    run_env_artifacts_slice slice-store "$dir/drive.sh" env
  else
    echo "SKIP  slice-store: driver present as run.sh but determinism_gate.sh has no runner wired for it yet — extend run_slice_store when it lands"
  fi
}

if [ -n "$module" ]; then
  case "$module" in
    slice-fold) run_slice_fold ;;
    slice-types-full) run_slice_types_full ;;
    slice-types) run_slice_types ;;
    slice-store) run_slice_store ;;
    slice-vec) run_slice_vec ;;
    slice-kernel-classify) run_slice_kernel_classify ;;
    *) echo "determinism_gate.sh: unknown --module: $module" >&2; exit 2 ;;
  esac
elif [ "$quick" -eq 1 ]; then
  run_slice_fold
else
  run_slice_fold
  run_slice_types_full
  run_slice_types
  run_slice_store
  run_slice_vec
  run_slice_kernel_classify
fi

exit "$status"
