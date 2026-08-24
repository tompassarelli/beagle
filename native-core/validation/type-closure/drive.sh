#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-type-closure.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

provider="$here/provider.bgl"
consumer="$here/consumer.bgl"
bundle="$scratch/source.bundle.json"
consumer_ast="$scratch/consumer.ast.json"
consumer_interface="$scratch/consumer.interface.sha256"
facts="$scratch/consumer.facts.manifest"
compiled="$scratch/compiled"

"$repo/bin/beagle" check --agent "$provider" "$consumer"
"$repo/bin/beagle-ast" --bundle -- "$provider" "$consumer" >"$bundle"

bb -e '
  (require (quote [cheshire.core :as json]))
  (let [bundle (json/parse-string (slurp (first *command-line-args*)))
        matches (filterv
                  (fn [module]
                    (= "native.type-closure-consumer"
                      (get-in module ["program" "namespace"])))
                  (get bundle "modules"))]
    (when-not (= 1 (count matches))
      (throw (ex-info "checked bundle did not contain exactly one consumer"
               {:matches (count matches)})))
    (let [consumer (nth matches 0)]
      (spit (second *command-line-args*)
        (json/generate-string (get consumer "program")))
      (spit (nth *command-line-args* 2)
        (str (get consumer "interfaceSha256") "\n"))))' \
  "$bundle" "$consumer_ast" "$consumer_interface"

consumer_path="native-core/validation/type-closure/consumer.bgl"
interface_sha256="$(<"$consumer_interface")"
bb "$repo/native-core/bin/source-facts.clj" \
  --input "$consumer_ast=$consumer_path" \
  --interface-sha256 "$consumer_path=$interface_sha256" \
  --output "$facts" --include-defs

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
  "$repo/native-core/src/native/simd.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
  "$repo/native-core/src/native/lower.bclj" \
  "$repo/native-core/src/native/c11.bclj" \
  "$repo/native-core/src/native/slice.bclj" \
  --out "$compiled" >"$scratch/build.log" 2>&1 || {
    sed -n '1,240p' "$scratch/build.log" >&2
    exit 1
  }

bb -cp "$compiled" -e '
  (require (quote [native.core :as core])
           (quote [native.lower :as lower])
           (quote [native.slice :as slice])
           (quote [native.stages :as stages]))
  (let [rows (slice/read-fact-manifest (first *command-line-args*))
        source (slice/source-program rows "native.type-closure-consumer"
                 "native-core/validation/type-closure/consumer.bgl")
        configuration ["profile=3"]
        frozen (lower/sourcefreezeacceptedv0-frozen
                 (lower/freeze-source-stage source "type-closure-v0"
                   configuration))
        result (lower/lower-typed-stage frozen "type-closure-v0"
                 configuration)]
    (when-not (instance? native.lower.TypingRejectedV0 result)
      (throw (ex-info "unclosed imported record type was accepted"
               {:result result})))
    (let [receipt (lower/typingrejectedv0-receipt result)
          obligations
          (filterv
            (fn [obligation]
              (instance? native.core.ClosedLayoutsObligation
                (core/receiptobligationv0-code obligation)))
            (core/passreceiptv0-obligations receipt))
          diagnostics (core/passreceiptv0-diagnostics receipt)
          consumer-key "native.type-closure-consumer/Consumer"
          consumer-id (lower/source-type-id consumer-key)
          external-id
          (lower/source-type-id "native.type-closure-provider/External")
          expected-detail
          (stages/canonical-record "lower-type-closure-v0"
            [(stages/canonical-record "closed-type-v0"
               [(core/nativeid-value consumer-id)
                "Consumer"
                (stages/canonical-record "record"
                  [(stages/canonical-record "field"
                     [(core/nativeid-value
                        (lower/field-id consumer-key "foreign"))
                      "foreign"
                      (core/nativeid-value external-id)])])])
             (stages/canonical-set "missing-type-ids"
               [(core/nativeid-value external-id)])])]
      (when-not (and (= 1 (count obligations))
                  (false? (core/receiptobligationv0-passed
                            (nth obligations 0))))
        (throw (ex-info "ClosedLayoutsObligation did not fail exactly once"
                 {:obligations obligations})))
      (when-not (and (= 1 (count diagnostics))
                  (= "LOWER-TYPE-CLOSURE"
                    (core/diagnosticv0-code (nth diagnostics 0)))
                  (= expected-detail
                    (core/diagnosticv0-detail (nth diagnostics 0))))
        (throw (ex-info "type closure diagnostic changed"
                 {:expected-code "LOWER-TYPE-CLOSURE"
                  :expected-detail expected-detail
                  :diagnostics diagnostics})))))' "$facts"

echo "type-closure: imported missing TypeDef rejected with canonical diagnostic PASS"
