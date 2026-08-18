#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
corpus="$repo/bin/test/branch-compile-corpus/corpus"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-dev-fact-compile.XXXXXX")"
store="$scratch/dev-facts.framlog"

cleanup() {
  rm -rf -- "${scratch:?}"
}
trap cleanup EXIT

mkdir -p "$scratch/sources"
cp "$corpus/foundation.bgl" "$scratch/sources/foundation.bgl"
cp "$corpus/feature.bgl" "$scratch/sources/feature.bgl"
cp "$corpus/independent.bgl" "$scratch/sources/independent.bgl"
cp "$corpus/app.bgl" "$scratch/sources/app.bgl"

sources=(
  "$scratch/sources/foundation.bgl"
  "$scratch/sources/feature.bgl"
  "$scratch/sources/independent.bgl"
  "$scratch/sources/app.bgl"
)
entries=(
  --entry corpus.app/run-score
  --entry corpus.app/run-stable
  --entry corpus.app/run-independent
)

run_build() {
  local label="$1"
  local out="$scratch/$label"
  local log="$scratch/$label.log"
  echo "dev-fact compile: $label START"
  BEAGLE_DEV_FACT_REUSE=1 \
    BEAGLE_DEV_FACT_STORE="$store" \
    BEAGLE_CORE_OVERALL_TIMEOUT_SECONDS=220 \
    timeout --foreground 240s \
    "$repo/bin/beagle" build --materializer c17 --out "$out" \
      "${entries[@]}" "${sources[@]}" >"$log" 2>&1
  grep -Fqx 'result PASS' "$out/report.txt"
  echo "dev-fact compile: $label END"
}

compare_compile_outputs() {
  local expected="$1"
  local actual="$2"
  local artifact
  for artifact in source.facts module.native-program native.entry-map \
                  native.receipts c17.receipt module_0.c module_0.h; do
    cmp -s "$expected/$artifact" "$actual/$artifact" || {
      echo "dev-fact compile: $artifact differs between $expected and $actual" >&2
      exit 1
    }
  done
}

require_log() {
  local pattern="$1"
  local log="$2"
  if ! rg -q "$pattern" "$log"; then
    echo "dev-fact compile: missing log pattern: $pattern" >&2
    tail -n 120 "$log" >&2
    exit 1
  fi
}

run_build miss
require_log 'dev-facts mode=COLD-POPULATE hits=0 misses=18 divergences=0' \
  "$scratch/miss/report.txt"

run_build hit
require_log 'dev-facts mode=FACT-REUSE hits=18 misses=0 divergences=0' \
  "$scratch/hit/report.txt"
compare_compile_outputs "$scratch/miss" "$scratch/hit"
echo "dev-fact compile: hit serves identical output PASS"

bb -cp "$repo/store/out" "$here/tamper.clj" "$repo" "$store" \
  >"$scratch/tampered-key"
run_build divergence
require_log 'dev-facts DIVERGENCE .*fallback=cold-unit' \
  "$scratch/divergence.log"
require_log 'dev-facts mode=MIXED-DIVERGENCE hits=17 misses=0 divergences=1' \
  "$scratch/divergence/report.txt"
compare_compile_outputs "$scratch/miss" "$scratch/divergence"
echo "dev-fact compile: tampered fact falls back cold PASS"

bash "$here/gate-isolation.sh"

echo "dev-fact compile: PASS hit=18 miss=18 divergence=1 gate=cold"
