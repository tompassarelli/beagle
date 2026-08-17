#!/usr/bin/env bash
# Package one READY wasm-embed artifact as deterministic release bytes and bind
# those bytes to the exact tagged Fram source commit.
set -euo pipefail
export LC_ALL=C
umask 022

die() {
  echo "package-cloudflare-wasm-release: $*" >&2
  exit 2
}

usage() {
  cat <<'USAGE'
Usage:
  package-cloudflare-wasm-release.sh --artifact DIR --output DIR \
    --version vMAJOR.MINOR.PATCH [--source-root DIR]

DIR must be a READY fram-native-build wasm-embed artifact. The source root must
be a clean Git worktree whose requested tag points at HEAD. Bun 1.3.13 and GNU
tar produce one normalized archive and one path-independent receipt.
USAGE
}

artifact=""
output=""
version=""
source_root=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifact)
      [[ $# -ge 2 && -z "$artifact" ]] || die "--artifact needs one path"
      artifact="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 && -z "$output" ]] || die "--output needs one path"
      output="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 && -z "$version" ]] || die "--version needs one tag"
      version="$2"
      shift 2
      ;;
    --source-root)
      [[ $# -ge 2 && -z "$source_root" ]] || die "--source-root needs one path"
      source_root="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$artifact" && -n "$output" && -n "$version" ]] || {
  usage >&2
  exit 2
}
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "--version must be vMAJOR.MINOR.PATCH: $version"

for command in awk bun cmp git grep gzip install mktemp mv realpath sha256sum tar; do
  command -v "$command" >/dev/null 2>&1 ||
    die "required command is unavailable: $command"
done
[[ "$(bun --version)" == "1.3.13" ]] ||
  die "Bun 1.3.13 is required to produce canonical release bytes"
tar --version 2>/dev/null | grep -Fq 'GNU tar' ||
  die "GNU tar is required for normalized release archives"

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_root="${source_root:-$script_root}"
[[ ! -L "$source_root" ]] || die "source root must not be a symlink: $source_root"
source_root="$(realpath "$source_root")"
git_root="$(git -C "$source_root" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$git_root" && "$(realpath "$git_root")" == "$source_root" ]] ||
  die "source root must name the top of one Git worktree: $source_root"
[[ -z "$(git -C "$source_root" status --porcelain --untracked-files=normal)" ]] ||
  die "source worktree is not clean: $source_root"

source_commit="$(git -C "$source_root" rev-parse 'HEAD^{commit}')"
tag_object="$(git -C "$source_root" rev-parse "refs/tags/$version" 2>/dev/null || true)"
tag_commit="$(git -C "$source_root" rev-parse "refs/tags/$version^{commit}" 2>/dev/null || true)"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ && "$tag_object" =~ ^[0-9a-f]{40}$ ]] ||
  die "source commit or release tag is not a full object identity"
[[ "$(git -C "$source_root" cat-file -t "$tag_object")" == tag ]] ||
  die "$version must name an annotated tag object"
[[ "$tag_commit" == "$source_commit" ]] ||
  die "$version does not point at source commit $source_commit"
source_epoch="$(git -C "$source_root" show -s --format=%ct "$source_commit")"
[[ "$source_epoch" =~ ^[0-9]+$ ]] ||
  die "source commit has no integer timestamp: $source_commit"

source_files=(
  LICENSE
  LICENSE-MIT
  LICENSE-APACHE
  beagle-pin.txt
  bin/fram-native-build
  native/core_closure_sources.txt
  native/fram_embed.c
  native/fram.h
  native/server_host.h
  native/server_generated.c
  native/fram_wasm_host.c
  native/wasm-embed.seams
)
for source_file in "${source_files[@]}"; do
  path="$source_root/$source_file"
  [[ -f "$path" && ! -L "$path" ]] ||
    die "source file is unavailable or symlinked: $source_file"
  git -C "$source_root" ls-files --error-unmatch "$source_file" >/dev/null 2>&1 ||
    die "source file is not tracked: $source_file"
