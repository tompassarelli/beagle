#!/usr/bin/env bash
# Installed server-closure smoke: native fail-closed launch, explicit JVM oracle, CLI,
# MCP, leases, restart replay, and writable default state.
set -euo pipefail

package_root="${1:?usage: package_server_smoke.sh /nix/store/...-fram}"
bb="${FRAM_SMOKE_BB:?FRAM_SMOKE_BB is required}"
env_bin="${FRAM_SMOKE_ENV:?FRAM_SMOKE_ENV is required}"
grep_bin="${FRAM_SMOKE_GREP:?FRAM_SMOKE_GREP is required}"
readlink_bin="${FRAM_SMOKE_READLINK:?FRAM_SMOKE_READLINK is required}"
tr_bin="${FRAM_SMOKE_TR:?FRAM_SMOKE_TR is required}"
require_proc="${FRAM_SMOKE_REQUIRE_PROC:-0}"

case "$package_root" in /nix/store/*) ;; *)
  echo "fram package smoke: refusing non-store package root: $package_root" >&2
  exit 2;; esac

runtime="$package_root/libexec/fram"
required=(
  "$package_root/bin/fram" "$package_root/bin/fram-server"
  "$package_root/bin/fram-backup" "$package_root/bin/fram-mcp"
  "$runtime/clients/bun/backup.mjs" "$runtime/clients/bun/framrpc.mjs"
  "$runtime/bin/fram-fast.clj"
  "$runtime/database.clj" "$runtime/server.clj"
  "$runtime/writer_authority.clj" "$runtime/rotations.clj"
  "$runtime/out/framrpc.clj" "$runtime/out/fram/rt.clj"
  "$runtime/out/fram/types.clj" "$runtime/tests/fram_mcp.clj"
  "$runtime/server.classpath"
)
for path in "${required[@]}"; do
  [[ -e "$path" ]] || { echo "fram package smoke: missing runtime asset: $path" >&2; exit 1; }
done
if ! "$env_bin" -i "$package_root/bin/fram-backup" --help \
    | "$grep_bin" -Fq 'fram-backup create'; then
  echo "fram package smoke: packaged backup operator did not start under an empty environment" >&2
  exit 1
fi

hidden_commands=(fram-code-off fram-code-on fram-code-status
  fram-defcheck fram-defcheck-server.rkt fram-ingest-code fram-up)
for name in "${hidden_commands[@]}"; do
  [[ ! -e "$package_root/bin/$name" ]] || {
    echo "fram package smoke: non-core helper exposed as public command: $name" >&2; exit 1; }
done
[[ ! -e "$runtime/.cpcache" ]] || {
  echo "fram package smoke: tools.deps cache leaked into runtime" >&2; exit 1; }
if checkout_hits="$("$grep_bin" -R -a -n -m 5 -F "/home/" "$package_root" 2>/dev/null)"; then
  echo "fram package smoke: checkout-local path leaked into runtime" >&2
  printf '%s\n' "$checkout_hits" >&2
  exit 1
fi

work="$(mktemp -d)"
home="$work/home"
mkdir -p "$home" "$work/cwd"
log="$work/history.framlog"
space="package-native-rpc"
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
if "$env_bin" -i FRAM_SPACE_ID="$space" \
    "$package_root/bin/fram-server" serve "$port" "$log" \
    >"$native_error" 2>&1; then
  echo "fram package smoke: default launch silently fell back from native" >&2
  exit 1
fi
"$grep_bin" -Fxq \
  "fram-server: FRAM_NATIVE_ARTIFACT_DIR is required for FRAM_SERVER_RUNTIME=native" \
  "$native_error" || {
    echo "fram package smoke: missing native artifact did not fail exactly" >&2
    sed -n '1,40p' "$native_error" >&2
    exit 1
  }

graal_error="$work/graal-error.out"
if "$env_bin" -i FRAM_SPACE_ID="$space" FRAM_SERVER_RUNTIME=graal \
    "$package_root/bin/fram-server" serve "$port" "$log" \
    >"$graal_error" 2>&1; then
  echo "fram package smoke: Graal launch silently ran without an artifact" >&2
  exit 1
fi
"$grep_bin" -Fxq \
  "fram-server: FRAM_GRAAL_ARTIFACT is required for FRAM_SERVER_RUNTIME=graal" \
  "$graal_error" || {
    echo "fram package smoke: missing Graal artifact did not fail exactly" >&2
    sed -n '1,40p' "$graal_error" >&2
    exit 1
  }

start_server() {
  (
    cd "$work/cwd"
    exec "$env_bin" -i HOME="$home" XDG_CACHE_HOME="$home/.cache" \
      FRAM_BIND=127.0.0.1 FRAM_SPACE_ID="$space" \
      FRAM_SERVER_RUNTIME=jvm-oracle \
      "$package_root/bin/fram-server" serve "$port" "$log"
  ) >"$server_output" 2>&1 &
  pid=$!
}

native_probe='
(require (quote [framrpc :as wire])
         (quote [fram.rt :as rt])
         (quote [fram.types :as t]))
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
      echo "fram package smoke: server exited before readiness" >&2
      sed -n '1,160p' "$server_output" >&2
      return 1
    fi
    if response="$("$bb" -cp "$runtime/out" -e "$native_probe" "$port" "$space" 2>/dev/null)"; then
      printf '%s\n' "$response"
      return 0
    fi
    sleep 0.1
  done
  echo "fram package smoke: no native version response" >&2
  sed -n '1,160p' "$server_output" >&2
  return 1
}

stop_server() {
  kill "$pid"
  for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  if kill -0 "$pid" 2>/dev/null; then
    echo "fram package smoke: server ignored SIGTERM" >&2; exit 1
  fi
  wait "$pid" 2>/dev/null || true
  pid=
}

start_server
initial_version="$(wait_ready)"
[[ "$initial_version" == "0" ]] || {
  echo "fram package smoke: fresh FRAMLOG did not start at version 0: $initial_version" >&2; exit 1; }

if [[ "$require_proc" == "1" ]]; then
  cmdline="$("$tr_bin" '\0' '\n' <"/proc/$pid/cmdline")"
  ! "$grep_bin" -Fq "/home/tom" <<<"$cmdline" || {
    echo "fram package smoke: server escaped into checkout" >&2; exit 1; }
  "$grep_bin" -Fq "$package_root" <<<"$cmdline" || {
    echo "fram package smoke: server cmdline lacks package root" >&2; exit 1; }
  [[ "$("$readlink_bin" "/proc/$pid/cwd")" == "$runtime" ]] || {
    echo "fram package smoke: server cwd is not packaged runtime" >&2; exit 1; }
fi

cli_env=("$env_bin" -i FRAM_SERVER_PORT="$port" FRAM_SPACE_ID="$space")
tell_output="$("${cli_env[@]}" "$package_root/bin/fram" tell package title installed)"
"$grep_bin" -Fq "committed via server" <<<"$tell_output" || {
  echo "fram package smoke: native CLI tell failed" >&2; printf '%s\n' "$tell_output" >&2; exit 1; }
show_output="$("${cli_env[@]}" "$package_root/bin/fram" show package)"
"$grep_bin" -Fq "title  installed" <<<"$show_output" || {
  echo "fram package smoke: native CLI show failed" >&2; printf '%s\n' "$show_output" >&2; exit 1; }
validate_output="$("${cli_env[@]}" "$package_root/bin/fram" validate)"
"$grep_bin" -Fq "valid" <<<"$validate_output" || {
  echo "fram package smoke: native CLI validate failed" >&2; exit 1; }

mcp_input='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"tell","arguments":{"subject":"package","predicate":"kind","object":"smoke"}}}'
mcp_output="$(printf '%s\n' "$mcp_input" | "$env_bin" -i FRAM_SERVER_PORT="$port" \
  FRAM_SPACE_ID="$space" FRAM_GRAPH_OPS_LOG=off "$package_root/bin/fram-mcp" \
  2>"$work/mcp.err")"
if ! "$grep_bin" -Fq '"isError":false' <<<"$mcp_output"; then
  echo "fram package smoke: MCP native tell failed" >&2
  sed -n '1,120p' "$work/mcp.err" >&2; printf '%s\n' "$mcp_output" >&2; exit 1
fi

lease_probe='
(require (quote [framrpc :as wire])
         (quote [fram.rt :as rt])
         (quote [fram.types :as t]))
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
  echo "fram package smoke: exact-epoch lease failed" >&2; exit 1; }

bytes_before="$(wc -c <"$log")"
wrong_space_probe='
(require (quote [framrpc :as wire])
         (quote [fram.rt :as rt])
         (quote [fram.types :as t]))
(let [port (parse-long (first *command-line-args*))
      response (rt/native-request-to! "127.0.0.1" port
                 (wire/rpc-request! "wrong-space" :rpc/version nil nil nil wire/rpc-unit))]
  (if (= :rpc/space-mismatch (some-> response t/rpcresponse-error t/rpcerror-code))
    (println "space-rejected")
    (System/exit 1)))'
space_receipt="$("$bb" -cp "$runtime/out" -e "$wrong_space_probe" "$port")"
[[ "$space_receipt" == "space-rejected" && "$bytes_before" == "$(wc -c <"$log")" ]] || {
  echo "fram package smoke: SpaceId mismatch did not fail without mutation" >&2; exit 1; }

version_before_restart="$(wait_ready)"
[[ "$version_before_restart" =~ ^[1-9][0-9]*$ ]] || {
  echo "fram package smoke: writes did not advance logical version: $version_before_restart" >&2; exit 1; }
stop_server
start_server
restart_version="$(wait_ready)"
[[ "$restart_version" == "$version_before_restart" ]] || {
  echo "fram package smoke: restart replay expected version $version_before_restart, got $restart_version" >&2; exit 1; }
restart_show="$("${cli_env[@]}" "$package_root/bin/fram" show package)"
"$grep_bin" -Fq "kind  smoke" <<<"$restart_show" || {
  echo "fram package smoke: restart lost MCP write" >&2; exit 1; }
stop_server

# Packaged default state is writable history.framlog and still needs an explicit
# database identity.
state_dir="$work/state"
port="$(free_port)"
server_output="$work/state-server.out"
(
  cd "$work/cwd"
  exec "$env_bin" -i HOME="$home" FRAM_STATE_DIR="$state_dir" \
    FRAM_BIND=127.0.0.1 FRAM_SPACE_ID="$space" \
    FRAM_SERVER_RUNTIME=jvm-oracle \
    "$package_root/bin/fram-server" serve "$port"
) >"$server_output" 2>&1 &
pid=$!
wait_ready >/dev/null
[[ -f "$state_dir/history.framlog" ]] || {
  echo "fram package smoke: default state did not create history.framlog" >&2; exit 1; }
stop_server

echo "fram package smoke: native version $restart_version"
echo "fram package smoke: exact-epoch $lease_receipt"
