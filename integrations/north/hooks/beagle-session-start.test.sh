#!/usr/bin/env bash
# Hermetic activation/lifecycle tests for beagle-session-start.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/beagle-session-start.sh"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/beagle-session-start-test.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

PROJECT="$SCRATCH/project"
PLAIN="$SCRATCH/plain"
STATE="$SCRATCH/state"
FAKE_BEAGLE="$SCRATCH/beagle"
TRACE="$SCRATCH/revive.trace"
mkdir -p "$PROJECT" "$PLAIN" "$STATE" "$FAKE_BEAGLE/bin" "$SCRATCH/home"
touch "$PROJECT/main.bnix"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >>"$BEAGLE_TEST_TRACE"' \
  >"$FAKE_BEAGLE/bin/beagle"
chmod +x "$FAKE_BEAGLE/bin/beagle"

pass=0
fail=0

ok() {
  pass=$((pass + 1))
  printf 'PASS  %s\n' "$1"
}

not_ok() {
  fail=$((fail + 1))
  printf 'FAIL  %s\n' "$1" >&2
}

assert_contains() {
  local value="$1" needle="$2" label="$3"
  if [[ "$value" == *"$needle"* ]]; then ok "$label"
  else not_ok "$label (missing: $needle; got: $value)"; fi
}

assert_not_contains() {
  local value="$1" needle="$2" label="$3"
  if [[ "$value" != *"$needle"* ]]; then ok "$label"
  else not_ok "$label (unexpected: $needle; got: $value)"; fi
}

assert_empty() {
  local value="$1" label="$2"
  if [ -z "$value" ]; then ok "$label"
  else not_ok "$label (got: $value)"; fi
}

trace_count() {
  if [ -f "$TRACE" ]; then wc -l <"$TRACE"
  else printf '0\n'; fi
}

event_json() {
  python3 -c '
import json
import sys
print(json.dumps({
    "hook_event_name": "SessionStart",
    "session_id": sys.argv[1],
    "source": sys.argv[2],
    "cwd": sys.argv[3],
}))
' "$1" "$2" "$3"
}

run_hook_raw() {
  local sid="$1" source="$2" cwd="$3"
  event_json "$sid" "$source" "$cwd" |
    env -u AGENT_NO_AUTHORING_HOOKS \
      HOME="$SCRATCH/home" \
      BEAGLE_PATH="$FAKE_BEAGLE" \
      BEAGLE_SESSION_STATE_DIR="$STATE" \
      BEAGLE_TEST_TRACE="$TRACE" \
      BEAGLE_SWITCHBOARD_ACTIVITY_LIB="${BEAGLE_SWITCHBOARD_ACTIVITY_LIB:-$SCRATCH/missing-switchboard-activity.sh}" \
      AUTHORING_KILLSWITCH_STATE="$SCRATCH/killswitch.state" \
      "$HOOK"
}

context_of() {
  jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$1"
}

first="$(run_hook_raw session-a startup "$PROJECT")"
if jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' <<<"$first" >/dev/null 2>&1; then
  ok 'startup emits valid SessionStart JSON'
else
  not_ok "startup emits valid SessionStart JSON (got: $first)"
fi
first_ctx="$(context_of "$first")"
assert_contains "$first_ctx" 'Beagle authoring is active.' 'startup injects the full handshake'
assert_contains "$first_ctx" 'Existing fast health evidence or passing functional canaries authorize editing' \
  'startup accepts proportional health evidence'
assert_contains "$first_ctx" 'beagle doctor --deep` only after concrete degraded feedback' \
  'startup reserves deep doctor for concrete degradation'
assert_not_contains "$first_ctx" 'Before the first Beagle edit' \
  'startup does not impose a first-edit ritual'
if [ "$(trace_count)" -eq 0 ]; then ok 'startup runs no Beagle command'
else not_ok "startup runs no Beagle command (count=$(trace_count))"; fi

resume="$(run_hook_raw session-a resume "$PROJECT")"
assert_empty "$resume" 'resume in the same session is silent'
if [ "$(trace_count)" -eq 0 ]; then ok 'resume runs no Beagle command'
else not_ok "resume runs no Beagle command (count=$(trace_count))"; fi

second_session="$(run_hook_raw session-b startup "$PROJECT")"
second_ctx="$(context_of "$second_session")"
assert_contains "$second_ctx" 'Beagle authoring is active.' 'a new session receives the full handshake'
if [ "$(trace_count)" -eq 0 ]; then ok 'a new session runs no Beagle command'
else not_ok "a new session runs no Beagle command (count=$(trace_count))"; fi

