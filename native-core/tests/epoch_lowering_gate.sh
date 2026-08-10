#!/usr/bin/env bash
# Gates lower-epoch-stage, the compiler pass (native-core/analysis/epoch/ is a
# different thing, gated by epoch_stage_gate.sh).
#
#   G2  derived assignment: the rewritten fixture programs keep all nine
#       obligations green under an honest digest change, and the mint fixture
#       forces the mint-retarget-close path.
#   G3  identity assignment: the stage is a relabelling and nothing else, so
#       every materializer downstream of it emits the same bytes it emitted
#       before the stage existed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

command -v bb >/dev/null 2>&1 || { echo "epoch_lowering_gate.sh: babashka (bb) is required" >&2; exit 2; }

work="$(mktemp -d)"
cleanup() { rm -rf "${work:?}"; }
trap cleanup EXIT

mkdir -p "$work/src/native"
for name in core stages lower obligations; do
  cp "$repo/native-core/src/native/$name.bclj" "$work/src/native/$name.bclj"
done

BEAGLE_OUT="$work/out" "$repo/bin/beagle" build "$work"/src/native/*.bclj \
  > "$work/build.log" 2>&1 || { cat "$work/build.log" >&2; exit 1; }

# See native-core/validation/slice-fold/drive.sh: cross-module `match` on an
# imported union emits an unqualified variant name, so each consumer module
# re-exports native.core's records under :refer :all as a standing workaround.
records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' "$work/out/native/core.clj" | tr '\n' ' ')"
for m in stages lower obligations; do
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' "$work/out/native/$m.clj"
  awk -v imp="(import '[native.core $records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' \
    "$work/out/native/$m.clj" > "$work/out/native/$m.clj.tmp"
  mv "$work/out/native/$m.clj.tmp" "$work/out/native/$m.clj"
done

report="$work/report.edn"
bb -cp "$work/out" -e "
(require 'native.lower)
(def ns (find-ns 'native.lower))
(doseq [n ['epoch-stage-fixture-passes? 'epoch-stage-fold-passes?
           'epoch-stage-mint-passes? 'epoch-stage-nested-mint-passes?
           'epoch-stage-no-arena-refusal-passes?
           'epoch-identity-fixture-passes? 'epoch-identity-fold-passes?
           'epoch-identity-mint-passes? 'epoch-identity-nested-passes?]]
  (println (pr-str [n (deref (ns-resolve ns n))])))
" > "$report"

status=0
echo "=== epoch lowering gate (G2 derived, G3 identity) ==="
while IFS= read -r line; do
  name="$(echo "$line" | sed -nE "s/^\[([a-zA-Z0-9?!*+._-]+) (true|false)\]$/\1/p")"
  value="$(echo "$line" | sed -nE "s/^\[([a-zA-Z0-9?!*+._-]+) (true|false)\]$/\2/p")"
  if [ "$value" = "true" ]; then
    printf 'PASS  %s\n' "$name"
  else
    printf 'FAIL  %s\n' "$name"
    status=1
  fi
done < "$report"

if [ "$status" -ne 0 ]; then
  echo "epoch_lowering_gate.sh: the epoch stage did not hold its assignment contract" >&2
fi
exit "$status"
