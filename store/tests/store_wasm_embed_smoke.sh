#!/usr/bin/env bash
# The wasm host-import regime end to end: an external engine embedder supplies
# every store_host_v1 hook as a named import and must answer byte-for-byte like
# the native lp64 embed library on the same packets.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
builder="$repo/bin/beagle-store-native-build"
packets="$repo/tests/wasm_embed/packets"
space="store-wasm-embed"

skip() {
  echo "store wasm embed smoke: SKIP ($*)"
  exit 0
}

fail() {
  echo "store wasm embed smoke: FAIL: $*" >&2
  exit 1
}

wasi_cc="${BEAGLE_STORE_WASI_CC:-${WASI_CC:-}}"
[[ -n "$wasi_cc" && -x "$(command -v "$wasi_cc" 2>/dev/null || true)" ]] ||
  skip "set BEAGLE_STORE_WASI_CC to a wasi C17 compiler"
command -v wasm-tools >/dev/null 2>&1 || skip "wasm-tools is not on PATH"
python3 -c 'import wasmtime' >/dev/null 2>&1 ||
  skip "python3 cannot import wasmtime"

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch:?}"' EXIT INT TERM

mapfile -t sources < <(sed 's|^|'"$repo"'/|' "$repo/native/core_closure_sources.txt")

wasm_artifact="$(BEAGLE_STORE_WASI_CC="$wasi_cc" "$builder" --host wasm-embed \
  --abi wasm32 "${sources[@]}")" || fail "wasm-embed build failed"
wasm_again="$(BEAGLE_STORE_WASI_CC="$wasi_cc" "$builder" --host wasm-embed \
  --abi wasm32 "${sources[@]}")" || fail "wasm-embed rebuild failed"
[[ "$wasm_again" == "$wasm_artifact" ]] ||
  fail "wasm-embed build is not content-addressed: $wasm_artifact vs $wasm_again"
[[ -f "$wasm_artifact/lib/libstore.wasm" ]] ||
  fail "wasm-embed artifact omitted lib/libstore.wasm"

for receipt in \
  'native-host-abi PASS host=wasm-embed exports=9 version=1' \
  'native-wasm-seams PASS ledger=native/wasm-embed.seams' \
  'native-qbe-frontier REFUSED scope=store-native-server@wasm32 ledger=abi-profile/wasm32'; do
  grep -Fqx "$receipt" "$wasm_artifact/native-host.report.txt" ||
    fail "wasm-embed report omitted: $receipt"
done

grep -v '^[[:space:]]*#' "$repo/native/wasm-embed.seams" |
  grep -v '^[[:space:]]*$' >"$scratch/seams.expected"
cmp -s "$scratch/seams.expected" "$wasm_artifact/wasm-embed.seams" ||
  fail "linked seams differ from native/wasm-embed.seams"
awk '$1 == "import" && $2 == "wasi_snapshot_preview1" { print $3 }' \
  "$wasm_artifact/wasm-embed.seams" >"$scratch/wasi.observed"
printf '%s\n' clock_time_get environ_get environ_sizes_get fd_close fd_seek \
  fd_write proc_exit >"$scratch/wasi.expected"
cmp -s "$scratch/wasi.expected" "$scratch/wasi.observed" ||
  fail "wasi import set moved: $(tr '\n' ' ' <"$scratch/wasi.observed")"
awk '$1 == "export" { print $2 }' "$wasm_artifact/wasm-embed.seams" \
  >"$scratch/exports.observed"
printf '%s\n' _initialize store_abi_version store_buffer_release store_close \
  store_open store_query store_snapshot store_transact store_wasm_alloc \
  store_wasm_free memory | LC_ALL=C sort >"$scratch/exports.expected"
cmp -s "$scratch/exports.expected" "$scratch/exports.observed" ||
  fail "export set moved: $(tr '\n' ' ' <"$scratch/exports.observed")"

embed_artifact="$("$builder" --host embed "${sources[@]}")" ||
  fail "native embed oracle build failed"
"${CC:-cc}" -std=c17 -pedantic -Wall -Wextra -Werror -pthread \
  -I"$embed_artifact/include" "$repo/tests/wasm_embed/packets_driver.c" \
  "$embed_artifact/lib/libbeagle_store.a" -o "$scratch/packets_driver" ||
  fail "native oracle driver did not compile"
