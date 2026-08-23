#!/usr/bin/env bash
# store_code_wire_test.sh — focused test for Codex MCP wiring
# shared by beagle-store-code-on/off (bin/beagle-store-code-wire, beagle-store-code-wire-toml.py) and
# for bin/beagle-store-code-status's canonical= registry read. No server boot, no
# Beagle ingest — exercises only the merge/unwire/status-read logic so it
# runs in well under a second. Exits 0 iff every assertion holds.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
assert() { local desc="$1" cond="$2"; if eval "$cond"; then echo "ok - $desc"; else echo "FAIL - $desc"; FAIL=1; fi; }
assert_code_on_line() {
  local desc="$1" line="$2"
  if grep -Fq -- "$line" "$HERE/bin/beagle-store-code-on"; then
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

# --- pre-existing unrelated wiring ------------------------------------------
cat >"$DIR/.codex/config.toml" <<'TOML'
[projects.unrelated]
trust_level = "trusted"

[mcp_servers.other]
command = "/bin/other"
args = []
TOML
cp "$DIR/.codex/config.toml" "$TMP/config.toml.orig"

SERVER_JSON='{"command":"/fake/beagle-store-mcp","args":[],"env":{"BEAGLE_STORE_SPACE_ID":"wire-test-space","BEAGLE_STORE_SERVER_PORT":"31337","BEAGLE_STORE_LOG":"/canonical/store/.store/code.log"}}'

# Markerless tables are not owned by Beagle Store. Refuse to overwrite one on set and
# leave it byte-identical on unset.
UNMANAGED_TOML="$TMP/unmanaged.toml"
printf '[mcp_servers.beagle-store]\ncommand = "/manual/server"\n' > "$UNMANAGED_TOML"
cp "$UNMANAGED_TOML" "$UNMANAGED_TOML.orig"
if python3 "$HERE/bin/beagle-store-code-wire-toml.py" set "$UNMANAGED_TOML" "$SERVER_JSON" \
    >"$TMP/unmanaged-set.out" 2>&1; then
  echo "FAIL - set refuses an unmarked Beagle Store table"
  FAIL=1
else
  echo "ok - set refuses an unmarked Beagle Store table"
fi
assert "refused set leaves the unmarked Beagle Store table byte-identical" \
  'cmp -s "$UNMANAGED_TOML" "$UNMANAGED_TOML.orig"'
python3 "$HERE/bin/beagle-store-code-wire-toml.py" unset "$UNMANAGED_TOML"
assert "unset ignores an unmarked Beagle Store table byte-identically" \
  'cmp -s "$UNMANAGED_TOML" "$UNMANAGED_TOML.orig"'

# beagle-store-code-on binds one stable SpaceId to ingest, server, and MCP configuration.
assert_code_on_line "beagle-store-code-on requires an explicit stable SpaceId" \
  'beagle-store-code-on: --space-id is required and must be nonempty'
assert_code_on_line "beagle-store-code-on passes SpaceId to native ingest" \
  '--root "$SRC" --out "$CODE_LOG" --space-id "$SPACE_ID"'
assert_code_on_line "beagle-store-code-on binds BEAGLE_STORE_SPACE_ID into MCP configuration" \
  '"BEAGLE_STORE_SPACE_ID": "$SPACE_ID"'
assert_code_on_line "beagle-store-code-on binds the native server port" \
  '"BEAGLE_STORE_SERVER_PORT": "$PORT"'
assert_code_on_line "beagle-store-code-on binds the native STORELOG path" \
  '"BEAGLE_STORE_LOG": "$CODE_LOG"'
assert_code_on_line "beagle-store-code-on excludes inherited telemetry from graph servers" \
  'exec env -u BEAGLE_STORE_TELEMETRY_LOG \'
assert_code_on_line "beagle-store-code-on launches the native server with SpaceId" \
  'bin/beagle-store-server serve "$PORT" "$CODE_LOG" "$SPACE_ID"'
assert_code_on_line "beagle-store-code-on probes native rpc/status" \
  'native_status_line() {'
assert_code_on_line "beagle-store-code-on validates the typed native status shape" \
  '[[ ! "$status" =~ ^up\|[0-9]+\|[0-9]+\|ready\|jvm$ ]]'
assert_code_on_line "beagle-store-code-on reserves L3 for graph control" \
  'Level 3 stays'
assert_code_on_line "beagle-store-code-on proves the complete native stack before success" \
  'beagle-store-code-on: FAILED final native stack postcondition:'
assert_code_on_line "beagle-store-code-on stops immediately when its server exits" \
  'FAILED to boot — server exited; see $DIR/.store/server-$PORT.log'
assert_code_on_line "beagle-store-code-on excludes singular test trees from the authoring corpus" \
  "-not -path '*/test/*'"
assert_code_on_line "beagle-store-code-on excludes plural tests trees from the authoring corpus" \
  "-not -path '*/tests/*'"
assert "beagle-store-code-on does not configure the separate graph-control plane" \
  '! grep -Eq "BEAGLE_STORE_GRAPH_EDIT|BEAGLE_STORE_CODE_(PORT|LOG)|:edit-protocol" "$HERE/bin/beagle-store-code-on"'

# The authoring corpus contains production source, not parser/checker fixtures.
CORPUS_ROOT="$TMP/corpus-selection"
mkdir -p "$CORPUS_ROOT/src/store" \
         "$CORPUS_ROOT/codegraph/test" \
         "$CORPUS_ROOT/tests/fixtures"
printf '(ns store.real)\n' >"$CORPUS_ROOT/src/store/real.bclj"
printf '(ns codegraph.test.fixture)\n' >"$CORPUS_ROOT/codegraph/test/fixture.bclj"
printf '(ns store.test.fixture)\n' >"$CORPUS_ROOT/tests/fixtures/fixture.bclj"
mapfile -t CORPUS_SRCS < <(
  find "$CORPUS_ROOT" -regextype posix-extended \
    -regex '.*\.b(clj|js|nix|gl)$' \
    -not -path '*/.store/*' \
    -not -path '*/docs/private/*' \
    -not -path '*/test/*' \
    -not -path '*/tests/*' |
    sort
)
assert "beagle-store-code-on corpus selection retains a real source module" \
  '[ "${#CORPUS_SRCS[@]}" = 1 ] && [ "${CORPUS_SRCS[0]}" = "$CORPUS_ROOT/src/store/real.bclj" ]'
assert "beagle-store-code-on corpus selection excludes codegraph/test fixtures" \
  '[[ ! " ${CORPUS_SRCS[*]} " =~ " $CORPUS_ROOT/codegraph/test/fixture.bclj " ]]'
assert "beagle-store-code-on corpus selection excludes tests/fixtures sources" \
  '[[ ! " ${CORPUS_SRCS[*]} " =~ " $CORPUS_ROOT/tests/fixtures/fixture.bclj " ]]'

# --- wire ON: merge, preserve unrelated keys --------------------------------
"$HERE/bin/beagle-store-code-wire" on "$DIR" "$SERVER_JSON"

assert "config.toml gains [mcp_servers.beagle-store]" \
  'grep -q "^\[mcp_servers.beagle-store\]$" "$DIR/.codex/config.toml"'
assert "config.toml store command matches" \
  'grep -A2 "^\[mcp_servers.beagle-store\]$" "$DIR/.codex/config.toml" | grep -q "/fake/beagle-store-mcp"'
assert "config.toml preserves stable SpaceId" \
  'grep -q "^BEAGLE_STORE_SPACE_ID = \"wire-test-space\"$" "$DIR/.codex/config.toml"'
assert "config.toml preserves native server port" \
  'grep -q "^BEAGLE_STORE_SERVER_PORT = \"31337\"$" "$DIR/.codex/config.toml"'
assert "config.toml preserves native STORELOG" \
  'grep -q "^BEAGLE_STORE_LOG = \"/canonical/store/.store/code.log\"$" "$DIR/.codex/config.toml"'
assert "config.toml keeps unrelated [projects.unrelated]" \
  'grep -q "^\[projects.unrelated\]$" "$DIR/.codex/config.toml"'
assert "config.toml keeps unrelated [mcp_servers.other]" \
  'grep -q "^\[mcp_servers.other\]$" "$DIR/.codex/config.toml"'

# --- idempotency: re-run ON must not duplicate -------------------------------
"$HERE/bin/beagle-store-code-wire" on "$DIR" "$SERVER_JSON"
BEAGLE_STORE_HEADER_COUNT="$(grep -c '^\[mcp_servers\.beagle-store\]$' "$DIR/.codex/config.toml")"
assert "re-running wire on: exactly one [mcp_servers.beagle-store] block" \
  '[ "$BEAGLE_STORE_HEADER_COUNT" = "1" ]'

# --- beagle-store-code-status reports the guard's registry contract -----------------
REG="$TMP/graph-upstream-files"
mkdir -p "$DIR/some"
printf '%s\n' '(define-target clj)' '(defn ordinary [] 1)' > "$DIR/some/file.bclj"
printf '%s/some/file.bclj\n' "$DIR" > "$REG"
STATUS_LINE="$(GRAPH_UPSTREAM_REGISTRY="$REG" "$HERE/bin/beagle-store-code-status" "$DIR")"
assert "beagle-store-code-status honors GRAPH_UPSTREAM_REGISTRY override" \
  'echo "$STATUS_LINE" | grep -q "canonical=1"'
assert "beagle-store-code-status carries the configured SpaceId" \
  'echo "$STATUS_LINE" | grep -q "space=wire-test-space"'

printf '%s\n' '(define-target clj)' '(defn unregistered [] 1)' > "$DIR/some/unregistered.bclj"
printf '%s\n' '/stale/pre-container/file.bclj' > "$REG"
STATUS_LINE="$(GRAPH_UPSTREAM_REGISTRY="$REG" "$HERE/bin/beagle-store-code-status" "$DIR")"
assert "beagle-store-code-status ignores an unregistered file and a stale registry row" \
  'echo "$STATUS_LINE" | grep -q "canonical=0"'

PRIMARY="$TMP/status-main"
LINKED="$TMP/status-linked"
git init -q "$PRIMARY"
git -C "$PRIMARY" config user.name store-test
git -C "$PRIMARY" config user.email store-test@example.invalid
mkdir -p "$PRIMARY/src"
printf '%s\n' '(define-target clj)' '(defn linked [] 3)' > "$PRIMARY/src/linked.bclj"
git -C "$PRIMARY" add src/linked.bclj
git -C "$PRIMARY" commit -qm seed
git -C "$PRIMARY" worktree add -q -b status-linked "$LINKED"
printf '%s/src/linked.bclj\n' "$PRIMARY" > "$REG"
STATUS_LINE="$(GRAPH_UPSTREAM_REGISTRY="$REG" "$HERE/bin/beagle-store-code-status" "$LINKED")"
assert "beagle-store-code-status carries registry adoption across a linked worktree" \
  'echo "$STATUS_LINE" | grep -q "canonical=1"'
assert "bin/beagle-store-code-status never references graph-owned-files" \
  '[ "$(grep -c "graph-owned-files" "$HERE/bin/beagle-store-code-status")" = "0" ]'

# --- wire OFF: remove only the store section, byte-identical unrelated toml --
"$HERE/bin/beagle-store-code-wire" off "$DIR"

assert "config.toml loses [mcp_servers.beagle-store]" \
  '! grep -q "^\[mcp_servers.beagle-store\]$" "$DIR/.codex/config.toml"'
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
  "$HERE/bin/beagle-store-code-wire" on "$repo" "$SERVER_JSON"
  "$HERE/bin/beagle-store-code-wire" on "$repo" "$SERVER_JSON"
  if [ "$(grep -c '^# >>> beagle-store-code-wire managed mcp_servers\.beagle-store ' "$repo/.codex/config.toml")" = "1" ] &&
     [ "$(grep -c '^# <<< beagle-store-code-wire managed mcp_servers\.beagle-store$' "$repo/.codex/config.toml")" = "1" ]; then
    echo "ok - $name has one owned marker pair after repeated on"
  else
    echo "FAIL - $name has one owned marker pair after repeated on"
    FAIL=1
  fi
  "$HERE/bin/beagle-store-code-wire" off "$repo"
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

# --- store-only config is removed entirely on off ---------------------------
DIR2="$TMP/repo2"
mkdir -p "$DIR2"
"$HERE/bin/beagle-store-code-wire" on "$DIR2" "$SERVER_JSON"
assert "store-only config.toml created" '[ -f "$DIR2/.codex/config.toml" ]'
assert "store-only config.toml has owned marker" \
  'grep -q "^# >>> beagle-store-code-wire managed mcp_servers\.beagle-store separator=0$" "$DIR2/.codex/config.toml"'
"$HERE/bin/beagle-store-code-wire" off "$DIR2"
assert "store-only config.toml removed on off" '[ ! -f "$DIR2/.codex/config.toml" ]'

if [ "$FAIL" = 0 ]; then
  echo "store_code_wire_test.sh: all assertions passed"
else
  echo "store_code_wire_test.sh: FAILURES ABOVE" >&2
fi
exit "$FAIL"
