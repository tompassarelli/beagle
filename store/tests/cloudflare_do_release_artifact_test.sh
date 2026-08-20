#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
packager="$repo/scripts/package-cloudflare-do-release.sh"
scratch="$(mktemp -d)"
cleanup() {
  rm -rf "${scratch:?}"
}
trap cleanup EXIT INT TERM

fail() {
  echo "Cloudflare DO release artifact test: FAIL: $*" >&2
  exit 1
}

for command in bun cmp git grep sha256sum tar touch; do
  command -v "$command" >/dev/null 2>&1 || fail "missing command: $command"
done
[[ "$(bun --version)" == "1.3.13" ]] || fail "Bun 1.3.13 is required"

source_seed="$scratch/source-seed"
package_seed="$source_seed/store/clients/cloudflare-do"
mkdir -p "$package_seed/src"
cp "$repo/LICENSE" "$repo/LICENSE-MIT" "$repo/LICENSE-APACHE" "$source_seed/store/"
cp "$repo/clients/cloudflare-do/README.md" "$package_seed/README.md"
cp "$repo/clients/cloudflare-do/src/adapter.mjs" "$package_seed/src/adapter.mjs"
cp "$repo/clients/cloudflare-do/src/adapter.d.ts" "$package_seed/src/adapter.d.ts"
cp "$repo/clients/cloudflare-do/src/seams.mjs" "$package_seed/src/seams.mjs"
cp "$repo/clients/cloudflare-do/src/seams.d.ts" "$package_seed/src/seams.d.ts"
cat >"$package_seed/package.json" <<'JSON'
{
  "name": "@tompassarelli/store-cloudflare-do",
  "version": "0.3.0",
  "description": "Embed the Beagle Store engine inside a Cloudflare Durable Object over the wasm-embed host seam",
  "type": "module",
  "types": "./src/adapter.d.ts",
  "exports": {
    ".": {
      "types": "./src/adapter.d.ts",
      "import": "./src/adapter.mjs"
    },
    "./seams": {
      "types": "./src/seams.d.ts",
      "import": "./src/seams.mjs"
    }
  },
  "files": [
    "LICENSE",
    "LICENSE-MIT",
    "LICENSE-APACHE",
    "src/adapter.mjs",
    "src/adapter.d.ts",
    "src/seams.mjs",
    "src/seams.d.ts",
    "README.md"
  ],
  "sideEffects": false,
  "engines": {
    "bun": "1.3.13"
  },
  "scripts": {
    "test:bun": "bun test/run-bun.mjs"
  },
  "devDependencies": {
    "miniflare": "5.20260804.1-alpha",
    "wrangler": "4.121.0"
  },
  "repository": {
    "type": "git",
    "url": "git+https://github.com/tompassarelli/beagle.git",
    "directory": "store/clients/cloudflare-do"
  },
  "license": "MIT OR Apache-2.0"
}
JSON

git -C "$source_seed" init -q
git -C "$source_seed" add \
  store/LICENSE \
  store/LICENSE-MIT \
  store/LICENSE-APACHE \
  store/clients/cloudflare-do/package.json \
  store/clients/cloudflare-do/README.md \
  store/clients/cloudflare-do/src/adapter.mjs \
  store/clients/cloudflare-do/src/adapter.d.ts \
  store/clients/cloudflare-do/src/seams.mjs \
  store/clients/cloudflare-do/src/seams.d.ts
GIT_AUTHOR_NAME='Beagle Store' GIT_AUTHOR_EMAIL=store@example.invalid \
GIT_AUTHOR_DATE='2026-01-02T03:04:05Z' \
GIT_COMMITTER_NAME='Beagle Store' GIT_COMMITTER_EMAIL=store@example.invalid \
GIT_COMMITTER_DATE='2026-01-02T03:04:05Z' \
  git -C "$source_seed" commit -q -m release
GIT_COMMITTER_NAME='Beagle Store' GIT_COMMITTER_EMAIL=store@example.invalid \
GIT_COMMITTER_DATE='2026-01-02T03:05:06Z' \
  git -C "$source_seed" tag -a v1.2.3 -m release