done
mapfile -t beagle_pin_lines <"$source_root/beagle-pin.txt"
[[ "${#beagle_pin_lines[@]}" == 1 &&
  "${beagle_pin_lines[0]}" =~ ^[0-9a-f]{40}$ ]] ||
  die "beagle-pin.txt must contain exactly one lowercase 40-hex revision"
beagle_pin="${beagle_pin_lines[0]}"

[[ ! -L "$artifact" ]] || die "artifact path must not be a symlink: $artifact"
artifact="$(realpath "$artifact")"
[[ -d "$artifact" ]] || die "artifact directory is unavailable: $artifact"
artifact_identity="${artifact##*/}"
[[ "$artifact_identity" =~ ^[0-9a-f]{64}$ ]] ||
  die "artifact directory name is not an input-manifest hash: $artifact"

artifact_files=(
  READY
  beagle-revision.txt
  input.manifest
  provenance.manifest
  module.native-program
  lib/libfram.wasm
  wasm-embed.seams
  UNICODE-LICENSE.txt
  THIRD-PARTY/WASI-TOOLCHAIN-LICENSES.txt
  THIRD-PARTY/ffc/LICENSE-MIT
  THIRD-PARTY/ffc/PROVENANCE
)
for artifact_file in "${artifact_files[@]}"; do
  path="$artifact/$artifact_file"
  [[ -f "$path" && ! -L "$path" ]] ||
    die "artifact file is unavailable or symlinked: $artifact_file"
done
[[ "$(<"$artifact/READY")" == "fram-native-build/v1 $artifact_identity" ]] ||
  die "artifact READY receipt does not match its input hash"
[[ "$(<"$artifact/beagle-revision.txt")" == "$beagle_pin" ]] ||
  die "artifact Beagle revision differs from beagle-pin.txt"
input_sha256="$(sha256sum "$artifact/input.manifest" | awk '{print $1}')"
[[ "$input_sha256" == "$artifact_identity" ]] ||
  die "artifact directory does not equal sha256(input.manifest)"
[[ "$(sed -n '1p' "$artifact/input.manifest")" == "fram-native-build-input/v3" ]] ||
  die "artifact input manifest is not fram-native-build-input/v3"
[[ "$(grep -Fxc 'host=wasm-embed' "$artifact/input.manifest" || true)" == 1 ]] ||
  die "artifact input manifest is not uniquely bound to host=wasm-embed"

provenance="$artifact/provenance.manifest"
[[ "$(sed -n '1p' "$provenance")" == "fram-native-build-provenance/v2" ]] ||
  die "artifact provenance manifest has an unsupported format"
provenance_keys="$(awk 'NR > 1 { print $1 }' "$provenance")"
expected_fixed_keys=$'builder-sha256\nbeagle-compiler-inputs-sha256\nbeagle-revision\nabi\nhost\nnative-program-sha256'
[[ "$(printf '%s\n' "$provenance_keys" | sed -n '1,6p')" == "$expected_fixed_keys" ]] ||
  die "artifact provenance manifest has a non-canonical prefix"
beagle_revision="$(awk '$1 == "beagle-revision" { print $2 }' "$provenance")"
[[ "$(grep -c '^beagle-revision ' "$provenance" || true)" == 1 &&
  "$beagle_revision" =~ ^[0-9a-f]{40}$ ]] ||
  die "artifact provenance manifest has an invalid beagle-revision"
[[ "$beagle_revision" == "$beagle_pin" ]] ||
  die "artifact Beagle revision differs from beagle-pin.txt"
[[ "$beagle_revision" == "$(<"$artifact/beagle-revision.txt")" ]] ||
  die "artifact provenance disagrees with its Beagle revision marker"
[[ "$(awk '$1 == "abi" { print $2 }' "$provenance")" == "wasm32" &&
  "$(awk '$1 == "host" { print $2 }' "$provenance")" == "wasm-embed" ]] ||
  die "artifact provenance manifest is not bound to wasm32-wasm-embed"
