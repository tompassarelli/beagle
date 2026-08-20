#!/usr/bin/env bash
# Pack the Worker-safe Durable Object adapter into one reproducible npm
# tarball and bind the exact bytes to the repository tag and commit.
set -euo pipefail
export LC_ALL=C
umask 022

die() {
  echo "package-cloudflare-do-release: $*" >&2
  exit 2
}

usage() {
  cat <<'USAGE'
Usage:
  package-cloudflare-do-release.sh --output DIR --version vMAJOR.MINOR.PATCH \
    [--source-root DIR]

The source root must be a clean Beagle checkout whose requested release tag
points at HEAD. The command uses Bun 1.3.13 to write the canonical adapter
tarball and a path-independent receipt, then prints their absolute paths on
separate lines. The package's 0.3.0 semver is independent from the repository
release tag.
USAGE
}

output=""
version=""
source_root=""
while [[ $# -gt 0 ]]; do
  case "$1" in
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

[[ -n "$output" && -n "$version" ]] || {
  usage >&2
  exit 2
}
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "--version must be vMAJOR.MINOR.PATCH: $version"

for command in awk bun cmp git grep install mktemp mv realpath sha256sum tar; do
  command -v "$command" >/dev/null 2>&1 ||
    die "required command is unavailable: $command"
done
[[ "$(bun --version)" == "1.3.13" ]] ||
  die "Bun 1.3.13 is required to produce canonical package bytes"

script_store_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_root="${source_root:-$(cd "$script_store_root/.." && pwd -P)}"
[[ ! -L "$source_root" ]] || die "source root must not be a symlink: $source_root"
source_root="$(realpath "$source_root")"
[[ -d "$source_root/.git" || -f "$source_root/.git" ]] ||
  die "source root is not a Git worktree: $source_root"
git_root="$(git -C "$source_root" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$git_root" && "$(realpath "$git_root")" == "$source_root" ]] ||
  die "source root must name the top of one Git worktree: $source_root"
[[ -z "$(git -C "$source_root" status --porcelain=v1 --untracked-files=all)" ]] ||
  die "source worktree is not clean: $source_root"
store_root="$source_root/store"
[[ -d "$store_root" && ! -L "$store_root" ]] ||
  die "Beagle Store root is unavailable or is a symlink: $store_root"

source_commit="$(git -C "$source_root" rev-parse 'HEAD^{commit}')"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] ||
  die "source HEAD is not a full commit identity"
tag_object="$(git -C "$source_root" rev-parse "refs/tags/$version" 2>/dev/null || true)"
[[ "$tag_object" =~ ^[0-9a-f]{40}$ ]] ||
  die "$version is not a local tag object"
[[ "$(git -C "$source_root" cat-file -t "$tag_object" 2>/dev/null || true)" == tag ]] ||
  die "$version must name an annotated tag object"
tag_commit="$(git -C "$source_root" rev-parse "refs/tags/$version^{commit}" 2>/dev/null || true)"
[[ "$tag_commit" == "$source_commit" ]] ||
  die "$version does not point at source commit $source_commit"
source_epoch="$(git -C "$source_root" show -s --format=%ct "$source_commit")"
[[ "$source_epoch" =~ ^[0-9]+$ ]] ||
  die "source commit has no integer timestamp: $source_commit"

package_root="$store_root/clients/cloudflare-do"
package_json="$package_root/package.json"
[[ -d "$package_root" && ! -L "$package_root" ]] ||
  die "Cloudflare package root is unavailable or is a symlink: $package_root"
[[ -f "$package_json" && ! -L "$package_json" ]] ||
  die "Cloudflare package manifest is unavailable or is a symlink: $package_json"
[[ "$(realpath "$package_json")" == "$package_json" ]] ||
  die "Cloudflare package manifest traverses a symlink: $package_json"
git -C "$source_root" ls-files --error-unmatch \
  store/clients/cloudflare-do/package.json >/dev/null 2>&1 ||
  die "Cloudflare package manifest is not tracked"

