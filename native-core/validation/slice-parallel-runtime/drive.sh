#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"

if [[ "${BEAGLE_PARALLEL_RUNTIME_BOUNDED:-0}" != "1" ]]; then
  source "$repo/bin/_beagle-racket"
  supervisor="$repo/native-core/bin/run-bounded.rkt"
  command -v unshare >/dev/null 2>&1 || {
    echo "parallel-runtime fixture: util-linux unshare is required" >&2
    exit 2
  }
  [[ -f "$supervisor" ]] || {
    echo "parallel-runtime fixture: shared bounded supervisor is unavailable" >&2
    exit 2
  }
  receipt="$(mktemp "${TMPDIR:-/tmp}/parallel-runtime-receipt.XXXXXX")"
  trap 'rm -f -- "$receipt"' EXIT
  if BEAGLE_PARALLEL_RUNTIME_BOUNDED=1 \
      BEAGLE_BOUNDED_COMPLETION_RECEIPT="$receipt" \
      unshare --user --map-current-user --pid --fork --kill-child \
        --forward-signals "$RACKET" "$supervisor" 30 5 -- "$0"; then
    rc=0
  else
    rc=$?
  fi
  grep -Fqx "subtree-reaped-v0 exit status=$rc" "$receipt" || {
    echo "parallel-runtime fixture: supervisor did not reap its subtree" >&2
    exit 125
  }
  exit "$rc"
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-parallel-runtime.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT
echo "parallel-runtime fixture: compile START"
gcc -std=c17 -pedantic -Wall -Wextra -Werror -pthread -ffp-contract=off \
  -I "$repo/native-core/shim" \
  "$repo/native-core/shim/native_shim.c" \
  "$repo/native-core/shim/native_parallel.c" \
  "$here/main.c" -o "$scratch/parallel-runtime"
echo "parallel-runtime fixture: execute START"
"$scratch/parallel-runtime"
