#!/usr/bin/env bash
# The Cloudflare Durable Object client end to end: the published adapter drives
# the same wasm-embed engine inside workerd that tests/store_wasm_embed_smoke.sh
# drives from python, over real DurableObjectStorage, and must answer the
# native lp64 oracle byte for byte on the same frames.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
client="$repo/clients/cloudflare-do"
frames="$repo/tests/wasm_embed/frames"
space="store-wasm-embed"

skip() {
  echo "store do client smoke: SKIP ($*)"
  exit 0
}

fail() {
  echo "store do client smoke: FAIL: $*" >&2
  exit 1
}

command -v bun >/dev/null 2>&1 || skip "Bun is not on PATH"
[[ -d "$client/node_modules/miniflare" ]] ||
  skip "Miniflare is not installed; run bun install in clients/cloudflare-do"

wasi_cc="${BEAGLE_STORE_WASI_CC:-${WASI_CC:-}}"
[[ -n "$wasi_cc" && -x "$(command -v "$wasi_cc" 2>/dev/null || true)" ]] ||
  skip "set BEAGLE_STORE_WASI_CC to a wasi C17 compiler"

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch:?}"' EXIT INT TERM

mapfile -t sources < <(sed 's|^|'"$repo"'/|' "$repo/native/core_closure_sources.txt")

wasm_artifact="$(BEAGLE_STORE_WASI_CC="$wasi_cc" "$repo/bin/beagle-store-native-build" \
  --host wasm-embed --abi wasm32 "${sources[@]}")" ||
  fail "wasm-embed build failed"
BEAGLE_STORE_DO_WASM_ARTIFACT="$wasm_artifact" bash "$client/scripts/build-wasm.sh" ||
  fail "publishing lib/libstore.wasm failed"
bun "$client/scripts/check-seams.mjs" ||
  fail "the adapter's seam list is not native/wasm-embed.seams"
bun "$client/test/pack-frames.mjs" "$frames" "$client/test/bundle" >/dev/null ||
  fail "packing the frame bundle failed"

# The oracle: the same frames through the native lp64 embed library.
embed_artifact="$("$repo/bin/beagle-store-native-build" --host embed "${sources[@]}")" ||
  fail "native embed oracle build failed"
"${CC:-cc}" -std=c17 -pedantic -Wall -Wextra -Werror -pthread \
  -I"$embed_artifact/include" "$repo/tests/wasm_embed/frames_driver.c" \
  "$embed_artifact/lib/libbeagle_store.a" -o "$scratch/frames_driver" ||
  fail "native oracle driver did not compile"
"$scratch/frames_driver" "$frames" "$frames/manifest.txt" \
  "$frames/manifest-reopen.txt" "$frames/manifest-image.txt" \
  "$scratch/native.framlog" "$space" >"$scratch/native.transcript" ||
  fail "native oracle reported a failure: $(tail -3 "$scratch/native.transcript")"
"$scratch/frames_driver" "$frames" "$frames/manifest-depth.txt" \
  "$frames/manifest-depth-reopen.txt" "$frames/manifest-depth-image.txt" \
  "$scratch/native-depth.framlog" "$space" \
  >"$scratch/native-depth.transcript" ||
  fail "native oracle failed the depth matrix: $(tail -3 "$scratch/native-depth.transcript")"

# 20 minutes is well past the observed runtime of either half; the bound exists
# so a wedged isolate fails the row instead of hanging the suite.
budget="${BEAGLE_STORE_DO_SMOKE_TIMEOUT:-1200}"

bun_status=0
timeout "$budget" bun "$client/test/run-node.mjs" \
  "$client/lib/libstore.wasm" "$frames" >"$scratch/bun.out" 2>&1 ||
  bun_status=$?
cat "$scratch/bun.out"
[[ $bun_status -eq 0 ]] ||
  fail "the durability harness failed (exit $bun_status)"

workerd_status=0
timeout "$budget" bun "$client/test/run-matrix.mjs" "$scratch" \
  "$scratch/native.transcript" "$scratch/native-depth.transcript" \
  >"$scratch/workerd.out" 2>&1 || workerd_status=$?
cat "$scratch/workerd.out"
[[ $workerd_status -eq 0 ]] ||
  fail "the workerd harness failed (exit $workerd_status)"

cmp -s "$scratch/native.framlog" "$scratch/workerd.framlog" ||
  fail "the FRAMLOG written through DurableObjectStorage differs from the native one"
cmp -s "$scratch/native-depth.framlog" "$scratch/workerd-depth.framlog" ||
  fail "the depth-matrix FRAMLOG differs from the native one"
[[ -s "$scratch/workerd.framimage" ]] ||
  fail "the checkpoint wrote no bytes to the durable image range"

printf 'store do client smoke: PASS frames=%s framlog=%s image=%s artifact=%s\n' \
  "$(grep -c '^frame ' "$scratch/workerd.transcript")" \
  "$(sha256sum "$scratch/workerd.framlog" | sed 's/ .*//')" \
  "$(wc -c <"$scratch/workerd.framimage")" \
  "$(basename "$wasm_artifact")"