git -C "$source_seed" tag v1.2.4
source_commit="$(git -C "$source_seed" rev-parse 'HEAD^{commit}')"
source_epoch="$(git -C "$source_seed" show -s --format=%ct HEAD)"
tag_object="$(git -C "$source_seed" rev-parse refs/tags/v1.2.3)"
[[ "$tag_object" != "$source_commit" ]] ||
  fail "annotated test tag did not produce a distinct tag object"

git clone -q --no-local "$source_seed" "$scratch/work-a"
git clone -q --no-local "$source_seed" "$scratch/different/depth/work-b"
for source_file in \
  store/LICENSE \
  store/LICENSE-MIT \
  store/LICENSE-APACHE \
  store/clients/cloudflare-do/package.json \
  store/clients/cloudflare-do/README.md \
  store/clients/cloudflare-do/src/adapter.mjs \
  store/clients/cloudflare-do/src/adapter.d.ts \
  store/clients/cloudflare-do/src/seams.mjs \
  store/clients/cloudflare-do/src/seams.d.ts; do
  touch -t 203801020304.05 "$scratch/different/depth/work-b/$source_file"
done

mapfile -t files_a < <(
  "$packager" --source-root "$scratch/work-a" \
    --output "$scratch/out-a" --version v1.2.3
)
mapfile -t files_b < <(
  "$packager" --source-root "$scratch/different/depth/work-b" \
    --output "$scratch/different/out-b" --version v1.2.3
)
[[ "${#files_a[@]}" == 2 && "${#files_b[@]}" == 2 ]] ||
  fail "packager did not return one archive and one receipt"
cmp -s "${files_a[0]}" "${files_b[0]}" ||
  fail "package archives differ across source workdirs and mtimes"
cmp -s "${files_a[1]}" "${files_b[1]}" ||
  fail "package receipts differ across source workdirs and mtimes"

expected_entries=$'package/package.json\npackage/LICENSE\npackage/LICENSE-APACHE\npackage/LICENSE-MIT\npackage/README.md\npackage/src/adapter.d.ts\npackage/src/adapter.mjs\npackage/src/seams.d.ts\npackage/src/seams.mjs'
[[ "$(tar -tzf "${files_a[0]}")" == "$expected_entries" ]] ||
  fail "archive member set or order is not canonical"
if ! tar --numeric-owner -tvzf "${files_a[0]}" |
    awk '$1 != "-rw-r--r--" { exit 1 }'; then
  fail "archive member type or mode is not canonical"
fi

extract="$scratch/extract"
mkdir -p "$extract"
tar -xzf "${files_a[0]}" -C "$extract"
cmp -s "$source_seed/store/clients/cloudflare-do/package.json" \
  "$extract/package/package.json" || fail "archive changed package.json"
for root_file in LICENSE LICENSE-MIT LICENSE-APACHE; do
  cmp -s "$source_seed/store/$root_file" "$extract/package/$root_file" ||
    fail "archive changed or omitted $root_file"
done
for package_file in README.md src/adapter.mjs src/adapter.d.ts src/seams.mjs src/seams.d.ts; do
  cmp -s "$source_seed/store/clients/cloudflare-do/$package_file" \
    "$extract/package/$package_file" ||
    fail "archive changed or omitted $package_file"
done

package_json_sha256="$(sha256sum "$extract/package/package.json" | awk '{print $1}')"
archive_sha256="$(sha256sum "${files_a[0]}" | awk '{print $1}')"
expected_receipt="$scratch/expected.receipt.txt"
cat >"$expected_receipt" <<RECEIPT
store-cloudflare-do-release-receipt/v1
source-commit $source_commit
source-date-epoch $source_epoch
release-tag v1.2.3
release-tag-object $tag_object
package-name @tompassarelli/store-cloudflare-do
package-version 0.3.0
package-json-sha256 $package_json_sha256
archive-name tompassarelli-store-cloudflare-do-0.3.0.tgz
archive-sha256 $archive_sha256
RECEIPT
cmp -s "$expected_receipt" "${files_a[1]}" ||
  fail "receipt is not the closed canonical envelope"
! grep -Fq "$scratch" "${files_a[1]}" ||
  fail "receipt leaked a checkout-local path"

