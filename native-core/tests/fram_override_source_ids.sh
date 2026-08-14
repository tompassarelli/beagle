#!/usr/bin/env bash
# A live Fram override has its own checked-AST source identity. Prove each
# driver carries that identity from projection into source freeze instead of
# silently substituting the vendored path.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
source "$repo/bin/_beagle-racket"
supervisor="$repo/native-core/bin/run-bounded.rkt"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/fram-override-source-ids.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

for command in env git grep unshare; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "fram-override-source-ids: required command is unavailable: $command" >&2
    exit 2
  }
done
[[ -f "$supervisor" ]] || {
  echo "fram-override-source-ids: bounded supervisor is unavailable" >&2
  exit 2
}

run_bounded() {
  local label="$1"
  shift
  local receipt="$scratch/$label.receipt"
  local status
  if BEAGLE_BOUNDED_COMPLETION_RECEIPT="$receipt" \
      unshare --user --map-current-user --pid --fork --kill-child \
        --forward-signals "$RACKET" "$supervisor" 90 5 -- "$@"; then
    status=0
  else
    status=$?
  fi
  grep -Fqx "subtree-reaped-v0 exit status=$status" "$receipt" || {
    echo "fram-override-source-ids: $label supervisor did not reap its subtree" >&2
    exit 125
  }
  [[ "$status" -eq 0 ]]
}

override="$scratch/fram"
git -C "$scratch" init -q
mkdir -p "$override/src/fram" "$scratch/bodies" "$scratch/kernel" "$scratch/classify"
cp "$repo/native-core/validation/upstream/fram/src/fram/types.bgl" \
  "$override/src/fram/types.bgl"
cp "$repo/native-core/validation/upstream/fram/src/fram/kernel.bgl" \
  "$override/src/fram/kernel.bgl"
cp "$repo/native-core/validation/upstream/fram/src/fram/kernel_classify.bgl" \
  "$override/src/fram/kernel_classify.bgl"

run_bounded bodies env \
  FRAM_TYPES="$override/src/fram/types.bgl" \
  NATIVE_SLICE_ARTIFACTS="$scratch/bodies" \
  NATIVE_SLICE_SOURCE_ID_PROOF=1 \
  "$repo/native-core/validation/slice-bodies/drive.sh" \
  >"$scratch/bodies.log"
grep -Fqx 'slice-bodies: source-id proof PASS logical=fram/src/fram/types.bgl' \
  "$scratch/bodies.log"

run_bounded kernel env \
  FRAM_TYPES="$override/src/fram/types.bgl" \
  FRAM_KERNEL="$override/src/fram/kernel.bgl" \
  NATIVE_SLICE_ARTIFACTS="$scratch/kernel" \
  NATIVE_SLICE_SOURCE_ID_PROOF=1 \
  "$repo/native-core/validation/slice-kernel-capability/drive.sh" \
  >"$scratch/kernel.log"
grep -Fqx \
  'slice-kernel-capability: source-id proof PASS types=fram/src/fram/types.bgl kernel=fram/src/fram/kernel.bgl probe=native-core/validation/slice-kernel-capability/host_capability_probe.bgl' \
  "$scratch/kernel.log"

run_bounded classify env \
  FRAM_KERNEL_CLASSIFY="$override/src/fram/kernel_classify.bgl" \
  NATIVE_SLICE_ARTIFACTS="$scratch/classify" \
  NATIVE_SLICE_SOURCE_ID_PROOF=1 \
  "$repo/native-core/validation/slice-kernel-classify/drive.sh" \
  >"$scratch/classify.log"
grep -Fqx \
  'slice-kernel-classify: source-id proof PASS source=fram/src/fram/kernel_classify.bgl probe=native-core/validation/slice-kernel-classify/kernel_classify_probe.bgl' \
  "$scratch/classify.log"

if find "$scratch/bodies" "$scratch/kernel" "$scratch/classify" \
     -type f -print -quit | grep -q .; then
  echo "fram-override-source-ids: proof mode published artifacts" >&2
  exit 1
fi

echo "fram-override-source-ids: 3/3 logical source identities PASS"
