#!/usr/bin/env bash
# Durable sole-writer comparison. Scratch files only; no live Beagle Store port/log.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SIZES="${BENCH_SIZES:-3000,30000}"
RUNS="${BENCH_RUNS:-2}"
ADAPTERS="${BENCH_ADAPTERS:-store,sqlite}"
OUTPUT="${BENCH_OUTPUT:-$(mktemp /tmp/store-in-class.XXXXXX.jsonl)}"
META="${BENCH_META_OUTPUT:-${OUTPUT%.jsonl}.meta}"

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || {
  echo "BENCH_RUNS must be a positive integer" >&2
  exit 2
}
: >"$OUTPUT"
{
  printf 'started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'revision=%s\n' "$(git -C "$ROOT" rev-parse HEAD)"
  printf 'kernel=%s\n' "$(uname -srmo)"
  printf 'nproc=%s\n' "$(nproc)"
  printf 'cpu_model=%s\n' "$(lscpu | sed -n 's/^Model name:[[:space:]]*//p')"
  printf 'mem_total=%s\n' "$(sed -n 's/^MemTotal:[[:space:]]*//p' /proc/meminfo)"
  printf 'python=%s\n' "$(python3 --version 2>&1)"
  printf 'sqlite=%s\n' "$(sqlite3 --version)"
  printf 'rdf4j_nativestore=%s\n' \
    'org.eclipse.rdf4j/rdf4j-sail-nativerdf:4.3.11 forceSync=true'
  printf 'start_load=%s\n' "$(cat /proc/loadavg)"
  printf 'sizes=%s\n' "$SIZES"
  printf 'runs=%s\n' "$RUNS"
} >"$META"

run_adapter() {
  local adapter="$1" size="$2" run="$3" raw row
  case "$adapter" in
    store)
      # JVM, not bb: server.clj is explicitly a JVM-only server (see its
      # header comment); bb's interpreter overhead swamps op timings.
      raw="$(cd "$ROOT" && clojure -M "$HERE/adapters/store.clj" "$size" "$run")"
      ;;
    sqlite)
      raw="$(python3 "$HERE/adapters/sqlite.py" "$size" "$run")"
      ;;
    rdf4j-nativestore)
      raw="$(cd "$ROOT" && clojure -M:bench-rdf4j \
        "$HERE/adapters/rdf4j.clj" "$size" "$run")"
      ;;
    *)
      echo "unknown adapter: $adapter" >&2
      return 2
      ;;
  esac
  printf '%s\n' "$raw" >&2
  row="$(sed -n 's/^BENCHROW //p' <<<"$raw")"
  [[ "$(wc -l <<<"$row")" -eq 1 && -n "$row" ]] || {
    echo "$adapter emitted zero or multiple BENCHROW records" >&2
    return 1
  }
  printf '%s\n' "$row" >>"$OUTPUT"
}

IFS=',' read -r -a sizes <<<"$SIZES"
IFS=',' read -r -a adapters <<<"$ADAPTERS"
for size in "${sizes[@]}"; do
  [[ "$size" =~ ^[1-9][0-9]*$ && $((size % 3)) -eq 0 ]] || {
    echo "each BENCH_SIZES value must be a positive multiple of 3 live triples: $size" >&2
    exit 2
  }
  for run in $(seq 1 "$RUNS"); do
    if (( run % 2 == 0 )); then
      for ((index=${#adapters[@]} - 1; index >= 0; index--)); do
        adapter="${adapters[$index]}"
        echo "running adapter=$adapter corpus-triples=$size run=$run" >&2
        run_adapter "$adapter" "$size" "$run"
      done
    else
      for adapter in "${adapters[@]}"; do
        echo "running adapter=$adapter corpus-triples=$size run=$run" >&2
        run_adapter "$adapter" "$size" "$run"
      done
    fi
  done
done

bb "$HERE/report.bb" "$OUTPUT"
{
  printf 'ended_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'end_load=%s\n' "$(cat /proc/loadavg)"
} >>"$META"
echo "raw-results=$OUTPUT" >&2
echo "metadata=$META" >&2