"$scratch/packets_driver" "$packets" "$packets/manifest.txt" \
  "$packets/manifest-reopen.txt" "$packets/manifest-image.txt" \
  "$scratch/native.storelog" "$space" \
  >"$scratch/native.transcript" ||
  fail "native oracle reported a failure: $(tail -3 "$scratch/native.transcript")"

python3 "$repo/tests/wasm_embed/embedder.py" \
  "$wasm_artifact/lib/libstore.wasm" "$packets" "$packets/manifest.txt" \
  "$packets/manifest-reopen.txt" "$packets/manifest-image.txt" \
  "$scratch/wasm.storelog" "$scratch/wasm.tally" \
  "$space" >"$scratch/wasm.transcript" ||
  fail "external wasm embedder reported a failure: $(tail -3 "$scratch/wasm.transcript")"

if ! cmp -s "$scratch/native.transcript" "$scratch/wasm.transcript"; then
  fail "$(printf 'wasm responses diverge from the native oracle:\n%s' \
    "$(diff "$scratch/native.transcript" "$scratch/wasm.transcript" |
       cut -c1-160 | head -6)")"
fi
cmp -s "$scratch/native.storelog" "$scratch/wasm.storelog" ||
  fail "the STORELOG written through the imports differs from the native one"
[[ -s "$scratch/wasm.storelog" ]] || fail "no STORELOG bytes were written"
# Every refused WASI import must packet zero calls; the embedder answers only
# the shim's clock and environment, which have no store_host_v1 field.
! grep -q '^wasi ' "$scratch/wasm.tally" ||
  fail "the host-import path called a refused WASI import: $(grep '^wasi ' "$scratch/wasm.tally" | tr '\n' ' ')"
if awk '$1 == "served" && $2 != "clock_time_get" && $2 != "environ_get" &&
        $2 != "environ_sizes_get"' "$scratch/wasm.tally" | grep -q .; then
  fail "an unexpected WASI import was served: $(awk '$1 == "served" { printf "%s ", $2 }' "$scratch/wasm.tally")"
fi
grep -q '^served clock_time_get ' "$scratch/wasm.tally" ||
  fail "the monotonic clock import was never called; the seam ledger claims it is live"
awk '$1 == "image" { print $2 }' "$scratch/wasm.transcript" |
  grep -qv '^0$' ||
  fail "the checkpoint wrote no bytes to the host image object"
grep -Fq 'image 0 ""' "$scratch/wasm.transcript" ||
  fail "the third pass did not open over the host-held image"
# The guest holds no stderr capability, so the image object -- not a printed
# line -- is how this regime shows which boot route ran.
grep -Fq 'storage_truncate' "$scratch/wasm.tally" ||
  fail "the image object was never rewritten through the imports"
for hook in allocate deallocate clock_milliseconds storage_append \
  storage_close storage_read storage_size storage_sync storage_truncate; do
  grep -q "^host $hook " "$scratch/wasm.tally" ||
    fail "the $hook import was never called"
done

# The unpaged codec bound has one store: 40 answers at 248 rows, 41 adds one
# row, 42 refuses the resulting 249-row unpaged response, and 43 pages it.
# Its reopen pass checkpoints, so the refusal must survive the image boot too.
"$scratch/packets_driver" "$packets" "$packets/manifest-depth.txt" \
  "$packets/manifest-depth-reopen.txt" "$packets/manifest-depth-image.txt" \
  "$scratch/native-depth.storelog" \
  "$space" >"$scratch/native-depth.transcript" ||
  fail "native oracle failed the depth matrix: $(tail -3 "$scratch/native-depth.transcript")"
python3 "$repo/tests/wasm_embed/embedder.py" \
  "$wasm_artifact/lib/libstore.wasm" "$packets" "$packets/manifest-depth.txt" \
  "$packets/manifest-depth-reopen.txt" "$packets/manifest-depth-image.txt" \
  "$scratch/wasm-depth.storelog" \
  "$scratch/wasm-depth.tally" "$space" >"$scratch/wasm-depth.transcript" ||
  fail "external wasm embedder failed the depth matrix: $(tail -3 "$scratch/wasm-depth.transcript")"
