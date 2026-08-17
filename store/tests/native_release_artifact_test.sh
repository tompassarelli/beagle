#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
packager="$repo/scripts/package-native-release.sh"
scratch="$(mktemp -d)"
cleanup() {
  rm -rf "${scratch:?}"
}
trap cleanup EXIT INT TERM

fail() {
  echo "native release artifact test: FAIL: $*" >&2
  exit 1
}

for command in cmp git gzip readelf sha256sum tar; do
  command -v "$command" >/dev/null 2>&1 || fail "missing command: $command"
done
source_seed="$scratch/source-seed"
mkdir -p "$source_seed/bin"
git -C "$source_seed" init -q
printf '%s\n' 'release source' >"$source_seed/source.txt"
cat >"$source_seed/server.c" <<'C'
int main(void) { return 0; }
C
cp "$repo/LICENSE" "$repo/LICENSE-MIT" "$repo/LICENSE-APACHE" "$source_seed/"
cp "$repo/beagle-pin.txt" "$source_seed/"
cp "$repo/bin/beagle-store-native-build" "$source_seed/bin/"
git -C "$source_seed" add source.txt server.c LICENSE LICENSE-MIT LICENSE-APACHE \
  beagle-pin.txt bin/beagle-store-native-build
GIT_AUTHOR_NAME=Beagle Store GIT_AUTHOR_EMAIL=store@example.invalid \
GIT_AUTHOR_DATE='2026-01-02T03:04:05Z' \
GIT_COMMITTER_NAME=Beagle Store GIT_COMMITTER_EMAIL=store@example.invalid \
GIT_COMMITTER_DATE='2026-01-02T03:04:05Z' \
  git -C "$source_seed" commit -q -m release
GIT_COMMITTER_NAME=Beagle Store GIT_COMMITTER_EMAIL=store@example.invalid \
GIT_COMMITTER_DATE='2026-01-02T04:05:06Z' \
  git -C "$source_seed" tag -a v1.2.3 -m release
git -C "$source_seed" tag v1.2.4
source_commit="$(git -C "$source_seed" rev-parse HEAD)"
tag_object="$(git -C "$source_seed" rev-parse refs/tags/v1.2.3)"
beagle_revision="$(<"$source_seed/beagle-pin.txt")"

git clone -q --no-local "$source_seed" "$scratch/work-a"
git clone -q --no-local "$source_seed" "$scratch/different/depth/work-b"

cc="${CC:-cc}"
command -v "$cc" >/dev/null 2>&1 || fail "missing C compiler: $cc"

input_template="$scratch/input.manifest"
printf '%s\n' \
  'beagle-store-native-build-input/v3' \
  "$(sha256sum "$source_seed/bin/beagle-store-native-build" | awk '{print $1}')" \
  'host=server' \
  'program=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
  >"$input_template"
artifact_identity="$(sha256sum "$input_template" | awk '{print $1}')"
for work in "$scratch/work-a" "$scratch/different/depth/work-b"; do
  mkdir -p "$work/artifacts/$artifact_identity/bin"
  server="$work/artifacts/$artifact_identity/bin/beagle-store-server-native"
  "$cc" -static "$work/server.c" -o "$server" ||
    fail "$cc cannot produce the static release-test executable"
  readelf -l "$server" | grep -Fq 'Requesting program interpreter' &&
    fail "release-test executable is dynamically linked"
  printf 'beagle-store-native-build/v1 %s\n' "$artifact_identity" \
    >"$work/artifacts/$artifact_identity/READY"
  cp "$input_template" "$work/artifacts/$artifact_identity/input.manifest"
  printf '%s\n' "$beagle_revision" \
    >"$work/artifacts/$artifact_identity/beagle-revision.txt"
done
reference_server="$scratch/work-a/artifacts/$artifact_identity/bin/beagle-store-server-native"

mapfile -t files_a < <(
  "$packager" --source-root "$scratch/work-a" \
    --artifact "$scratch/work-a/artifacts/$artifact_identity" \
    --output "$scratch/out-a" --version v1.2.3
)
mapfile -t files_b < <(
  "$packager" --source-root "$scratch/different/depth/work-b" \
    --artifact "$scratch/different/depth/work-b/artifacts/$artifact_identity" \
    --output "$scratch/different/out-b" --version v1.2.3
)
[[ "${#files_a[@]}" == 2 && "${#files_b[@]}" == 2 ]] ||
  fail "packager did not return one archive and one receipt"
cmp -s "${files_a[0]}" "${files_b[0]}" ||
  fail "normalized archives differ across source and artifact workdirs"
cmp -s "${files_a[1]}" "${files_b[1]}" ||
  fail "release receipts differ across source and artifact workdirs"

for forbidden_path in "$scratch/work-a" "$scratch/different/depth/work-b"; do
  ! grep -Fq "$forbidden_path" "${files_a[1]}" ||
    fail "receipt leaked a checkout-local path: $forbidden_path"
done
grep -Fxq "source-commit $source_commit" "${files_a[1]}" ||
  fail "receipt omitted the exact source commit"
grep -Fxq "release-tag-object $tag_object" "${files_a[1]}" ||
  fail "receipt omitted the annotated tag object"
grep -Fxq "native-build-closure-sha256 $artifact_identity" "${files_a[1]}" ||
  fail "receipt omitted the native build closure"
grep -Fxq "beagle-revision $beagle_revision" "${files_a[1]}" ||
  fail "receipt omitted the pinned Beagle revision"
archive_sha256="$(sha256sum "${files_a[0]}" | awk '{print $1}')"
grep -Fxq "archive-sha256 $archive_sha256" "${files_a[1]}" ||
  fail "receipt does not hash the shipped archive"

