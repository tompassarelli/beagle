#!/usr/bin/env bash
# Installed server-closure smoke: JVM production launch, explicit Native
# experimental fail-closed launch, CLI, MCP, leases, restart replay, and state.
set -euo pipefail

package_root="${1:?usage: package_server_smoke.sh /nix/store/...-store}"
bb="${BEAGLE_STORE_SMOKE_BB:?BEAGLE_STORE_SMOKE_BB is required}"
env_bin="${BEAGLE_STORE_SMOKE_ENV:?BEAGLE_STORE_SMOKE_ENV is required}"
grep_bin="${BEAGLE_STORE_SMOKE_GREP:?BEAGLE_STORE_SMOKE_GREP is required}"
readlink_bin="${BEAGLE_STORE_SMOKE_READLINK:?BEAGLE_STORE_SMOKE_READLINK is required}"
tr_bin="${BEAGLE_STORE_SMOKE_TR:?BEAGLE_STORE_SMOKE_TR is required}"
require_proc="${BEAGLE_STORE_SMOKE_REQUIRE_PROC:-0}"

case "$package_root" in /nix/store/*) ;; *)
  echo "store package smoke: refusing non-store package root: $package_root" >&2
  exit 2;; esac

runtime="$package_root/libexec/store"
required=(
  "$package_root/bin/beagle-store-server"
  "$package_root/bin/beagle-store-backup" "$package_root/bin/beagle-store-mcp"
  "$runtime/clients/bun/backup.mjs" "$runtime/clients/bun/store-rpc.mjs"
  "$runtime/bin/beagle-store-cli.clj"
  "$runtime/database.clj" "$runtime/server.clj"
  "$runtime/writer_authority.clj" "$runtime/rotations.clj"
  "$runtime/out/store/rpc.clj" "$runtime/out/store/rt.clj"
  "$runtime/out/store/types.clj" "$runtime/tests/store_mcp.clj"
  "$runtime/server.classpath"
)
for path in "${required[@]}"; do
  [[ -e "$path" ]] || { echo "store package smoke: missing runtime asset: $path" >&2; exit 1; }
done
if ! "$env_bin" -i "$package_root/bin/beagle-store-backup" --help \
    | "$grep_bin" -Fq 'beagle-store-backup create'; then
  echo "store package smoke: packaged backup operator did not start under an empty environment" >&2
  exit 1
fi

hidden_commands=(beagle-store-code-off beagle-store-code-on beagle-store-code-status
  beagle-store-defcheck beagle-store-defcheck-server.rkt beagle-store-ingest-code beagle-store-up)
for name in "${hidden_commands[@]}"; do
  [[ ! -e "$package_root/bin/$name" ]] || {
    echo "store package smoke: non-core helper exposed as public command: $name" >&2; exit 1; }
done
[[ ! -e "$runtime/.cpcache" ]] || {
  echo "store package smoke: tools.deps cache leaked into runtime" >&2; exit 1; }
if checkout_hits="$("$grep_bin" -R -a -n -m 5 -F "/home/" "$package_root" 2>/dev/null)"; then
  echo "store package smoke: checkout-local path leaked into runtime" >&2
  printf '%s\n' "$checkout_hits" >&2
  exit 1
fi

work="$(mktemp -d)"
home="$work/home"
mkdir -p "$home" "$work/cwd"
log="$work/history.storelog"
space="package-jvm-rpc"
server_output="$work/server.out"
pid=
cleanup() {
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -rf "${work:?}"
}
trap cleanup EXIT INT TERM

free_port() { "$bb" -e '(with-open [s (java.net.ServerSocket. 0)] (println (.getLocalPort s)))'; }
port="$(free_port)"

native_error="$work/native-error.out"
if "$env_bin" -i BEAGLE_STORE_SPACE_ID="$space" \
    BEAGLE_STORE_SERVER_RUNTIME=native \
    "$package_root/bin/beagle-store-server" serve "$port" "$log" \
    >"$native_error" 2>&1; then
  echo "store package smoke: experimental Native launch ran without an artifact" >&2
  exit 1
fi
"$grep_bin" -Fxq \
  "beagle-store-server: BEAGLE_STORE_NATIVE_ARTIFACT_DIR is required for experimental Native runtime" \
  "$native_error" || {
    echo "store package smoke: missing native artifact did not fail exactly" >&2
    sed -n '1,40p' "$native_error" >&2
    exit 1
  }

start_server() {
  (
    cd "$work/cwd"
    exec "$env_bin" -i HOME="$home" XDG_CACHE_HOME="$home/.cache" \
      BEAGLE_STORE_BIND=127.0.0.1 BEAGLE_STORE_SPACE_ID="$space" \
      "$package_root/bin/beagle-store-server" serve "$port" "$log"
  ) >"$server_output" 2>&1 &
  pid=$!
}

native_probe='
(require (quote [store.rpc :as wire])
         (quote [store.rt :as rt])
         (quote [store.types :as t]))
(let [port (parse-long (first *command-line-args*))
      space (second *command-line-args*)
      response (rt/native-request-to!
                "127.0.0.1" port
                (wire/rpc-request! space :rpc/version nil nil nil wire/rpc-unit))]
  (if (nil? (t/rpcresponse-error response))
    (println (t/rpcresponse-served-version response))
    (System/exit 1)))'

wait_ready() {
  local response=
  for _ in $(seq 1 180); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "store package smoke: server exited before readiness" >&2
      sed -n '1,160p' "$server_output" >&2
      return 1
    fi
    if response="$("$bb" -cp "$runtime/out" -e "$native_probe" "$port" "$space" 2>/dev/null)"; then
      printf '%s\n' "$response"
      return 0
    fi
    sleep 0.1
  done
  echo "store package smoke: no JVM version response" >&2
  sed -n '1,160p' "$server_output" >&2
  return 1
}

stop_server() {
  kill "$pid"
  for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  if kill -0 "$pid" 2>/dev/null; then
    echo "store package smoke: server ignored SIGTERM" >&2; exit 1
  fi
  wait "$pid" 2>/dev/null || true
  pid=
}

start_server
initial_version="$(wait_ready)"
[[ "$initial_version" == "0" ]] || {
  echo "store package smoke: fresh STORELOG did not start at version 0: $initial_version" >&2; exit 1; }

if [[ "$require_proc" == "1" ]]; then
  cmdline="$("$tr_bin" '\0' '\n' <"/proc/$pid/cmdline")"
  ! "$grep_bin" -Fq "/home/tom" <<<"$cmdline" || {
    echo "store package smoke: server escaped into checkout" >&2; exit 1; }
  "$grep_bin" -Fq "$package_root" <<<"$cmdline" || {
    echo "store package smoke: server cmdline lacks package root" >&2; exit 1; }
  [[ "$("$readlink_bin" "/proc/$pid/cwd")" == "$runtime" ]] || {
    echo "store package smoke: server cwd is not packaged runtime" >&2; exit 1; }
fi

cli_env=("$env_bin" -i BEAGLE_STORE_SERVER_PORT="$port" BEAGLE_STORE_SPACE_ID="$space")
run_private_cli() {
  "${cli_env[@]}" "$bb" -cp "$runtime/out" \
    "$runtime/bin/beagle-store-cli.clj" "$@"
}
tell_output="$(run_private_cli tell package title installed)"
"$grep_bin" -Fq "committed via server" <<<"$tell_output" || {
  echo "store package smoke: JVM CLI tell failed" >&2; printf '%s\n' "$tell_output" >&2; exit 1; }
show_output="$(run_private_cli show package)"
"$grep_bin" -Fq "title  installed" <<<"$show_output" || {
  echo "store package smoke: JVM CLI show failed" >&2; printf '%s\n' "$show_output" >&2; exit 1; }
validate_output="$(run_private_cli validate)"
"$grep_bin" -Fq "valid" <<<"$validate_output" || {
  echo "store package smoke: JVM CLI validate failed" >&2; exit 1; }

mcp_input='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"tell","arguments":{"subject":"package","predicate":"kind","object":"smoke"}}}'
mcp_output="$(printf '%s\n' "$mcp_input" | "$env_bin" -i BEAGLE_STORE_SERVER_PORT="$port" \
  BEAGLE_STORE_SPACE_ID="$space" BEAGLE_STORE_GRAPH_OPS_LOG=off "$package_root/bin/beagle-store-mcp" \
  2>"$work/mcp.err")"
if ! "$grep_bin" -Fq '"isError":false' <<<"$mcp_output"; then
  echo "store package smoke: MCP JVM tell failed" >&2
  sed -n '1,120p' "$work/mcp.err" >&2; printf '%s\n' "$mcp_output" >&2; exit 1
fi

lease_probe='
(require (quote [store.rpc :as wire])
         (quote [store.rt :as rt])
         (quote [store.types :as t]))
(let [port (parse-long (first *command-line-args*)) space (second *command-line-args*)
      call (fn [op payload]
             (rt/native-request-to! "127.0.0.1" port
               (wire/rpc-request! space op nil nil nil payload)))
      acquired (call :rpc/lease-acquire (wire/rpc-lease-acquire! :package "holder" 5000))
      [fence _] (wire/rpc-record-fields! (t/rpc-response-payload-value acquired) :lease/grant 2)
      renewed (call :rpc/lease-renew (wire/rpc-lease-renew! fence 10000))
      [next-fence _] (wire/rpc-record-fields! (t/rpc-response-payload-value renewed) :lease/grant 2)
      old-check (call :rpc/lease-check fence)
      [old-valid _] (wire/rpc-record-fields! (t/rpc-response-payload-value old-check) :lease/check 2)
      released (call :rpc/lease-release next-fence)
      [released?] (wire/rpc-record-fields! (t/rpc-response-payload-value released) :lease/released 1)]
  (if (and (nil? (t/rpcresponse-error acquired))
           (not= fence next-fence) (false? old-valid) released?)
    (println "lease-ok")
    (System/exit 1)))'
lease_receipt="$("$bb" -cp "$runtime/out" -e "$lease_probe" "$port" "$space")"
[[ "$lease_receipt" == "lease-ok" ]] || {
  echo "store package smoke: exact-epoch lease failed" >&2; exit 1; }

bytes_before="$(wc -c <"$log")"
wrong_space_probe='
(require (quote [store.rpc :as wire])
         (quote [store.rt :as rt])
         (quote [store.types :as t]))
(let [port (parse-long (first *command-line-args*))
      response (rt/native-request-to! "127.0.0.1" port
                 (wire/rpc-request! "wrong-space" :rpc/version nil nil nil wire/rpc-unit))]
  (if (= :rpc/space-mismatch (some-> response t/rpcresponse-error t/rpcerror-code))
    (println "space-rejected")
    (System/exit 1)))'
space_receipt="$("$bb" -cp "$runtime/out" -e "$wrong_space_probe" "$port")"
[[ "$space_receipt" == "space-rejected" && "$bytes_before" == "$(wc -c <"$log")" ]] || {
  echo "store package smoke: SpaceId mismatch did not fail without mutation" >&2; exit 1; }

version_before_restart="$(wait_ready)"
[[ "$version_before_restart" =~ ^[1-9][0-9]*$ ]] || {
  echo "store package smoke: writes did not advance logical version: $version_before_restart" >&2; exit 1; }
stop_server
start_server
restart_version="$(wait_ready)"
[[ "$restart_version" == "$version_before_restart" ]] || {
  echo "store package smoke: restart replay expected version $version_before_restart, got $restart_version" >&2; exit 1; }
restart_show="$(run_private_cli show package)"
"$grep_bin" -Fq "kind  smoke" <<<"$restart_show" || {
  echo "store package smoke: restart lost MCP write" >&2; exit 1; }
stop_server

# Packaged default state is writable history.storelog and still needs an explicit
# database identity.
state_dir="$work/state"
port="$(free_port)"
server_output="$work/state-server.out"
(
  cd "$work/cwd"
  exec "$env_bin" -i HOME="$home" BEAGLE_STORE_STATE_DIR="$state_dir" \
    BEAGLE_STORE_BIND=127.0.0.1 BEAGLE_STORE_SPACE_ID="$space" \
    "$package_root/bin/beagle-store-server" serve "$port"
) >"$server_output" 2>&1 &
pid=$!
wait_ready >/dev/null
[[ -f "$state_dir/history.storelog" ]] || {
  echo "store package smoke: default state did not create history.storelog" >&2; exit 1; }
stop_server

echo "store package smoke: JVM version $restart_version"
echo "store package smoke: exact-epoch $lease_receipt"
