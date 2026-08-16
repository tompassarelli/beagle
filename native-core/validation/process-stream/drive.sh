#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-process-stream.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "process-stream: $*" >&2
  exit 1
}

phase() {
  echo "process-stream: $*"
}

run_phase() {
  local label="$1"
  local seconds="$2"
  shift 2
  phase "$label (deadline ${seconds}s)"
  timeout --foreground --signal=TERM --kill-after=2s "${seconds}s" "$@" \
    || die "$label failed or exceeded ${seconds}s"
}

for command in cc rg timeout; do
  command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

mkdir -p \
  "$scratch/stream-c17" \
  "$scratch/stream-qbe" \
  "$scratch/sleep-c17" \
  "$scratch/sleep-qbe" \
  "$scratch/finite-artifacts" \
  "$scratch/long-artifacts"

run_phase "typed source check" 30 \
  "$repo/bin/beagle" check --agent \
  "$here/process_stream_probe.bgl" "$here/sleep_probe.bgl"

run_phase "stream C17 materialization" 180 \
  "$repo/bin/beagle" build --materializer c17 \
  --out "$scratch/stream-c17" "$here/process_stream_probe.bgl"

stream_report="$scratch/stream-c17/report.txt"
rg -Fx 'stage typed-to-native COMPLETE' "$stream_report" >/dev/null \
  || die "stream probe did not lower"
[[ "$(rg -c '^obligation-projection PASS ' "$stream_report")" == "10" ]] \
  || die "stream probe failed native obligations"
rg -Fx 'materialize-c17 OK module_0.h module_0.c' "$stream_report" >/dev/null \
  || die "stream probe did not materialize as C17"
for symbol in \
  native_host_process_spawn_stdout_v0 \
  native_host_process_read_line_bounded_v0 \
  native_host_process_wait_v0 \
  native_host_process_close_v0 \
  native_host_time_sleep_milliseconds_v0; do
  rg -F "$symbol" "$scratch/stream-c17/module_0.c" >/dev/null \
    || die "missing stream C17 import: $symbol"
done
if rg -F 'native_host_process_run_' "$scratch/stream-c17/module_0.c" >/dev/null; then
  die "stream probe published an unused run process ABI"
fi

run_phase "sleep-only C17 materialization" 180 \
  "$repo/bin/beagle" build --materializer c17 \
  --out "$scratch/sleep-c17" "$here/sleep_probe.bgl"
rg -F 'native_host_time_sleep_milliseconds_v0' \
  "$scratch/sleep-c17/module_0.c" >/dev/null \
  || die "missing sleep-only C17 import"
if rg -F 'native_host_process_' "$scratch/sleep-c17/module_0.c" >/dev/null; then
  die "sleep-only probe published a process ABI"
fi

phase "stream QBE refusal (deadline 180s)"
set +e
timeout --foreground --signal=TERM --kill-after=2s 180s \
  "$repo/bin/beagle" build --materializer qbe \
  --out "$scratch/stream-qbe" "$here/process_stream_probe.bgl" \
  >"$scratch/stream-qbe.log" 2>&1
stream_qbe_status=$?
set -e
[[ $stream_qbe_status -ne 0 ]] || die "QBE unexpectedly accepted process streams"
[[ $stream_qbe_status -ne 124 && $stream_qbe_status -ne 137 ]] \
  || die "stream QBE refusal exceeded 180s"
rg -Fx \
  'materialize-qbe REFUSED QBE process extern ABI is unsupported: inherited process execution has no QBE call representation' \
  "$scratch/stream-qbe.log" >/dev/null \
  || die "QBE process refusal changed"

phase "sleep-only QBE refusal (deadline 180s)"
set +e
timeout --foreground --signal=TERM --kill-after=2s 180s \
  "$repo/bin/beagle" build --materializer qbe \
  --out "$scratch/sleep-qbe" "$here/sleep_probe.bgl" \
  >"$scratch/sleep-qbe.log" 2>&1
sleep_qbe_status=$?
set -e
[[ $sleep_qbe_status -ne 0 ]] || die "QBE unexpectedly accepted sleep"
[[ $sleep_qbe_status -ne 124 && $sleep_qbe_status -ne 137 ]] \
  || die "sleep QBE refusal exceeded 180s"
rg -Fx \
  'materialize-qbe REFUSED QBE monotonic clock extern ABI is unsupported: host clock reads have no QBE call representation' \
  "$scratch/sleep-qbe.log" >/dev/null \
  || die "QBE sleep refusal changed"

run_phase "generated stream C17 strict compile" 30 \
  cc -std=c17 -Wall -Wextra -Werror -pedantic \
  -I"$repo/native-core/shim" -I"$scratch/stream-c17" \
  -c "$scratch/stream-c17/module_0.c" -o "$scratch/stream-module.o"

run_phase "native child compile" 30 \
  cc -std=c17 -Wall -Wextra -Werror -pedantic \
  "$here/child.c" -o "$scratch/child"

run_phase "native shim lifecycle compile" 30 \
  cc -std=c17 -Wall -Wextra -Werror -pedantic \
  -I"$repo/native-core/shim" \
  "$here/shim_contract.c" "$repo/native-core/shim/native_shim.c" \
  -pthread -lm -o "$scratch/shim-contract"
run_phase "native shim lifecycle runtime" 20 \
  "$scratch/shim-contract" "$scratch/child"

run_phase "WASI fail-closed compile" 30 \
  cc -std=c17 -Wall -Wextra -Werror -pedantic -D__wasi__ \
  -I"$repo/native-core/shim" \
  "$here/shim_contract.c" "$repo/native-core/shim/native_shim.c" \
  -pthread -lm -o "$scratch/wasi-contract"
run_phase "WASI fail-closed runtime" 10 "$scratch/wasi-contract"

run_phase "finite native executable build" 180 \
  "$repo/bin/beagle-native-exe" \
  --out "$scratch/process-stream-finite" \
  --artifacts "$scratch/finite-artifacts" \
  --entry native.process-stream-probe/finite \
  -- "$here/process_stream_probe.bgl"
run_phase "finite native lifecycle runtime" 10 \
  "$scratch/process-stream-finite" "$scratch/child" finite

run_phase "long-lived native executable build" 180 \
  "$repo/bin/beagle-native-exe" \
  --out "$scratch/process-stream-long" \
  --artifacts "$scratch/long-artifacts" \
  --entry native.process-stream-probe/long-lived \
  -- "$here/process_stream_probe.bgl"
run_phase "long-lived native lifecycle runtime" 10 \
  "$scratch/process-stream-long" "$scratch/child" long-lived

echo "process-stream fixture: finite EOF, long-lived close/reap, bounds, EINTR, C17, QBE, and WASI pass"
