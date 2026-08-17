#!/usr/bin/env bash
# Hermetic contract test for the sealed graph-edit runtime package.
set -euo pipefail

package_root="${1:?usage: package_graph_edit_runtime_smoke.sh /nix/store/...-beagle-store-graph-edit-runtime}"
bb="${BEAGLE_STORE_RUNTIME_TEST_BB:?BEAGLE_STORE_RUNTIME_TEST_BB is required}"
cmp_bin="${BEAGLE_STORE_RUNTIME_TEST_CMP:?BEAGLE_STORE_RUNTIME_TEST_CMP is required}"
env_bin="${BEAGLE_STORE_RUNTIME_TEST_ENV:?BEAGLE_STORE_RUNTIME_TEST_ENV is required}"
grep_bin="${BEAGLE_STORE_RUNTIME_TEST_GREP:?BEAGLE_STORE_RUNTIME_TEST_GREP is required}"
python="${BEAGLE_STORE_RUNTIME_TEST_PYTHON:?BEAGLE_STORE_RUNTIME_TEST_PYTHON is required}"
sleep_bin="${BEAGLE_STORE_RUNTIME_TEST_SLEEP:?BEAGLE_STORE_RUNTIME_TEST_SLEEP is required}"
expected_system="${BEAGLE_STORE_RUNTIME_TEST_SYSTEM:?BEAGLE_STORE_RUNTIME_TEST_SYSTEM is required}"

