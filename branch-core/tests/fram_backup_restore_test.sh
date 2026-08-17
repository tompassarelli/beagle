#!/usr/bin/env bash
# Full native operator gate. Building the server exceeds the hosted-runner
# budget, so this gate runs in the flake devShell and before a release.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
builder="$repo/bin/fram-native-build"
backup_command="$repo/bin/fram-backup"
driver="$repo/tests/fram_backup_restore_driver.mjs"
space="fram-backup-restore"

skip() {
  echo "fram backup restore: SKIP ($*)"
  exit 0
}

fail() {
  echo "fram backup restore: FAIL: $*" >&2
  exit 1
}

beagle="${FRAM_BEAGLE:-${BEAGLE_HOME:+$BEAGLE_HOME/bin/beagle}}"
[[ -n "$beagle" && -x "$beagle" ]] || skip "set FRAM_BEAGLE to a beagle CLI"
for command in bb bun python3 cc; do
  command -v "$command" >/dev/null 2>&1 || skip "$command is not on PATH"
done

scratch="$(mktemp -d)"
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "${scratch:?}"
}
trap cleanup EXIT INT TERM

mapfile -t sources < <(sed 's|^|'"$repo"'/|' "$repo/native/core_closure_sources.txt")
artifact="${FRAM_BACKUP_ARTIFACT:-}"
if [[ -z "$artifact" ]]; then
  artifact="$(FRAM_BEAGLE="$beagle" "$builder" --host server "${sources[@]}")" ||
    fail "server build failed"
fi
server="$artifact/bin/fram-server-native"
artifact_receipt="$artifact/READY"
[[ -x "$server" ]] || fail "artifact has no fram-server-native"
[[ -f "$artifact_receipt" ]] || fail "artifact has no READY receipt"

port="$(python3 -c 'import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
source_log="$scratch/source/history.framlog"
backup="$scratch/backup"
restore_log="$scratch/restore/history.framlog"
mkdir -p "$(dirname "$source_log")" "$(dirname "$restore_log")"

start_server() { # log-path output-stem
  local log_path="$1"
  local stem="$2"
  "$server" "$port" "$log_path" "$space" >"$scratch/$stem.out" 2>"$scratch/$stem.err" &
  server_pid=$!
  for _ in $(seq 1 200); do
    if python3 -c 'import socket,sys
s=socket.socket(); s.settimeout(0.2)
sys.exit(0 if s.connect_ex(("127.0.0.1",'"$port"'))==0 else 1)' 2>/dev/null; then
      if bun "$driver" "$port" "$space" version >"$scratch/$stem.version" 2>/dev/null; then
        return 0
      fi
    fi
    kill -0 "$server_pid" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

stop_server() {
  [[ -n "$server_pid" ]] || return 0
  kill -TERM "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  server_pid=""
}

start_server "$source_log" source || fail "source server did not become replay-ready"
seed_version="$(bun "$driver" "$port" "$space" seed)"
[[ "$seed_version" == "1" ]] || fail "seed ended at unexpected version $seed_version"

create_receipt="$(
  "$backup_command" create \
    --output "$backup" \
    --log "$source_log" \
    --artifact-receipt "$artifact_receipt" \
    --space-id "$space" \
    --host 127.0.0.1 \
    --port "$port"
)"
[[ -f "$backup/manifest.json" && -f "$backup/manifest.sha256" ]] ||
  fail "backup did not publish its manifest"
[[ ! -e "$backup/history.framlog.snapshot" ]] ||
  fail "backup copied derived snapshot state"
verify_receipt="$("$backup_command" verify --backup "$backup" --space-id "$space")"
grep -Fq 'fram-backup/create-receipt/v1' <<<"$create_receipt" ||
  fail "create receipt has the wrong format"
grep -Fq 'fram-backup/verify-receipt/v1' <<<"$verify_receipt" ||
  fail "verify receipt has the wrong format"
if "$backup_command" verify --backup "$backup" --space-id wrong-space \
    >"$scratch/verify-wrong.out" 2>"$scratch/verify-wrong.err"; then
  fail "verify accepted the wrong SpaceId"
fi
grep -Fq 'space-mismatch' "$scratch/verify-wrong.err" ||
  fail "wrong-SpaceId verify did not fail typed"

served_version="$(sed -n 's/.*"servedVersion":"\([0-9][0-9]*\)".*/\1/p' "$backup/manifest.json")"
[[ "$served_version" == "$seed_version" ]] ||
  fail "manifest version $served_version does not equal checkpoint version $seed_version"
tail_version="$(bun "$driver" "$port" "$space" tail "$served_version")"
[[ "$tail_version" == "2" ]] || fail "source tail ended at unexpected version $tail_version"
stop_server

cp "$backup/history.framlog" "$restore_log"
[[ ! -e "$restore_log.snapshot" ]] || fail "restore storage was not fresh"
restore_hash_before="$(bun -e 'const bytes = await Bun.file(Bun.argv[1]).arrayBuffer();
console.log(new Bun.CryptoHasher("sha256").update(bytes).digest("hex"));' "$restore_log")"
if timeout 10 "$server" "$port" "$restore_log" wrong-space \
    >"$scratch/wrong-space.out" 2>"$scratch/wrong-space.err"; then
  fail "restored FRAMLOG booted under the wrong SpaceId"
fi
grep -Fq 'generated store boot failed' "$scratch/wrong-space.err" ||
  fail "wrong-SpaceId restore did not fail closed during store boot"
restore_hash_after="$(bun -e 'const bytes = await Bun.file(Bun.argv[1]).arrayBuffer();
console.log(new Bun.CryptoHasher("sha256").update(bytes).digest("hex"));' "$restore_log")"
[[ "$restore_hash_after" == "$restore_hash_before" ]] ||
  fail "wrong-SpaceId boot mutated the restored FRAMLOG"

start_server "$restore_log" restore-1 || fail "restored server did not become replay-ready"
bun "$driver" "$port" "$space" restored "$served_version" >/dev/null
post_version="$(bun "$driver" "$port" "$space" postwrite "$served_version")"
[[ "$post_version" == "$((served_version + 1))" ]] ||
  fail "post-restore write ended at unexpected version $post_version"
stop_server

start_server "$restore_log" restore-2 || fail "post-write server did not restart"
bun "$driver" "$port" "$space" postrestart "$post_version" >/dev/null
stop_server

read -r manifest_hash _ <"$backup/manifest.sha256"
history_hash="$(sed -n 's/.*"history":{[^}]*"sha256":"\([0-9a-f][0-9a-f]*\)".*/\1/p' "$backup/manifest.json")"
[[ ${#manifest_hash} -eq 64 && ${#history_hash} -eq 64 ]] ||
  fail "backup hashes are not complete SHA-256 values"
echo "fram backup restore: PASS manifest=$manifest_hash history=$history_hash version=$post_version"
