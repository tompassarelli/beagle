#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-socket-capability.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

die() {
  echo "socket-capability: $*" >&2
  exit 1
}

for command in clojure cc rg; do
  command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done
mkdir -p "$scratch/out" "$scratch/generated" "$scratch/source-c17" \
  "$scratch/source-qbe"

"$repo/bin/beagle" check --agent "$here/socket_byte_sink.bgl"
"$repo/bin/beagle" build --materializer c17 \
  --out "$scratch/source-c17" \
  --entry native.socket-byte-sink/write-frame \
  "$here/socket_byte_sink.bgl" >"$scratch/source-c17.log"

source_report="$scratch/source-c17/report.txt"
rg -Fx 'stage typed-to-native COMPLETE' "$source_report" >/dev/null \
  || die "canonical byte sink did not lower"
[[ "$(rg -c '^obligation-projection PASS ' "$source_report")" == "7" ]] \
  || die "canonical byte sink failed native obligations"
rg -Fx 'materialize-c17 OK module_0.h module_0.c' "$source_report" >/dev/null \
  || die "canonical byte sink did not materialize as C17"
rg -F 'native_bytes_from_ints_bounded' \
  "$scratch/source-c17/module_0.c" >/dev/null \
  || die "C17 lost bounded NativeBytes construction"
rg -F 'native_host_socket_write_bounded_v0' \
  "$scratch/source-c17/module_0.c" >/dev/null \
  || die "C17 lost bounded socket write"

set +e
"$repo/bin/beagle" build --materializer qbe \
  --out "$scratch/source-qbe" \
  --entry native.socket-byte-sink/write-frame \
  "$here/socket_byte_sink.bgl" >"$scratch/source-qbe.log" 2>&1
qbe_status=$?
set -e
[[ $qbe_status -ne 0 ]] || die "QBE unexpectedly accepted the socket effect"
rg -Fx \
  'materialize-qbe REFUSED QBE socket extern ABI is unsupported: native_bytes and peer lifecycle have no QBE call representation' \
  "$scratch/source-qbe/report.txt" >/dev/null \
  || die "QBE socket refusal changed"

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
  "$repo/native-core/src/native/lower.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
  "$repo/native-core/src/native/fold_c17.bclj" \
  "$repo/native-core/src/native/body_c17.bclj" \
  "$repo/native-core/src/native/qbe.bclj" \
  "$here/socket_capability_fixture.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,240p' "$scratch/build.log" >&2
    exit 1
  }

records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
  "$scratch/out/native/core.clj" | tr '\n' ' ')"
for module in stages lower obligations fold_c17 body_c17 qbe socket_capability_fixture; do
  generated="$scratch/out/native/$module.clj"
  [[ -f "$generated" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$generated"
  awk -v imp="(import '[native.core $records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' \
    "$generated" >"$generated.tmp"
  mv "$generated.tmp" "$generated"
done

clojure -Sdeps "{:paths [\"$scratch/out\"]}" -M -e "
(require 'native.socket-capability-fixture)
(spit \"$scratch/generated/report.txt\"
  (native.socket-capability-fixture/emit-fixture!
    \"$scratch/generated\"))"

report="$scratch/generated/report.txt"
rg -Fx 'fixture PASS' "$report" >/dev/null || {
  cat "$report" >&2
  die "native program fixture failed"
}
rg -Fx 'abis 5' "$report" >/dev/null || die "socket imports were not closed"
rg -Fx \
  'qbe REFUSED QBE socket extern ABI is unsupported: native_bytes and peer lifecycle have no QBE call representation' \
  "$report" >/dev/null || die "QBE refusal changed"

generated_c="$scratch/generated/module_0.c"
for symbol in \
  native_host_socket_inherited_listener_v0 \
  native_host_socket_accept_v0 \
  native_host_socket_read_bounded_v0 \
  native_host_socket_write_bounded_v0 \
  native_host_socket_close_v0; do
  rg -F "$symbol" "$generated_c" >/dev/null || die "missing C17 import: $symbol"
done
rg -F 'NATIVE_HOST_SOCKET_PEER_CLOSED' "$generated_c" >/dev/null \
  || die "C17 emitter lost the peer-closed branch"

cc -std=c17 -Wall -Wextra -Werror -pedantic \
  -I"$repo/native-core/shim" -I"$scratch/generated" \
  -c "$generated_c" -o "$scratch/module_0.o"
cc -std=c17 -Wall -Wextra -Werror -pedantic \
  -I"$repo/native-core/shim" -I"$scratch/source-c17" \
  "$here/main.c" "$scratch/source-c17/module_0.c" \
  "$repo/native-core/shim/native_shim.c" \
  -o "$scratch/socket-capability"
"$scratch/socket-capability" >"$scratch/runtime.out"
rg -Fx 'socket capability fixture: ok' "$scratch/runtime.out" >/dev/null \
  || die "runtime lifecycle failed"

cat "$report"
cat "$source_report"
cat "$scratch/runtime.out"
