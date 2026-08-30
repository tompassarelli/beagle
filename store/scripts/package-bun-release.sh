#!/usr/bin/env bash
# Pack the official Bun client into one reproducible, offline-installable
# tarball and bind the exact bytes to the repository tag and commit.
set -euo pipefail
export LC_ALL=C
umask 022

die() {
  echo "package-bun-release: $*" >&2
  exit 2
}

usage() {
  cat <<'USAGE'
Usage:
  package-bun-release.sh --output DIR --version vMAJOR.MINOR.PATCH \
    [--source-root DIR]

The source root must be a clean Beagle checkout whose requested release tag
points at HEAD. The command uses Bun 1.3.13 to write the canonical package
tarball and a path-independent receipt, then prints their absolute paths on
separate lines. The package's own semver is recorded independently from the
repository tag.
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

for command in awk bun cmp git grep mktemp mv realpath sha256sum tar; do
  command -v "$command" >/dev/null 2>&1 ||
    die "required command is unavailable: $command"
done
[[ "$(bun --version)" == "1.3.13" ]] ||
  die "Bun 1.3.13 is required to produce canonical package bytes"

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

package_root="$store_root/clients/bun"
package_json="$package_root/package.json"
[[ -d "$package_root" && ! -L "$package_root" ]] ||
  die "Bun package root is unavailable or is a symlink: $package_root"
[[ -f "$package_json" && ! -L "$package_json" ]] ||
  die "Bun package manifest is unavailable or is a symlink: $package_json"
git -C "$source_root" ls-files --error-unmatch store/clients/bun/package.json \
  >/dev/null 2>&1 || die "Bun package manifest is not tracked"

# The following single-quoted string is Bun source, not shell.
# shellcheck disable=SC2016
package_version="$(bun -e '
  const manifestPath = Bun.argv.at(-1);
  const manifest = await Bun.file(manifestPath).json();
  const expectedFiles = [
    "LICENSE",
    "LICENSE-MIT",
    "LICENSE-APACHE",
    "store-rpc.mjs",
    "store-rpc-core.mjs",
    "transport-deadline.js",
    "store-rpc-core.d.ts",
    "store-rpc.d.ts",
    "backup.mjs",
    "schema.mjs",
    "schema.d.ts",
    "README.md",
  ];
  const expectedExports = {
    ".": { types: "./store-rpc.d.ts", import: "./store-rpc.mjs" },
    "./core": { types: "./store-rpc-core.d.ts", import: "./store-rpc-core.mjs" },
    "./schema": { types: "./schema.d.ts", import: "./schema.mjs" },
  };
  const expectedRepository = {
    type: "git",
    url: "git+https://github.com/tompassarelli/beagle.git",
    directory: "store/clients/bun",
  };
  const fail = message => {
    console.error(`package-bun-release: ${message}`);
    process.exit(2);
  };
  if (manifest.name !== "@tompassarelli/beagle-store-rpc") fail("unexpected package name");
  if (!/^[0-9]+\.[0-9]+\.[0-9]+$/.test(manifest.version ?? "")) {
    fail("package version must be stable semver");
  }
  if (JSON.stringify(manifest.exports) !== JSON.stringify(expectedExports)) {
    fail("package exports must contain only root, ./core, and ./schema entry points");
  }
  if (manifest.types !== "./store-rpc.d.ts") fail("unexpected root declaration entry");
  if (JSON.stringify(manifest.files) !== JSON.stringify(expectedFiles)) {
    fail("package files do not match the closed release set");
  }
  if (manifest.sideEffects !== false) fail("package must remain side-effect free");
  if (manifest.engines?.bun !== ">=1.3.13") fail("unexpected Bun engine floor");
  if (manifest.license !== "MIT OR Apache-2.0") fail("unexpected package license");
  if (JSON.stringify(manifest.repository) !== JSON.stringify(expectedRepository)) {
    fail("unexpected package repository metadata");
  }
  for (const key of ["dependencies", "optionalDependencies", "peerDependencies"]) {
    if (manifest[key] && Object.keys(manifest[key]).length !== 0) {
      fail(`runtime dependency surface is not closed: ${key}`);
    }
  }
  console.log(manifest.version);
' "$package_json")"
[[ "$package_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "could not read the package version"

package_files=(
  LICENSE
  LICENSE-MIT
  LICENSE-APACHE
  store-rpc.mjs
  store-rpc-core.mjs
  transport-deadline.js
  store-rpc-core.d.ts
  store-rpc.d.ts
  backup.mjs
  schema.mjs
  schema.d.ts
  README.md
)
for package_file in "${package_files[@]}"; do
  source_file="$package_root/$package_file"
  [[ -f "$source_file" && ! -L "$source_file" ]] ||
    die "package file is unavailable or is a symlink: store/clients/bun/$package_file"
  git -C "$source_root" ls-files --error-unmatch "store/clients/bun/$package_file" \
    >/dev/null 2>&1 || die "package file is not tracked: store/clients/bun/$package_file"
done

mkdir -p "$output"
output="$(cd "$output" && pwd -P)"
release_name="tompassarelli-beagle-store-rpc-${package_version}"
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

(
  cd "$package_root"
  bun pm pack --filename "$temporary_archive" --ignore-scripts --quiet \
    >/dev/null
)
[[ -f "$temporary_archive" && ! -L "$temporary_archive" ]] ||
  die "Bun did not produce the package archive"

expected_entries=$'package/package.json\npackage/LICENSE\npackage/LICENSE-APACHE\npackage/LICENSE-MIT\npackage/README.md\npackage/backup.mjs\npackage/schema.d.ts\npackage/schema.mjs\npackage/store-rpc-core.d.ts\npackage/store-rpc-core.mjs\npackage/store-rpc.d.ts\npackage/store-rpc.mjs\npackage/transport-deadline.js'
archive_entries="$(tar -tzf "$temporary_archive")"
[[ "$archive_entries" == "$expected_entries" ]] ||
  die "package archive member set or order is not canonical"
if tar -tvzf "$temporary_archive" | awk 'substr($0, 1, 1) != "-" { exit 1 }'; then
  :
else
  die "package archive contains a non-regular member"
fi

verify_root="$scratch/verify"
mkdir -p "$verify_root"
tar -xzf "$temporary_archive" -C "$verify_root"
shipped_root="$verify_root/package"
cmp -s "$package_json" "$shipped_root/package.json" ||
  die "package archive changed package.json"
for package_file in "${package_files[@]}"; do
  cmp -s "$package_root/$package_file" "$shipped_root/$package_file" ||
    die "package archive changed or omitted $package_file"
done

package_json_sha256="$(sha256sum "$shipped_root/package.json" | awk '{print $1}')"
archive_sha256="$(sha256sum "$temporary_archive" | awk '{print $1}')"
cat >"$temporary_receipt" <<RECEIPT
store-bun-release-receipt/v2
source-commit $source_commit
source-date-epoch $source_epoch
release-tag $version
release-tag-object $tag_object
package-name @tompassarelli/beagle-store-rpc
package-version $package_version
package-json-sha256 $package_json_sha256
archive-name $release_name.tgz
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
  else
    mv "$candidate" "$destination"
  fi
}
publish_file "$temporary_archive" "$archive"
publish_file "$temporary_receipt" "$receipt"

printf '%s\n%s\n' "$archive" "$receipt"
