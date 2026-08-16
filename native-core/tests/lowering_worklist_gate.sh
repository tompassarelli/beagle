#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

# Cached gate: the complete two-process equality run is keyed on its exact
# compiler and corpus closure. BEAGLE_GATE_NO_CACHE=1 forces execution.
if [[ -z "${BEAGLE_GATE_CACHE_INNER:-}" && -x "$repo/bin/_gate-cache-run" ]]; then
  exec "$repo/bin/_gate-cache-run" --domain native-gates \
    --id "$(basename "$0")${1:+ $*}" -- "$0" "$@"
fi

command -v bb >/dev/null 2>&1 || {
  echo "lowering_worklist_gate.sh: babashka (bb) is required" >&2
  exit 2
}

work="$(mktemp -d "${TMPDIR:-/tmp}/native-lowering-worklist.XXXXXX")"
cleanup() { rm -rf "${work:?}"; }
trap cleanup EXIT

mkdir -p "$work/src/native" "$work/run-one" "$work/run-two"
modules=(core stages lower obligations lowering_worklist_validation_corpus)
for name in "${modules[@]}"; do
  cp "$repo/native-core/src/native/$name.bclj" "$work/src/native/$name.bclj"
done

echo "lowering_worklist_gate.sh: phase build"
timeout --foreground 240s env BEAGLE_OUT="$work/out" \
  "$repo/bin/beagle" build "$work"/src/native/*.bclj \
  > "$work/build.log" 2>&1 || {
    sed -n '1,260p' "$work/build.log" >&2
    exit 1
  }

# Cross-module matches and records use the same emitted-Clojure import repair
# as the existing Native validation drivers.
records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
  "$work/out/native/core.clj" | tr '\n' ' ')"
for module in "${modules[@]}"; do
  [[ "$module" == core ]] && continue
  module_path="$work/out/native/$module.clj"
  [[ -f "$module_path" ]] || continue
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$module_path"
  awk -v import_form="(import '[native.core $records])" \
    '!seen && /^$/ { print import_form; seen = 1 } { print }' \
    "$module_path" > "$module_path.tmp"
  mv "$module_path.tmp" "$module_path"
done

run_corpus() {
  local destination="$1"
  timeout --foreground 120s bb -cp "$work/out" -e "
(require 'native.lowering-worklist-validation-corpus)
(def corpus-ns (find-ns 'native.lowering-worklist-validation-corpus))
(def run ((deref (ns-resolve corpus-ns 'run-worklist-gate))))
(spit \"$destination/metrics.txt\"
  ((deref (ns-resolve corpus-ns 'gate-metrics)) run))
(spit \"$destination/reference.bin\" (get run :reference-artifacts))
(spit \"$destination/optimized.bin\" (get run :optimized-artifacts))
(when-not ((deref (ns-resolve corpus-ns 'gate-passes?)) run)
  (throw (ex-info \"lowering worklist corpus failed\" {})))
"
}

echo "lowering_worklist_gate.sh: phase corpus-run-one"
run_corpus "$work/run-one"
echo "lowering_worklist_gate.sh: phase corpus-run-two"
run_corpus "$work/run-two"

cmp "$work/run-one/reference.bin" "$work/run-one/optimized.bin"
cmp "$work/run-two/reference.bin" "$work/run-two/optimized.bin"
cmp "$work/run-one/reference.bin" "$work/run-two/reference.bin"
cmp "$work/run-one/optimized.bin" "$work/run-two/optimized.bin"
cmp "$work/run-one/metrics.txt" "$work/run-two/metrics.txt"

report="$work/run-one/metrics.txt"
cat "$report"
grep -Fxq "function-count 256" "$report"
grep -Fxq "call-edge-count 366" "$report"
grep -Fxq "effect-kind-count 12" "$report"
grep -Fxq "reference-equals-optimized true" "$report"
grep -Fxq "unaffected-component-unchanged true" "$report"
grep -Fxq "readiness-closure-correct true" "$report"
grep -Fxq "effect-closure-correct true" "$report"
grep -Fxq "mixed-closure-correct true" "$report"
grep -Fxq "bounds-hold true" "$report"
grep -Fxq "gate-passes true" "$report"

readiness_visits="$(awk '$1 == "readiness-edge-visits" { print $2 }' "$report")"
effect_visits="$(awk '$1 == "effect-edge-visits" { print $2 }' "$report")"
total_visits="$(awk '$1 == "total-edge-visits" { print $2 }' "$report")"
[[ "$readiness_visits" -le 366 ]]
[[ "$effect_visits" -le 4392 ]]
[[ "$total_visits" -le 4758 ]]

echo "lowering_worklist_gate.sh: deterministic worklist closure PASS"
