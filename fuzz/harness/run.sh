#!/usr/bin/env bash
# fuzz/harness/run.sh — differential fuzzing harness entry point.
#
# Usage:
#   fuzz/harness/run.sh <corpus-dir> <out-dir> [--target clj|js|nix] [--jobs N]
#
# Env overrides:
#   FUZZ_SELFHOST_BIN — path to the self-hosted compiler binary
#                       (default: auto-detect native binary, fall back to bb)
#
# Output:
#   <out-dir>/report.edn          — summary + divergence list
#   <out-dir>/repros/<sig>.<ext>  — shrunk repro per unique divergence signature

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BEAGLE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Parse arguments ──────────────────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
  echo "usage: $0 <corpus-dir> <out-dir> [--target clj|js|nix] [--jobs N]" >&2
  exit 1
fi

CORPUS_DIR="$1"
OUT_DIR="$2"
shift 2

TARGET="clj"
JOBS="$(nproc 2>/dev/null || echo 4)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --jobs)   JOBS="$2";   shift 2 ;;
    *)        echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ─── Racket env ───────────────────────────────────────────────────────────────
# shellcheck disable=SC1090
source "$BEAGLE_ROOT/bin/_beagle-racket"
# $RACKET is now set to the pinned Racket 9.1 binary.

# ─── Locate self-hosted binary ────────────────────────────────────────────────
SELFHOST_BIN="${FUZZ_SELFHOST_BIN:-}"

if [[ -z "$SELFHOST_BIN" ]]; then
  # Try local worktree first, then the main git checkout
  MAIN_ROOT="$(git -C "$BEAGLE_ROOT" worktree list --porcelain 2>/dev/null | awk 'NR==1{print $2}')"
  for candidate in \
      "$BEAGLE_ROOT/self-host/native/beagle-selfhost" \
      "${MAIN_ROOT:-}/self-host/native/beagle-selfhost"; do
    if [[ -x "$candidate" ]]; then
      SELFHOST_BIN="$candidate"
      break
    fi
  done
fi

if [[ -z "$SELFHOST_BIN" ]]; then
  echo "run.sh: native selfhost binary not found; falling back to bb seed (slower)" >&2
  SELFHOST_BIN="bb_fallback"
fi

echo "run.sh: oracle=$RACKET"
echo "run.sh: selfhost=$SELFHOST_BIN"
echo "run.sh: target=$TARGET  corpus=$CORPUS_DIR  out=$OUT_DIR  jobs=$JOBS"

# ─── Prepare output directory ─────────────────────────────────────────────────
mkdir -p "$OUT_DIR" "$OUT_DIR/repros"

# ─── Run harness ──────────────────────────────────────────────────────────────
exec bb "$SCRIPT_DIR/harness.clj" \
  --corpus      "$CORPUS_DIR"  \
  --out         "$OUT_DIR"     \
  --jobs        "$JOBS"        \
  --target      "$TARGET"      \
  --beagle-root "$BEAGLE_ROOT" \
  --racket      "$RACKET"      \
  --selfhost-bin "$SELFHOST_BIN"
