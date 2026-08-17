#!/usr/bin/env bash
# Run one hosted test in an owned process group and leave no descendants behind.
set -uo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: tests/run_hosted_test.sh DURATION COMMAND [ARG...]" >&2
  exit 2
fi

duration="$1"
shift
kill_after="${BEAGLE_STORE_HOSTED_TEST_KILL_AFTER:-10s}"
supervisor_pid=""
owned_pgid=""
group_owned=0
pending_signal=0
ready_dir="$(mktemp -d)"
ready_file="$ready_dir/session.pid"
owned_file="$ready_dir/owned"

group_alive() {
  [[ $group_owned -eq 1 ]] &&
    kill -0 -- "-$owned_pgid" 2>/dev/null
}

adopt_owned_group() {
  local session_pid

  [[ -s "$ready_file" ]] || return 1
  read -r session_pid <"$ready_file"
  if [[ ! "$session_pid" =~ ^[1-9][0-9]*$ ]] || [[ "$session_pid" == "$$" ]]; then
    echo "run_hosted_test: invalid owned process group $session_pid" >&2
    return 2
  fi
  owned_pgid="$session_pid"
  group_owned=1
}

reap_owned_processes() {
  local clean=0

  if [[ -n "$supervisor_pid" ]]; then
    # TERM can arrive between launch and the main handshake. The setsid
    # supervisor is still alive then, so give its private child enough time to
    # publish the exact session ID before falling back to the supervisor PID.
    if [[ $group_owned -eq 0 ]]; then
      for _ in $(seq 1 100); do
        adopt_owned_group && break
        [[ $? -eq 2 ]] && break
        sleep 0.01
      done
    fi
    if [[ $group_owned -eq 1 ]]; then
      if group_alive; then
        kill -TERM -- "-$owned_pgid" 2>/dev/null || true
        for _ in $(seq 1 50); do
          group_alive || break
          sleep 0.1
        done
      fi
      if group_alive; then
        kill -KILL -- "-$owned_pgid" 2>/dev/null || true
        for _ in $(seq 1 50); do
          group_alive || break
          sleep 0.1
        done
      fi
      if group_alive; then
        echo "run_hosted_test: process group $owned_pgid survived cleanup" >&2
        clean=1
      fi
    elif kill -0 "$supervisor_pid" 2>/dev/null; then
      kill -TERM "$supervisor_pid" 2>/dev/null || true
    fi
    wait "$supervisor_pid" 2>/dev/null || true
  fi

  rm -rf "${ready_dir:?}"
  return "$clean"
}

finish() {
  local status="$1"
  trap - EXIT HUP INT TERM
  if ! reap_owned_processes; then
    status=125
  fi
  exit "$status"
}

trap 'finish $?' EXIT
# Until the background PID is captured, defer signals instead of entering
# cleanup with an unowned process between launch and `$!` assignment.
trap 'pending_signal=129' HUP
trap 'pending_signal=130' INT
trap 'pending_signal=143' TERM

# `setsid --fork --wait` makes the ownership boundary independent of whether
# the calling shell has job control enabled. Its child cannot launch COMMAND
# until the parent acknowledges the private session-ID handshake, so there is
# no interruption window where descendants exist before their group is owned.
# The setsid supervisor preserves the command's exit status, and
# `timeout --foreground` keeps COMMAND inside the owned group.
# shellcheck disable=SC2016
setsid --fork --wait bash -c '
  ready_file="$1"
  owned_file="$2"
  shift 2
  printf "%s\n" "$$" >"$ready_file"
  for _ in {1..100}; do
    [[ -e "$owned_file" ]] && break
    sleep 0.01
  done
  if [[ ! -e "$owned_file" ]]; then
    echo "run_hosted_test: parent did not acknowledge process-group ownership" >&2
    exit 125
  fi
  exec "$@"
' bash "$ready_file" "$owned_file" \
  timeout --foreground --signal=TERM --kill-after="$kill_after" \
  "$duration" "$@" &
supervisor_pid=$!
trap 'finish 129' HUP
trap 'finish 130' INT
trap 'finish 143' TERM
if [[ $pending_signal -ne 0 ]]; then
  finish "$pending_signal"
fi

for _ in $(seq 1 100); do
  [[ -s "$ready_file" ]] && break
  kill -0 "$supervisor_pid" 2>/dev/null || break
  sleep 0.01
done

if [[ -s "$ready_file" ]]; then
  adopt_owned_group || finish 125
  : >"$owned_file"
else
  wait "$supervisor_pid" 2>/dev/null
  echo "run_hosted_test: child exited before establishing its process group" >&2
  finish 125
fi

wait "$supervisor_pid"
status=$?
finish "$status"
