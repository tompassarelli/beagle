#!/usr/bin/env bash
# The Cloudflare Fram server image: this checkout's static native artifact
# packaged into a scratch runtime image. stdout is only the image tag:
#   export FRAM_SERVER_IMAGE="$(deploy/cloudflare/build-native-image.sh)"
set -euo pipefail

die() {
  echo "build-native-image: $*" >&2
  exit 2
}

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cc_link="${FRAM_NATIVE_CC_LINK:-${HOME:?}/.cache/fram/native-build/.musl-cc}"
image_name="${FRAM_SERVER_IMAGE_NAME:-fram-server-native}"

cc="${FRAM_NATIVE_CC:-}"
if [[ -z "$cc" ]]; then
  for command in jq nix; do
    command -v "$command" >/dev/null 2>&1 || die "required command is unavailable: $command"
  done
  # The toolchain comes from the nixpkgs revision flake.lock already pins, and
  # --out-link roots it so nix GC cannot orphan it between builds.
  rev="$(jq -r '.nodes.nixpkgs.locked.rev' "$repo/flake.lock")"
  [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || die "flake.lock has no pinned nixpkgs revision"
  toolchain="$(
    nix build --out-link "$cc_link" --print-out-paths \
      "github:NixOS/nixpkgs/$rev#pkgsStatic.stdenv.cc" | grep -v -- '-man$'
  )"
  [[ -d "$toolchain" ]] || die "static musl toolchain did not realize: $toolchain"
  cc="$(echo "$toolchain"/bin/*-linux-musl-cc)"
fi
[[ -x "$cc" ]] || die "static musl compiler is not executable: $cc"

mapfile -t sources < <(sed "s#^#$repo/#" "$repo/native/core_closure_sources.txt")
[[ "${#sources[@]}" -gt 0 ]] || die "native/core_closure_sources.txt is empty"

artifact="$(
  FRAM_NATIVE_CC="$cc" FRAM_NATIVE_STATIC=1 \
    "$repo/bin/fram-native-build" --host server "${sources[@]}"
)"
tag="$image_name:${artifact##*/}"
"$repo/bin/fram-cloudflare-native-image" --artifact "$artifact" --tag "$tag" >&2

echo "$tag"
