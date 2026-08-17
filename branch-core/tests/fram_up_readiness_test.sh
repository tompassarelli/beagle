#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fram_up_source="${FRAM_UP_UNDER_TEST:-$repo_root/bin/fram-up}"
real_sleep="$(command -v sleep)"
scratch="$(mktemp -d)"

cleanup() {
  rm -rf "${scratch:?}"
}
trap cleanup EXIT INT TERM

fail() {
  echo "fram-up readiness: FAIL: $*" >&2
  exit 1
}

make_case() {
  local name="$1"
  local case_dir="$scratch/$name"
  mkdir -p "$case_dir/bin" "$case_dir/out" "$case_dir/work" "$case_dir/state"
  cp "$fram_up_source" "$case_dir/bin/fram-up"
  chmod +x "$case_dir/bin/fram-up"

  cat >"$case_dir/bin/bb" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_STATE/bb.calls"
case "$*" in
  *doctor*|*read-log*|*fold*)
    echo "heavyweight readiness path invoked: $*" >&2
    exit 99
    ;;
esac
[[ "$*" == *native-call!* && "$*" == *:rpc/version* ]] || exit 98
[[ "${TEST_MODE:-}" != "unavailable" ]] || exit 1
[[ "${TEST_MODE:-}" != "wrong-space" ]] || exit 42
[[ -s "$TEST_STATE/served-space" ]] || exit 1
[[ "$FRAM_SPACE_ID" == "$(cat "$TEST_STATE/served-space")" ]] || exit 42
if [[ "${TEST_MODE:-}" == "slow-start" ]]; then
  "$TEST_SLEEP" 0.5
fi
STUB

  cat >"$case_dir/bin/fram-server" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "$1" "$2" >>"$TEST_STATE/server.calls"
if [[ "${TEST_MODE:-}" != "unavailable" ]]; then
  printf '%s\n' "$FRAM_SPACE_ID" >"$TEST_STATE/served-space"
fi
STUB

  cat >"$case_dir/bin/fram" <<'STUB'
#!/usr/bin/env bash
echo "heavyweight fram CLI invoked: $*" >&2
exit 97
STUB

  cat >"$case_dir/bin/ss" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

  cat >"$case_dir/bin/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

  chmod +x "$case_dir/bin/bb" "$case_dir/bin/fram-server" \
    "$case_dir/bin/fram" "$case_dir/bin/ss" "$case_dir/bin/sleep"
  : >"$case_dir/state/bb.calls"
  : >"$case_dir/state/server.calls"
  printf '%s\n' "$case_dir"
}

run_up() {
  local case_dir="$1"
  local mode="$2"
  local log="$3"
  local timeout_seconds="${4:-2}"
  (
    cd "$case_dir/work"
    PATH="$case_dir/bin:$PATH" \
      TEST_STATE="$case_dir/state" \
      TEST_MODE="$mode" \
      TEST_SLEEP="$real_sleep" \
      FRAM_SERVER_PORT=43129 \
      FRAM_SPACE_ID=test-space \
      FRAM_LOG="$log" \
      FRAM_STARTUP_TIMEOUT_SECONDS="$timeout_seconds" \
      "$case_dir/bin/fram-up"
  )
}

ready_dir="$(make_case ready)"
ready_log="$ready_dir/work/coordination.log"
: >"$ready_log"
printf '%s\n' test-space >"$ready_dir/state/served-space"
ready_output="$(run_up "$ready_dir" ready "$ready_log")" ||
  fail "exact-log ready server was rejected"
[[ "$ready_output" == *"server already up"* ]] ||
  fail "exact-log ready server was not recognized"
[[ ! -s "$ready_dir/state/server.calls" ]] ||
  fail "exact-log ready server was unnecessarily restarted"

wrong_dir="$(make_case wrong-log)"
wrong_log="$wrong_dir/work/coordination.log"
: >"$wrong_log"
if run_up "$wrong_dir" wrong-space "$wrong_log" >"$wrong_dir/state/output" 2>&1; then
  fail "wrong-space server was accepted"
fi
grep -q "different FRAM_SPACE_ID" "$wrong_dir/state/output" ||
  fail "wrong-space server did not report the identity mismatch"
[[ ! -s "$wrong_dir/state/server.calls" ]] ||
  fail "wrong-space server triggered a competing launch"

slow_dir="$(make_case slow-start)"
slow_log="$slow_dir/work/coordination.log"
: >"$slow_log"
slow_output="$(run_up "$slow_dir" slow-start "$slow_log" 2)" ||
  fail "delayed healthy server missed the configured deadline"
[[ "$slow_output" == *"starting server"* &&
   "$slow_output" == *"server up"* ]] ||
  fail "delayed healthy server did not complete the startup path"

down_dir="$(make_case unavailable)"
down_log="$down_dir/work/coordination.log"
: >"$down_log"
down_started_ms="$(date +%s%3N)"
if run_up "$down_dir" unavailable "$down_log" 1 >"$down_dir/state/output" 2>&1; then
  fail "unavailable server was accepted as ready"
fi
down_elapsed_ms="$(( $(date +%s%3N) - down_started_ms ))"
grep -q "server did not come up" "$down_dir/state/output" ||
  fail "unavailable server did not report the readiness deadline"
(( down_elapsed_ms >= 800 && down_elapsed_ms < 3000 )) ||
  fail "readiness deadline was not absolute (elapsed ${down_elapsed_ms}ms)"

invalid_dir="$(make_case invalid-timeout)"
invalid_log="$invalid_dir/work/coordination.log"
: >"$invalid_log"
if run_up "$invalid_dir" ready "$invalid_log" 0 >"$invalid_dir/state/output" 2>&1; then
  fail "zero startup timeout was accepted"
fi
grep -q "FRAM_STARTUP_TIMEOUT_SECONDS must be an integer from 1 to 3600" \
  "$invalid_dir/state/output" ||
  fail "invalid startup timeout did not report its accepted range"
[[ ! -s "$invalid_dir/state/server.calls" ]] ||
  fail "invalid startup timeout launched the server"

for calls in "$ready_dir/state/bb.calls" \
             "$wrong_dir/state/bb.calls" \
             "$slow_dir/state/bb.calls" \
             "$down_dir/state/bb.calls"; do
  [[ -s "$calls" ]] || fail "lightweight runtime probe was not invoked"
  if grep -Eq 'doctor|read-log|fold' "$calls"; then
    fail "readiness invoked a heavyweight CLI/log path"
  fi
done

echo "fram-up readiness: PASS"
