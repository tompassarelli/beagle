#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-type-closure.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

provider="$here/provider.bgl"
consumer="$here/consumer.bgl"
payloadless="$here/payloadless.bgl"
declared_duplicate="$here/declared_duplicate.bgl"
bundle="$scratch/source.bundle.json"
consumer_ast="$scratch/consumer.ast.json"
consumer_interface="$scratch/consumer.interface.sha256"
consumer_facts="$scratch/consumer.facts.manifest"
provider_ast="$scratch/provider.ast.json"
provider_interface="$scratch/provider.interface.sha256"
payloadless_ast="$scratch/payloadless.ast.json"
payloadless_interface="$scratch/payloadless.interface.sha256"
payloadless_facts="$scratch/payloadless.facts.manifest"
declared_duplicate_ast="$scratch/declared-duplicate.ast.json"
declared_duplicate_interface="$scratch/declared-duplicate.interface.sha256"
declared_duplicate_facts="$scratch/declared-duplicate.facts.manifest"
compiled="$scratch/compiled"

"$repo/bin/beagle" check --agent \
  "$provider" "$consumer" "$payloadless" "$declared_duplicate"
"$repo/bin/beagle-ast" --bundle -- \
  "$provider" "$consumer" "$payloadless" "$declared_duplicate" >"$bundle"

bb -e '
  (require (quote [cheshire.core :as json]))
  (let [bundle (json/parse-string (slurp (first *command-line-args*)))
        modules (get bundle "modules")
        select
        (fn [namespace]
          (let [matches (filterv
                          (fn [module]
                            (= namespace
                              (get-in module ["program" "namespace"])))
                          modules)]
            (when-not (= 1 (count matches))
              (throw (ex-info "checked bundle namespace was not unique"
                       {:namespace namespace :matches (count matches)})))
            (nth matches 0)))
        consumer (select "native.type-closure-consumer")
        payloadless (select "native.type-closure-payloadless")
        provider (select "native.type-closure-provider")
        declared-duplicate
        (select "native.type-closure-declared-duplicate")]
    (spit (nth *command-line-args* 1)
      (json/generate-string (get consumer "program")))
    (spit (nth *command-line-args* 2)
      (str (get consumer "interfaceSha256") "\n"))
    (spit (nth *command-line-args* 3)
      (json/generate-string (get payloadless "program")))
    (spit (nth *command-line-args* 4)
      (str (get payloadless "interfaceSha256") "\n"))
    (spit (nth *command-line-args* 5)
      (json/generate-string (get provider "program")))
    (spit (nth *command-line-args* 6)
      (str (get provider "interfaceSha256") "\n"))
    (spit (nth *command-line-args* 7)
      (json/generate-string (get declared-duplicate "program")))
    (spit (nth *command-line-args* 8)
      (str (get declared-duplicate "interfaceSha256") "\n")))' \
  "$bundle" "$consumer_ast" "$consumer_interface" \
  "$payloadless_ast" "$payloadless_interface" \
  "$provider_ast" "$provider_interface" \
  "$declared_duplicate_ast" "$declared_duplicate_interface"

consumer_path="native-core/validation/type-closure/consumer.bgl"
interface_sha256="$(<"$consumer_interface")"
bb "$repo/native-core/bin/source-facts.clj" \
  --input "$consumer_ast=$consumer_path" \
  --interface-sha256 "$consumer_path=$interface_sha256" \
  --output "$consumer_facts" --include-defs

payloadless_path="native-core/validation/type-closure/payloadless.bgl"
payloadless_interface_sha256="$(<"$payloadless_interface")"
provider_path="native-core/validation/type-closure/provider.bgl"
provider_interface_sha256="$(<"$provider_interface")"
bb "$repo/native-core/bin/source-facts.clj" \
  --input "$provider_ast=$provider_path" \
  --input "$payloadless_ast=$payloadless_path" \
  --interface-sha256 "$provider_path=$provider_interface_sha256" \
  --interface-sha256 "$payloadless_path=$payloadless_interface_sha256" \
  --output "$payloadless_facts" --include-defs

