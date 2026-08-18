#!/usr/bin/env bash
# Package the oracle's complete Stage 1 projection as an immutable artifact.
#
# The projection is an external, content-addressed build result.  This script
# deliberately does not call git, a compiler, or a network client: Nix owns the
# build environment and this step only authenticates and copies the finished
# native executable while recording every closure input that produced it.

set -euo pipefail

die() {
    printf 'stage1-package: %s\n' "$*" >&2
    exit 2
}

projection=""
source_root=""
out=""
manifest=""
lock=""
projection_commit_override=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --projection)
            [[ $# -ge 2 ]] || die "--projection needs a directory"
            projection="$2"
            shift 2
            ;;
        --source-root)
            [[ $# -ge 2 ]] || die "--source-root needs a directory"
            source_root="$2"
            shift 2
            ;;
        --out)
            [[ $# -ge 2 ]] || die "--out needs a directory"
            out="$2"
            shift 2
            ;;
        --manifest)
            [[ $# -ge 2 ]] || die "--manifest needs a file"
            manifest="$2"
            shift 2
            ;;
        --lock)
            [[ $# -ge 2 ]] || die "--lock needs a file"
            lock="$2"
            shift 2
            ;;
        --projection-commit)
            [[ $# -ge 2 ]] || die "--projection-commit needs a full commit"
            projection_commit_override="$2"
            shift 2
            ;;
        --help|-h)
            sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[[ -n "$projection" && -d "$projection" ]] ||
    die "complete projection directory is required"
[[ -n "$source_root" && -d "$source_root" ]] ||
    die "source root is required"
[[ -n "$out" ]] || die "output directory is required"
[[ -f "$manifest" ]] || die "closure manifest is unavailable: $manifest"
[[ -f "$lock" ]] || die "flake lock is unavailable: $lock"

projection="$(realpath "$projection")"
source_root="$(realpath "$source_root")"
manifest="$(realpath "$manifest")"
lock="$(realpath "$lock")"
mkdir -p "$out/bin"
out="$(realpath "$out")"

projection_commit="${projection_commit_override:-$(basename "$projection")}"
[[ "$projection_commit" =~ ^[0-9a-f]{40}$ ]] ||
    die "projection directory must be named by its full commit: $projection_commit"

source_names=(
    ast check emit-clj emit-js emit-nix facts-roundtrip macros main parse probe
    reader types
)
core_names=(
    core stages simd lower obligations c11 slice unit_reuse unit_compile
    fold_c17 body_c17 body_slice qbe
)
driver_names=(
    bin/beagle
    bin/beagle-build
    bin/beagle-build-all
    bin/beagle-build-core
    bin/beagle-native-exe
    bin/beagle-self-compiler-core
    bin/beagle-materialize-wasm
    native-core/bin/source-facts.clj
    native-core/bin/verify-checked-ast.rkt
    native-core/validation/build-finalize.clj
    native-core/bin/run-bounded.rkt
    beagle-lib/private/module-source-root-cli.rkt
    self-host/native/stage1-package.sh
)

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

for name in "${source_names[@]}"; do
    [[ -f "$projection/source/selfhost/$name.bgl" ]] ||
        die "projection is missing self-host source: $name.bgl"
done
mapfile -t projected_sources < <(
    find "$projection/source/selfhost" -maxdepth 1 -type f -name '*.bgl' -printf '%f\n' |
        LC_ALL=C sort
)
[[ "${#projected_sources[@]}" == "${#source_names[@]}" ]] ||
    die "projection self-host closure has ${#projected_sources[@]} files, expected ${#source_names[@]}"

for name in "${core_names[@]}"; do
    [[ -f "$source_root/native-core/src/native/$name.bclj" ]] ||
        die "source root is missing Native Core module: $name.bclj"
done
for name in "${driver_names[@]}"; do
    [[ -f "$source_root/$name" ]] ||
        die "source root is missing driver input: $name"
done

mapfile -t binaries < <(
    find "$projection/native-out" -type f -name 'beagle-compiler-native' \
        -perm -0100 -print 2>/dev/null | LC_ALL=C sort
)
[[ "${#binaries[@]}" == "1" ]] ||
    die "expected one complete native artifact under projection/native-out, found ${#binaries[@]}"
binary="${binaries[0]}"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/beagle-stage1-package.XXXXXX")"
cleanup() {
    local rc=$?
    rm -rf "${tmp:?}"
    return "$rc"
}
trap cleanup EXIT

records="$tmp/records"
{
    printf 'beagle-compiler-native-provenance/v1\n'
    printf 'projection commit=%s\n' "$projection_commit"
    printf 'input closure-manifest self-host/full-compiler-closure.manifest sha256:%s\n' \
        "$(sha256_file "$manifest")"
    printf 'input toolchain-file flake.lock sha256:%s\n' "$(sha256_file "$lock")"
    for name in "${projected_sources[@]}"; do
        printf 'input projection source/selfhost/%s sha256:%s\n' "$name" \
            "$(sha256_file "$projection/source/selfhost/$name")"
    done
    for name in "${core_names[@]}"; do
        printf 'input native-core native-core/src/native/%s.bclj sha256:%s\n' "$name" \
            "$(sha256_file "$source_root/native-core/src/native/$name.bclj")"
    done
    for name in "${driver_names[@]}"; do
        printf 'input driver %s sha256:%s\n' "$name" "$(sha256_file "$source_root/$name")"
    done
} >"$records"

projection_tree="$(LC_ALL=C sort "$records" | sha256sum | awk '{print $1}')"
artifact_sha="$(sha256_file "$binary")"

install -m 0755 "$binary" "$out/bin/beagle-compiler-native"
{
    sed -n '1p' "$records"
    sed -n '2,$p' "$records" | LC_ALL=C sort
    printf 'projection-tree-sha256 sha256:%s\n' "$projection_tree"
    printf 'artifact-sha256 sha256:%s\n' "$artifact_sha"
} >"$out/bin/beagle-compiler-native.provenance"
chmod 0444 "$out/bin/beagle-compiler-native.provenance"

printf 'stage1-package: projection=%s artifact-sha256=sha256:%s\n' \
    "$projection_commit" "$artifact_sha" >&2
