#!/usr/bin/env bash
set -euo pipefail

pid_file="${1:?pid file is required}"
mode="${2:?mode is required}"
process_name="${3:?process name is required}"

bash -c 'exec -a "$1" bash -c "while :; do sleep 300; done"' \
  bash "$process_name" &
descendant_pid=$!
printf '%s\n' "$descendant_pid" >"$pid_file"

case "$mode" in
  success) exit 0 ;;
  failure) exit 23 ;;
  wait) wait "$descendant_pid" ;;
  *) echo "unknown fixture mode: $mode" >&2; exit 2 ;;
esac
