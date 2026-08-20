#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
packager="$repo/scripts/package-cloudflare-wasm-release.sh"
scratch="$(mktemp -d)"
cleanup() { rm -rf "${scratch:?}"; }
trap cleanup EXIT INT TERM

fail() {
  echo "cloudflare wasm release artifact test: FAIL: $*" >&2
  exit 1
}

for command in bun cmp git gzip sha256sum tar touch; do
  command -v "$command" >/dev/null 2>&1 || fail "missing command: $command"
done
[[ "$(bun --version)" == "1.3.13" ]] || fail "Bun 1.3.13 is required"

source_seed="$scratch/source-seed"
store_seed="$source_seed/store"
mkdir -p "$store_seed/bin" "$store_seed/native" "$store_seed/src" \
  "$source_seed/native-core/src"
cp "$repo/LICENSE" "$repo/LICENSE-MIT" "$repo/LICENSE-APACHE" "$store_seed/"
cp "$repo/beagle-pin.txt" "$store_seed/"
cp "$repo/native/wasm-embed.seams" "$store_seed/native/wasm-embed.seams"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$store_seed/bin/beagle-store-native-build"
chmod +x "$store_seed/bin/beagle-store-native-build"
for member in store_embed.c store.h server_host.h server_generated.c store_wasm_host.c; do
  printf 'synthetic %s\n' "$member" >"$store_seed/native/$member"
done
printf '%s\n' ../native-core/src/core-a.bgl src/core-b.bgl \
  >"$store_seed/native/core_closure_sources.txt"
printf '%s\n' '#lang beagle' '(ns synthetic.a)' \
  >"$source_seed/native-core/src/core-a.bgl"
printf '%s\n' '#lang beagle' '(ns synthetic.b)' >"$store_seed/src/core-b.bgl"
git -C "$source_seed" init -q
git -C "$source_seed" add store native-core
GIT_AUTHOR_NAME='Beagle Store' GIT_AUTHOR_EMAIL=store@example.invalid \
GIT_AUTHOR_DATE='2026-01-02T03:04:05Z' \
GIT_COMMITTER_NAME='Beagle Store' GIT_COMMITTER_EMAIL=store@example.invalid \
GIT_COMMITTER_DATE='2026-01-02T03:04:05Z' \
  git -C "$source_seed" commit -q -m release
GIT_COMMITTER_NAME='Beagle Store' GIT_COMMITTER_EMAIL=store@example.invalid \
GIT_COMMITTER_DATE='2026-01-02T04:05:06Z' \
  git -C "$source_seed" tag -a v1.2.3 -m release
git -C "$source_seed" tag v1.2.4
source_commit="$(git -C "$source_seed" rev-parse HEAD)"
tag_object="$(git -C "$source_seed" rev-parse refs/tags/v1.2.3)"
beagle_revision="$(<"$store_seed/beagle-pin.txt")"

git clone -q --no-local "$source_seed" "$scratch/work-a"
git clone -q --no-local "$source_seed" "$scratch/different/depth/work-b"
touch -t 203801020304.05 \
  "$scratch/different/depth/work-b/store/LICENSE" \
  "$scratch/different/depth/work-b/store/LICENSE-MIT" \
  "$scratch/different/depth/work-b/store/LICENSE-APACHE" \
  "$scratch/different/depth/work-b/store/native/wasm-embed.seams"

