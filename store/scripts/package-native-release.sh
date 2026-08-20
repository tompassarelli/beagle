#!/usr/bin/env bash
# Turn one READY static server artifact into a reproducible release archive and
# a path-independent receipt bound to the exact shipped bytes and source commit.
set -euo pipefail
export LC_ALL=C
umask 022

die() {
  echo "package-native-release: $*" >&2
  exit 2
}

usage() {
  cat <<'USAGE'
Usage:
  package-native-release.sh --artifact DIR --output DIR --version vMAJOR.MINOR.PATCH \
    [--target x86_64-linux-musl|aarch64-linux-musl] [--source-root DIR]

DIR must be the immutable READY directory emitted by beagle-store-native-build
for a static server host. The source root must be a clean Beagle checkout whose
requested version tag points at HEAD. The command writes a normalized .tar.gz
archive and its receipt, then prints their absolute paths on separate lines.
USAGE
}

artifact=""
output=""
version=""
target="x86_64-linux-musl"
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
    --target)
      [[ $# -ge 2 ]] || die "--target needs one target"
      target="$2"
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
case "$target" in
  x86_64-linux-musl|aarch64-linux-musl) ;;
  *) die "unsupported release target: $target" ;;
esac

for command in awk cmp git grep gzip install mktemp readelf realpath sha256sum tar; do
  command -v "$command" >/dev/null 2>&1 ||
    die "required command is unavailable: $command"
done
tar --version 2>/dev/null | grep -Fq 'GNU tar' ||
  die "GNU tar is required for normalized release archives"

script_store_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_root="${source_root:-$(cd "$script_store_root/.." && pwd -P)}"
source_root="$(realpath "$source_root")"
[[ -d "$source_root/.git" || -f "$source_root/.git" ]] ||
  die "source root is not a Git worktree: $source_root"
git_root="$(git -C "$source_root" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$git_root" && "$(realpath "$git_root")" == "$source_root" ]] ||
  die "source root must name the top of one Git worktree: $source_root"
git -C "$source_root" diff --quiet --ignore-submodules -- ||
  die "source worktree has tracked changes: $source_root"
git -C "$source_root" diff --cached --quiet --ignore-submodules -- ||
  die "source worktree has staged changes: $source_root"
store_root="$source_root/store"
[[ -d "$store_root" && ! -L "$store_root" ]] ||
  die "Beagle Store root is unavailable or is a symlink: $store_root"

source_commit="$(git -C "$source_root" rev-parse 'HEAD^{commit}')"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] ||
  die "source HEAD is not a full commit identity"
tag_object="$(git -C "$source_root" rev-parse "refs/tags/$version" 2>/dev/null || true)"
tag_commit="$(git -C "$source_root" rev-parse "refs/tags/$version^{commit}" 2>/dev/null || true)"
[[ "$tag_object" =~ ^[0-9a-f]{40}$ &&
  "$(git -C "$source_root" cat-file -t "$tag_object" 2>/dev/null || true)" == tag ]] ||
  die "$version must name an annotated tag object"
[[ "$tag_commit" == "$source_commit" ]] ||
  die "$version does not point at source commit $source_commit"
source_epoch="$(git -C "$source_root" show -s --format=%ct "$source_commit")"
[[ "$source_epoch" =~ ^[0-9]+$ ]] ||
  die "source commit has no integer timestamp: $source_commit"

source_files=(LICENSE LICENSE-MIT LICENSE-APACHE beagle-pin.txt bin/beagle-store-native-build)
for source_file in "${source_files[@]}"; do
  [[ -f "$store_root/$source_file" && ! -L "$store_root/$source_file" ]] ||
    die "source worktree omitted regular $source_file"
  git -C "$source_root" ls-files --error-unmatch "store/$source_file" >/dev/null 2>&1 ||
    die "source file is not tracked: $source_file"
done
mapfile -t beagle_pin_lines <"$store_root/beagle-pin.txt"
[[ "${#beagle_pin_lines[@]}" == 1 &&
  "${beagle_pin_lines[0]}" =~ ^[0-9a-f]{40}$ ]] ||
  die "beagle-pin.txt must contain exactly one lowercase 40-hex revision"
beagle_revision="${beagle_pin_lines[0]}"

[[ ! -L "$artifact" ]] || die "artifact path must not be a symlink: $artifact"
artifact="$(realpath "$artifact")"
[[ -d "$artifact" ]] || die "artifact directory is unavailable: $artifact"
artifact_identity="${artifact##*/}"
[[ "$artifact_identity" =~ ^[0-9a-f]{64}$ ]] ||
  die "artifact directory name is not a content hash: $artifact"
ready="$artifact/READY"
input_manifest="$artifact/input.manifest"
artifact_beagle_revision_file="$artifact/beagle-revision.txt"
server="$artifact/bin/beagle-store-server-native"
[[ ! -L "$ready" ]] || die "artifact READY receipt must not be a symlink: $ready"
[[ ! -L "$input_manifest" ]] ||
  die "artifact input manifest must not be a symlink: $input_manifest"
[[ ! -L "$artifact_beagle_revision_file" ]] ||
  die "artifact Beagle revision provenance must not be a symlink"
