#!/usr/bin/env bash
# fram_code_wire_test.sh — focused test for the dual Claude/Codex MCP wiring
# shared by fram-code-on/off (bin/fram-code-wire, fram-code-wire-toml.py) and
# for bin/fram-code-status's canonical= registry read. No server boot, no
# Beagle ingest — exercises only the merge/unwire/status-read logic so it
# runs in well under a second. Exits 0 iff every assertion holds.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
assert() { local desc="$1" cond="$2"; if eval "$cond"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }
assert_code_on_line() {
  local desc="$1" line="$2"
  if grep -Fq -- "$line" "$HERE/bin/fram-code-on"; then
    echo "ok - $desc"
  else
    echo "FAIL - $desc"
    FAIL=1
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
DIR="$TMP/repo"
mkdir -p "$DIR/.codex"

# --- pre-existing unrelated wiring in both files ----------------------------
cat >"$DIR/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "other-tool": { "command": "/bin/other", "args": [], "env": {} }
  }
}
JSON
cat >"$DIR/.codex/config.toml" <<'TOML'
[projects.unrelated]
trust_level = "trusted"

[mcp_servers.other]
command = "/bin/other"
args = []
TOML
cp "$DIR/.codex/config.toml" "$TMP/config.toml.orig"

SERVER_JSON='{"command":"/fake/fram-mcp","args":[],"env":{"FRAM_SPACE_ID":"wire-test-space","FRAM_SERVER_PORT":"31337","FRAM_LOG":"/canonical/fram/.fram/code.log"}}'

# Markerless tables are not owned by Fram. Refuse to overwrite one on set and
# leave it byte-identical on unset.
UNMANAGED_TOML="$TMP/unmanaged.toml"
printf '[mcp_servers.fram]\ncommand = "/manual/server"\n' > "$UNMANAGED_TOML"
cp "$UNMANAGED_TOML" "$UNMANAGED_TOML.orig"
if python3 "$HERE/bin/fram-code-wire-toml.py" set "$UNMANAGED_TOML" "$SERVER_JSON" \
    >"$TMP/unmanaged-set.out" 2>&1; then
  echo "FAIL - set refuses an unmarked Fram table"
  FAIL=1
else
  echo "ok - set refuses an unmarked Fram table"
fi
assert "refused set leaves the unmarked Fram table byte-identical" \
  'cmp -s "$UNMANAGED_TOML" "$UNMANAGED_TOML.orig"'
python3 "$HERE/bin/fram-code-wire-toml.py" unset "$UNMANAGED_TOML"
assert "unset ignores an unmarked Fram table byte-identically" \
  'cmp -s "$UNMANAGED_TOML" "$UNMANAGED_TOML.orig"'

# fram-code-on binds one stable SpaceId to ingest, server, and MCP configuration.
assert_code_on_line "fram-code-on requires an explicit stable SpaceId" \
  'fram-code-on: --space-id is required and must be nonempty'
assert_code_on_line "fram-code-on passes SpaceId to native ingest" \
  '--root "$SRC" --out "$CODE_LOG" --space-id "$SPACE_ID"'
assert_code_on_line "fram-code-on binds FRAM_SPACE_ID into MCP configuration" \
  '"FRAM_SPACE_ID": "$SPACE_ID"'
assert_code_on_line "fram-code-on binds the native server port" \
  '"FRAM_SERVER_PORT": "$PORT"'
assert_code_on_line "fram-code-on binds the native FRAMLOG path" \
  '"FRAM_LOG": "$CODE_LOG"'
assert_code_on_line "fram-code-on excludes inherited telemetry from graph servers" \
  'exec env -u FRAM_TELEMETRY_LOG \'
assert_code_on_line "fram-code-on launches the native server with SpaceId" \
  'bin/fram-server serve "$PORT" "$CODE_LOG" "$SPACE_ID"'
assert_code_on_line "fram-code-on probes native rpc/status" \
  'native_status_line() {'
assert_code_on_line "fram-code-on validates the typed native status shape" \
  '[[ ! "$status" =~ ^up\|[0-9]+\|[0-9]+\|ready\|jvm$ ]]'
assert_code_on_line "fram-code-on reserves L3 for graph control" \
  'Level 3 stays'
assert_code_on_line "fram-code-on proves the complete native stack before success" \
  'fram-code-on: FAILED final native stack postcondition:'
assert_code_on_line "fram-code-on stops immediately when its server exits" \
  'FAILED to boot — server exited; see $DIR/.fram/server-$PORT.log'
