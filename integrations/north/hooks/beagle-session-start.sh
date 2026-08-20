#!/usr/bin/env bash
# SessionStart hook (global, guarded) — the DETERMINISTIC layer of the Beagle
# authoring setup. Skills/AGENTS.md are model-discretion (can be forgotten);
# this hook is harness-enforced at startup, resume, clear, and compact.
#
# In a Beagle project it injects source-aware authoring context without running
# compiler health or revival commands. Repeated resumes in one session are
# silent; clear/compact re-inject because they rebuild context. Outside a Beagle
# project it is a fast no-op (a few globs, no heavy work).
set -uo pipefail

# Drain before every decision, including the kill-switch. Keep active-path input
# memory-bounded; an oversized envelope follows the existing malformed no-op.
capture_hook_stdin() {
  local chunk status keep
  local LC_ALL=C
  payload=""
  payload_oversized=0
  while :; do
    chunk=""
    IFS= read -r -N 65536 chunk
    status=$?
    if [ -n "$chunk" ]; then
      keep=$((1048576 - ${#payload}))
      [ "$keep" -le 0 ] || payload+="${chunk:0:$keep}"
      [ "${#chunk}" -le "$keep" ] || payload_oversized=1
    fi
    [ "$status" -eq 0 ] || break
  done
}
capture_hook_stdin

# Codex requirements install the complete reviewed hook envelope once; the
# agents switchboard controls whether this member is effective. Claude composes
# only active hooks, so the helper is normally absent there. A pre-switchboard
# installation also keeps the established behavior when no projection exists.
switchboard_activity="${BEAGLE_SWITCHBOARD_ACTIVITY_LIB:-${BASH_SOURCE[0]%/*}/lib/switchboard-activity.sh}"
if [ -r "$switchboard_activity" ]; then
  # shellcheck disable=SC1090
  source "$switchboard_activity" || exit 0
  agents_switchboard_active hook beagle-session-start || exit 0
fi

# Clean-room / experiment kill-switch (opt-OUT), owner-local: when guards are
# OFF this hook no-ops — no authoring context is injected — so
# a controlled run keeps an identical neutral session surface across all arms.
# Engaged by env AGENT_NO_AUTHORING_HOOKS (or the CLAUDE_NO_AUTHORING_HOOKS
# compatibility alias): any value but 0/false = OFF; 0/false forces guards
# LIVE; unset/empty (the default) = normal behavior. This is a self-contained
# env-only check (no shared state file, no north-config dependency) — the
# smallest seam that lets a caller inject its own policy: set
# BEAGLE_AUTHORING_KILLSWITCH_LIB to a script defining `authoring_guards_off`
# before this line to override.
# shellcheck disable=SC1090,SC1091
[ -n "${BEAGLE_AUTHORING_KILLSWITCH_LIB:-}" ] && . "$BEAGLE_AUTHORING_KILLSWITCH_LIB" 2>/dev/null
if ! type authoring_guards_off >/dev/null 2>&1; then
  authoring_guards_off() {
    case "${AGENT_NO_AUTHORING_HOOKS:-${CLAUDE_NO_AUTHORING_HOOKS:-}}" in
      0|false|'') return 1 ;;
      *) return 0 ;;
    esac
  }
fi
authoring_guards_off && exit 0
[ "$payload_oversized" -eq 0 ] || exit 0

# Both Claude Code and Codex pass a SessionStart JSON envelope on stdin. Parse
# it opportunistically: malformed/missing input must never break startup.
event_cwd=""
session_id=""
session_source=""
if [ -n "$payload" ] && command -v python3 >/dev/null 2>&1; then
  mapfile -t event_fields < <(
    printf '%s' "$payload" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

for key in ("cwd", "session_id", "source"):
    value = data.get(key, "")
    print(value if isinstance(value, str) else "")
' 2>/dev/null
  )
  event_cwd="${event_fields[0]:-}"
  session_id="${event_fields[1]:-}"
  session_source="${event_fields[2]:-}"
fi
session_source="${session_source,,}"

# Claude Code sets CLAUDE_PROJECT_DIR. Codex relies on the event cwd. Preserve
# the Claude override, then fall back through the event and process cwd.
dir="${CLAUDE_PROJECT_DIR:-${event_cwd:-$PWD}}"
cd "$dir" 2>/dev/null || exit 0
dir="$(pwd -P)"

# SessionStart is not literally once per session: resume, clear, and compact
# also fire it. An atomic marker keeps ordinary startup/resume idempotent while
# clear/compact deliberately restore context after a context reset.
if [ -n "${BEAGLE_SESSION_STATE_DIR:-}" ]; then
  state_dir="$BEAGLE_SESSION_STATE_DIR"
elif [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  state_dir="$XDG_RUNTIME_DIR/beagle-session-start"
else
  runtime_uid="${UID:-$(id -u)}"
  state_dir="${TMPDIR:-/tmp}/beagle-session-start-$runtime_uid"
fi
state_ready=0
if mkdir -p "$state_dir" 2>/dev/null; then
  chmod 700 "$state_dir" 2>/dev/null || true
  state_ready=1
fi

state_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
  else
    cksum | awk '{print $1}'
  fi
}

session_marker=""
if [ -n "$session_id" ]; then
  session_key="$(printf '%s\0%s' "$session_id" "$dir" | state_hash)"
  session_marker="$state_dir/context-$session_key"
fi

claim_session_context() {
  if [ "$state_ready" -eq 0 ] || [ -z "$session_marker" ]; then
    return 0
  fi
  (set -o noclobber; printf '%s\n' "$session_source" >"$session_marker") 2>/dev/null
}

remember_session_context() {
  [ "$state_ready" -eq 1 ] && [ -n "$session_marker" ] || return 0
  printf '%s\n' "$session_source" >"$session_marker" 2>/dev/null || true
}

context_mode=full
context_prepared=0
prepare_context_mode() {
  [ "$context_prepared" -eq 0 ] || return 0
  context_prepared=1
  case "$session_source" in
    clear)
      # /clear discards prior context, so restore the complete handshake.
      remember_session_context
      ;;
    compact)
      # Compaction also rebuilds context, but a concise reminder is enough.
      remember_session_context
      context_mode=compact
      ;;
    startup|resume|"")
      claim_session_context || context_mode=none
      ;;
    *)
      # Unknown providers/sources retain legacy behavior, with dedupe when a
      # stable session id is available.
      claim_session_context || context_mode=none
      ;;
  esac
}