[[ ! -L "$server" ]] || die "artifact executable must not be a symlink: $server"
[[ -r "$ready" ]] || die "artifact READY receipt is unavailable: $ready"
[[ -f "$input_manifest" ]] ||
  die "artifact input manifest is unavailable: $input_manifest"
[[ -f "$artifact_beagle_revision_file" ]] ||
  die "artifact Beagle revision provenance is unavailable"
[[ "$(<"$ready")" == "beagle-store-native-build/v1 $artifact_identity" ]] ||
  die "artifact READY receipt does not match its content hash: $ready"
[[ "$(sha256sum "$input_manifest" | awk '{print $1}')" == "$artifact_identity" ]] ||
  die "artifact directory does not equal sha256(input.manifest)"
[[ "$(sed -n '1p' "$input_manifest")" == "beagle-store-native-build-input/v3" ]] ||
  die "artifact input manifest is not beagle-store-native-build-input/v3"
[[ "$(grep -Fxc 'host=server' "$input_manifest" || true)" == 1 ]] ||
  die "artifact input manifest is not uniquely bound to host=server"
builder_sha256="$(sha256sum "$store_root/bin/beagle-store-native-build" | awk '{print $1}')"
[[ "$(sed -n '2p' "$input_manifest")" == "$builder_sha256" ]] ||
  die "artifact input manifest is not bound to the release builder"
artifact_beagle_revision="$(<"$artifact_beagle_revision_file")"
[[ "$artifact_beagle_revision" =~ ^[0-9a-f]{40}$ ]] ||
  die "artifact Beagle revision provenance is invalid"
[[ "$artifact_beagle_revision" == "$beagle_revision" ]] ||
  die "artifact Beagle revision differs from beagle-pin.txt"
[[ -f "$server" && -x "$server" ]] ||
  die "artifact native server is unavailable: $server"
readelf -h "$server" >/dev/null 2>&1 ||
  die "artifact native server is not an ELF executable: $server"
if readelf -l "$server" | grep -Fq 'Requesting program interpreter'; then
  die "artifact native server is dynamically linked: $server"
fi
machine="$(readelf -h "$server" | awk -F: '$1 ~ /^[[:space:]]*Machine$/ { sub(/^[[:space:]]+/, "", $2); print $2 }')"
case "$target:$machine" in
  'x86_64-linux-musl:Advanced Micro Devices X86-64'|'aarch64-linux-musl:AArch64') ;;
  *) die "artifact machine '$machine' does not match target $target" ;;
esac

mkdir -p "$output"
output="$(cd "$output" && pwd -P)"
release_name="store-${version}-${target}"
archive="$output/$release_name.tar.gz"
receipt="$output/$release_name.receipt.txt"
scratch="$(mktemp -d "$output/.${release_name}.XXXXXX")"
temporary_archive="$(mktemp "$output/.${release_name}.archive.XXXXXX")"
temporary_receipt="$(mktemp "$output/.${release_name}.receipt.XXXXXX")"
cleanup() {
  [[ ! -d "$scratch" ]] || rm -rf "${scratch:?}"
  [[ ! -f "$temporary_archive" ]] || rm -f "${temporary_archive:?}"
  [[ ! -f "$temporary_receipt" ]] || rm -f "${temporary_receipt:?}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

release_root="$scratch/$release_name"
mkdir -p "$release_root/bin"
install -m 0755 "$server" "$release_root/bin/beagle-store-server-native"
for license in LICENSE LICENSE-MIT LICENSE-APACHE; do
  install -m 0644 "$store_root/$license" "$release_root/$license"
done

tar --format=ustar --sort=name --mtime="@$source_epoch" \
  --owner=0 --group=0 --numeric-owner \
  -C "$scratch" -cf - "$release_name" |
  gzip -9n >"$temporary_archive"

verify_root="$scratch/verify"
mkdir -p "$verify_root"
tar -xzf "$temporary_archive" -C "$verify_root"
shipped_server="$verify_root/$release_name/bin/beagle-store-server-native"
[[ -f "$shipped_server" && -x "$shipped_server" ]] ||
  die "normalized archive omitted its executable"
cmp -s "$server" "$shipped_server" ||
  die "normalized archive changed the executable bytes"

executable_sha256="$(sha256sum "$shipped_server" | awk '{print $1}')"
archive_sha256="$(sha256sum "$temporary_archive" | awk '{print $1}')"
cat >"$temporary_receipt" <<RECEIPT
store-native-release-receipt/v2
source-commit $source_commit
source-date-epoch $source_epoch
release-tag $version
release-tag-object $tag_object
target $target
native-build-closure-sha256 $artifact_identity
beagle-revision $beagle_revision
executable-path $release_name/bin/beagle-store-server-native
executable-sha256 $executable_sha256
archive-name $release_name.tar.gz
archive-sha256 $archive_sha256
RECEIPT

[[ "$(git -C "$source_root" rev-parse 'HEAD^{commit}')" == "$source_commit" &&
  "$(git -C "$source_root" rev-parse "refs/tags/$version")" == "$tag_object" &&
  "$(git -C "$source_root" rev-parse "refs/tags/$version^{commit}")" == "$source_commit" ]] ||
  die "source HEAD or release tag moved during packaging"

publish_file() {
  local candidate="$1" destination="$2"
  if [[ -e "$destination" ]]; then
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