assert_code_on_line "fram-code-on excludes singular test trees from the authoring corpus" \
  "-not -path '*/test/*'"
assert_code_on_line "fram-code-on excludes plural tests trees from the authoring corpus" \
  "-not -path '*/tests/*'"
assert "fram-code-on does not configure the separate graph-control plane" \
  '! grep -Eq "FRAM_GRAPH_EDIT|FRAM_CODE_(PORT|LOG)|:edit-protocol" "$HERE/bin/fram-code-on"'

# The authoring corpus contains production source, not parser/checker fixtures.
CORPUS_ROOT="$TMP/corpus-selection"
mkdir -p "$CORPUS_ROOT/src/fram" \
         "$CORPUS_ROOT/codegraph/test" \
         "$CORPUS_ROOT/tests/fixtures"
printf '(ns fram.real)\n' >"$CORPUS_ROOT/src/fram/real.bclj"
printf '(ns codegraph.test.fixture)\n' >"$CORPUS_ROOT/codegraph/test/fixture.bclj"
printf '(ns fram.test.fixture)\n' >"$CORPUS_ROOT/tests/fixtures/fixture.bclj"
mapfile -t CORPUS_SRCS < <(
  find "$CORPUS_ROOT" -regextype posix-extended \
    -regex '.*\.b(clj|js|nix|gl)$' \
    -not -path '*/.fram/*' \
    -not -path '*/docs/private/*' \
    -not -path '*/test/*' \
    -not -path '*/tests/*' |
    sort
)
assert "fram-code-on corpus selection retains a real source module" \
  '[ "${#CORPUS_SRCS[@]}" = 1 ] && [ "${CORPUS_SRCS[0]}" = "$CORPUS_ROOT/src/fram/real.bclj" ]'
assert "fram-code-on corpus selection excludes codegraph/test fixtures" \
  '[[ ! " ${CORPUS_SRCS[*]} " =~ " $CORPUS_ROOT/codegraph/test/fixture.bclj " ]]'
assert "fram-code-on corpus selection excludes tests/fixtures sources" \
  '[[ ! " ${CORPUS_SRCS[*]} " =~ " $CORPUS_ROOT/tests/fixtures/fixture.bclj " ]]'

# --- wire ON: merge, preserve unrelated keys --------------------------------
"$HERE/bin/fram-code-wire" on "$DIR" "$SERVER_JSON"

assert "mcp.json gains mcpServers.fram" \
  '[ "$(jq -r ".mcpServers.fram.command" "$DIR/.mcp.json")" = "/fake/fram-mcp" ]'
assert "mcp.json preserves stable SpaceId" \
  '[ "$(jq -r ".mcpServers.fram.env.FRAM_SPACE_ID" "$DIR/.mcp.json")" = "wire-test-space" ]'
assert "mcp.json preserves native server port" \
  '[ "$(jq -r ".mcpServers.fram.env.FRAM_SERVER_PORT" "$DIR/.mcp.json")" = "31337" ]'
assert "mcp.json preserves native FRAMLOG" \
  '[ "$(jq -r ".mcpServers.fram.env.FRAM_LOG" "$DIR/.mcp.json")" = "/canonical/fram/.fram/code.log" ]'
assert "mcp.json keeps unrelated mcpServers.other-tool" \
  '[ "$(jq -r ".mcpServers[\"other-tool\"].command" "$DIR/.mcp.json")" = "/bin/other" ]'
assert "config.toml gains [mcp_servers.fram]" \
  'grep -q "^\[mcp_servers.fram\]$" "$DIR/.codex/config.toml"'
assert "config.toml fram command matches" \
  'grep -A2 "^\[mcp_servers.fram\]$" "$DIR/.codex/config.toml" | grep -q "/fake/fram-mcp"'
assert "config.toml preserves stable SpaceId" \
  'grep -q "^FRAM_SPACE_ID = \"wire-test-space\"$" "$DIR/.codex/config.toml"'
assert "config.toml preserves native server port" \
  'grep -q "^FRAM_SERVER_PORT = \"31337\"$" "$DIR/.codex/config.toml"'
assert "config.toml preserves native FRAMLOG" \
  'grep -q "^FRAM_LOG = \"/canonical/fram/.fram/code.log\"$" "$DIR/.codex/config.toml"'
assert "config.toml keeps unrelated [projects.unrelated]" \
  'grep -q "^\[projects.unrelated\]$" "$DIR/.codex/config.toml"'