# --- fast Beagle-context detection (cheap; gate all heavy work behind it) ---
is_beagle() {
  # Definitive: under the beagle checkout (or a worktree of it).
  case "$dir" in
    */code/beagle|*/code/beagle/*|*/code/beagle-*) return 0 ;;
  esac
  # Active beagle project: the daemon/cache marker dir.
  [ -d "$dir/.beagle" ] && return 0
  # Beagle sources at the project root or src/ (precise — NOT a broad subdir
  # scan, so a parent dir like ~ or /tmp that merely contains a beagle project
  # one level down does not trigger).
  # Extensions come from the generated target projection in THIS hook's own
  # checkout (the hook ships inside the beagle repo, so readlink -f finds it
  # even when ~/.agents/hooks symlinks it). The old hand list globbed a
  # phantom .bcljs and omitted current target extensions. If the
  # projection is unreachable the extension probe is simply skipped — the
  # .beagle/ marker and path checks above still identify a beagle project, so
  # no stale duplicate list is kept as a fallback.
  local g e hook_root
  hook_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/../../.." 2>/dev/null && pwd)" || hook_root=""
  if [ -n "$hook_root" ] && [ -f "$hook_root/share/targets.sh" ]; then
    # shellcheck source=/dev/null
    . "$hook_root/share/targets.sh"
    for e in "${BEAGLE_TARGET_IDS[@]}" bgl; do
      for g in ./*".${BEAGLE_TARGET_SRC_EXT[$e]:-$e}" ./src/*".${BEAGLE_TARGET_SRC_EXT[$e]:-$e}"; do
        [ -e "$g" ] && return 0
      done
    done
  fi
  return 1
}

# SessionStart is global, so an ordinary non-Beagle checkout must remain a pure
# no-op.
is_beagle || exit 0

prepare_context_mode
if [ "$context_mode" = none ]; then
  exit 0
fi

if [ "$context_mode" = compact ]; then
  ctx="Beagle authoring context restored after compaction. Existing fast health evidence or passing functional canaries authorize editing; trust compiler and PostToolUse repair feedback. Run \`beagle doctor --deep\` only after concrete degraded feedback that would affect the edit loop."
else
  ctx="Beagle authoring is active. YOU (the agent) own authoring-loop health, not the user. Existing fast health evidence or passing functional canaries authorize editing; do not add a pre-edit gate. Treat the compiler as source of truth and PostToolUse repair feedback as authoritative. Run \`beagle doctor --deep\` only after concrete degraded feedback affecting this edit loop, use \`beagle doctor --revive\` only when diagnosis identifies daemon failure, and use \`beagle init --hooks\` only when the project actually lacks required feedback. Never repeat doctor merely to turn status text green."
fi
# Inject into session context via the SessionStart additionalContext channel.
python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":sys.argv[1]}}))' "$ctx"
exit 0