# The following single-quoted string is Bun source, not shell.
# shellcheck disable=SC2016
package_version="$(bun -e '
  const manifestPath = Bun.argv.at(-1);
  const manifest = await Bun.file(manifestPath).json();
  const expectedFiles = [
    "LICENSE",
    "LICENSE-MIT",
    "LICENSE-APACHE",
    "src/adapter.mjs",
    "src/adapter.d.ts",
    "src/seams.mjs",
    "src/seams.d.ts",
    "README.md",
  ];
  const expectedExports = {
    ".": { types: "./src/adapter.d.ts", import: "./src/adapter.mjs" },
    "./seams": { types: "./src/seams.d.ts", import: "./src/seams.mjs" },
  };
  const expectedRepository = {
    type: "git",
    url: "git+https://github.com/tompassarelli/beagle.git",
    directory: "store/clients/cloudflare-do",
  };
  const fail = message => {
    console.error(`package-cloudflare-do-release: ${message}`);
    process.exit(2);
  };
  if (manifest.name !== "@tompassarelli/store-cloudflare-do") {
    fail("unexpected package name");
  }
  if (manifest.version !== "0.3.0") fail("package version must be 0.3.0");
  if (manifest.type !== "module") fail("package type must be module");
  if (manifest.types !== "./src/adapter.d.ts") {
    fail("unexpected root declaration entry");
  }
  if (JSON.stringify(manifest.exports) !== JSON.stringify(expectedExports)) {
    fail("package exports must contain only root and ./seams entry points");
  }
  if (JSON.stringify(manifest.files) !== JSON.stringify(expectedFiles)) {
    fail("package files do not match the closed release set");
  }
  if (manifest.sideEffects !== false) fail("package must remain side-effect free");
  if (manifest.engines?.bun !== "1.3.13") fail("unexpected Bun engine pin");
  if (manifest.license !== "MIT OR Apache-2.0") fail("unexpected package license");
  if (JSON.stringify(manifest.repository) !== JSON.stringify(expectedRepository)) {
    fail("unexpected package repository metadata");
  }
  for (const key of [
    "dependencies",
    "optionalDependencies",
    "peerDependencies",
    "bundledDependencies",
    "bundleDependencies",
  ]) {
    if (Array.isArray(manifest[key]) ? manifest[key].length !== 0 :
        manifest[key] && Object.keys(manifest[key]).length !== 0) {
      fail(`runtime dependency surface is not closed: ${key}`);
    }
  }
  console.log(manifest.version);
' "$package_json")"
[[ "$package_version" == "0.3.0" ]] ||
  die "could not read the Cloudflare package version"

root_files=(LICENSE LICENSE-MIT LICENSE-APACHE)
package_files=(
  README.md
  src/adapter.mjs
  src/adapter.d.ts
  src/seams.mjs
  src/seams.d.ts
)
for root_file in "${root_files[@]}"; do
  source_file="$store_root/$root_file"
  [[ -f "$source_file" && ! -L "$source_file" ]] ||
    die "release file is unavailable or is a symlink: $root_file"
  [[ "$(realpath "$source_file")" == "$source_file" ]] ||
    die "release file traverses a symlink: $root_file"
  git -C "$source_root" ls-files --error-unmatch "store/$root_file" >/dev/null 2>&1 ||
    die "release file is not tracked: $root_file"
done
for package_file in "${package_files[@]}"; do
  source_file="$package_root/$package_file"
  [[ -f "$source_file" && ! -L "$source_file" ]] ||
    die "package file is unavailable or is a symlink: store/clients/cloudflare-do/$package_file"
  [[ "$(realpath "$source_file")" == "$source_file" ]] ||
    die "package file traverses a symlink: store/clients/cloudflare-do/$package_file"
  git -C "$source_root" ls-files --error-unmatch \
    "store/clients/cloudflare-do/$package_file" >/dev/null 2>&1 ||
    die "package file is not tracked: store/clients/cloudflare-do/$package_file"
