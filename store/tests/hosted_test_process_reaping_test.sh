#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="$repo/tests/run_hosted_test.sh"
fixture="$repo/tests/fixtures/hosted_test_descendant.sh"
scratch="$(mktemp -d)"
owned_pids=()

cleanup() {
  local pid
  for pid in "${owned_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "${scratch:?}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

read_descendant() {
  local pid_file="$1"
  for _ in $(seq 1 200); do
    [[ -s "$pid_file" ]] && break
    sleep 0.01
  done
  [[ -s "$pid_file" ]] || {
    echo "hosted process reaping: fixture wrote no descendant PID" >&2
    exit 1
  }
  local pid
  read -r pid <"$pid_file"
  printf '%s\n' "$pid"
}

assert_reaped() {
  local label="$1"
  local pid="$2"
  for _ in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.02
  done
  echo "hosted process reaping: $label left PID $pid alive" >&2
  exit 1
}

success_pid_file="$scratch/success.pid"
"$runner" 5s "$fixture" "$success_pid_file" success beagle-store-server
success_pid="$(read_descendant "$success_pid_file")"
owned_pids+=("$success_pid")
assert_reaped success "$success_pid"

failure_pid_file="$scratch/failure.pid"
set +e
"$runner" 5s "$fixture" "$failure_pid_file" failure beagle-store-native-build
failure_status=$?
set -e
[[ $failure_status -eq 23 ]] || {
  echo "hosted process reaping: failure status became $failure_status, expected 23" >&2
  exit 1
}
failure_pid="$(read_descendant "$failure_pid_file")"
owned_pids+=("$failure_pid")
assert_reaped failure "$failure_pid"

timeout_pid_file="$scratch/timeout.pid"
set +e
"$runner" 0.2s "$fixture" "$timeout_pid_file" wait beagle-store-server
timeout_status=$?
set -e
[[ $timeout_status -eq 124 ]] || {
  echo "hosted process reaping: timeout status became $timeout_status, expected 124" >&2
  exit 1
}
timeout_pid="$(read_descendant "$timeout_pid_file")"
owned_pids+=("$timeout_pid")
assert_reaped timeout "$timeout_pid"

for attempt in $(seq 1 20); do
  interrupt_pid_file="$scratch/interrupt-$attempt.pid"
  "$runner" 30s "$fixture" "$interrupt_pid_file" wait beagle-store-native-build \
    2>"$scratch/interrupt-$attempt.err" &
  harness_pid=$!
  interrupt_pid="$(read_descendant "$interrupt_pid_file")"
  owned_pids+=("$interrupt_pid")
  kill -TERM "$harness_pid"
  set +e
  wait "$harness_pid"
  interrupt_status=$?
  set -e
  [[ $interrupt_status -eq 143 ]] || {
    echo "hosted process reaping: interrupt status became $interrupt_status, expected 143" >&2
    exit 1
  }
  assert_reaped "interruption $attempt" "$interrupt_pid"
done

echo "hosted process reaping: PASS success failure timeout interruption x20"