entrypoint="$package_root/bin/beagle-store-graph-edit-runtime"
manifest="$package_root/share/store/graph-edit-runtime-core-v1.json"
runtime_driver="$package_root/libexec/store/beagle-store-graph-edit-runtime"
case "$package_root" in
  /nix/store/*) ;;
  *) echo "graph-edit runtime smoke: non-store package root: $package_root" >&2; exit 2 ;;
esac
[[ -x "$entrypoint" ]] || { echo "graph-edit runtime smoke: missing entrypoint" >&2; exit 1; }
[[ -r "$manifest" ]] || { echo "graph-edit runtime smoke: missing core manifest" >&2; exit 1; }
[[ -r "$runtime_driver" ]] || { echo "graph-edit runtime smoke: missing runtime driver" >&2; exit 1; }

work="$(mktemp -d)"
cleanup() {
  rm -rf "${work:?}"
}
trap cleanup EXIT INT TERM

"$entrypoint" manifest >"$work/manifest-a.json"
"$entrypoint" manifest >"$work/manifest-b.json"
"$cmp_bin" -s "$manifest" "$work/manifest-a.json" || {
  echo "graph-edit runtime smoke: manifest command differs from packaged bytes" >&2
  exit 1
}
"$cmp_bin" -s "$work/manifest-a.json" "$work/manifest-b.json" || {
  echo "graph-edit runtime smoke: repeated manifest output is not byte-identical" >&2
  exit 1
}

"$bb" -e '
  (require (quote [cheshire.core :as json]))
  (let [[manifest expected-system] *command-line-args*
        m (json/parse-string (slurp manifest) true)
        roots (:storeRoots m)
        store? #(clojure.string/starts-with? (str (:path %)) "/nix/store/")]
    (when-not (and (= "store.graph-edit-runtime-core/v1" (:manifestVersion m))
                   (= "north" (:verificationOwner m))
                   (false? (:selfAttestation m))
                   (nil? (:closureDigest m))
                   (= "graph-edit-authority-v1" (:authorityProfile m))
                   ;; Exact evaluated Nix system, later bound to descriptor.runtime.system.
                   (= expected-system (:system m))
                   (= #{"babashka" "beagle" "store" "jdk" "racket"}
                      (set (map :role roots)))
                   (clojure.string/starts-with?
                    (str (get-in m [:executables :editVerifier]))
                    "/nix/store/")
                   (clojure.string/starts-with?
                    (str (get-in m [:helpers :factsCheckOverlay]))
                    "/nix/store/")
                   (every? store? roots))
      (binding [*out* *err*] (println (pr-str m)))
      (System/exit 1)))' "$manifest" "$expected_system"

# The final env -i is the graph-control authority boundary. It must bridge the
# already validated wrapper values under the exact sealed Beagle Store input names.
store_package="$("$python" -c '
import json, pathlib, sys
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
matches = [row["path"] for row in manifest["storeRoots"] if row["role"] == "store"]
if len(matches) != 1:
    raise SystemExit("graph-edit runtime smoke: manifest has no unique Beagle Store root")
print(matches[0])
' "$manifest")"
server_source="$store_package/libexec/store/server.clj"
[[ -r "$server_source" ]] || { echo "graph-edit runtime smoke: missing server source" >&2; exit 1; }
"$python" - "$runtime_driver" "$server_source" <<'PY'
import pathlib
import re
import sys

driver = pathlib.Path(sys.argv[1]).read_text()
server = pathlib.Path(sys.argv[2]).read_text()
marker = 'exec "$BEAGLE_STORE_GRAPH_EDIT_SEALED_ENV" -i \\\n'
try:
    final_boundary = driver.rsplit(marker, 1)[1]
except IndexError:
    raise SystemExit("graph-edit runtime smoke: final env-i boundary not found")

expected_assignments = {
    "BEAGLE_STORE_AUTHORITY_CORE_MANIFEST": '"$BEAGLE_STORE_GRAPH_EDIT_SEALED_MANIFEST"',
    "BEAGLE_STORE_CHECKOUT_ROOT": '"$checkout_root"',
    "BEAGLE_STORE_SOURCE_ROOT": '"$source_root"',
    "BEAGLE_STORE_CODE_LOG": '"$code_log"',
    "BEAGLE_STORE_AUTHORITY_EXPECTED_RUNTIME_CLOSURE_DIGEST": '"$runtime_digest"',
}
for name, rhs in expected_assignments.items():
    line = f"  {name}={rhs} \\"
    if line not in final_boundary:
        raise SystemExit(f"graph-edit runtime smoke: final env-i lost exact {name} bridge")
sealed_verifier_assignments = {
    "BEAGLE_STORE_EDIT_VERIFIER": '"$BEAGLE_STORE_GRAPH_EDIT_SEALED_EDIT_VERIFIER"',
    "BEAGLE_STORE_EDIT_VERIFIER_RACKET": '"$BEAGLE_STORE_GRAPH_EDIT_SEALED_RACKET"',
    "BEAGLE_STORE_EDIT_VERIFIER_OVERLAY_CHECK": '"$BEAGLE_STORE_GRAPH_EDIT_SEALED_OVERLAY_CHECK"',
}
for name, rhs in sealed_verifier_assignments.items():
    line = f"  {name}={rhs} \\"
    if line not in final_boundary:
        raise SystemExit(f"graph-edit runtime smoke: final env-i lost sealed {name}")
if "NORTH_STORE_" in final_boundary:
    raise SystemExit("graph-edit runtime smoke: NORTH_STORE_* crossed final env-i")

if "NORTH_STORE_" in server:
    raise SystemExit("graph-edit runtime smoke: server retains NORTH_STORE_* read/fallback")
PY

checkout="$work/checkout"
source_root="$checkout/src"
code_log="$checkout/.store/code.log"
evil="$work/evil"
marker="$work/hostile-executable-ran"
mkdir -p "$source_root" "$checkout/.store" "$evil/bin" "$evil/home/code/beagle"
printf '%s\n' '{:tx 1 :op "assert" :l "@empty#root" :p "file" :r "empty.bclj"}' >"$code_log"
printf '%s\n' '{"mcpServers":{"store":{"command":"/definitely/hostile"}}}' >"$checkout/.mcp.json"
for name in bb racket direnv beagle-build-all; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q >>%q\nexit 99\n' "$name" "$marker" >"$evil/bin/$name"
  chmod +x "$evil/bin/$name"
done
printf 'printf "BASH_ENV\\n" >>%q\n' "$marker" >"$evil/bash-env"
printf -v exported_printf \
  'BASH_FUNC_printf%%%%=() { echo BASH_FUNCTION >>%q; builtin printf "$@"; }' \
  "$marker"

instance_id="123e4567-e89b-42d3-a456-426614174000"
lease_id="123e4567-e89b-42d3-b456-426614174001"
lease_epoch=7
runtime_digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# A listener makes the no-side-effect claim observable: missing authority
# inputs must fail before any connection to the North-selected server.
port_file="$work/port"
accepted="$work/server-contacted"
"$python" -c '
import pathlib, socket, sys
port_file, accepted = map(pathlib.Path, sys.argv[1:])
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(2.0)
    port_file.write_text(str(listener.getsockname()[1]))
    try:
        connection, _ = listener.accept()
    except TimeoutError:
        pass
    else:
        accepted.write_text("contacted")
        connection.close()
' "$port_file" "$accepted" &
listener_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
  [[ -s "$port_file" ]] && break
  "$sleep_bin" 0.02
done
[[ -s "$port_file" ]] || { echo "graph-edit runtime smoke: listener did not start" >&2; exit 1; }
port="$(<"$port_file")"

common_hostile=(
  PATH="$evil/bin"
  HOME="$evil/home"
  BASH_ENV="$evil/bash-env"
  ENV="$evil/bash-env"
  "$exported_printf"
  BEAGLE_HOME="$evil/home/code/beagle"
  BEAGLE_STORE_BEAGLE="$evil/bin/beagle"
  BEAGLE_STORE="$evil/store"
  BEAGLE_STORE_AUTHORITY_CORE_MANIFEST="$evil/core.json"
  BEAGLE_STORE_AUTHORITY_EXPECTED_RUNTIME_CLOSURE_DIGEST="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  BEAGLE_STORE_BIN="$evil/bin"
  BEAGLE_STORE_BUILD_ALL="$evil/bin/beagle-build-all"
  BEAGLE_STORE_CHECK_EMIT="$evil/check-emit.rkt"
  BEAGLE_STORE_CHECKOUT_ROOT="$evil/checkout"
  BEAGLE_STORE_CODE_LOG="$evil/code.log"
  BEAGLE_STORE_CODE_PORT=1
  BEAGLE_STORE_EDIT_VERIFIER="$evil/bin/verifier"
  BEAGLE_STORE_EDIT_VERIFIER_ARGS='["hostile"]'
  BEAGLE_STORE_EDIT_VERIFIER_RACKET="$evil/bin/racket"
  BEAGLE_STORE_EDIT_VERIFIER_OVERLAY_CHECK="$evil/check-overlay.rkt"
  BEAGLE_STORE_HOME="$evil/store"
  BEAGLE_STORE_LOG="$evil/facts.log"
  BEAGLE_STORE_MCP_PROFILE=full
  BEAGLE_STORE_OUT="$evil/out"
  BEAGLE_STORE_RACKET="$evil/bin/racket"
  BEAGLE_STORE_RESOLVE="$evil/resolve.clj"
  BEAGLE_STORE_SOURCE_ROOT="$evil/source"
  BEAGLE_STORE_SRC="$evil/src"
  BEAGLE_STORE_THREADS="$evil/threads"
  BEAGLE_STORE_GRAPH_EDIT_SEALED_BB="$evil/bin/bb"
  BEAGLE_STORE_GRAPH_EDIT_SEALED_FRAM="$evil/store"
  NORTH_STORE_AUTHORITY_INSTANCE_ID="$instance_id"
  NORTH_STORE_AUTHORITY_LEASE_EPOCH="$lease_epoch"
  NORTH_STORE_CHECKOUT_ROOT="$checkout"
  NORTH_STORE_SOURCE_ROOT="$source_root"
  NORTH_STORE_CODE_LOG="$code_log"
  NORTH_STORE_CODE_PORT="$port"
)

if "$env_bin" -i "${common_hostile[@]}" \
     NORTH_STORE_RUNTIME_CLOSURE_DIGEST="$runtime_digest" \
     "$entrypoint" mcp >"$work/missing-lease.out" 2>"$work/missing-lease.err"; then
  echo "graph-edit runtime smoke: missing lease unexpectedly launched" >&2
  exit 1
fi
"$grep_bin" -Fq 'missing required North launch binding NORTH_STORE_AUTHORITY_LEASE_ID' \
  "$work/missing-lease.err" || {
  echo "graph-edit runtime smoke: missing lease diagnostic lost" >&2
  exit 1
}

if "$env_bin" -i "${common_hostile[@]}" \
     NORTH_STORE_AUTHORITY_LEASE_ID="$lease_id" \
     "$entrypoint" mcp >"$work/missing-runtime.out" 2>"$work/missing-runtime.err"; then
  echo "graph-edit runtime smoke: missing runtime digest unexpectedly launched" >&2
  exit 1
fi
"$grep_bin" -Fq 'missing required North launch binding NORTH_STORE_RUNTIME_CLOSURE_DIGEST' \
  "$work/missing-runtime.err" || {
  echo "graph-edit runtime smoke: missing runtime-seal diagnostic lost" >&2
  exit 1
}

wait "$listener_pid" || true
[[ ! -e "$accepted" ]] || {
  echo "graph-edit runtime smoke: missing-input path contacted the server" >&2
  exit 1
}
[[ ! -e "$marker" ]] || {
  echo "graph-edit runtime smoke: missing-input path ran a hostile executable" >&2
  exit 1
}

complete_hostile=(
  "${common_hostile[@]}"
  NORTH_STORE_AUTHORITY_LEASE_ID="$lease_id"
  NORTH_STORE_RUNTIME_CLOSURE_DIGEST="$runtime_digest"
)
# A fully shaped launch still fails when its selected server/log are not
# live native corpus inputs. This is the real preflight fence, not a manifest
# echo or an unsupported-profile placeholder.
if "$env_bin" -i "${complete_hostile[@]}" "$entrypoint" preflight \
     </dev/null >"$work/preflight.out" 2>"$work/preflight.err"; then
  echo "graph-edit runtime smoke: dead-corpus preflight unexpectedly passed" >&2
  exit 1
fi
[[ ! -s "$work/preflight.out" ]] || {
  echo "graph-edit runtime smoke: failed preflight emitted a success receipt" >&2
  exit 1
}
[[ ! -e "$marker" ]] || {
  echo "graph-edit runtime smoke: hostile PATH/HOME/Beagle Store/BEAGLE input redirected execution" >&2
  exit 1
}

printf '%s\n' 'graph-edit runtime smoke: PASS'
