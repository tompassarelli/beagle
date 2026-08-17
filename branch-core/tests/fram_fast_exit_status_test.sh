#!/usr/bin/env bash
# bin/north:684-706 dispatches on fram-fast's exit status: 3 = unresolved
# id-like ref, 4 = server unreachable, else 1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

scratch="$(mktemp -d)"
server_pid=
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "${scratch:?}"
}
trap cleanup EXIT

port="$(bb -e '(with-open [socket (java.net.ServerSocket. 0)] (print (.getLocalPort socket)))')"
bb -cp out server.clj serve "$port" "$scratch/coordination.log" test-space \
  >"$scratch/server.log" 2>&1 &
server_pid="$!"

ready=0
for _ in $(seq 1 200); do
  if (exec 9<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    exec 9>&-
    ready=1
    break
  fi
  sleep 0.05
done
if [[ "$ready" -ne 1 ]]; then
  printf 'fram_fast_exit_status: server failed to start\n' >&2
  sed -n '1,80p' "$scratch/server.log" >&2
  exit 1
fi

run_fast() {
  FRAM_SERVER_PORT="$1" FRAM_SPACE_ID=test-space bb -cp out bin/fram-fast.clj "${@:2}"
}

fail=0
check_exit() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'fram_fast_exit_status: %s expected exit %s, got %s\n' \
      "$label" "$expected" "$actual" >&2
    fail=1
  fi
}

# exit 3: -existing write against a subject with no live propositions.
set +e
run_fast "$port" tell-existing \
  '@019fa4d4-93aa-7447-aae5-0a5bcfca9999' title "ghost" >"$scratch/out3" 2>&1
status3=$?
set -e
check_exit "unresolved id-like ref (tell-existing on absent subject)" 3 "$status3"

# exit 4: server unreachable (nothing listening on this port).
dead_port=1
set +e
run_fast "$dead_port" tell-existing \
  '@019fa4d4-93aa-7447-aae5-0a5bcfca9999' title "ghost" >"$scratch/out4" 2>&1
status4=$?
set -e
check_exit "server unreachable" 4 "$status4"

# exit 1 preserved: a genuinely unclassified failure (CLI usage error).
set +e
run_fast "$port" tell only-one-arg >"$scratch/out1" 2>&1
status1=$?
set -e
check_exit "usage error stays unclassified" 1 "$status1"

# exit 0 preserved: a successful -existing write against a live subject.
run_fast "$port" tell '@019fa4d4-93aa-7447-aae5-0a5bcfca8888' title "seed" >/dev/null
set +e
run_fast "$port" tell-existing \
  '@019fa4d4-93aa-7447-aae5-0a5bcfca8888' progress "next" >"$scratch/out0" 2>&1
status0=$?
set -e
check_exit "successful existing write" 0 "$status0"

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
printf 'fram_fast_exit_status: PASS\n'
