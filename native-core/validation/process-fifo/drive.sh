#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-process-fifo.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT
exec 3>&2

die() {
  echo "process-fifo: $*" >&2
  exit 1
}

for command in cc rg sed sort unshare; do
  command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

source "$repo/bin/_beagle-racket"
supervisor="$repo/native-core/bin/run-bounded.rkt"
unshare_bin="$(command -v unshare)"

run_phase() {
  local phase="$1"
  local deadline="$2"
  shift 2
  local receipt="$scratch/$phase.receipt"
  local status
  local outcome

  echo "process-fifo: $phase START deadline=${deadline}s" >&3
  set +e
  BEAGLE_BOUNDED_COMPLETION_RECEIPT="$receipt" \
    "$unshare_bin" --user --map-current-user --pid --fork --kill-child \
      "$RACKET" "$supervisor" "$deadline" 5 -- "$@"
  status=$?
  set -e
  [[ -f "$receipt" ]] \
    || die "$phase SETUP-FAILURE status=2 observed=$status"
  outcome="$(<"$receipt")"
  if [[ "$outcome" == "subtree-reaped-v0 timeout status=124" && \
        "$status" -eq 124 ]]; then
    die "$phase TIMEOUT status=124"
  fi
  if [[ "$outcome" =~ ^subtree-reaped-v0\ exit\ status=([0-9]+)$ && \
        "${BASH_REMATCH[1]}" -eq "$status" ]]; then
    if [[ "$status" -eq 0 ]]; then
      echo "process-fifo: $phase PASS status=0" >&3
      return 0
    fi
    echo "process-fifo: $phase SEMANTIC-REJECTION child-status=$status" >&3
    return 1
  fi
  die "$phase SETUP-FAILURE invalid receipt '$outcome' observed=$status"
}

mkdir -p "$scratch/process-c17" "$scratch/process-qbe" "$scratch/runtime"

run_phase typed-source-check 45 \
  "$repo/bin/beagle" check --agent "$here/process_fifo_probe.bgl"

run_phase c17-materialization 180 \
  "$repo/bin/beagle" build --materializer c17 \
  --out "$scratch/process-c17" "$here/process_fifo_probe.bgl"

report="$scratch/process-c17/report.txt"
rg -Fx 'stage typed-to-native COMPLETE' "$report" >/dev/null \
  || die "process FIFO probe did not lower"
[[ "$(rg -c '^obligation-projection PASS ' "$report")" == "10" ]] \
  || die "process FIFO probe failed ten Native obligations"
rg -Fx 'materialize-c17 OK module_0.h module_0.c' "$report" >/dev/null \
  || die "process FIFO probe did not materialize as C17"

mapfile -t actual_imports < <(
  rg -o 'native_host_[[:alnum:]_]+_v0[[:space:]]*\(' \
    "$scratch/process-c17/module_0.c" \
    | sed -E 's/[[:space:]]*\($//' | sort -u
)
expected_imports=(
  native_host_process_alive_v0
  native_host_process_close_v0
  native_host_process_current_pid_v0
  native_host_process_fifo_create_v0
  native_host_process_fifo_open_read_v0
  native_host_process_fifo_write_deadline_v0
  native_host_process_poll_readable_v0
  native_host_process_read_line_deadline_v0
  native_host_process_signal_v0
  native_host_process_wait_not_alive_v0
)
[[ "$(printf '%s\n' "${actual_imports[@]}")" == \
   "$(printf '%s\n' "${expected_imports[@]}" | sort)" ]] \
  || die "C17 host imports were not exactly Group B plus close"

if run_phase process-qbe-refusal 180 \
    "$repo/bin/beagle" build --materializer qbe \
    --out "$scratch/process-qbe" "$here/process_fifo_probe.bgl" \
    >"$scratch/process-qbe.log" 2>&1; then
  die "QBE unexpectedly accepted process FIFO lifecycle"
fi
rg -Fx \
  'materialize-qbe REFUSED QBE process extern ABI is unsupported: inherited process execution has no QBE call representation' \
  "$scratch/process-qbe.log" >/dev/null \
  || die "QBE process FIFO refusal changed"

strict=(-std=c17 -Wall -Wextra -Werror -pedantic)
run_phase generated-c17-strict-compile 45 \
  cc "${strict[@]}" -I"$repo/native-core/shim" \
  -I"$scratch/process-c17" -c "$scratch/process-c17/module_0.c" \
  -o "$scratch/process-module.o"
run_phase native-shim-strict-build 60 \
  cc "${strict[@]}" -I"$repo/native-core/shim" \
  "$here/shim_contract.c" "$repo/native-core/shim/native_shim.c" \
  -pthread -lm -o "$scratch/native-contract"
run_phase native-process-fifo-runtime 30 \
  "$scratch/native-contract" "$scratch/runtime"
run_phase wasi-shim-strict-build 60 \
  cc "${strict[@]}" -D__wasi__ -I"$repo/native-core/shim" \
  "$here/shim_contract.c" "$repo/native-core/shim/native_shim.c" \
  -pthread -lm -o "$scratch/wasi-contract"
run_phase wasi-process-fifo-runtime 15 "$scratch/wasi-contract"

echo "process-fifo: strict source/C17/shim, ten obligations, imports, QBE refusal, native FIFO/process lifecycle, and WASI pass"
