#!/usr/bin/env bash
# The checkpoint operation and the snapshot boot route end to end: an image is
# written beside the FRAMLOG, a restart installs it and replays only the tail,
# and a damaged image degrades to a full fold instead of failing the boot.
# Builds the whole native server, so the CI manifest dispositions it
# exclude-runner: it gates in the flake devShell, not on a hosted runner.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
builder="$repo/bin/beagle-store-native-build"
space="store-snapshot-boot"

skip() {
  echo "store snapshot boot: SKIP ($*)"
  exit 0
}

fail() {
  echo "store snapshot boot: FAIL: $*" >&2
  exit 1
}

beagle="${BEAGLE_STORE_BEAGLE:-${BEAGLE_HOME:+$BEAGLE_HOME/bin/beagle}}"
[[ -n "$beagle" && -x "$beagle" ]] || skip "set BEAGLE_STORE_BEAGLE to a beagle CLI"
for command in bb python3 cc; do
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
artifact="${BEAGLE_STORE_SNAPSHOT_ARTIFACT:-}"
if [[ -z "$artifact" ]]; then
  artifact="$(BEAGLE_STORE_BEAGLE="$beagle" "$builder" --host server "${sources[@]}")" ||
    fail "server build failed"
fi
server="$artifact/bin/beagle-store-server-native"
[[ -x "$server" ]] || fail "artifact has no beagle-store-server-native"

log="$scratch/framlog"
image="$log.snapshot"

port="$(python3 -c 'import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

start_server() { # log-suffix
  "$server" "$port" "$log" "$space" >"$scratch/$1.out" 2>"$scratch/$1.err" &
  server_pid=$!
  for _ in $(seq 1 200); do
    if python3 -c 'import socket,sys
s=socket.socket()
s.settimeout(0.2)
sys.exit(0 if s.connect_ex(("127.0.0.1",'"$port"'))==0 else 1)' 2>/dev/null; then
      return 0
    fi
    kill -0 "$server_pid" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

stop_server() {
  [[ -n "$server_pid" ]] || return 0
  kill -TERM "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null
  server_pid=""
}

cat >"$scratch/drive.clj" <<'DRIVE'
(require '[store.rt :as rt] '[store.rpc :as wire] '[store.types :as t])
(let [[port-text space mode out] *command-line-args*
      port (Integer/parseInt port-text)
      call (fn [op payload]
             (rt/native-request!
              port (wire/rpc-request! space op nil nil nil payload)))]
  (when (= mode "write")
    (doseq [batch (range 6)]
      (let [response
            (call :rpc/batch
                  (wire/rpc-batch!
                   (mapv (fn [n]
                           (wire/rpc-action!
                            :rpc/assert
                            (t/->Triple (str "entity-" batch "-" n) "ordinal" n)
                            wire/rpc-subject-any))
                         (range 10))
                   nil))]
        (when (rt/native-error response)
          (binding [*out* *err*]
            (println "write failed" (pr-str (rt/native-error response))))
          (System/exit 1)))))
  (when (= mode "checkpoint")
    (let [response (call :rpc/checkpoint :rpc/unit)]
      (spit out (pr-str (t/rpc-response-payload-value response)))))
  (when (= mode "probe")
    (spit out
          (pr-str
           (mapv (fn [op] [op (pr-str (rt/native-error (call op :rpc/unit)))
                           (pr-str (t/rpc-response-payload-value (call op :rpc/unit)))])
                 [:rpc/version :rpc/status]))))
  (System/exit 0))
DRIVE

drive() { # mode outfile
  (cd "$repo" && timeout 120 bb -cp out "$scratch/drive.clj" "$port" "$space" "$1" "$2")
}

start_server boot-1 || fail "server did not start"
drive write "" || fail "write phase failed"
drive probe "$scratch/probe-fold.edn" || fail "fold probe failed"
drive checkpoint "$scratch/receipt.edn" || fail "checkpoint failed"
stop_server

[[ -s "$image" ]] || fail "checkpoint wrote no snapshot image"
head -c 16 "$image" | grep -Fq 'store-snapshot/v1' ||
  fail "snapshot image does not carry the store-snapshot/v1 magic"
grep -Fq ':rpc/checkpoint' "$scratch/receipt.edn" ||
  fail "checkpoint receipt is not a checkpoint record"
cp "$image" "$scratch/image.good"

start_server boot-2 || fail "server did not restart on the image"
drive probe "$scratch/probe-image.edn" || fail "image probe failed"
stop_server
grep -Fq 'snapshot boot installed the image' "$scratch/boot-2.err" ||
  fail "restart did not install the image: $(cat "$scratch/boot-2.err")"
cmp -s "$scratch/probe-fold.edn" "$scratch/probe-image.edn" ||
  fail "snapshot boot answered differently from the fold boot"

python3 - "$image" <<'PY'
import sys
path = sys.argv[1]
data = bytearray(open(path, 'rb').read())
data[-6] ^= 0xff
open(path, 'wb').write(data)
PY
start_server boot-3 || fail "server did not restart on a damaged image"
drive probe "$scratch/probe-damaged.edn" || fail "damaged-image probe failed"
stop_server
grep -Fq 'degraded to full fold' "$scratch/boot-3.err" ||
  fail "damaged image did not report a degrade: $(cat "$scratch/boot-3.err")"
cmp -s "$scratch/probe-fold.edn" "$scratch/probe-damaged.edn" ||
  fail "degraded boot answered differently from the fold boot"

echo "store snapshot boot: PASS"