make_artifact() {
  local root="$1" input_manifest="$1/input.manifest"
  mkdir -p "$root"
  printf '%s\n' \
    'beagle-store-native-build-input/v3' \
    "$(sha256sum "$store_seed/bin/beagle-store-native-build" | awk '{print $1}')" \
    'host=wasm-embed' \
    'program=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
    'native-program=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789' \
    'synthetic-toolchain-identity' \
    'link=dynamic' \
    "host-source repo:native/store_embed.c $(sha256sum "$store_seed/native/store_embed.c" | awk '{print $1}')" \
    >"$input_manifest"
  local artifact_identity artifact
  artifact_identity="$(sha256sum "$input_manifest" | awk '{print $1}')"
  artifact="$root/$artifact_identity"
  mkdir -p "$artifact/lib" "$artifact/THIRD-PARTY/ffc"
  cp "$input_manifest" "$artifact/input.manifest"
  printf 'beagle-store-native-build/v1 %s\n' "$artifact_identity" >"$artifact/READY"
  printf '%s\n' "$beagle_revision" >"$artifact/beagle-revision.txt"
  # A complete empty Wasm module; the native builder is responsible for the
  # full import/export validation before it writes READY.
  printf '\x00asm\x01\x00\x00\x00' >"$artifact/lib/libstore.wasm"
  grep -v '^[[:space:]]*#' "$store_seed/native/wasm-embed.seams" |
    grep -v '^[[:space:]]*$' >"$artifact/wasm-embed.seams"
  printf '%s\n' 'Unicode License V3 synthetic fixture' >"$artifact/UNICODE-LICENSE.txt"
  printf '%s\n' 'WASI toolchain licenses synthetic fixture' \
    >"$artifact/THIRD-PARTY/WASI-TOOLCHAIN-LICENSES.txt"
  printf '%s\n' 'MIT synthetic ffc fixture' >"$artifact/THIRD-PARTY/ffc/LICENSE-MIT"
  printf '%s\n' 'ffc provenance synthetic fixture' >"$artifact/THIRD-PARTY/ffc/PROVENANCE"
  printf '%s\n' 'synthetic native program' >"$artifact/module.native-program"
  {
    printf '%s\n' \
      'beagle-store-native-build-provenance/v2' \
      "builder-sha256 $(sha256sum "$store_seed/bin/beagle-store-native-build" | awk '{print $1}')" \
      'beagle-compiler-inputs-sha256 1111111111111111111111111111111111111111111111111111111111111111' \
      "beagle-revision $beagle_revision" \
      'abi wasm32' \
      'host wasm-embed' \
      "native-program-sha256 $(sha256sum "$artifact/module.native-program" | awk '{print $1}')"
    index=0
    while IFS= read -r source_member; do
      printf 'source-sha256 %06d %s\n' "$index" \
        "$(sha256sum "$store_seed/$source_member" | awk '{print $1}')"
      index=$((index + 1))
    done <"$store_seed/native/core_closure_sources.txt"
    printf '%s\n' \
      "host-source-sha256 $(sha256sum "$store_seed/native/store_embed.c" | awk '{print $1}')" \
      "host-header-sha256 $(sha256sum "$store_seed/native/store.h" | awk '{print $1}')" \
      "adapter-header-sha256 $(sha256sum "$store_seed/native/server_host.h" | awk '{print $1}')" \
      "adapter-sha256 $(sha256sum "$store_seed/native/server_generated.c" | awk '{print $1}')" \
      "wasm-host-source-sha256 $(sha256sum "$store_seed/native/store_wasm_host.c" | awk '{print $1}')" \
      "wasm-seams-sha256 $(sha256sum "$store_seed/native/wasm-embed.seams" | awk '{print $1}')" \
      'wasi-cc-sha256 2222222222222222222222222222222222222222222222222222222222222222' \
      'wasi-cc-version-sha256 3333333333333333333333333333333333333333333333333333333333333333' \
      'wasm-tools-sha256 4444444444444444444444444444444444444444444444444444444444444444' \
      'wasm-tools-version-sha256 5555555555555555555555555555555555555555555555555555555555555555' \
      "wasi-toolchain-licenses-sha256 $(sha256sum "$artifact/THIRD-PARTY/WASI-TOOLCHAIN-LICENSES.txt" | awk '{print $1}')" \
      "ffc-license-sha256 $(sha256sum "$artifact/THIRD-PARTY/ffc/LICENSE-MIT" | awk '{print $1}')" \
      "ffc-provenance-sha256 $(sha256sum "$artifact/THIRD-PARTY/ffc/PROVENANCE" | awk '{print $1}')"
  } >"$artifact/provenance.manifest"
  printf '%s\n' "$artifact"
}
artifact_a="$(make_artifact "$scratch/artifacts-a")"
artifact_b="$(make_artifact "$scratch/different/artifacts-b")"
[[ "${artifact_a##*/}" == "${artifact_b##*/}" ]] ||
  fail "logical input manifests produced different artifact addresses across checkouts"

mapfile -t files_a < <(
  "$packager" --source-root "$scratch/work-a" --artifact "$artifact_a" \
    --output "$scratch/out-a" --version v1.2.3
)
mapfile -t files_b < <(
  "$packager" --source-root "$scratch/different/depth/work-b" --artifact "$artifact_b" \
    --output "$scratch/different/out-b" --version v1.2.3
)
[[ "${#files_a[@]}" == 2 && "${#files_b[@]}" == 2 ]] ||
  fail "packager did not return one archive and one receipt"
cmp -s "${files_a[0]}" "${files_b[0]}" ||
  fail "archives differ across source and artifact workdirs"
cmp -s "${files_a[1]}" "${files_b[1]}" ||
  fail "receipts differ across source and artifact workdirs"

# Re-running is idempotent when every byte is identical.
mapfile -t repeated < <(
  "$packager" --source-root "$scratch/work-a" --artifact "$artifact_a" \
    --output "$scratch/out-a" --version v1.2.3
)
cmp -s "${files_a[0]}" "${repeated[0]}" || fail "idempotent archive changed"
cmp -s "${files_a[1]}" "${repeated[1]}" || fail "idempotent receipt changed"

release_name='store-v1.2.3-wasm32-wasm-embed'
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
$release_name/lib/libstore.wasm
$release_name/native-provenance.manifest
$release_name/wasm-embed.seams"
[[ "$(tar -tzf "${files_a[0]}")" == "$expected_entries" ]] ||
  fail "archive member set or order is not canonical"