# Re-running against identical destinations is idempotent, but an existing
# output with different bytes is never replaced.
mapfile -t repeated_files < <(
  "$packager" --source-root "$scratch/work-a" \
    --output "$scratch/out-a" --version v1.2.3
)
[[ "${repeated_files[0]}" == "${files_a[0]}" &&
   "${repeated_files[1]}" == "${files_a[1]}" ]] ||
  fail "idempotent packaging changed output paths"
printf 'different\n' >>"${files_a[0]}"
if "$packager" --source-root "$scratch/work-a" \
    --output "$scratch/out-a" --version v1.2.3 \
    >"$scratch/different-output.stdout" 2>"$scratch/different-output.stderr"; then
  fail "packager replaced a different existing output"
fi
grep -Fq 'refusing to replace different release output' \
  "$scratch/different-output.stderr" ||
  fail "different existing output did not fail exactly"

# Dirty worktrees, tag/HEAD mismatches, and clean tagged symlink inputs all
# fail before any release output is published.
git clone -q --no-local "$source_seed" "$scratch/dirty-source"
printf '\nchanged\n' >>"$scratch/dirty-source/store/clients/cloudflare-do/README.md"
if "$packager" --source-root "$scratch/dirty-source" \
    --output "$scratch/out-dirty" --version v1.2.3 \
    >"$scratch/dirty.stdout" 2>"$scratch/dirty.stderr"; then
  fail "packager accepted a tracked-dirty source"
fi
grep -Fq 'source worktree is not clean' "$scratch/dirty.stderr" ||
  fail "tracked-dirty source did not fail exactly"

git clone -q --no-local "$source_seed" "$scratch/untracked-source"
printf 'untracked\n' >"$scratch/untracked-source/untracked.txt"
if "$packager" --source-root "$scratch/untracked-source" \
    --output "$scratch/out-untracked" --version v1.2.3 \
    >"$scratch/untracked.stdout" 2>"$scratch/untracked.stderr"; then
  fail "packager accepted an untracked-dirty source"
fi
grep -Fq 'source worktree is not clean' "$scratch/untracked.stderr" ||
  fail "untracked-dirty source did not fail exactly"

git clone -q --no-local "$source_seed" "$scratch/untagged-source"
git -C "$scratch/untagged-source" config user.name Beagle Store
git -C "$scratch/untagged-source" config user.email store@example.invalid
git -C "$scratch/untagged-source" commit --allow-empty -q -m after-release
if "$packager" --source-root "$scratch/untagged-source" \
    --output "$scratch/out-untagged" --version v1.2.3 \
    >"$scratch/untagged.stdout" 2>"$scratch/untagged.stderr"; then
  fail "packager accepted a tag that did not point at HEAD"
fi
grep -Fq 'does not point at source commit' "$scratch/untagged.stderr" ||
  fail "tag/HEAD mismatch did not fail exactly"

if "$packager" --source-root "$scratch/work-a" \
    --output "$scratch/out-lightweight" --version v1.2.4 \
    >"$scratch/lightweight.stdout" 2>"$scratch/lightweight.stderr"; then
  fail "packager accepted a lightweight release tag"
fi
grep -Fq 'must name an annotated tag object' "$scratch/lightweight.stderr" ||
  fail "lightweight release tag failed for the wrong reason"

git clone -q --no-local "$source_seed" "$scratch/symlink-source"
git -C "$scratch/symlink-source" config user.name Beagle Store
git -C "$scratch/symlink-source" config user.email store@example.invalid
rm "$scratch/symlink-source/store/clients/cloudflare-do/README.md"
ln -s ../../LICENSE "$scratch/symlink-source/store/clients/cloudflare-do/README.md"
git -C "$scratch/symlink-source" add store/clients/cloudflare-do/README.md
git -C "$scratch/symlink-source" commit -q -m symlink-input
git -C "$scratch/symlink-source" tag -a v1.2.5 -m symlink-input
if "$packager" --source-root "$scratch/symlink-source" \
    --output "$scratch/out-symlink" --version v1.2.5 \
    >"$scratch/symlink.stdout" 2>"$scratch/symlink.stderr"; then
  fail "packager accepted a symlink package input"
fi
grep -Fq 'package file is unavailable or is a symlink' \
  "$scratch/symlink.stderr" ||
  fail "symlink package input did not fail exactly"

printf 'Cloudflare DO release artifact test: PASS commit=%s archive=%s\n' \
  "$source_commit" "$archive_sha256"