hash_keys=(
  builder-sha256
  beagle-compiler-inputs-sha256
  native-program-sha256
  host-source-sha256
  host-header-sha256
  adapter-header-sha256
  adapter-sha256
  wasm-host-source-sha256
  wasm-seams-sha256
  wasi-cc-sha256
  wasi-cc-version-sha256
  wasm-tools-sha256
  wasm-tools-version-sha256
  wasi-toolchain-licenses-sha256
  ffc-license-sha256
  ffc-provenance-sha256
)
for key in "${hash_keys[@]}"; do
  value="$(awk -v key="$key" '$1 == key { print $2 }' "$provenance")"
  [[ "$(grep -c "^$key " "$provenance" || true)" == 1 &&
    "$value" =~ ^[0-9a-f]{64}$ ]] ||
    die "artifact provenance manifest has an invalid $key"
done
expected_suffix_keys=$'host-source-sha256\nhost-header-sha256\nadapter-header-sha256\nadapter-sha256\nwasm-host-source-sha256\nwasm-seams-sha256\nwasi-cc-sha256\nwasi-cc-version-sha256\nwasm-tools-sha256\nwasm-tools-version-sha256\nwasi-toolchain-licenses-sha256\nffc-license-sha256\nffc-provenance-sha256'
[[ "$(printf '%s\n' "$provenance_keys" | sed -n '/^host-source-sha256$/,$p')" == "$expected_suffix_keys" ]] ||
  die "artifact provenance manifest has a non-canonical suffix"
mapfile -t provenance_sources < <(
  awk '$1 == "source-sha256" { print $2 " " $3 }' "$provenance"
)
mapfile -t closure_sources <"$source_root/native/core_closure_sources.txt"
[[ "${#provenance_sources[@]}" == "${#closure_sources[@]}" ]] ||
  die "artifact provenance source closure has the wrong size"
expected_provenance_keys="$expected_fixed_keys"
for _ in "${closure_sources[@]}"; do
  expected_provenance_keys+=$'\nsource-sha256'
done
expected_provenance_keys+=$'\n'"$expected_suffix_keys"
[[ "$provenance_keys" == "$expected_provenance_keys" ]] ||
  die "artifact provenance manifest schema is not closed and ordered"
for index in "${!closure_sources[@]}"; do
  printf -v ordinal '%06d' "$index"
  source_member="${closure_sources[$index]}"
  source_path="$source_root/$source_member"
  [[ -f "$source_path" && ! -L "$source_path" ]] ||
    die "release source closure member is unavailable or symlinked: $source_member"
  git -C "$source_root" ls-files --error-unmatch "$source_member" >/dev/null 2>&1 ||
    die "release source closure member is not tracked: $source_member"
  [[ "${provenance_sources[$index]}" == \
    "$ordinal $(sha256sum "$source_path" | awk '{print $1}')" ]] ||
    die "artifact provenance source closure differs at $ordinal"
done

check_provenance_hash() {
  local key="$1" path="$2" expected
  expected="$(awk -v key="$key" '$1 == key { print $2 }' "$provenance")"
  [[ "$expected" == "$(sha256sum "$path" | awk '{print $1}')" ]] ||
    die "artifact provenance $key differs from release bytes"
}
check_provenance_hash builder-sha256 "$source_root/bin/fram-native-build"
check_provenance_hash native-program-sha256 "$artifact/module.native-program"
check_provenance_hash host-source-sha256 "$source_root/native/fram_embed.c"
check_provenance_hash host-header-sha256 "$source_root/native/fram.h"
check_provenance_hash adapter-header-sha256 "$source_root/native/server_host.h"
check_provenance_hash adapter-sha256 "$source_root/native/server_generated.c"
check_provenance_hash wasm-host-source-sha256 "$source_root/native/fram_wasm_host.c"
check_provenance_hash wasm-seams-sha256 "$source_root/native/wasm-embed.seams"
check_provenance_hash wasi-toolchain-licenses-sha256 \
  "$artifact/THIRD-PARTY/WASI-TOOLCHAIN-LICENSES.txt"
