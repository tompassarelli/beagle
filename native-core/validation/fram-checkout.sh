#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ref_file="$here/fram.ref"

[[ -f "$ref_file" ]] || {
  echo "fram-checkout: missing ref: $ref_file" >&2
  exit 1
}
IFS= read -r fram_ref <"$ref_file"
[[ "$fram_ref" =~ ^[0-9a-f]{40}$ ]] || {
  echo "fram-checkout: ref must be one full lowercase Git object ID" >&2
  exit 1
}

if [[ -n "${FRAM_CHECKOUT:-}" ]]; then
  checkout="$FRAM_CHECKOUT"
else
  checkout="${HOME:?}/code/fram/pins/$fram_ref"
fi
[[ -d "$checkout" ]] || {
  echo "fram-checkout: checkout is unavailable: $checkout" >&2
  exit 1
}
checkout="$(cd "$checkout" && pwd -P)"
actual="$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)"
[[ "$actual" == "$fram_ref" ]] || {
  echo "fram-checkout: expected $fram_ref, found ${actual:-no Git HEAD}" >&2
  exit 1
}

printf '%s\n' "$checkout"
