#!/usr/bin/env bash
# Keep structured query ordering and text scoping inside Beagle Native Core.
# This projects only the three public roots that previously passed hosted tests
# while blocking the full wasm-embed server closure.
set -euo pipefail
export LC_ALL=C

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
beagle="${FRAM_BEAGLE:-$(command -v beagle || true)}"
scratch="$(mktemp -d)"
cleanup() { rm -rf "${scratch:?}"; }
trap cleanup EXIT INT TERM

fail() {
  echo "fram query native closure: FAIL: $*" >&2
  exit 1
}

[[ -n "$beagle" && -x "$beagle" ]] || fail "Beagle is not on PATH"
mapfile -t sources <"$repo/native/core_closure_sources.txt"
[[ "${#sources[@]}" -gt 0 ]] || fail "native source closure is empty"

(
  cd "$repo"
  "$beagle" build --materializer c17 --out "$scratch/artifact" --abi wasm32 \
    --entry fram.query/plan-text-attribute-scope \
    --entry fram.query/term-compare \
    --entry fram.query/ordered-plan-rows \
    -- "${sources[@]}"
) >"$scratch/build.log" 2>&1 || {
  cat "$scratch/build.log" >&2
  fail "the focused native projection was rejected"
}

report="$scratch/artifact/report.txt"
[[ -s "$report" ]] || fail "the focused native projection wrote no report"
grep -Fxq 'result PASS' "$report" || fail "the focused native report did not pass"
for root in plan-text-attribute-scope term-compare ordered-plan-rows; do
  grep -Eq "^lowered fn_[0-9]+ ${root} [1-9][0-9]* blocks$" "$report" ||
    fail "the native report omitted $root"
done
grep -Fxq 'materialize-c17 OK module_0.h module_0.c' "$report" ||
  fail "the focused native C17 materializer did not finish"

printf 'fram query native closure: PASS report=%s\n' "$report"