if ! cmp -s "$scratch/native-depth.transcript" "$scratch/wasm-depth.transcript"; then
  fail "$(printf 'wasm depth answers diverge from the native oracle:\n%s' \
    "$(diff "$scratch/native-depth.transcript" "$scratch/wasm-depth.transcript" |
       cut -c1-160 | head -6)")"
fi
cmp -s "$scratch/native-depth.storelog" "$scratch/wasm-depth.storelog" ||
  fail "the depth-matrix STORELOG written through the imports differs from the native one"
# The refusal travels as a typed payload inside an OK response, so look for its
# code in the response bytes rather than in the transport status.
depth_code_hex="$(printf 'term-depth-exceeded' | od -An -tx1 | tr -d ' \n')"
packet_response_hex() {
  awk -v name="$2" '$1 == "packet" && $2 == name { print $4; exit }' "$1"
}
packet_response_body_hex() {
  local response
  response="$(packet_response_hex "$1" "$2")"
  # The first 26 bytes are the packet header, including the differing request id.
  printf '%s\n' "${response:52}"
}
for transcript in "$scratch/native-depth.transcript" \
  "$scratch/wasm-depth.transcript"; do
  packet_response_hex "$transcript" 42-query-bulk-over-limit.bin |
    grep -q "$depth_code_hex" ||
    fail "one row over the unpaged bound was answered instead of refused: $transcript"
  for answered in 40-query-bulk-at-limit.bin 41-batch-bulk-over-limit.bin \
    43-query-bulk-paged.bin; do
    ! packet_response_hex "$transcript" "$answered" | grep -q "$depth_code_hex" ||
      fail "$answered was refused for depth; the unpaged bound is too tight: $transcript"
  done
done

long_packets="$scratch/long-space-packets"
mkdir -p "$long_packets"
(cd "$repo" &&
  bb -cp out tests/wasm_embed/gen_long_space_receipt_packets.clj \
    "$long_packets") >"$scratch/long-space-generate.log" ||
  fail "long-SpaceId fixture generation failed"
long_space="$(<"$long_packets/space.txt")"
[[ "${#long_space}" -eq 4096 ]] ||
  fail "long-SpaceId fixture did not contain 4096 ASCII bytes"

"$scratch/packets_driver" "$long_packets" "$long_packets/manifest.txt" \
  "$long_packets/manifest-empty.txt" "$long_packets/manifest-empty.txt" \
  "$scratch/native-long-space.storelog" \
  "$long_space" >"$scratch/native-long-space.transcript" ||
  fail "native oracle failed the long-SpaceId response-preflight matrix"
python3 "$repo/tests/wasm_embed/embedder.py" \
  "$wasm_artifact/lib/libstore.wasm" "$long_packets" \
  "$long_packets/manifest.txt" "$long_packets/manifest-empty.txt" \
  "$long_packets/manifest-empty.txt" "$scratch/wasm-long-space.storelog" \
  "$scratch/wasm-long-space.tally" \
  "$long_space" >"$scratch/wasm-long-space.transcript" ||
  fail "external wasm embedder failed the long-SpaceId response-preflight matrix"
if ! cmp -s "$scratch/native-long-space.transcript" \
  "$scratch/wasm-long-space.transcript"; then
  fail "$(printf 'wasm long-SpaceId answers diverge from the native oracle:\n%s' \
    "$(diff "$scratch/native-long-space.transcript" \
      "$scratch/wasm-long-space.transcript" | cut -c1-160 | head -6)")"
fi
cmp -s "$scratch/native-long-space.storelog" \
  "$scratch/wasm-long-space.storelog" ||
  fail "the long-SpaceId STORELOG differs between native and wasm32"

packet_too_large_hex="$(printf 'rpc-packet-too-large' | od -An -tx1 | tr -d ' \n')"
expected_long_space_hex="$(od -An -v -tx1 \
  "$long_packets/expected-03-batch-243-response.bin" | tr -d ' \n')"
