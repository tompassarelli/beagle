#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
needle='qualified-ref''->symbol'

if hits="$(git -C "$ROOT" grep -n -F "$needle" -- .)"; then
  printf 'qualified reference scaffold guard: forbidden tracked occurrence(s):\n%s\n' \
    "$hits" >&2
  exit 1
else
  status=$?
  if [[ $status -ne 1 ]]; then
    printf 'qualified reference scaffold guard: git grep failed (status %s)\n' \
      "$status" >&2
    exit "$status"
  fi
fi

echo "qualified reference scaffold guard: zero tracked occurrences"
