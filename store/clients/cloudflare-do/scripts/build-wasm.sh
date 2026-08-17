#!/usr/bin/env bash
# Publish lib/libstore.wasm out of a content-addressed beagle-store-native-build
# artifact, beside the provenance file that pins which artifact it came from.
#
#   scripts/build-wasm.sh                 # build the artifact, then copy
#   BEAGLE_STORE_DO_WASM_ARTIFACT=DIR scripts/build-wasm.sh   # copy from an existing one
set -euo pipefail
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$here/../.." && pwd)"

die() {
  echo "build-wasm: $*" >&2
  exit 2
}

artifact="${BEAGLE_STORE_DO_WASM_ARTIFACT:-}"
source_mode="supplied-artifact"
if [[ -z "$artifact" ]]; then
  [[ -n "${BEAGLE_STORE_WASI_CC:-${WASI_CC:-}}" ]] ||
    die "set BEAGLE_STORE_WASI_CC to a wasi C17 compiler, or BEAGLE_STORE_DO_WASM_ARTIFACT"
  mapfile -t sources < <(sed "s|^|$repo/|" "$repo/native/core_closure_sources.txt")
  artifact="$("$repo/bin/beagle-store-native-build" --host wasm-embed --abi wasm32 \
    "${sources[@]}")" || die "the wasm-embed build failed"
  source_mode="built-current-tree"
fi

[[ -f "$artifact/lib/libstore.wasm" ]] ||
  die "no lib/libstore.wasm in $artifact"
[[ -f "$artifact/wasm-embed.seams" ]] ||
  die "no wasm-embed.seams in $artifact"
[[ -f "$artifact/input.manifest" ]] ||
  die "no input.manifest in $artifact"

# The artifact directory name IS its content address, so it is the whole pin.
address="$(basename "$artifact")"
artifact_input_sha="$(sha256sum "$artifact/input.manifest" | sed 's/ .*//')"
[[ "$address" == "$artifact_input_sha" ]] ||
  die "artifact address does not match input.manifest: $artifact"
mkdir -p "$here/lib"
cp "$artifact/lib/libstore.wasm" "$here/lib/libstore.wasm"
cp "$artifact/wasm-embed.seams" "$here/lib/wasm-embed.seams"
chmod 0644 "$here/lib/libstore.wasm" "$here/lib/wasm-embed.seams"

wasm_sha="$(sha256sum "$here/lib/libstore.wasm" | sed 's/ .*//')"
seams_sha="$(sha256sum "$here/lib/wasm-embed.seams" | sed 's/ .*//')"
wasm_bytes="$(wc -c <"$here/lib/libstore.wasm")"
store_commit="$(git -C "$repo" rev-parse 'HEAD^{commit}' 2>/dev/null || echo unknown)"
source_tree_clean=false
if [[ -z "$(git -C "$repo" status --porcelain --untracked-files=all)" ]]; then
  source_tree_clean=true
fi

cat >"$here/lib/provenance.json" <<PROVENANCE
{
  "artifactAddress": "$address",
  "artifactPath": "$artifact",
  "artifactInputManifestSha256": "$artifact_input_sha",
  "host": "wasm-embed",
  "abi": "wasm32",
  "wasmSha256": "$wasm_sha",
  "wasmBytes": $wasm_bytes,
  "seamsSha256": "$seams_sha",
  "sourceCommit": "$store_commit",
  "sourceMode": "$source_mode",
  "sourceTreeClean": $source_tree_clean
}
PROVENANCE

echo "build-wasm: lib/libstore.wasm <- $address ($wasm_bytes bytes, sha256 $wasm_sha)"