for transcript in "$scratch/native-long-space.transcript" \
  "$scratch/wasm-long-space.transcript"; do
  [[ "$(packet_response_hex "$transcript" 03-batch-243.bin)" == \
     "$expected_long_space_hex" ]] ||
    fail "243-action long-SpaceId receipt did not return coordinates 0 through 242: $transcript"
  packet_response_hex "$transcript" 06-batch-244.bin |
    grep -q "$packet_too_large_hex" ||
    fail "244-action long-SpaceId receipt was not rejected before commit: $transcript"
  [[ "$(packet_response_body_hex "$transcript" 01-version-before.bin)" != \
     "$(packet_response_body_hex "$transcript" 04-version-after-success.bin)" ]] ||
    fail "243-action long-SpaceId receipt did not advance the version: $transcript"
  [[ "$(packet_response_body_hex "$transcript" 04-version-after-success.bin)" == \
     "$(packet_response_body_hex "$transcript" 07-version-after-rejection.bin)" ]] ||
    fail "244-action long-SpaceId rejection changed the version: $transcript"
  [[ "$(packet_response_body_hex "$transcript" 02-scan-before.bin)" != \
     "$(packet_response_body_hex "$transcript" 05-scan-after-success.bin)" ]] ||
    fail "243-action long-SpaceId receipt left no scan state: $transcript"
  [[ "$(packet_response_body_hex "$transcript" 05-scan-after-success.bin)" == \
     "$(packet_response_body_hex "$transcript" 08-scan-after-rejection.bin)" ]] ||
    fail "244-action long-SpaceId rejection changed scan state: $transcript"
done

receipt_packets="$scratch/mutation-receipt-bound-packets"
mkdir -p "$receipt_packets"
(cd "$repo" &&
  bb -cp out tests/wasm_embed/gen_mutation_receipt_bound_packets.clj \
    "$receipt_packets") >"$scratch/mutation-receipt-bound-generate.log" ||
  fail "mutation-receipt-bound fixture generation failed"
receipt_space="$(<"$receipt_packets/space.txt")"

"$scratch/packets_driver" "$receipt_packets" "$receipt_packets/manifest.txt" \
  "$receipt_packets/manifest-empty.txt" \
  "$receipt_packets/manifest-empty.txt" \
  "$scratch/native-mutation-receipt-bound.storelog" \
  "$receipt_space" >"$scratch/native-mutation-receipt-bound.transcript" ||
  fail "native oracle failed the mutation-receipt-bound matrix"
python3 "$repo/tests/wasm_embed/embedder.py" \
  "$wasm_artifact/lib/libstore.wasm" "$receipt_packets" \
  "$receipt_packets/manifest.txt" "$receipt_packets/manifest-empty.txt" \
  "$receipt_packets/manifest-empty.txt" \
  "$scratch/wasm-mutation-receipt-bound.storelog" \
  "$scratch/wasm-mutation-receipt-bound.tally" \
  "$receipt_space" >"$scratch/wasm-mutation-receipt-bound.transcript" ||
  fail "external wasm embedder failed the mutation-receipt-bound matrix"
if ! cmp -s "$scratch/native-mutation-receipt-bound.transcript" \
  "$scratch/wasm-mutation-receipt-bound.transcript"; then
  fail "$(printf 'wasm mutation-receipt answers diverge from the native oracle:\n%s' \
    "$(diff "$scratch/native-mutation-receipt-bound.transcript" \
      "$scratch/wasm-mutation-receipt-bound.transcript" |
      cut -c1-160 | head -6)")"
fi
cmp -s "$scratch/native-mutation-receipt-bound.storelog" \
  "$scratch/wasm-mutation-receipt-bound.storelog" ||
  fail "the mutation-receipt-bound STORELOG differs between native and wasm32"

expected_receipt_hex="$(od -An -v -tx1 \
  "$receipt_packets/expected-03-batch-247-response.bin" | tr -d ' \n')"
for transcript in "$scratch/native-mutation-receipt-bound.transcript" \
  "$scratch/wasm-mutation-receipt-bound.transcript"; do
  [[ "$(packet_response_hex "$transcript" 03-batch-247.bin)" == \
     "$expected_receipt_hex" ]] ||
    fail "247-action receipt did not return coordinates 0 through 246: $transcript"
  packet_response_hex "$transcript" 06-batch-248.bin |
    grep -q "$depth_code_hex" ||
    fail "248-action batch did not return typed term-depth-exceeded: $transcript"
  [[ "$(packet_response_body_hex "$transcript" 01-version-before.bin)" != \
     "$(packet_response_body_hex "$transcript" 04-version-after-success.bin)" ]] ||
    fail "247-action receipt-bound batch did not advance the version: $transcript"
  [[ "$(packet_response_body_hex "$transcript" 04-version-after-success.bin)" == \
     "$(packet_response_body_hex "$transcript" 07-version-after-rejection.bin)" ]] ||
    fail "248-action rejection changed the receipt-bound version: $transcript"
  [[ "$(packet_response_body_hex "$transcript" 02-scan-before.bin)" != \
     "$(packet_response_body_hex "$transcript" 05-scan-after-success.bin)" ]] ||
    fail "247-action receipt-bound batch left no scan state: $transcript"
  [[ "$(packet_response_body_hex "$transcript" 05-scan-after-success.bin)" == \
     "$(packet_response_body_hex "$transcript" 08-scan-after-rejection.bin)" ]] ||
    fail "248-action rejection changed receipt-bound scan state: $transcript"