declared_duplicate_path="native-core/validation/type-closure/declared_duplicate.bgl"
declared_duplicate_interface_sha256="$(<"$declared_duplicate_interface")"
bb "$repo/native-core/bin/source-facts.clj" \
  --input "$declared_duplicate_ast=$declared_duplicate_path" \
  --interface-sha256 \
    "$declared_duplicate_path=$declared_duplicate_interface_sha256" \
  --output "$declared_duplicate_facts" --include-defs

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
        source
        (slice/source-program rows "native.type-closure-declared-duplicate"
          "native-core/validation/type-closure/declared_duplicate.bgl")
        index
        (lower/build-source-index (stages/sourcestagev1-terms source)
          (stages/sourcestagev1-modules source))
        parent
        (some
          (fn [candidate]
            (if (= "DuplicateParent" (lower/fact-text index candidate "name"))
              candidate
              nil))
          (lower/index-form-ids index "defunion"))
        union-types (lower/index-form-ids index "type-union")
        structural-union
        (some
          (fn [source-type]
            (let [names
                  (set
                    (mapv
                      (fn [member]
                        (lower/source-type-spelling index member))
                      (lower/source-type-arguments index source-type)))]
              (if (= #{"DuplicateLeft" "DuplicateRight"} names)
                source-type
                nil)))
          union-types)]
    (when-not (some? parent)
      (throw (ex-info "declared-duplicate parent was not projected"
               {:unions (lower/index-form-ids index "defunion")})))
    (let [members (lower/union-member-group-items index parent)
          names
          (mapv
            (fn [member] (lower/fact-text index member "name"))
            members)]
      (when-not (and (= ["DuplicateLeft" "DuplicateLeft" "DuplicateRight"]
                        names)
                  (nil?
                    (lower/declared-union-member-identities index parent)))
        (throw (ex-info "duplicate declared identities were accepted"
                 {:members names}))))
    (when-not (some? structural-union)
      (throw (ex-info "declared-duplicate structural union was not projected"
               {:union-types union-types})))
    (let [arguments (lower/source-type-arguments index structural-union)
          resolution (lower/resolve-source-type index structural-union)
          type-id (lower/typeresolutionv0-type-id resolution)
          definition
          (lower/lookup-type
            (lower/typeresolutionv0-definitions resolution) type-id)]
      (when-not (and (nil? (lower/common-source-union index arguments))
                  (lower/typeresolutionv0-valid resolution)
                  (some? definition)
                  (instance? native.core.UnionType
                    (core/typedef-shape definition)))
        (throw (ex-info "declared-duplicate union did not remain structural"
                 {:resolution resolution})))))' "$declared_duplicate_facts"

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
                  :diagnostics diagnostics})))))' "$consumer_facts"