assert "config.toml keeps unrelated [mcp_servers.other]" \
  'grep -q "^\[mcp_servers.other\]$" "$DIR/.codex/config.toml"'

# --- idempotency: re-run ON must not duplicate -------------------------------
"$HERE/bin/fram-code-wire" on "$DIR" "$SERVER_JSON"
FRAM_HEADER_COUNT="$(grep -c '^\[mcp_servers\.fram\]$' "$DIR/.codex/config.toml")"
assert "re-running wire on: exactly one [mcp_servers.fram] block" \
  '[ "$FRAM_HEADER_COUNT" = "1" ]'
assert "re-running wire on: exactly one mcpServers.fram key" \
  '[ "$(jq ".mcpServers | keys | map(select(. == \"fram\")) | length" "$DIR/.mcp.json")" = "1" ]'

# --- fram-code-status reports the guard's registry contract -----------------
REG="$TMP/graph-upstream-files"
mkdir -p "$DIR/some"
printf '%s\n' '(define-target clj)' '(defn ordinary [] 1)' > "$DIR/some/file.bclj"
printf '%s/some/file.bclj\n' "$DIR" > "$REG"
STATUS_LINE="$(GRAPH_UPSTREAM_REGISTRY="$REG" "$HERE/bin/fram-code-status" "$DIR")"
assert "fram-code-status honors GRAPH_UPSTREAM_REGISTRY override" \
  'echo "$STATUS_LINE" | grep -q "canonical=1"'
assert "fram-code-status carries the configured SpaceId" \
  'echo "$STATUS_LINE" | grep -q "space=wire-test-space"'

printf '%s\n' '(define-target clj)' '(defn unregistered [] 1)' > "$DIR/some/unregistered.bclj"
printf '%s\n' '/stale/pre-container/file.bclj' > "$REG"
STATUS_LINE="$(GRAPH_UPSTREAM_REGISTRY="$REG" "$HERE/bin/fram-code-status" "$DIR")"
assert "fram-code-status ignores an unregistered file and a stale registry row" \
  'echo "$STATUS_LINE" | grep -q "canonical=0"'

PRIMARY="$TMP/status-main"
LINKED="$TMP/status-linked"
git init -q "$PRIMARY"
git -C "$PRIMARY" config user.name fram-test
git -C "$PRIMARY" config user.email fram-test@example.invalid
mkdir -p "$PRIMARY/src"
printf '%s\n' '(define-target clj)' '(defn linked [] 3)' > "$PRIMARY/src/linked.bclj"
git -C "$PRIMARY" add src/linked.bclj
git -C "$PRIMARY" commit -qm seed
git -C "$PRIMARY" worktree add -q -b status-linked "$LINKED"
printf '%s/src/linked.bclj\n' "$PRIMARY" > "$REG"
STATUS_LINE="$(GRAPH_UPSTREAM_REGISTRY="$REG" "$HERE/bin/fram-code-status" "$LINKED")"
assert "fram-code-status carries registry adoption across a linked worktree" \
  'echo "$STATUS_LINE" | grep -q "canonical=1"'
assert "bin/fram-code-status never references graph-owned-files" \
  '[ "$(grep -c "graph-owned-files" "$HERE/bin/fram-code-status")" = "0" ]'

# --- wire OFF: remove only the fram section, byte-identical unrelated toml --
"$HERE/bin/fram-code-wire" off "$DIR"

assert "mcp.json loses mcpServers.fram" \
  '! jq -e ".mcpServers.fram" "$DIR/.mcp.json" >/dev/null 2>&1'
assert "mcp.json keeps unrelated mcpServers.other-tool after off" \
  '[ "$(jq -r ".mcpServers[\"other-tool\"].command" "$DIR/.mcp.json")" = "/bin/other" ]'
assert "config.toml loses [mcp_servers.fram]" \
  '! grep -q "^\[mcp_servers.fram\]$" "$DIR/.codex/config.toml"'
assert "config.toml unrelated sections still present after off" \
  'grep -q "^\[projects.unrelated\]$" "$DIR/.codex/config.toml" && grep -q "^\[mcp_servers.other\]$" "$DIR/.codex/config.toml"'

# --- byte-for-byte: unrelated config.toml content restored exactly after off,
#     not merely "unrelated sections still grep-able" ------------------------
assert "config.toml is byte-for-byte identical to pre-wire original after off" \
  'cmp -s "$DIR/.codex/config.toml" "$TMP/config.toml.orig"'

