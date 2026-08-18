#!/usr/bin/env bash
# Native primary for the source-freeze path validation.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$repo/native-core/validation/native-compiler-route.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/native-source-freeze-selected.XXXXXX")"
trap 'rm -rf "${work:?}"' EXIT

native_bin=""
native_validation_select_binary native_bin || exit $?
compiler_deadline="${BEAGLE_NATIVE_VALIDATION_COMPILER_DEADLINE_SECONDS:-120}"
receipts="${BEAGLE_NATIVE_VALIDATION_RECEIPT_DIR:-$work/receipts}"

run_case() {
  local label="$1" cwd="$2"
  local case_dir="$work/$label"
  local store_checkout source_path module_root
  mkdir -p "$case_dir/artifacts"
  printf 'source-freeze path case %s: START from %s\n' "$label" "$cwd"
  store_checkout="$("$repo/native-core/validation/store-checkout.sh")"
  source_path="$store_checkout/src/fram/types.bgl"
  module_root="store/src=$store_checkout/src"
  [[ -f "$source_path" ]] || {
    echo "source_freeze_native.sh: Store source is missing: $source_path" >&2
    return 1
  }
  (
    cd "$cwd"
    native_validation_run_phase "source-freeze-$label" "$compiler_deadline" "$receipts" \
      env -u BEAGLE_NATIVE_COMPILER_BIN "$native_bin" \
        --materializer c17 --module-root "$module_root" \
        --out "$case_dir/artifacts" "$source_path"
  )
  grep -Fx 'stage source-freeze ACCEPTED' "$case_dir/artifacts/report.txt"
  printf 'source-freeze path case %s: ACCEPTED from %s\n' "$label" "$cwd"
}

run_case repo "$repo"
run_case tmp /tmp