bb -cp "$compiled" -e '
  (require (quote [native.core :as core])
           (quote [native.lower :as lower])
           (quote [native.slice :as slice])
           (quote [native.stages :as stages]))
  (let [rows (slice/read-fact-manifest (first *command-line-args*))
        source (slice/source-program rows "native.type-closure-payloadless"
                 "native-core/validation/type-closure/payloadless.bgl")
        graph (stages/sourcestagev1-terms source)
        index (lower/build-source-index graph
                (stages/sourcestagev1-modules source))
        inferred-types (lower/sourceindexv0-inferred-types index)
        structural-unions
        (filterv
          (fn [source-type]
            (and (= "type-union"
                   (lower/source-type-kind index source-type))
              (= 7 (count
                     (lower/source-type-arguments index source-type)))))
          inferred-types)
        union-types (lower/index-form-ids index "type-union")
        structural-union-named
        (fn [expected]
          (some
            (fn [source-type]
              (let [names
                    (set
                      (mapv
                        (fn [member]
                          (lower/source-type-spelling index member))
                        (lower/source-type-arguments index source-type)))]
                (if (= expected names) source-type nil)))
            union-types))
        structural-resolution?
        (fn [source-type]
          (let [resolution (lower/resolve-source-type index source-type)
                type-id (lower/typeresolutionv0-type-id resolution)
                definition
                (lower/lookup-type
                  (lower/typeresolutionv0-definitions resolution) type-id)]
            (and (lower/typeresolutionv0-valid resolution)
              (some? definition)
              (instance? native.core.UnionType
                (core/typedef-shape definition)))))
        overlap-union
        (structural-union-named #{"OverlapLeft" "OverlapRight"})
        ambiguous-union
        (structural-union-named #{"AmbiguousLeft" "AmbiguousRight"})
        action-subset-union
        (structural-union-named #{"ViewsOverview" "ViewsHost"})
        cross-module-union
        (structural-union-named
          #{"provider/CrossLeft" "provider/CrossRight"})
        error-union
        (structural-union-named #{"ClosureMissing" "ClosureDenied"})]
    (when-not (> (count structural-unions) 0)
      (throw (ex-info
               "fixture no longer projects a seven-member inferred structural union"
               {:inferred-types inferred-types})))
    (let [structural-members
          (lower/source-type-arguments index (first structural-unions))
          common-full
          (lower/common-source-union index structural-members)
          reordered-members
          (conj (vec (reverse structural-members)) (first structural-members))
          common-reordered
          (lower/common-source-union index reordered-members)
          proper-subset
          (subvec structural-members 0 (- (count structural-members) 1))]
      (when-not (and (some? common-full)
                  (some? common-reordered)
                  (core/native-id= common-full common-reordered))
        (throw (ex-info
                 "complete structural union changed under reordering or duplication"
                 {:members reordered-members
                  :resolved common-reordered})))
      (when-not (nil? (lower/common-source-union index proper-subset))
        (throw (ex-info "proper structural subset widened to its parent union"
                 {:members proper-subset}))))
    (when-not (and (some? action-subset-union)
                (nil? (lower/common-source-union index
                        (lower/source-type-arguments index action-subset-union)))
                (structural-resolution? action-subset-union))
      (throw (ex-info "proper subset did not retain a structural type identity"
               {:source-type action-subset-union})))
    (when-not (some? overlap-union)
      (throw (ex-info "overlapping-parent structural union was not projected"
               {:union-types union-types})))
    (let [overlap-parent
          (lower/common-source-union index
            (lower/source-type-arguments index overlap-union))]
      (when-not (and (some? overlap-parent)
                  (= "OverlapExact"
                    (lower/fact-text index overlap-parent "name"))
                  (core/native-id=
                    (lower/source-type-id
                      "native.type-closure-payloadless/OverlapExact")
                    (lower/typeresolutionv0-type-id
                      (lower/resolve-source-type index overlap-union))))
        (throw (ex-info "unique exact parent was not selected"
                 {:resolved overlap-parent}))))
    (when-not (some? ambiguous-union)
      (throw (ex-info "ambiguous-parent structural union was not projected"
               {:union-types union-types})))
    (when-not (and
                (nil? (lower/common-source-union index
                        (lower/source-type-arguments index ambiguous-union)))
                (structural-resolution? ambiguous-union))
      (throw (ex-info "ambiguous structural union selected a nominal parent"
               {:source-type ambiguous-union})))
    (when-not (and (some? cross-module-union)
                (nil? (lower/common-source-union index
                        (lower/source-type-arguments index cross-module-union)))
                (structural-resolution? cross-module-union))
      (throw (ex-info "same-local cross-module members matched a local parent"
               {:source-type cross-module-union})))
    (when-not (some? error-union)
      (throw (ex-info "throwable structural union was not projected"
               {:union-types union-types})))
    (let [error-parent
          (lower/common-source-union index
            (lower/source-type-arguments index error-union))]
      (when-not (and (some? error-parent)
                  (= "ClosureProblem"
                    (lower/fact-text index error-parent "name")))
        (throw (ex-info "complete throwable union did not normalize"
                 {:resolved error-parent}))))
    (let [configuration ["profile=3"]
          frozen (lower/sourcefreezeacceptedv0-frozen
                   (lower/freeze-source-stage source "type-closure-v0"
                     configuration))
          result (lower/lower-typed-stage frozen "type-closure-v0"
                   configuration)]
      (when-not (instance? native.lower.TypingAcceptedV0 result)
        (throw (ex-info "payloadless structural union was rejected"
                 {:result result})))
      (let [receipt (lower/typingacceptedv0-receipt result)
            slice (lower/typingacceptedv0-slice result)
            types (lower/typedslicev0-types slice)
            functions (lower/typedslicev0-functions slice)
            union-id
            (lower/source-type-id
              "native.type-closure-payloadless/ViewsAction")
            union-definition (lower/lookup-type types union-id)
            union-shape (if (nil? union-definition) nil
                          (core/typedef-shape union-definition))
            variants (if (instance? native.core.UnionType union-shape)
                       (core/uniontype-variants union-shape)
                       [])
            payloadless-count
            (count
              (filterv
                (fn [variant]
                  (nil? (core/typevariant-payload-type variant)))
                variants))
            inline-payloads
            (filterv some?
              (mapv core/typevariant-payload-type variants))
            inline-references-valid
            (every?
              (fn [payload]
                (let [reference (lower/lookup-type types payload)
                      shape (if (nil? reference) nil
                              (core/typedef-shape reference))
                      target (if (instance? native.core.ReferenceType shape)
                               (core/referencetype-target-type shape)
                               nil)
                      record (if (nil? target) nil
                               (lower/lookup-type types target))]
                  (and (some? target)
                    (some? record)
                    (instance? native.core.RecordType
                      (core/typedef-shape record)))))
              inline-payloads)
            function
            (some
              (fn [candidate]
                (if (= "preserve-action"
                      (lower/typedfunctionv0-name candidate))
                  candidate
                  nil))
              functions)
            obligations
            (filterv
              (fn [obligation]
                (instance? native.core.ClosedLayoutsObligation
                  (core/receiptobligationv0-code obligation)))
              (core/passreceiptv0-obligations receipt))
            closure-diagnostics
            (filterv
              (fn [diagnostic]
                (= "LOWER-TYPE-CLOSURE"
                  (core/diagnosticv0-code diagnostic)))
              (core/passreceiptv0-diagnostics receipt))]
        (when-not (and (= 7 (count variants))
                    (= 4 payloadless-count)
                    (= 3 (count inline-payloads))
                    inline-references-valid)
          (throw (ex-info "declared union payload representation changed"
                   {:variants variants})))
        (when-not (and (some? function)
                    (= 1 (count
                           (lower/typedfunctionv0-parameters function)))
                    (core/native-id= union-id
                      (core/parameter-type-id
                        (first
                          (lower/typedfunctionv0-parameters function))))
                    (core/native-id= union-id
                      (lower/typedfunctionv0-return-type function)))
          (throw (ex-info "structural union did not normalize to its parent"
                   {:function function})))
        (when-not (and (= 1 (count obligations))
                    (core/receiptobligationv0-passed (first obligations))
                    (= 0 (count closure-diagnostics)))
          (throw (ex-info "normalized union did not close"
                   {:obligations obligations
                    :diagnostics closure-diagnostics}))))))' \
  "$payloadless_facts"

echo "type-closure: payloadless nominal union normalized and imported missing TypeDef rejected PASS"
