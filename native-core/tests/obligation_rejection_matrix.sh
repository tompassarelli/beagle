#!/usr/bin/env bash
# Evaluates every obligations.bclj fixture (positive + all negatives) via a
# bb-hosted clj build and reports each corrupt program's rejection tag.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

command -v bb >/dev/null 2>&1 || { echo "obligation_rejection_matrix.sh: babashka (bb) is required" >&2; exit 2; }

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
(require 'native.obligations)
(def ns (find-ns 'native.obligations))
(def fixtures
  ['valid-ssa-negative 'exhaustive-matches-negative 'closed-layouts-negative
   'checked-arithmetic-negative 'legal-abi-negative 'discharged-tokens-negative
   'bounded-effects-negative 'epoch-soundness-negative 'leak-freedom-negative
   'valid-ssa-negative-sibling 'valid-ssa-negative-jump-mismatch
   'exhaustive-matches-negative-duplicate 'exhaustive-matches-negative-unknown-variant
   'closed-layouts-negative-zero-size 'closed-layouts-negative-misaligned-offset
   'checked-arithmetic-negative-raw-consume 'checked-arithmetic-negative-non-outcome
   'legal-abi-negative-result-mismatch 'legal-abi-negative-missing-capability
   'discharged-tokens-negative-leak 'discharged-tokens-negative-phantom-consume
   'bounded-effects-negative-undeclared-region 'bounded-effects-negative-unbounded-call
   'epoch-soundness-negative-return-young 'epoch-soundness-negative-call-young
   'epoch-soundness-negative-atom-young-store
   'epoch-soundness-negative-call-promote-atom-escape
   'epoch-soundness-negative-call-promote-young-use
   'epoch-soundness-negative-extern-promote-return
   'epoch-soundness-positive-atom-root-store
   'epoch-soundness-positive-atom-promoted-store
   'epoch-soundness-positive-call-promoted-result
   'epoch-soundness-positive-extern-promoted-result
   'leak-freedom-negative-lifo 'leak-freedom-negative-double-close])
(doseq [n fixtures]
  (println (pr-str [n (deref (ns-resolve ns n))])))
(println (pr-str ['nine-valid-passes? (deref (ns-resolve ns 'nine-valid-passes?))]))
(println (pr-str ['nine-negatives-named? (deref (ns-resolve ns 'nine-negatives-named?))]))
(println (pr-str ['twenty-two-rejection-depth-fixtures-named?
                  (deref (ns-resolve ns 'twenty-two-rejection-depth-fixtures-named?))]))
" > "$report"

status=0
echo "=== obligation rejection-depth matrix ==="
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
  echo "obligation_rejection_matrix.sh: one or more fixtures did not reject with the expected diagnostic" >&2
fi
exit "$status"