extract="$scratch/extract"
mkdir -p "$extract"
tar -xzf "${files_a[0]}" -C "$extract"
shipped="$extract/store-v1.2.3-x86_64-linux-musl/bin/beagle-store-server-native"
cmp -s "$reference_server" "$shipped" ||
  fail "archive does not contain the exact native executable"
executable_sha256="$(sha256sum "$shipped" | awk '{print $1}')"
grep -Fxq "executable-sha256 $executable_sha256" "${files_a[1]}" ||
  fail "receipt does not hash the executable extracted from the archive"

archive_entries="$(tar -tzf "${files_a[0]}")"
[[ "$archive_entries" == $'store-v1.2.3-x86_64-linux-musl/\nbeagle-store-v1.2.3-x86_64-linux-musl/LICENSE\nbeagle-store-v1.2.3-x86_64-linux-musl/LICENSE-APACHE\nbeagle-store-v1.2.3-x86_64-linux-musl/LICENSE-MIT\nbeagle-store-v1.2.3-x86_64-linux-musl/bin/\nbeagle-store-v1.2.3-x86_64-linux-musl/bin/beagle-store-server-native' ]] ||
  fail "archive member set or order is not canonical"

# Artifact and executable paths are identity-bearing inputs, never links that
# can be retargeted between validation and copy.
symlink_artifact_parent="$scratch/symlink-artifact"
mkdir -p "$symlink_artifact_parent"
ln -s "$scratch/work-a/artifacts/$artifact_identity" \
  "$symlink_artifact_parent/$artifact_identity"
if "$packager" --source-root "$scratch/work-a" \
    --artifact "$symlink_artifact_parent/$artifact_identity" \
    --output "$scratch/out-symlink-artifact" --version v1.2.3 \
    >"$scratch/symlink-artifact.stdout" 2>"$scratch/symlink-artifact.stderr"; then
  fail "packager accepted a symlink artifact path"
fi
grep -Fq 'artifact path must not be a symlink' \
  "$scratch/symlink-artifact.stderr" ||
  fail "symlink artifact path did not fail exactly"

symlink_server_artifact="$scratch/symlink-server/$artifact_identity"
mkdir -p "$symlink_server_artifact/bin"
printf 'beagle-store-native-build/v1 %s\n' "$artifact_identity" \
  >"$symlink_server_artifact/READY"
cp "$input_template" "$symlink_server_artifact/input.manifest"
printf '%s\n' "$beagle_revision" >"$symlink_server_artifact/beagle-revision.txt"
ln -s "$reference_server" \
  "$symlink_server_artifact/bin/beagle-store-server-native"
if "$packager" --source-root "$scratch/work-a" \
    --artifact "$symlink_server_artifact" \
    --output "$scratch/out-symlink-server" --version v1.2.3 \
    >"$scratch/symlink-server.stdout" 2>"$scratch/symlink-server.stderr"; then
  fail "packager accepted a symlink executable"
fi
grep -Fq 'artifact executable must not be a symlink' \
  "$scratch/symlink-server.stderr" ||
  fail "symlink executable did not fail exactly"

# The receipt must follow shipped bytes, not the READY directory name.
changed_artifact="$scratch/changed/$artifact_identity"
mkdir -p "$changed_artifact/bin"
cat >"$scratch/changed-server.c" <<'C'
int main(void) { return 7; }
C
"$cc" -static "$scratch/changed-server.c" \
  -o "$changed_artifact/bin/beagle-store-server-native" ||
  fail "$cc cannot produce the changed static release-test executable"
set +e
"$changed_artifact/bin/beagle-store-server-native"
changed_status=$?
set -e
[[ "$changed_status" == 7 ]] ||
  fail "changed release-test executable did not run with its expected result"
printf 'beagle-store-native-build/v1 %s\n' "$artifact_identity" >"$changed_artifact/READY"
cp "$input_template" "$changed_artifact/input.manifest"
printf '%s\n' "$beagle_revision" >"$changed_artifact/beagle-revision.txt"
mapfile -t changed_files < <(
  "$packager" --source-root "$scratch/work-a" --artifact "$changed_artifact" \
    --output "$scratch/out-changed" --version v1.2.3
)
! cmp -s "${files_a[0]}" "${changed_files[0]}" ||
  fail "changed executable did not change the archive"
! cmp -s "${files_a[1]}" "${changed_files[1]}" ||
  fail "changed executable did not change the receipt"

expected_receipt_keys=$'store-native-release-receipt/v2\nsource-commit\nsource-date-epoch\nrelease-tag\nrelease-tag-object\ntarget\nnative-build-closure-sha256\nbeagle-revision\nexecutable-path\nexecutable-sha256\narchive-name\narchive-sha256'
[[ "$(awk 'NR == 1 { print; next } { print $1 }' "${files_a[1]}")" == \
  "$expected_receipt_keys" ]] ||
  fail "receipt schema is not closed and ordered"

if "$packager" --source-root "$scratch/work-a" \
    --artifact "$scratch/work-a/artifacts/$artifact_identity" \
    --output "$scratch/out-lightweight" --version v1.2.4 \
    >"$scratch/lightweight.stdout" 2>"$scratch/lightweight.stderr"; then
  fail "packager accepted a lightweight release tag"
fi
grep -Fq 'must name an annotated tag object' "$scratch/lightweight.stderr" ||
  fail "lightweight release tag failed for the wrong reason"

printf 'native release artifact test: PASS commit=%s archive=%s\n' \
  "$source_commit" "$archive_sha256"