# --- every EOF shape round-trips byte-for-byte -----------------------------
roundtrip_toml() {
  local name="$1" repo="$2"
  cp "$repo/.codex/config.toml" "$repo/config.toml.orig"
  "$HERE/bin/fram-code-wire" on "$repo" "$SERVER_JSON"
  "$HERE/bin/fram-code-wire" on "$repo" "$SERVER_JSON"
  if [ "$(grep -c '^# >>> fram-code-wire managed mcp_servers\.fram ' "$repo/.codex/config.toml")" = "1" ] &&
     [ "$(grep -c '^# <<< fram-code-wire managed mcp_servers\.fram$' "$repo/.codex/config.toml")" = "1" ]; then
    echo "ok - $name has one owned marker pair after repeated on"
  else
    echo "FAIL - $name has one owned marker pair after repeated on"
    FAIL=1
  fi
  "$HERE/bin/fram-code-wire" off "$repo"
  if cmp -s "$repo/.codex/config.toml" "$repo/config.toml.orig"; then
    echo "ok - $name restores config.toml byte-for-byte"
  else
    echo "FAIL - $name restores config.toml byte-for-byte"
    FAIL=1
  fi
}

ROUNDTRIP_ROOT="$TMP/roundtrip"
mkdir -p "$ROUNDTRIP_ROOT/nonblank-newline/.codex" \
         "$ROUNDTRIP_ROOT/one-blank-line/.codex" \
         "$ROUNDTRIP_ROOT/multiple-blank-lines/.codex" \
         "$ROUNDTRIP_ROOT/no-final-newline/.codex"
printf '[features]\nfoo = true\n' > "$ROUNDTRIP_ROOT/nonblank-newline/.codex/config.toml"
printf '[features]\nfoo = true\n\n' > "$ROUNDTRIP_ROOT/one-blank-line/.codex/config.toml"
printf '[features]\nfoo = true\n\n\n\n' > "$ROUNDTRIP_ROOT/multiple-blank-lines/.codex/config.toml"
printf '[features]\nfoo = true' > "$ROUNDTRIP_ROOT/no-final-newline/.codex/config.toml"
roundtrip_toml "nonblank newline" "$ROUNDTRIP_ROOT/nonblank-newline"
roundtrip_toml "one blank line" "$ROUNDTRIP_ROOT/one-blank-line"
roundtrip_toml "multiple blank lines" "$ROUNDTRIP_ROOT/multiple-blank-lines"
roundtrip_toml "no final newline" "$ROUNDTRIP_ROOT/no-final-newline"

# --- fram-only .mcp.json is removed entirely on off -------------------------
DIR2="$TMP/repo2"
mkdir -p "$DIR2"
"$HERE/bin/fram-code-wire" on "$DIR2" "$SERVER_JSON"
assert "fram-only .mcp.json created" '[ -f "$DIR2/.mcp.json" ]'
assert "fram-only config.toml created" '[ -f "$DIR2/.codex/config.toml" ]'
assert "fram-only config.toml has owned marker" \
  'grep -q "^# >>> fram-code-wire managed mcp_servers\.fram separator=0$" "$DIR2/.codex/config.toml"'
"$HERE/bin/fram-code-wire" off "$DIR2"
assert "fram-only .mcp.json removed on off" '[ ! -f "$DIR2/.mcp.json" ]'
assert "fram-only config.toml removed on off" '[ ! -f "$DIR2/.codex/config.toml" ]'

# --- mcp.json: unrelated ROOT key (not just mcpServers) survives off, and
#     an emptied mcpServers is dropped entirely rather than left as {} -------
DIR3="$TMP/repo3"
mkdir -p "$DIR3"
cat >"$DIR3/.mcp.json" <<'JSON'
{
  "$schema": "https://example.com/mcp.schema.json"
}
JSON
"$HERE/bin/fram-code-wire" on "$DIR3" "$SERVER_JSON"
"$HERE/bin/fram-code-wire" off "$DIR3"
assert "mcp.json keeps unrelated root key after off" \
  '[ "$(jq -r ".\"\$schema\"" "$DIR3/.mcp.json")" = "https://example.com/mcp.schema.json" ]'
assert "mcp.json drops mcpServers key entirely (not empty {}) when emptied" \
  '[ "$(jq "has(\"mcpServers\")" "$DIR3/.mcp.json")" = "false" ]'

if [ "$FAIL" = 0 ]; then
  echo "fram_code_wire_test.sh: all assertions passed"
else
  echo "fram_code_wire_test.sh: FAILURES ABOVE" >&2
fi
exit "$FAIL"