receipt_keys="$(awk '{print $1}' "${files_a[1]}")"
expected_keys=$'store-cloudflare-wasm-release-receipt/v2\nsource-commit\nsource-date-epoch\nrelease-tag\nrelease-tag-object\ntarget\nnative-build-closure-sha256\nbeagle-revision\nnative-provenance-sha256\nwasm-path\nwasm-bytes\nwasm-sha256\nseams-path\nseams-sha256\nunicode-license-sha256\nwasi-toolchain-licenses-sha256\nffc-license-sha256\nffc-provenance-sha256\narchive-name\narchive-sha256'
[[ "$receipt_keys" == "$expected_keys" ]] || fail "receipt schema is not closed and ordered"
grep -Fxq "source-commit $source_commit" "${files_a[1]}" || fail "receipt omitted source commit"
grep -Fxq "release-tag-object $tag_object" "${files_a[1]}" || fail "receipt omitted tag object"
grep -Fxq "native-build-closure-sha256 ${artifact_a##*/}" "${files_a[1]}" ||
  fail "receipt omitted native build closure"
grep -Fxq "beagle-revision $beagle_revision" "${files_a[1]}" ||
  fail "receipt omitted pinned Beagle revision"
native_provenance_sha256="$(sha256sum "$artifact_a/provenance.manifest" | awk '{print $1}')"
grep -Fxq "native-provenance-sha256 $native_provenance_sha256" "${files_a[1]}" ||
  fail "receipt omitted path-independent native provenance"
archive_sha256="$(sha256sum "${files_a[0]}" | awk '{print $1}')"
grep -Fxq "archive-sha256 $archive_sha256" "${files_a[1]}" || fail "receipt archive hash differs"
for forbidden in "$scratch/work-a" "$scratch/different/depth/work-b" \
  "$scratch/artifacts-a" "$scratch/different/artifacts-b"; do
  ! grep -Fq "$forbidden" "${files_a[1]}" || fail "receipt leaked path: $forbidden"
done

extract="$scratch/extract"
mkdir -p "$extract"
tar -xzf "${files_a[0]}" -C "$extract"
shipped="$extract/$release_name"
cmp -s "$artifact_a/lib/libstore.wasm" "$shipped/lib/libstore.wasm" || fail "Wasm bytes changed"
cmp -s "$artifact_a/wasm-embed.seams" "$shipped/wasm-embed.seams" || fail "seams changed"
wasm_sha256="$(sha256sum "$shipped/lib/libstore.wasm" | awk '{print $1}')"
grep -Fxq "wasm-sha256 $wasm_sha256" "${files_a[1]}" || fail "receipt Wasm hash differs"

expect_failure() {
  local label="$1" pattern="$2"
  shift 2
  if "$@" >"$scratch/$label.stdout" 2>"$scratch/$label.stderr"; then
    fail "$label unexpectedly succeeded"
  fi
  grep -Fq "$pattern" "$scratch/$label.stderr" || fail "$label did not fail exactly"
}

ln -s "$artifact_a" "$scratch/artifact-link"
expect_failure artifact-link 'artifact path must not be a symlink' \
  "$packager" --source-root "$scratch/work-a" --artifact "$scratch/artifact-link" \
  --output "$scratch/out-link" --version v1.2.3

symlink_member="$scratch/symlink-member/${artifact_a##*/}"
mkdir -p "$(dirname "$symlink_member")"
cp -R "$artifact_a" "$symlink_member"
rm "$symlink_member/lib/libstore.wasm"
ln -s "$artifact_a/lib/libstore.wasm" "$symlink_member/lib/libstore.wasm"
expect_failure member-link 'artifact file is unavailable or symlinked: lib/libstore.wasm' \
  "$packager" --source-root "$scratch/work-a" --artifact "$symlink_member" \
  --output "$scratch/out-member-link" --version v1.2.3

git clone -q --no-local "$source_seed" "$scratch/dirty"
printf '%s\n' dirty >>"$scratch/dirty/store/LICENSE"
expect_failure dirty 'source worktree is not clean' \
  "$packager" --source-root "$scratch/dirty" --artifact "$artifact_a" \
  --output "$scratch/out-dirty" --version v1.2.3

git clone -q --no-local "$source_seed" "$scratch/untagged"
git -C "$scratch/untagged" config user.name Beagle Store
git -C "$scratch/untagged" config user.email store@example.invalid
git -C "$scratch/untagged" commit --allow-empty -q -m after-release
expect_failure untagged 'does not point at source commit' \
  "$packager" --source-root "$scratch/untagged" --artifact "$artifact_a" \
  --output "$scratch/out-untagged" --version v1.2.3

expect_failure lightweight 'must name an annotated tag object' \
  "$packager" --source-root "$scratch/work-a" --artifact "$artifact_a" \
  --output "$scratch/out-lightweight" --version v1.2.4

printf '%s\n' different >"${files_a[1]}"
expect_failure different-output 'refusing to replace different release output' \
  "$packager" --source-root "$scratch/work-a" --artifact "$artifact_a" \
  --output "$scratch/out-a" --version v1.2.3

printf 'cloudflare wasm release artifact test: PASS commit=%s archive=%s\n' \
  "$source_commit" "$archive_sha256"
