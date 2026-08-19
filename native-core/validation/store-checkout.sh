#!/usr/bin/env bash
# Resolve the Beagle Store root the validation gates compile against, and prove
# it is the exact revision store.ref names rather than whatever a working tree
# currently holds.
#
# The Store is tracked in this repository at store/, so the pinned revision is a
# Beagle object and the checkout is a Beagle pin. BEAGLE_STORE_CHECKOUT
# overrides the location but not the hash proof, and names the Store root — the
# directory holding src/ and out/ — in both cases.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ref_file="$here/store.ref"

[[ -f "$ref_file" ]] || {
  echo "store-checkout: missing ref: $ref_file" >&2
  exit 1
}
IFS= read -r store_ref <"$ref_file"
[[ "$store_ref" =~ ^[0-9a-f]{40}$ ]] || {
  echo "store-checkout: ref must be one full lowercase Git object ID" >&2
  exit 1
}

if [[ -n "${BEAGLE_STORE_CHECKOUT:-}" ]]; then
  checkout="$BEAGLE_STORE_CHECKOUT"
else
  checkout="${HOME:?}/code/beagle/pins/$store_ref/store"
fi
[[ -d "$checkout" ]] || {
  echo "store-checkout: checkout is unavailable: $checkout" >&2
  exit 1
}
checkout="$(cd "$checkout" && pwd -P)"
actual="$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)"
[[ "$actual" == "$store_ref" ]] || {
  echo "store-checkout: expected $store_ref, found ${actual:-no Git HEAD}" >&2
  exit 1
}

printf '%s\n' "$checkout"