done

if [[ -e "$output" ]]; then
  [[ -d "$output" && ! -L "$output" ]] ||
    die "output must be a directory and not a symlink: $output"
else
  mkdir -p "$output"
fi
output="$(cd "$output" && pwd -P)"
release_name="tompassarelli-store-cloudflare-do-${package_version}"
archive="$output/$release_name.tgz"
receipt="$output/$release_name.receipt.txt"
scratch="$(mktemp -d "$output/.${release_name}.XXXXXX")"
temporary_archive="$scratch/$release_name.tgz"
temporary_receipt="$scratch/$release_name.receipt.txt"
cleanup() {
  [[ ! -d "$scratch" ]] || rm -rf "${scratch:?}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

staging="$scratch/staging"
mkdir -p "$staging/src"
install -m 0644 "$package_json" "$staging/package.json"
for root_file in "${root_files[@]}"; do
  install -m 0644 "$store_root/$root_file" "$staging/$root_file"
done
for package_file in "${package_files[@]}"; do
  install -m 0644 "$package_root/$package_file" "$staging/$package_file"
done

(
  cd "$staging"
  bun pm pack --filename "$temporary_archive" --ignore-scripts --quiet \
    >/dev/null
)
[[ -f "$temporary_archive" && ! -L "$temporary_archive" ]] ||
  die "Bun did not produce the package archive"

expected_entries=$'package/package.json\npackage/LICENSE\npackage/LICENSE-APACHE\npackage/LICENSE-MIT\npackage/README.md\npackage/src/adapter.d.ts\npackage/src/adapter.mjs\npackage/src/seams.d.ts\npackage/src/seams.mjs'
archive_entries="$(tar -tzf "$temporary_archive")"
[[ "$archive_entries" == "$expected_entries" ]] ||
  die "package archive member set or order is not canonical"
if tar --numeric-owner -tvzf "$temporary_archive" |
    awk '$1 != "-rw-r--r--" { exit 1 }'; then
  :
else
  die "package archive contains a non-regular or non-canonical member"
fi

verify_root="$scratch/verify"
mkdir -p "$verify_root"
tar -xzf "$temporary_archive" -C "$verify_root"
shipped_root="$verify_root/package"
cmp -s "$package_json" "$shipped_root/package.json" ||
  die "package archive changed package.json"
for root_file in "${root_files[@]}"; do
  cmp -s "$store_root/$root_file" "$shipped_root/$root_file" ||
    die "package archive changed or omitted $root_file"
done
for package_file in "${package_files[@]}"; do
  cmp -s "$package_root/$package_file" "$shipped_root/$package_file" ||
    die "package archive changed or omitted $package_file"
done

package_json_sha256="$(sha256sum "$shipped_root/package.json" | awk '{print $1}')"
archive_sha256="$(sha256sum "$temporary_archive" | awk '{print $1}')"
cat >"$temporary_receipt" <<RECEIPT
store-cloudflare-do-release-receipt/v1
source-commit $source_commit
source-date-epoch $source_epoch
release-tag $version
release-tag-object $tag_object
package-name @tompassarelli/store-cloudflare-do
package-version $package_version
package-json-sha256 $package_json_sha256
archive-name $release_name.tgz
archive-sha256 $archive_sha256
RECEIPT

verify_destination() {
  local candidate="$1" destination="$2"
  [[ ! -L "$destination" ]] ||
    die "refusing release output symlink: $destination"
  if [[ -e "$destination" ]]; then
    cmp -s "$candidate" "$destination" ||
      die "refusing to replace different release output: $destination"
  fi
}
verify_destination "$temporary_archive" "$archive"
verify_destination "$temporary_receipt" "$receipt"
[[ -e "$archive" ]] || mv "$temporary_archive" "$archive"
[[ -e "$receipt" ]] || mv "$temporary_receipt" "$receipt"

printf '%s\n%s\n' "$archive" "$receipt"
