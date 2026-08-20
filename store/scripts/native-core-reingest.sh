#!/usr/bin/env bash
# native-core-reingest.sh — offline graph re-ingest coverage run over a SCRATCH
# corpus copy. Never touches a live space, a production log, or the source tree.
#   scripts/native-core-reingest.sh [--src <dir-or-file>]...
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
BEAGLE_HOME="${BEAGLE_HOME:-$HOME/code/beagle/main}"
BEAGLE="${BEAGLE_STORE_BEAGLE:-$BEAGLE_HOME/bin/beagle}"
SRCS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRCS+=("${2:?--src needs a path}"); shift 2;;
    *) echo "native-core-reingest: unknown argument $1" >&2; exit 2;;
  esac
done
[[ "${#SRCS[@]}" -gt 0 ]] || SRCS=("$HOME/code/beagle/main/native-core/src/native")

SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/store-native-reingest-XXXXXX")"
SPACE_ID="native-core-reingest-scratch-$$"
CODE_LOG="$SCRATCH_ROOT/code.storelog"
SCRATCH_SRC="$SCRATCH_ROOT/src"
MANIFEST="$SCRATCH_ROOT/modules.tsv"
SERVER_PID=""

reap() {
  local status=$?
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    for _ in $(seq 1 40); do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 0.25
    done
    kill -9 "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ "${BEAGLE_STORE_REINGEST_KEEP:-0}" != "1" ]]; then
    rm -rf "${SCRATCH_ROOT:?}"
  else
    echo "reingest: scratch kept at $SCRATCH_ROOT" >&2
  fi
  exit "$status"
}
trap reap EXIT

free_port() {
  local p
  for _ in $(seq 1 200); do
    p=$(( (RANDOM % 20000) + 40000 ))
    ss -ltn 2>/dev/null | grep -q ":$p " || { echo "$p"; return 0; }
  done
  echo "reingest: no free scratch port" >&2
  return 1
}
PORT="$(free_port)"

echo "reingest: scratch=$SCRATCH_ROOT space=$SPACE_ID port=$PORT"
mkdir -p "$SCRATCH_SRC" "$SCRATCH_ROOT/rendered"
: >"$MANIFEST"
FILES=()
for s in "${SRCS[@]}"; do
  if [[ -d "$s" ]]; then
    while IFS= read -r f; do FILES+=("$f"); done < <(
      find "$s" -maxdepth 1 -regextype posix-extended \
        -regex '.*\.b(clj|js|nix|gl)$' | sort)
  elif [[ -f "$s" ]]; then
    FILES+=("$s")
  else
    echo "reingest: no such source $s" >&2; exit 1
  fi
done
[[ "${#FILES[@]}" -gt 0 ]] || { echo "reingest: no Beagle source found" >&2; exit 1; }

# Flat scratch copies: beagle-store-ingest-code derives the module name from the path
# relative to --root, so a flat dir keeps module names equal to basenames.
COPIES=()
for f in "${FILES[@]}"; do
  base="$(basename "$f")"
  mod="${base%.*}"
  [[ -e "$SCRATCH_SRC/$base" ]] && { echo "reingest: module name collision on $base" >&2; exit 1; }
  cp "$f" "$SCRATCH_SRC/$base"
  cmp -s "$f" "$SCRATCH_SRC/$base" || { echo "reingest: scratch copy diverged for $f" >&2; exit 1; }
  printf '%s\t%s\t%s\n' "$mod" "$f" "$SCRATCH_SRC/$base" >>"$MANIFEST"
  COPIES+=("$SCRATCH_SRC/$base")
done

echo "  [1/3] ingesting ${#COPIES[@]} module(s) -> $CODE_LOG"
( cd "$HERE" && BEAGLE_HOME="$BEAGLE_HOME" BEAGLE_STORE_BEAGLE="$BEAGLE" \
    bin/beagle-store-ingest-code "${COPIES[@]}" \
      --root "$SCRATCH_SRC" --out "$CODE_LOG" --space-id "$SPACE_ID" )

echo "  [2/3] booting scratch server on :$PORT"
( cd "$HERE" && exec env -u BEAGLE_STORE_TELEMETRY_LOG BEAGLE_HOME="$BEAGLE_HOME" \
    bin/beagle-store-server serve "$PORT" "$CODE_LOG" "$SPACE_ID" \
    >"$SCRATCH_ROOT/server-$PORT.log" 2>&1 ) &
SERVER_PID=$!
for _ in $(seq 1 480); do
  grep -q "listening on" "$SCRATCH_ROOT/server-$PORT.log" 2>/dev/null && break
  kill -0 "$SERVER_PID" 2>/dev/null || {
    echo "reingest: server exited" >&2
    tail -n 20 "$SCRATCH_ROOT/server-$PORT.log" >&2 || true
    exit 1
  }
  sleep 0.5
done
grep -q "listening on" "$SCRATCH_ROOT/server-$PORT.log" || {
  echo "reingest: server never listened" >&2
  tail -n 20 "$SCRATCH_ROOT/server-$PORT.log" >&2 || true
  exit 1
}

echo "  [3/4] round-tripping every module through the landed reader"
( cd "$HERE" && BEAGLE_STORE_BEAGLE="$BEAGLE" \
    bb -cp out scripts/native_core_reingest_probe.clj \
      "$PORT" "$SPACE_ID" "$SCRATCH_ROOT" "$MANIFEST" )

# Attribution: the same emit/render pair WITHOUT the graph. A module that
# diverges here too is a Beagle-projection gap, not a Beagle Store graph-pipeline gap.
echo
echo "  [4/4] attribution — graph path vs bare beagle facts-roundtrip"
mkdir -p "$SCRATCH_ROOT/direct"
while IFS=$'\t' read -r mod orig copy; do
  [[ -n "$mod" ]] || continue
  "$BEAGLE" facts-roundtrip --emit-edn "$copy" >"$SCRATCH_ROOT/direct/$mod.edn" 2>/dev/null
  "$BEAGLE" facts-roundtrip --render "$SCRATCH_ROOT/direct/$mod.edn" \
    >"$SCRATCH_ROOT/direct/$mod.rendered" 2>/dev/null
  if cmp -s "$SCRATCH_ROOT/direct/$mod.rendered" "$SCRATCH_ROOT/rendered/$mod.rendered"; then
    attribution="graph-path==beagle-direct (divergence is upstream of Beagle Store)"
  else
    attribution="GRAPH-PATH ADDS DIVERGENCE"
  fi
  if cmp -s "$orig" "$copy"; then drift=""; else drift="  [SOURCE DRIFTED MID-RUN]"; fi
  printf '  %-26s %s%s\n' "$mod" "$attribution" "$drift"
done <"$MANIFEST"