first_resume="$(run_hook_raw session-resume-first resume "$PROJECT")"
first_resume_ctx="$(context_of "$first_resume")"
assert_contains "$first_resume_ctx" 'Beagle authoring is active.' \
  'a first-seen resume restores context after process/runtime-state loss'
repeat_resume="$(run_hook_raw session-resume-first resume "$PROJECT")"
assert_empty "$repeat_resume" 'a repeated resume remains deduplicated'

compact="$(run_hook_raw session-a compact "$PROJECT")"
compact_ctx="$(context_of "$compact")"
assert_contains "$compact_ctx" 'after compaction' 'compact restores concise authoring context'
assert_not_contains "$compact_ctx" 'Beagle authoring is active.' 'compact does not repeat the full handshake'
assert_contains "$compact_ctx" 'only after concrete degraded feedback' \
  'compact preserves the proportional recovery rule'

clear="$(run_hook_raw session-a clear "$PROJECT")"
clear_ctx="$(context_of "$clear")"
assert_contains "$clear_ctx" 'Beagle authoring is active.' 'clear restores the full handshake'
if [ "$(trace_count)" -eq 0 ]; then ok 'clear runs no Beagle command'
else not_ok "clear runs no Beagle command (count=$(trace_count))"; fi

plain="$(run_hook_raw session-plain startup "$PLAIN")"
assert_empty "$plain" 'a non-Beagle checkout is silent'
touch "$PLAIN/late.bnix"
late_beagle="$(run_hook_raw session-plain resume "$PLAIN")"
late_beagle_ctx="$(context_of "$late_beagle")"
assert_contains "$late_beagle_ctx" 'Beagle authoring is active.' \
  'a silent non-Beagle start does not consume the later Beagle context claim'
rm -f "$PLAIN/late.bnix"

disabled_payload="$(event_json session-disabled startup "$PROJECT")"
disabled="$(
  printf '%s' "$disabled_payload" |
    env HOME="$SCRATCH/home" \
      AGENT_NO_AUTHORING_HOOKS=1 \
      BEAGLE_PATH="$FAKE_BEAGLE" \
      BEAGLE_SESSION_STATE_DIR="$STATE" \
      BEAGLE_TEST_TRACE="$TRACE" \
      AUTHORING_KILLSWITCH_STATE="$SCRATCH/killswitch.state" \
      "$HOOK"
)"
assert_empty "$disabled" 'the authoring kill-switch is silent'

cat >"$SCRATCH/switchboard-activity.sh" <<'SH'
agents_switchboard_active() {
  [ "${BEAGLE_TEST_SWITCHBOARD_STATE:-off}" = on ]
}
SH
export BEAGLE_SWITCHBOARD_ACTIVITY_LIB="$SCRATCH/switchboard-activity.sh"
export BEAGLE_TEST_SWITCHBOARD_STATE=off
switchboard_off="$(run_hook_raw session-switchboard-off startup "$PROJECT")"
assert_empty "$switchboard_off" 'the switchboard off verdict is silent'
export BEAGLE_TEST_SWITCHBOARD_STATE=on
switchboard_on="$(run_hook_raw session-switchboard-on startup "$PROJECT")"
assert_contains "$(context_of "$switchboard_on")" 'Beagle authoring is active.' \
  'the switchboard on verdict keeps the startup hook active'
unset BEAGLE_SWITCHBOARD_ACTIVITY_LIB BEAGLE_TEST_SWITCHBOARD_STATE

invalid="$(
  cd "$PROJECT" || exit 1
  printf 'not-json' |
    env -u AGENT_NO_AUTHORING_HOOKS \
      HOME="$SCRATCH/home" \
      BEAGLE_PATH="$FAKE_BEAGLE" \
      BEAGLE_SESSION_STATE_DIR="$STATE" \
      BEAGLE_TEST_TRACE="$TRACE" \
      AUTHORING_KILLSWITCH_STATE="$SCRATCH/killswitch.state" \
      "$HOOK"
)"
invalid_ctx="$(context_of "$invalid")"
assert_contains "$invalid_ctx" 'Beagle authoring is active.' 'invalid stdin falls back safely to process cwd'

if [ "$(trace_count)" -eq 0 ]; then ok 'all activation paths avoid startup compiler ceremony'
else not_ok "all activation paths avoid startup compiler ceremony (count=$(trace_count))"; fi
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