check_provenance_hash ffc-license-sha256 "$artifact/THIRD-PARTY/ffc/LICENSE-MIT"
check_provenance_hash ffc-provenance-sha256 "$artifact/THIRD-PARTY/ffc/PROVENANCE"

expected_seams="$(mktemp)"
cleanup_expected() { rm -f "${expected_seams:?}"; }
trap cleanup_expected EXIT
grep -v '^[[:space:]]*#' "$source_root/native/wasm-embed.seams" |
  grep -v '^[[:space:]]*$' >"$expected_seams"
cmp -s "$expected_seams" "$artifact/wasm-embed.seams" ||
  die "artifact seams differ from native/wasm-embed.seams"

mkdir -p "$output"
[[ ! -L "$output" ]] || die "output directory must not be a symlink: $output"
output="$(cd "$output" && pwd -P)"
release_name="fram-${version}-wasm32-wasm-embed"
archive="$output/$release_name.tar.gz"
receipt="$output/$release_name.receipt.txt"
scratch="$(mktemp -d "$output/.${release_name}.XXXXXX")"
temporary_archive="$(mktemp "$output/.${release_name}.archive.XXXXXX")"
temporary_receipt="$(mktemp "$output/.${release_name}.receipt.XXXXXX")"
cleanup() {
  rm -f "${expected_seams:?}"
  [[ ! -d "$scratch" ]] || rm -rf "${scratch:?}"
  [[ ! -f "$temporary_archive" ]] || rm -f "${temporary_archive:?}"
  [[ ! -f "$temporary_receipt" ]] || rm -f "${temporary_receipt:?}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

release_root="$scratch/$release_name"
mkdir -p "$release_root/lib" "$release_root/THIRD-PARTY/ffc"
for license in LICENSE LICENSE-MIT LICENSE-APACHE; do
  install -m 0644 "$source_root/$license" "$release_root/$license"
done
install -m 0644 "$artifact/lib/libfram.wasm" "$release_root/lib/libfram.wasm"
install -m 0644 "$provenance" "$release_root/native-provenance.manifest"
install -m 0644 "$artifact/wasm-embed.seams" "$release_root/wasm-embed.seams"
install -m 0644 "$artifact/UNICODE-LICENSE.txt" \
  "$release_root/THIRD-PARTY/UNICODE-LICENSE.txt"
install -m 0644 "$artifact/THIRD-PARTY/WASI-TOOLCHAIN-LICENSES.txt" \
  "$release_root/THIRD-PARTY/WASI-TOOLCHAIN-LICENSES.txt"
install -m 0644 "$artifact/THIRD-PARTY/ffc/LICENSE-MIT" \
  "$release_root/THIRD-PARTY/ffc/LICENSE-MIT"
install -m 0644 "$artifact/THIRD-PARTY/ffc/PROVENANCE" \
  "$release_root/THIRD-PARTY/ffc/PROVENANCE"

tar --format=ustar --sort=name --mtime="@$source_epoch" \
  --owner=0 --group=0 --numeric-owner \
  -C "$scratch" -cf - "$release_name" | gzip -9n >"$temporary_archive"

expected_entries="$release_name/
$release_name/LICENSE
$release_name/LICENSE-APACHE
$release_name/LICENSE-MIT
$release_name/THIRD-PARTY/
$release_name/THIRD-PARTY/UNICODE-LICENSE.txt
$release_name/THIRD-PARTY/WASI-TOOLCHAIN-LICENSES.txt
$release_name/THIRD-PARTY/ffc/
$release_name/THIRD-PARTY/ffc/LICENSE-MIT
$release_name/THIRD-PARTY/ffc/PROVENANCE
$release_name/lib/
$release_name/lib/libfram.wasm
$release_name/native-provenance.manifest
$release_name/wasm-embed.seams"
[[ "$(tar -tzf "$temporary_archive")" == "$expected_entries" ]] ||
  die "release archive member set or order is not canonical"
if ! tar -tvzf "$temporary_archive" |
  awk 'substr($0, 1, 1) != "-" && substr($0, 1, 1) != "d" { exit 1 }'; then
  die "release archive contains a non-regular, non-directory member"
fi

verify_root="$scratch/verify/$release_name"
mkdir -p "$scratch/verify"
tar -xzf "$temporary_archive" -C "$scratch/verify"
cmp -s "$artifact/lib/libfram.wasm" "$verify_root/lib/libfram.wasm" ||
  die "normalized archive changed the Wasm bytes"
cmp -s "$artifact/wasm-embed.seams" "$verify_root/wasm-embed.seams" ||
  die "normalized archive changed the seam ledger"

wasm_sha256="$(sha256sum "$verify_root/lib/libfram.wasm" | awk '{print $1}')"
wasm_bytes="$(wc -c <"$verify_root/lib/libfram.wasm" | tr -d '[:space:]')"
seams_sha256="$(sha256sum "$verify_root/wasm-embed.seams" | awk '{print $1}')"
unicode_sha256="$(sha256sum "$verify_root/THIRD-PARTY/UNICODE-LICENSE.txt" | awk '{print $1}')"
wasi_licenses_sha256="$(sha256sum "$verify_root/THIRD-PARTY/WASI-TOOLCHAIN-LICENSES.txt" | awk '{print $1}')"
ffc_license_sha256="$(sha256sum "$verify_root/THIRD-PARTY/ffc/LICENSE-MIT" | awk '{print $1}')"
ffc_provenance_sha256="$(sha256sum "$verify_root/THIRD-PARTY/ffc/PROVENANCE" | awk '{print $1}')"
native_provenance_sha256="$(sha256sum "$verify_root/native-provenance.manifest" | awk '{print $1}')"
archive_sha256="$(sha256sum "$temporary_archive" | awk '{print $1}')"
cat >"$temporary_receipt" <<RECEIPT
fram-cloudflare-wasm-release-receipt/v2
source-commit $source_commit
source-date-epoch $source_epoch
release-tag $version
release-tag-object $tag_object
target wasm32-wasm-embed
native-build-closure-sha256 $artifact_identity
beagle-revision $beagle_revision
native-provenance-sha256 $native_provenance_sha256
wasm-path $release_name/lib/libfram.wasm
wasm-bytes $wasm_bytes
wasm-sha256 $wasm_sha256
seams-path $release_name/wasm-embed.seams
seams-sha256 $seams_sha256
unicode-license-sha256 $unicode_sha256
wasi-toolchain-licenses-sha256 $wasi_licenses_sha256
ffc-license-sha256 $ffc_license_sha256
ffc-provenance-sha256 $ffc_provenance_sha256
archive-name $release_name.tar.gz
archive-sha256 $archive_sha256
RECEIPT

# Recheck the named object immediately before publishing the bytes.
[[ "$(git -C "$source_root" rev-parse 'HEAD^{commit}')" == "$source_commit" &&
  "$(git -C "$source_root" rev-parse "refs/tags/$version")" == "$tag_object" &&
  "$(git -C "$source_root" rev-parse "refs/tags/$version^{commit}")" == "$source_commit" ]] ||
  die "source HEAD or release tag moved during packaging"

publish_file() {
  local candidate="$1" destination="$2"
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" ]] ||
      die "refusing non-regular release output: $destination"
    cmp -s "$candidate" "$destination" ||
      die "refusing to replace different release output: $destination"
    rm -f "${candidate:?}"
  else
    mv "$candidate" "$destination"
  fi
}
publish_file "$temporary_archive" "$archive"
publish_file "$temporary_receipt" "$receipt"

printf '%s\n%s\n' "$archive" "$receipt"