done

lease_packets="$scratch/lease-preflight-packets"
mkdir -p "$lease_packets"
(cd "$repo" &&
  bb -cp out tests/wasm_embed/gen_lease_preflight_packets.clj \
    "$lease_packets") >"$scratch/lease-preflight-generate.log" ||
  fail "lease-preflight fixture generation failed"
lease_space="$(<"$lease_packets/space.txt")"

"$scratch/packets_driver" "$lease_packets" "$lease_packets/manifest.txt" \
  "$lease_packets/manifest-empty.txt" "$lease_packets/manifest-empty.txt" \
  "$scratch/native-lease-preflight.storelog" \
  "$lease_space" >"$scratch/native-lease-preflight.transcript" ||
  fail "native oracle failed the lease-response-preflight matrix"
python3 "$repo/tests/wasm_embed/embedder.py" \
  "$wasm_artifact/lib/libstore.wasm" "$lease_packets" \
  "$lease_packets/manifest.txt" "$lease_packets/manifest-empty.txt" \
  "$lease_packets/manifest-empty.txt" \
  "$scratch/wasm-lease-preflight.storelog" \
  "$scratch/wasm-lease-preflight.tally" \
  "$lease_space" >"$scratch/wasm-lease-preflight.transcript" ||
  fail "external wasm embedder failed the lease-response-preflight matrix"
if ! cmp -s "$scratch/native-lease-preflight.transcript" \
  "$scratch/wasm-lease-preflight.transcript"; then
  fail "$(printf 'wasm lease-preflight answers diverge from the native oracle:\n%s' \
    "$(diff "$scratch/native-lease-preflight.transcript" \
      "$scratch/wasm-lease-preflight.transcript" |
      cut -c1-160 | head -6)")"
fi
cmp -s "$scratch/native-lease-preflight.storelog" \
  "$scratch/wasm-lease-preflight.storelog" ||
  fail "the lease-preflight STORELOG differs between native and wasm32"

for transcript in "$scratch/native-lease-preflight.transcript" \
  "$scratch/wasm-lease-preflight.transcript"; do
  packet_response_hex "$transcript" 03-lease-acquire-deep.bin |
    grep -q "$depth_code_hex" ||
    fail "deep lease acquire did not return typed term-depth-exceeded: $transcript"
  [[ "$(packet_response_body_hex "$transcript" 01-version-before.bin)" == \
     "$(packet_response_body_hex "$transcript" 04-version-after.bin)" ]] ||
    fail "deep lease rejection changed the version: $transcript"
  [[ "$(packet_response_body_hex "$transcript" 02-scan-before.bin)" == \
     "$(packet_response_body_hex "$transcript" 05-scan-after.bin)" ]] ||
    fail "deep lease rejection changed lease state: $transcript"
done

printf 'store wasm embed smoke: PASS packets=%s depth-packets=%s long-space-packets=%s receipt-bound-packets=%s lease-preflight-packets=%s store-log=%s refused-wasi-calls=0 served-wasi=%s\n' \
  "$(grep -c '^packet ' "$scratch/wasm.transcript")" \
  "$(grep -c '^packet ' "$scratch/wasm-depth.transcript")" \
  "$(grep -c '^packet ' "$scratch/wasm-long-space.transcript")" \
  "$(grep -c '^packet ' "$scratch/wasm-mutation-receipt-bound.transcript")" \
  "$(grep -c '^packet ' "$scratch/wasm-lease-preflight.transcript")" \
  "$(sha256sum "$scratch/wasm.storelog" | sed 's/ .*//')" \
  "$(awk '$1 == "served" { printf "%s=%s ", $2, $3 }' "$scratch/wasm.tally")"
