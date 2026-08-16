(ns unit-reuse-gate
  (:require [clojure.walk :as walk]
            [native.core :as core]
            [native.stages :as stages]
            [native.lower :as lower]
            [native.obligations :as obligations]
            [native.slice :as slice]
            [native.unit-reuse :as unit]
            [native.unit-compile :as singleton]
            [native.body-slice :as body-slice]
            [native.body-c17 :as body]))

(defn fail! [detail]
  (binding [*out* *err*]
    (println (str "branch-compile-corpus: unit reuse gate: " detail)))
  (System/exit 1))

(defn require! [condition detail]
  (when-not condition (fail! detail)))

(defn native-id-text [identity]
  (core/nativeid-value identity))

(defn raw-byte-count [encoding]
  (alength (.getBytes encoding java.nio.charset.StandardCharsets/UTF_8)))

(defn typed-wire-result [encoding expected-id]
  (unit/decode-typed-unit-wire-v1
   encoding
   (raw-byte-count encoding)
   (stages/content-digest encoding)
   expected-id))

(defn native-wire-result [encoding expected-id]
  (unit/decode-native-unit-wire-v1
   encoding
   (raw-byte-count encoding)
   (stages/content-digest encoding)
   expected-id))

(defn require-typed-rejection! [result code detail]
  (require! (instance? native.unit_reuse.TypedUnitWireRejectedV1 result)
            (str detail " was accepted"))
  (require! (= code (unit/typedunitwirerejectedv1-code result))
            (str detail " rejected with "
                 (unit/typedunitwirerejectedv1-code result)
                 ", expected " code)))

(defn require-native-rejection! [result code detail]
  (require! (instance? native.unit_reuse.NativeUnitWireRejectedV1 result)
            (str detail " was accepted"))
  (require! (= code (unit/nativeunitwirerejectedv1-code result))
            (str detail " rejected with "
                 (unit/nativeunitwirerejectedv1-code result)
                 ", expected " code)))

(defn require-typed-rejected! [result detail]
  (require! (instance? native.unit_reuse.TypedUnitWireRejectedV1 result)
            (str detail " was accepted")))

(defn require-native-rejected! [result detail]
  (require! (instance? native.unit_reuse.NativeUnitWireRejectedV1 result)
            (str detail " was accepted")))

(defn framing-cuts [encoding]
  (vec
   (filter
    #(< % (count encoding))
    (distinct
     (mapcat
      (fn [position]
        (if (= \: (nth encoding position))
          [position (inc position)]
          []))
      (range (count encoding)))))))

(defn corrupt-first-tag-byte [encoding]
  (let [colon (.indexOf encoding ":")
        position (inc colon)
        replacement (if (= "x" (subs encoding position (inc position))) "y" "x")]
    (str (subs encoding 0 position)
         replacement
         (subs encoding (inc position)))))

(defn record-fields [encoding]
  (let [record (unit/parse-wire-record encoding)]
    (require! (some? record) "gate could not parse an encoder-owned record")
    (unit/wirerecordv1-fields record)))

(defn replace-record-field [encoding position replacement]
  (let [record (unit/parse-wire-record encoding)]
    (require! (some? record) "gate could not rewrite an encoder-owned record")
    (stages/canonical-record
     (unit/wirerecordv1-tag record)
     (assoc (unit/wirerecordv1-fields record) position replacement))))

(defn typed-unit-v0-encoding [typed]
  (stages/canonical-record
   "typed-unit-v0"
   [(native-id-text (unit/typedunitv0-unit-id typed))
    (unit/encode-typed-function-payload (unit/typedunitv0-function typed))
    (stages/canonical-set
     "types"
     (mapv lower/encode-type-def (unit/typedunitv0-types typed)))
    (stages/canonical-set
     "effects"
     (mapv lower/encode-effect (unit/typedunitv0-effects typed)))
    (stages/canonical-set
     "capabilities"
     (mapv unit/encode-capability (unit/typedunitv0-capabilities typed)))]))

(defn native-unit-v0-encoding [native]
  (stages/canonical-record
   "native-unit-v0"
   [(native-id-text (unit/nativeunitv0-unit-id native))
    (lower/encode-native-function (unit/nativeunitv0-function native))
    (stages/canonical-set
     "layouts"
     (mapv lower/encode-layout-def (unit/nativeunitv0-layouts native)))
    (stages/canonical-set
     "abis"
     (mapv lower/encode-abi (unit/nativeunitv0-abis native)))
    (stages/canonical-set
     "regions"
     (mapv stages/encode-region (unit/nativeunitv0-regions native)))]))

(defn case-configuration [facts-text abi-id]
  ["profile=3"
   (str "abi=" abi-id)
   (str "source-facts-sha256="
        (subs (stages/content-digest facts-text) 7))])

(defn extracted-rows [source extraction]
  (mapv
   (fn [contract typed native]
     (let [unit-id (unit/unitcontractv0-unit-id contract)
           source-unit
           (unit/source-unit-for (stages/sourcestagev1-units source) unit-id)]
       (require! (some? source-unit)
                 (str "missing source unit " (native-id-text unit-id)))
       {:name (unit/unitcontractv0-qualified-name contract)
        :id unit-id
        :source source-unit
        :contract contract
        :typed typed
        :native native}))
   (unit/unitextractionacceptedv0-contracts extraction)
   (unit/unitextractionacceptedv0-typed-units extraction)
   (unit/unitextractionacceptedv0-native-units extraction)))

(defn load-case [build-root case-id compiler-commit abi]
  (let [directory (str build-root "/" case-id)
        facts-text (slurp (str directory "/source.facts"))
        configuration
        (case-configuration facts-text (core/abiprofilev0-id abi))
        rows (slice/parse-facts facts-text)
        source (slice/source-program rows "beagle.core" "source.facts")
        freeze-result
        (lower/freeze-source-stage source compiler-commit configuration)]
    (require! (instance? native.lower.SourceFreezeAcceptedV0 freeze-result)
              (str case-id " source freeze rejected"))
    (let [frozen-source (lower/sourcefreezeacceptedv0-frozen freeze-result)
          typing-result
          (lower/lower-typed-stage frozen-source compiler-commit configuration)]
      (require! (instance? native.lower.TypingAcceptedV0 typing-result)
                (str case-id " typing rejected"))
      (let [frozen-typed (lower/typingacceptedv0-frozen typing-result)
            typed-slice (lower/typingacceptedv0-slice typing-result)
            native-result
            (lower/lower-native-stage frozen-typed typed-slice compiler-commit
                                      configuration abi)]
        (require! (instance? native.lower.NativeLoweringCompleteV0 native-result)
                  (str case-id " native lowering did not complete"))
        (let [frozen-native
              (lower/nativeloweringcompletev0-frozen native-result)
              epoch-result
              (lower/epoch-derived-stage frozen-native compiler-commit
                                         configuration abi)]
          (require! (lower/epoch-result-complete? epoch-result)
                    (str case-id " epoch lowering did not complete"))
          (let [frozen-epoch (lower/epoch-result-frozen epoch-result)
                extraction
                (unit/extract-unit-payloads source typed-slice frozen-native)]
            (require!
             (instance? native.unit_reuse.UnitExtractionAcceptedV0 extraction)
             (str case-id " unit extraction rejected"
                  (when
                   (instance? native.unit_reuse.UnitExtractionRejectedV0
                              extraction)
                   (str ": " (unit/unitextractionrejectedv0-code extraction)
                        " "
                        (unit/unitextractionrejectedv0-detail extraction)))))
            {:id case-id
             :directory directory
             :configuration configuration
             :source source
             :frozen-source frozen-source
             :frozen-typed frozen-typed
             :typed-slice typed-slice
             :frozen-native frozen-native
             :frozen-epoch frozen-epoch
             :contracts
             (unit/unitextractionacceptedv0-contracts extraction)
             :typed-units
             (unit/unitextractionacceptedv0-typed-units extraction)
             :native-units
             (unit/unitextractionacceptedv0-native-units extraction)
             :rows (extracted-rows source extraction)}))))))

(defn rows-by-name [case-data]
  (into {} (map (juxt :name identity) (:rows case-data))))

(defn changed-names [baseline candidate field digest-fn]
  (let [baseline-rows (rows-by-name baseline)]
    (set
     (for [row (:rows candidate)
           :let [prior (get baseline-rows (:name row))]
           :when (not= (digest-fn (field prior))
                       (digest-fn (field row)))]
       (:name row)))))

(defn contract-digest [contract]
  (unit/unitcontractv0-digest contract))

(defn typed-digest [typed]
  (unit/typedunitv0-digest typed))

(defn native-digest [native]
  (unit/nativeunitv0-digest native))

(defn result-keys [case-data compiler-context]
  (into {}
        (map
         (fn [row]
           [(:name row)
            (unit/unit-result-key compiler-context (:source row)
                                  (:contracts case-data))])
         (:rows case-data))))

(defn changed-result-names [baseline candidate compiler-context]
  (let [before (result-keys baseline compiler-context)
        after (result-keys candidate compiler-context)]
    (set (for [[name digest] after
               :when (not= digest (get before name))]
           name))))

(defn mixed-payloads [baseline candidate recompute]
  (let [baseline-rows (rows-by-name baseline)]
    {:typed
     (mapv (fn [row]
             (:typed (if (contains? recompute (:name row))
                       row
                       (get baseline-rows (:name row)))))
           (:rows candidate))
     :native
     (mapv (fn [row]
             (:native (if (contains? recompute (:name row))
                        row
                        (get baseline-rows (:name row)))))
           (:rows candidate))}))

(defn assembly! [result label]
  (require! (instance? native.unit_reuse.UnitAssemblyAcceptedV0 result)
            (str label " assembly rejected"
                 (when (instance? native.unit_reuse.UnitAssemblyRejectedV0 result)
                   (str ": " (unit/unitassemblyrejectedv0-code result)
                        " " (unit/unitassemblyrejectedv0-detail result)))))
  (unit/unitassemblyacceptedv0-assembly result))

(defn require-assembly-rejection! [result code detail]
  (require! (instance? native.unit_reuse.UnitAssemblyRejectedV0 result)
            (str detail " was accepted"))
  (require! (= code (unit/unitassemblyrejectedv0-code result))
            (str detail " rejected with "
                 (unit/unitassemblyrejectedv0-code result)
                 ", expected " code)))

(defn assemble-case [baseline candidate recompute compiler-commit abi]
  (let [mixed (mixed-payloads baseline candidate recompute)]
    (assembly!
     (unit/assemble-unit-payloads
      (:frozen-source candidate)
      (:contracts candidate)
      (:typed mixed)
      (:native mixed)
      compiler-commit
      (:configuration candidate)
      abi)
     (:id candidate))))

(defn assert-frozen-equality! [candidate assembly]
  (let [clean-typed (:frozen-typed candidate)
        assembled-typed (unit/unitassemblyv0-typed assembly)
        clean-stage (stages/frozentypedstagev0-stage clean-typed)
        assembled-stage (stages/frozentypedstagev0-stage assembled-typed)]
    (require!
     (= (stages/frozentypedstagev0-encoding clean-typed)
        (stages/frozentypedstagev0-encoding assembled-typed))
     (str (:id candidate) " assembled typed bytes differ from clean build; "
          "clean=" (stages/frozentypedstagev0-digest clean-typed)
          " assembled=" (stages/frozentypedstagev0-digest assembled-typed)
          " clean-types="
          (sort (map native-id-text
                     (stages/typedstagev0-type-roots clean-stage)))
          " assembled-types="
          (sort (map native-id-text
                     (stages/typedstagev0-type-roots assembled-stage)))
          " clean-effects="
          (sort (map native-id-text
                     (stages/typedstagev0-effect-roots clean-stage)))
          " assembled-effects="
          (sort (map native-id-text
                     (stages/typedstagev0-effect-roots assembled-stage))))))
  (require!
   (= (stages/frozennativestagev0-encoding (:frozen-native candidate))
      (stages/frozennativestagev0-encoding
       (unit/unitassemblyv0-native assembly)))
   (str (:id candidate) " assembled native bytes differ from clean build"))
  (let [epoch-encoding
        (stages/frozennativestagev0-encoding
         (unit/unitassemblyv0-epoch assembly))]
    (require!
     (= (stages/frozennativestagev0-encoding (:frozen-epoch candidate))
        epoch-encoding)
     (str (:id candidate) " assembled epoch bytes differ from clean build"))
    (require!
     (= (slurp (str (:directory candidate) "/module.native-program"))
        epoch-encoding)
     (str (:id candidate) " assembled native artifact differs from clean build"))))

(defn assert-obligations! [candidate assembly]
  (let [verdicts (unit/unitassemblyv0-verdicts assembly)]
    (require! (= 10 (count verdicts))
              (str (:id candidate) " did not rerun ten obligations"))
    (require! (every? obligations/obligation-passed? verdicts)
              (str (:id candidate) " assembled obligation failed"))))

(defn assert-c17! [candidate assembly]
  (let [epoch-program
        (stages/nativestagev0-program
         (stages/frozennativestagev0-stage
          (unit/unitassemblyv0-epoch assembly)))
        projected (body-slice/projected-program epoch-program)
        result (body/materialize-program projected 0)]
    (require! (instance? native.body_c17.BodySuccessV0 result)
              (str (:id candidate) " assembled C17 materializer refused"))
    (let [artifact (body/bodysuccessv0-artifact result)]
      (require!
       (= (slurp (str (:directory candidate) "/module_0.h"))
          (body/bodyartifactv0-header-text artifact))
       (str (:id candidate) " assembled C17 header differs from clean build"))
      (require!
       (= (slurp (str (:directory candidate) "/module_0.c"))
          (body/bodyartifactv0-source-text artifact))
       (str (:id candidate) " assembled C17 source differs from clean build")))))

(defn assert-reversed!
  [candidate mixed assembly compiler-commit abi]
  (let [reversed
        (assembly!
         (unit/assemble-unit-payloads
          (:frozen-source candidate)
          (vec (reverse (:contracts candidate)))
          (vec (reverse (:typed mixed)))
          (vec (reverse (:native mixed)))
          compiler-commit
          (:configuration candidate)
          abi)
         (str (:id candidate) " reversed"))]
    (require!
     (= (stages/frozentypedstagev0-encoding
         (unit/unitassemblyv0-typed assembly))
        (stages/frozentypedstagev0-encoding
         (unit/unitassemblyv0-typed reversed)))
     (str (:id candidate) " typed assembly depends on unit order"))
    (require!
     (= (stages/frozennativestagev0-encoding
         (unit/unitassemblyv0-native assembly))
        (stages/frozennativestagev0-encoding
         (unit/unitassemblyv0-native reversed)))
     (str (:id candidate) " native assembly depends on unit order"))
    (require!
     (= (stages/frozennativestagev0-encoding
         (unit/unitassemblyv0-epoch assembly))
        (stages/frozennativestagev0-encoding
         (unit/unitassemblyv0-epoch reversed)))
     (str (:id candidate) " epoch assembly depends on unit order"))))

(defn assert-case!
  [baseline candidate expected compiler-context compiler-commit abi]
  (let [key-changes (changed-result-names baseline candidate compiler-context)
        expected-set (set expected)]
    (require! (= expected-set key-changes)
              (str (:id candidate) " result-key cone was "
                   (sort key-changes) ", expected " (sort expected-set)))
    (require! (= expected-set
                 (changed-names baseline candidate :typed typed-digest))
              (str (:id candidate) " typed payload cone differs"))
    (require! (= expected-set
                 (changed-names baseline candidate :native native-digest))
              (str (:id candidate) " native payload cone differs"))
    (let [mixed (mixed-payloads baseline candidate expected-set)
          assembly
          (assembly!
           (unit/assemble-unit-payloads
            (:frozen-source candidate)
            (:contracts candidate)
            (:typed mixed)
            (:native mixed)
            compiler-commit
            (:configuration candidate)
            abi)
           (:id candidate))]
      (assert-frozen-equality! candidate assembly)
      (assert-obligations! candidate assembly)
      (assert-c17! candidate assembly)
      (assert-reversed! candidate mixed assembly compiler-commit abi)
      assembly)))

(defn contract-for [case-data name]
  (:contract (get (rows-by-name case-data) name)))

(defn source-for [case-data name]
  (:source (get (rows-by-name case-data) name)))

(defn assert-contracts! [baseline private public]
  (require!
   (= #{} (changed-names baseline private :contract contract-digest))
   "private implementation changed a unit contract")
  (require!
   (= #{"corpus.foundation/adjust"}
      (changed-names baseline public :contract contract-digest))
   "public interface changed the wrong unit contract")
  (let [score (source-for baseline "corpus.feature/score-value")
        stable (source-for baseline "corpus.feature/stable-score")
        run-score (source-for baseline "corpus.app/run-score")]
    (require!
     (not= (unit/dependency-context-digest score (:contracts baseline))
           (unit/dependency-context-digest score (:contracts public)))
     "adjust contract change did not invalidate its exact reader")
    (require!
     (= (unit/dependency-context-digest stable (:contracts baseline))
        (unit/dependency-context-digest stable (:contracts public)))
     "unrelated same-module contract change invalidated stable-score")
    (require!
     (= (unit/dependency-context-digest run-score (:contracts baseline))
        (unit/dependency-context-digest run-score (:contracts public)))
     "contract propagation crossed an unchanged direct interface")))

(defn assert-contract-shape! [baseline]
  (let [private-names
        (set (for [contract (:contracts baseline)
                   :when (= "private"
                            (unit/unitcontractv0-visibility contract))]
               (unit/unitcontractv0-qualified-name contract)))]
    (require! (= #{"corpus.foundation/private-offset"} private-names)
              "compiler-owned visibility contract differs from corpus")
    (require! (every? #(empty? (unit/unitcontractv0-generated-bindings %))
                      (:contracts baseline))
              "defn-only corpus unexpectedly acquired generated bindings")))

(defn assert-wire-round-trips! [baseline]
  (require! (= 9 (count (:rows baseline)))
            "wire round-trip gate did not receive all nine units")
  (doseq [row (:rows baseline)]
    (let [typed (:typed row)
          native (:native row)
          unit-id (:id row)
          typed-encoding (unit/typedunitv0-encoding typed)
          native-encoding (unit/nativeunitv0-encoding native)
          typed-record (unit/parse-wire-record typed-encoding)
          native-record (unit/parse-wire-record native-encoding)
          typed-result (typed-wire-result typed-encoding unit-id)
          native-result (native-wire-result native-encoding unit-id)]
      (require! (= "typed-unit-wire-v1"
                   (unit/wirerecordv1-tag typed-record))
                (str (:name row) " did not use the typed v1 outer tag"))
      (require! (= "native-unit-wire-v1"
                   (unit/wirerecordv1-tag native-record))
                (str (:name row) " did not use the native v1 outer tag"))
      (require! (= (raw-byte-count typed-encoding)
                   (unit/unit-wire-byte-count typed-encoding))
                (str (:name row) " typed UTF-8 byte count differs"))
      (require! (= (raw-byte-count native-encoding)
                   (unit/unit-wire-byte-count native-encoding))
                (str (:name row) " native UTF-8 byte count differs"))
      (require!
       (instance? native.unit_reuse.TypedUnitWireDecodedV1 typed-result)
       (str (:name row) " typed v1 payload did not decode"))
      (require!
       (instance? native.unit_reuse.NativeUnitWireDecodedV1 native-result)
       (str (:name row) " native v1 payload did not decode"))
      (let [decoded-typed (unit/typedunitwiredecodedv1-unit typed-result)
            decoded-native (unit/nativeunitwiredecodedv1-unit native-result)]
        (require! (= typed decoded-typed)
                  (str (:name row) " typed record changed across wire v1"))
        (require! (= native decoded-native)
                  (str (:name row) " native record changed across wire v1"))
        (require! (= typed-encoding (unit/typedunitv0-encoding decoded-typed))
                  (str (:name row) " typed raw bytes changed after decode"))
        (require! (= native-encoding (unit/nativeunitv0-encoding decoded-native))
                  (str (:name row) " native raw bytes changed after decode"))
        (require! (= (unit/typedunitv0-digest typed)
                     (unit/typedunitv0-digest decoded-typed))
                  (str (:name row) " typed digest changed after decode"))
        (require! (= (unit/nativeunitv0-digest native)
                     (unit/nativeunitv0-digest decoded-native))
                  (str (:name row) " native digest changed after decode"))))))

(defn assert-v0-rejected! [baseline]
  (let [typed (first (:typed-units baseline))
        native (first (:native-units baseline))
        typed-v0 (typed-unit-v0-encoding typed)
        native-v0 (native-unit-v0-encoding native)]
    (require-typed-rejection!
     (typed-wire-result typed-v0 (unit/typedunitv0-unit-id typed))
     "UNIT-WIRE-V0-NONINVERTIBLE"
     "typed unit V0 payload")
    (require-native-rejection!
     (native-wire-result native-v0 (unit/nativeunitv0-unit-id native))
     "UNIT-WIRE-V0-NONINVERTIBLE"
     "native unit V0 payload")))

(defn assert-v0-semantic-collision! [baseline]
  (let [typed-target
        (first
         (filter
          (fn [typed]
            (some #(instance? native.core.SwitchTerminator %)
                  (mapcat core/basicblock-terminators
                          (lower/readiness-blocks
                           (lower/typedfunctionv0-readiness
                            (unit/typedunitv0-function typed))))))
          (:typed-units baseline)))
        native-target
        (first
         (filter
          (fn [native]
            (some #(instance? native.core.CallInstruction %)
                  (mapcat core/basicblock-instructions
                          (core/functiondef-blocks
                           (unit/nativeunitv0-function native)))))
          (:native-units baseline)))
        switch (first
                (filter #(instance? native.core.SwitchTerminator %)
                        (mapcat core/basicblock-terminators
                                (lower/readiness-blocks
                                 (lower/typedfunctionv0-readiness
                                  (unit/typedunitv0-function typed-target))))))
        call (first
              (filter #(instance? native.core.CallInstruction %)
                      (mapcat core/basicblock-instructions
                              (core/functiondef-blocks
                               (unit/nativeunitv0-function native-target)))))
        bogus-block (core/->NativeId "unit-wire-v1-gate/switch-destination")
        bogus-token (core/->NativeId "unit-wire-v1-gate/consumed-token")]
    (require! (some? switch) "corpus has no switch for the V0 collision witness")
    (require! (some? call) "corpus has no call for the V0 collision witness")
    (let [cases (core/switchterminator-cases switch)
          changed-case (assoc (first cases) :block-id bogus-block)
          changed-switch (assoc switch :cases (assoc cases 0 changed-case))
          reordered-switch (assoc switch :cases (vec (reverse cases)))
          typed-function (unit/typedunitv0-function typed-target)
          reordered-function
          (walk/postwalk #(if (= % switch) reordered-switch %) typed-function)
          reordered-unit
          (unit/make-typed-unit
           (unit/typedunitv0-unit-id typed-target)
           reordered-function
           (unit/typedunitv0-types typed-target)
           (unit/typedunitv0-effects typed-target)
           (unit/typedunitv0-capabilities typed-target))]
      (require! (> (count cases) 1)
                "corpus switch has no ordered-case falsifier")
      (require! (not= switch changed-switch)
                "switch collision witness did not change semantics")
      (require! (= (lower/encode-terminator switch)
                   (lower/encode-terminator changed-switch))
                "V0 switch encoder unexpectedly bound its omitted cases")
      (require! (= (stages/content-digest (lower/encode-terminator switch))
                   (stages/content-digest
                    (lower/encode-terminator changed-switch)))
                "V0 switch collision did not retain its digest")
      (require! (not= (unit/encode-terminator-wire-v1 switch)
                      (unit/encode-terminator-wire-v1 changed-switch))
                "wire v1 failed to bind switch cases")
      (require! (not= (stages/content-digest
                       (unit/encode-terminator-wire-v1 switch))
                      (stages/content-digest
                       (unit/encode-terminator-wire-v1 changed-switch)))
                "wire v1 switch mutation retained its digest")
      (require! (not= (unit/encode-terminator-wire-v1 switch)
                      (unit/encode-terminator-wire-v1 reordered-switch))
                "wire v1 erased ordered switch-case order")
      (require! (not= (stages/content-digest
                       (unit/encode-terminator-wire-v1 switch))
                      (stages/content-digest
                       (unit/encode-terminator-wire-v1 reordered-switch)))
                "wire v1 switch-case reorder retained its digest")
      (require! (= (typed-unit-v0-encoding typed-target)
                   (typed-unit-v0-encoding reordered-unit))
                "V0 typed unit did not preserve the switch collision")
      (require! (= (stages/content-digest
                    (typed-unit-v0-encoding typed-target))
                   (stages/content-digest
                    (typed-unit-v0-encoding reordered-unit)))
                "V0 typed unit switch collision changed digest")
      (require! (not= (unit/typedunitv0-encoding typed-target)
                      (unit/typedunitv0-encoding reordered-unit))
                "wire v1 typed unit failed to bind switch-case order")
      (require! (not= (unit/typedunitv0-digest typed-target)
                      (unit/typedunitv0-digest reordered-unit))
                "wire v1 typed unit switch reorder retained its digest"))
    (let [tokens (core/callinstruction-tokens call)
          changed-tokens
          (assoc tokens :consumed
                 (conj (core/tokenflowv0-consumed tokens) bogus-token))
          changed-call (assoc call :tokens changed-tokens)
          native-function (unit/nativeunitv0-function native-target)
          changed-function
          (walk/postwalk #(if (= % call) changed-call %) native-function)
          changed-unit
          (unit/make-native-unit
           (unit/nativeunitv0-unit-id native-target)
           changed-function
           (unit/nativeunitv0-layouts native-target)
           (unit/nativeunitv0-abis native-target)
           (unit/nativeunitv0-regions native-target))]
      (require! (not= call changed-call)
                "call collision witness did not change token flow")
      (require! (= (lower/encode-instruction call)
                   (lower/encode-instruction changed-call))
                "V0 call encoder unexpectedly bound its omitted token flow")
      (require! (= (stages/content-digest (lower/encode-instruction call))
                   (stages/content-digest
                    (lower/encode-instruction changed-call)))
                "V0 call collision did not retain its digest")
      (require! (not= (unit/encode-instruction-wire-v1 call)
                      (unit/encode-instruction-wire-v1 changed-call))
                "wire v1 failed to bind call token flow")
      (require! (not= (stages/content-digest
                       (unit/encode-instruction-wire-v1 call))
                      (stages/content-digest
                       (unit/encode-instruction-wire-v1 changed-call)))
                "wire v1 call token mutation retained its digest")
      (require! (= (native-unit-v0-encoding native-target)
                   (native-unit-v0-encoding changed-unit))
                "V0 native unit did not preserve the call-token collision")
      (require! (= (stages/content-digest
                    (native-unit-v0-encoding native-target))
                   (stages/content-digest
                    (native-unit-v0-encoding changed-unit)))
                "V0 native unit call-token collision changed digest")
      (require! (not= (unit/nativeunitv0-encoding native-target)
                      (unit/nativeunitv0-encoding changed-unit))
                "wire v1 native unit failed to bind call token flow")
      (require! (not= (unit/nativeunitv0-digest native-target)
                      (unit/nativeunitv0-digest changed-unit))
                "wire v1 native unit call-token mutation retained its digest"))))

(defn assert-wire-rejections! [baseline]
  (let [typed (first (:typed-units baseline))
        native (first (:native-units baseline))
        typed-id (unit/typedunitv0-unit-id typed)
        native-id (unit/nativeunitv0-unit-id native)
        typed-encoding (unit/typedunitv0-encoding typed)
        native-encoding (unit/nativeunitv0-encoding native)
        wrong-id (core/->NativeId "unit-wire-v1-gate/wrong-unit")
        wrong-digest (stages/content-digest "unit-wire-v1-gate/wrong-digest")]
    (require-typed-rejection!
     (unit/decode-typed-unit-wire-v1
      typed-encoding (inc (raw-byte-count typed-encoding))
      (unit/typedunitv0-digest typed) typed-id)
     "UNIT-WIRE-BYTE-COUNT"
     "typed byte-count mismatch")
    (require-native-rejection!
     (unit/decode-native-unit-wire-v1
      native-encoding (inc (raw-byte-count native-encoding))
      (unit/nativeunitv0-digest native) native-id)
     "UNIT-WIRE-BYTE-COUNT"
     "native byte-count mismatch")
    (require-typed-rejection!
     (unit/decode-typed-unit-wire-v1
      typed-encoding (raw-byte-count typed-encoding)
      wrong-digest typed-id)
     "UNIT-WIRE-DIGEST"
     "typed digest mismatch")
    (require-native-rejection!
     (unit/decode-native-unit-wire-v1
      native-encoding (raw-byte-count native-encoding)
      wrong-digest native-id)
     "UNIT-WIRE-DIGEST"
     "native digest mismatch")
    (require-typed-rejection!
     (typed-wire-result typed-encoding wrong-id)
     "UNIT-WIRE-ID-MISMATCH"
     "typed requested-unit mismatch")
    (require-native-rejection!
     (native-wire-result native-encoding wrong-id)
     "UNIT-WIRE-ID-MISMATCH"
     "native requested-unit mismatch")
    (doseq [malformed
            [""
             "01:x:"
             "999999999999999999999999999999999999:x:"
             "1:x"
             "1:x:1"
             (str typed-encoding "x")
             (subs typed-encoding 0 (dec (count typed-encoding)))]]
      (require-typed-rejection!
       (typed-wire-result malformed typed-id)
       "UNIT-WIRE-MALFORMED"
       (str "malformed canonical record " (pr-str malformed))))
    (doseq [malformed
            [""
             "01:x:"
             "999999999999999999999999999999999999:x:"
             "1:x"
             "1:x:1"
             (str native-encoding "x")
             (subs native-encoding 0 (dec (count native-encoding)))]]
      (require-native-rejection!
       (native-wire-result malformed native-id)
       "UNIT-WIRE-MALFORMED"
       (str "malformed native canonical record " (pr-str malformed))))
    (require-typed-rejected!
     (typed-wire-result (corrupt-first-tag-byte typed-encoding) typed-id)
     "typed recomputed-metadata one-byte corruption")
    (require-native-rejected!
     (native-wire-result (corrupt-first-tag-byte native-encoding) native-id)
     "native recomputed-metadata one-byte corruption")
    (let [smallest-typed
          (apply min-key #(count (unit/typedunitv0-encoding %))
                 (:typed-units baseline))
          encoding (unit/typedunitv0-encoding smallest-typed)
          unit-id (unit/typedunitv0-unit-id smallest-typed)]
      (doseq [cut (framing-cuts encoding)]
        (require-typed-rejected!
         (typed-wire-result (subs encoding 0 cut) unit-id)
         (str "typed framing-boundary truncation at " cut))))
    (let [smallest-native
          (apply min-key #(count (unit/nativeunitv0-encoding %))
                 (:native-units baseline))
          encoding (unit/nativeunitv0-encoding smallest-native)
          unit-id (unit/nativeunitv0-unit-id smallest-native)]
      (doseq [cut (framing-cuts encoding)]
        (require-native-rejected!
         (native-wire-result (subs encoding 0 cut) unit-id)
         (str "native framing-boundary truncation at " cut))))
    (let [typed-fields (record-fields typed-encoding)
          unknown-outer
          (stages/canonical-record "typed-unit-wire-v1-unknown" typed-fields)
          missing-field
          (stages/canonical-record "typed-unit-wire-v1" (pop typed-fields))
          unknown-nested
          (replace-record-field
           typed-encoding 1 (stages/canonical-record "unknown-function" []))
          function-record (unit/parse-wire-record (nth typed-fields 1))
          wrong-function
          (stages/canonical-record
           (unit/wirerecordv1-tag function-record)
           (assoc (unit/wirerecordv1-fields function-record) 0
                  (stages/encode-id wrong-id)))
          altered-function-id
          (replace-record-field typed-encoding 1 wrong-function)
          altered-unit-id
          (replace-record-field typed-encoding 0 (stages/encode-id wrong-id))]
      (require-typed-rejection!
       (typed-wire-result unknown-outer typed-id)
       "UNIT-WIRE-TAG"
       "unknown typed outer tag")
      (require-typed-rejection!
       (typed-wire-result missing-field typed-id)
       "UNIT-WIRE-TAG"
       "typed outer field-count mismatch")
      (require-typed-rejection!
       (typed-wire-result unknown-nested typed-id)
       "UNIT-WIRE-SCHEMA"
       "unknown typed nested tag")
      (require-typed-rejection!
       (typed-wire-result altered-function-id typed-id)
       "UNIT-WIRE-REENCODE"
       "typed nested function identity mismatch")
      (require-typed-rejection!
       (typed-wire-result altered-unit-id wrong-id)
       "UNIT-WIRE-REENCODE"
       "typed unit/function identity mismatch"))
    (let [native-fields (record-fields native-encoding)
          unknown-outer
          (stages/canonical-record "native-unit-wire-v1-unknown" native-fields)
          missing-field
          (stages/canonical-record "native-unit-wire-v1" (pop native-fields))
          unknown-nested
          (replace-record-field
           native-encoding 1 (stages/canonical-record "unknown-function" []))
          function-record (unit/parse-wire-record (nth native-fields 1))
          wrong-function
          (stages/canonical-record
           (unit/wirerecordv1-tag function-record)
           (assoc (unit/wirerecordv1-fields function-record) 0
                  (stages/encode-id wrong-id)))
          altered-function-id
          (replace-record-field native-encoding 1 wrong-function)
          altered-unit-id
          (replace-record-field native-encoding 0 (stages/encode-id wrong-id))]
      (require-native-rejection!
       (native-wire-result unknown-outer native-id)
       "UNIT-WIRE-TAG"
       "unknown native outer tag")
      (require-native-rejection!
       (native-wire-result missing-field native-id)
       "UNIT-WIRE-TAG"
       "native outer field-count mismatch")
      (require-native-rejection!
       (native-wire-result unknown-nested native-id)
       "UNIT-WIRE-SCHEMA"
       "unknown native nested tag")
      (require-native-rejection!
       (native-wire-result altered-function-id native-id)
       "UNIT-WIRE-REENCODE"
       "native nested function identity mismatch")
      (require-native-rejection!
       (native-wire-result altered-unit-id wrong-id)
       "UNIT-WIRE-REENCODE"
       "native unit/function identity mismatch"))
    (let [ordered-unit
          (first
           (filter #(> (count (unit/typedunitv0-types %)) 1)
                   (:typed-units baseline)))
          encoding (unit/typedunitv0-encoding ordered-unit)
          fields (record-fields encoding)
          type-set (unit/parse-wire-record (nth fields 2))
          type-fields (unit/wirerecordv1-fields type-set)
          reversed-types
          (stages/canonical-record
           (unit/wirerecordv1-tag type-set)
           (vec (reverse type-fields)))
          duplicate-types
          (stages/canonical-record
           (unit/wirerecordv1-tag type-set)
           (conj type-fields (first type-fields)))
          reversed-wire (replace-record-field encoding 2 reversed-types)
          duplicate-wire (replace-record-field encoding 2 duplicate-types)
          unit-id (unit/typedunitv0-unit-id ordered-unit)]
      (require! (not= type-fields (vec (reverse type-fields)))
                "corpus has no ordered typed support set for the wire gate")
      (require-typed-rejection!
       (typed-wire-result reversed-wire unit-id)
       "UNIT-WIRE-SCHEMA"
       "unsorted typed support set")
      (require-typed-rejection!
       (typed-wire-result duplicate-wire unit-id)
       "UNIT-WIRE-SCHEMA"
       "duplicate typed support-set entry"))
    (let [ordered-unit
          (first
           (filter #(> (count (unit/nativeunitv0-layouts %)) 1)
                   (:native-units baseline)))
          encoding (unit/nativeunitv0-encoding ordered-unit)
          fields (record-fields encoding)
          layout-set (unit/parse-wire-record (nth fields 2))
          layout-fields (unit/wirerecordv1-fields layout-set)
          reversed-layouts
          (stages/canonical-record
           (unit/wirerecordv1-tag layout-set)
           (vec (reverse layout-fields)))
          duplicate-layouts
          (stages/canonical-record
           (unit/wirerecordv1-tag layout-set)
           (conj layout-fields (first layout-fields)))
          first-layout (unit/parse-wire-record (first layout-fields))
          wrong-layout
          (stages/canonical-record
           (unit/wirerecordv1-tag first-layout)
           (assoc (unit/wirerecordv1-fields first-layout) 0
                  (stages/encode-id wrong-id)))
          wrong-layouts
          (stages/canonical-set
           (unit/wirerecordv1-tag layout-set)
           (assoc layout-fields 0 wrong-layout))
          reversed-wire (replace-record-field encoding 2 reversed-layouts)
          duplicate-wire (replace-record-field encoding 2 duplicate-layouts)
          wrong-layout-wire (replace-record-field encoding 2 wrong-layouts)
          unit-id (unit/nativeunitv0-unit-id ordered-unit)]
      (require! (not= layout-fields (vec (reverse layout-fields)))
                "corpus has no ordered native support set for the wire gate")
      (require-native-rejection!
       (native-wire-result reversed-wire unit-id)
       "UNIT-WIRE-SCHEMA"
       "unsorted native support set")
      (require-native-rejection!
       (native-wire-result duplicate-wire unit-id)
       "UNIT-WIRE-SCHEMA"
       "duplicate native support-set entry")
      (require-native-rejection!
       (native-wire-result wrong-layout-wire unit-id)
       "UNIT-WIRE-REENCODE"
       "native layout identity/type derivation mismatch"))))

(defn shared-type-id [typed-units]
  (let [frequencies
        (frequencies
         (mapcat
          (fn [typed]
            (map #(native-id-text (core/typedef-id %))
                 (unit/typedunitv0-types typed)))
          typed-units))]
    (first (sort (for [[identity count] frequencies :when (> count 1)]
                   identity)))))

(defn assert-shared-support! [baseline]
  (let [shared (shared-type-id (:typed-units baseline))
        definitions
        (for [typed (:typed-units baseline)
              definition (unit/typedunitv0-types typed)
              :when (= shared (native-id-text (core/typedef-id definition)))]
          definition)
        encodings (map unit/encode-type-def-wire-v1 definitions)]
    (require! (some? shared)
              "corpus has no equal shared support identity")
    (require! (> (count definitions) 1)
              "shared support identity occurs in only one unit")
    (require! (= 1 (count (distinct encodings)))
              "equal shared support identity has unequal v1 bytes")))

(defn assert-duplicate-identities-rejected! [baseline compiler-commit abi]
  (let [duplicate-top-result
        (unit/assemble-unit-payloads
         (:frozen-source baseline)
         (:contracts baseline)
         (conj (:typed-units baseline) (first (:typed-units baseline)))
         (:native-units baseline)
         compiler-commit
         (:configuration baseline)
         abi)]
    (require!
     (instance? native.unit_reuse.UnitAssemblyRejectedV0 duplicate-top-result)
     "equal duplicate top-level unit identity was accepted")
    (require! (= "UNIT-SET-MISMATCH"
                 (unit/unitassemblyrejectedv0-code duplicate-top-result))
              "equal duplicate top-level unit received the wrong rejection"))
  (let [duplicate-top-result
        (unit/assemble-unit-payloads
         (:frozen-source baseline)
         (:contracts baseline)
         (:typed-units baseline)
         (conj (:native-units baseline) (first (:native-units baseline)))
         compiler-commit
         (:configuration baseline)
         abi)]
    (require-assembly-rejection!
     duplicate-top-result "UNIT-SET-MISMATCH"
     "equal duplicate native top-level unit identity"))
  (let [target
        (first
         (filter #(seq (unit/typedunitv0-types %)) (:typed-units baseline)))
        types (unit/typedunitv0-types target)
        changed-type
        (assoc (first types) :name
               (str (core/typedef-name (first types)) "TopCollision"))
        unequal-top
        (unit/make-typed-unit
         (unit/typedunitv0-unit-id target)
         (unit/typedunitv0-function target)
         (assoc types 0 changed-type)
         (unit/typedunitv0-effects target)
         (unit/typedunitv0-capabilities target))
        result
        (unit/assemble-unit-payloads
         (:frozen-source baseline)
         (:contracts baseline)
         (conj (:typed-units baseline) unequal-top)
         (:native-units baseline)
         compiler-commit
         (:configuration baseline)
         abi)]
    (require! (not= (unit/typedunitv0-encoding target)
                    (unit/typedunitv0-encoding unequal-top))
              "unequal duplicate top-level witness retained equal bytes")
    (require-assembly-rejection!
     result "UNIT-SET-MISMATCH"
     "unequal duplicate top-level unit identity"))
  (let [target
        (first
         (filter #(seq (unit/typedunitv0-types %)) (:typed-units baseline)))
        types (unit/typedunitv0-types target)
        duplicate
        (unit/make-typed-unit
         (unit/typedunitv0-unit-id target)
         (unit/typedunitv0-function target)
         (conj types (first types))
         (unit/typedunitv0-effects target)
         (unit/typedunitv0-capabilities target))
        missing
        (unit/make-typed-unit
         (unit/typedunitv0-unit-id target)
         (unit/typedunitv0-function target)
         (vec (rest types))
         (unit/typedunitv0-effects target)
         (unit/typedunitv0-capabilities target))
        altered
        (mapv
         (fn [typed]
           (if (core/native-id= (unit/typedunitv0-unit-id typed)
                                (unit/typedunitv0-unit-id target))
             duplicate
             typed))
         (:typed-units baseline))
        duplicate-support-result
        (unit/assemble-unit-payloads
         (:frozen-source baseline)
         (:contracts baseline)
         altered
         (:native-units baseline)
         compiler-commit
         (:configuration baseline)
         abi)]
    (require! (not (unit/typed-unit-record-valid? duplicate))
              "equal duplicate support identity passed the v1 validator")
    (require! (not (unit/typed-unit-record-valid? missing))
              "missing required typed support passed the v1 validator")
    (require!
     (instance? native.unit_reuse.UnitAssemblyRejectedV0
                duplicate-support-result)
     "equal duplicate support identity was accepted")
    (require! (= "UNIT-PAYLOAD-CORRUPT"
                 (unit/unitassemblyrejectedv0-code duplicate-support-result))
              "equal duplicate support identity received the wrong rejection"))
  (let [target
        (first
         (filter #(seq (unit/typedunitv0-types %)) (:typed-units baseline)))
        types (unit/typedunitv0-types target)
        unequal-type
        (assoc (first types) :name
               (str (core/typedef-name (first types)) "WithinCollision"))
        duplicate
        (unit/make-typed-unit
         (unit/typedunitv0-unit-id target)
         (unit/typedunitv0-function target)
         (conj types unequal-type)
         (unit/typedunitv0-effects target)
         (unit/typedunitv0-capabilities target))
        altered
        (mapv
         (fn [typed]
           (if (core/native-id= (unit/typedunitv0-unit-id typed)
                                (unit/typedunitv0-unit-id target))
             duplicate typed))
         (:typed-units baseline))
        result
        (unit/assemble-unit-payloads
         (:frozen-source baseline)
         (:contracts baseline)
         altered
         (:native-units baseline)
         compiler-commit
         (:configuration baseline)
         abi)]
    (require! (not (unit/typed-unit-record-valid? duplicate))
              "unequal duplicate support identity passed the v1 validator")
    (require-assembly-rejection!
     result "UNIT-PAYLOAD-CORRUPT"
     "unequal duplicate support identity"))
  (let [target
        (first
         (filter #(seq (unit/nativeunitv0-layouts %)) (:native-units baseline)))
        layouts (unit/nativeunitv0-layouts target)
        equal-duplicate
        (unit/make-native-unit
         (unit/nativeunitv0-unit-id target)
         (unit/nativeunitv0-function target)
         (conj layouts (first layouts))
         (unit/nativeunitv0-abis target)
         (unit/nativeunitv0-regions target))
        changed-layout
        (assoc (first layouts) :size-bytes
               (inc (core/layoutdef-size-bytes (first layouts))))
        unequal-duplicate
        (unit/make-native-unit
         (unit/nativeunitv0-unit-id target)
         (unit/nativeunitv0-function target)
         (conj layouts changed-layout)
         (unit/nativeunitv0-abis target)
         (unit/nativeunitv0-regions target))
        missing
        (unit/make-native-unit
         (unit/nativeunitv0-unit-id target)
         (unit/nativeunitv0-function target)
         (vec (rest layouts))
         (unit/nativeunitv0-abis target)
         (unit/nativeunitv0-regions target))]
    (doseq [[label duplicate] [["equal" equal-duplicate]
                               ["unequal" unequal-duplicate]]]
      (let [altered
            (mapv
             (fn [native]
               (if (core/native-id= (unit/nativeunitv0-unit-id native)
                                    (unit/nativeunitv0-unit-id target))
                 duplicate native))
             (:native-units baseline))
            result
            (unit/assemble-unit-payloads
             (:frozen-source baseline)
             (:contracts baseline)
             (:typed-units baseline)
             altered
             compiler-commit
             (:configuration baseline)
             abi)]
        (require! (not (unit/native-unit-record-valid? duplicate))
                  (str label " duplicate native support passed validation"))
        (require-assembly-rejection!
         result "UNIT-PAYLOAD-CORRUPT"
         (str label " duplicate native support identity"))))
    (let [altered
          (mapv
           (fn [native]
             (if (core/native-id= (unit/nativeunitv0-unit-id native)
                                  (unit/nativeunitv0-unit-id target))
               missing native))
           (:native-units baseline))
          result
          (unit/assemble-unit-payloads
           (:frozen-source baseline)
           (:contracts baseline)
           (:typed-units baseline)
           altered
           compiler-commit
           (:configuration baseline)
           abi)]
      (require-assembly-rejection!
       result "UNIT-PAYLOAD-CORRUPT"
       "missing required native layout support"))))

(defn assert-collision-rejected! [baseline compiler-commit abi]
  (let [shared (shared-type-id (:typed-units baseline))]
    (require! (some? shared) "corpus has no shared typed root for collision test")
    (let [target
          (first
           (filter
            (fn [typed]
              (some #(= shared (native-id-text (core/typedef-id %)))
                    (unit/typedunitv0-types typed)))
            (:typed-units baseline)))
          conflicting-types
          (mapv
           (fn [definition]
             (if (= shared (native-id-text (core/typedef-id definition)))
               (assoc definition :name
                      (str (core/typedef-name definition) "Collision"))
               definition))
           (unit/typedunitv0-types target))
          conflicting
          (unit/make-typed-unit
           (unit/typedunitv0-unit-id target)
           (unit/typedunitv0-function target)
           conflicting-types
           (unit/typedunitv0-effects target)
           (unit/typedunitv0-capabilities target))
          typed-units
          (mapv (fn [typed]
                  (if (core/native-id= (unit/typedunitv0-unit-id typed)
                                       (unit/typedunitv0-unit-id target))
                    conflicting typed))
                (:typed-units baseline))
          result
          (unit/assemble-unit-payloads
           (:frozen-source baseline)
           (:contracts baseline)
           typed-units
           (:native-units baseline)
           compiler-commit
           (:configuration baseline)
           abi)]
      (require! (instance? native.unit_reuse.UnitAssemblyRejectedV0 result)
                "unequal bytes under one NativeId were accepted")
      (require! (= "UNIT-PAYLOAD-COLLISION"
                   (unit/unitassemblyrejectedv0-code result))
                (str "collision rejected with "
                     (unit/unitassemblyrejectedv0-code result))))))

(defn assert-layout-digest-rejected! [baseline compiler-commit abi]
  (let [target (first (:native-units baseline))
        declaration (first (unit/nativeunitv0-abis target))
        wrong-layout-digest
        (stages/content-digest "unit-wire-v1-gate/wrong-layout-set")
        changed-declaration
        (assoc declaration :layout-digest wrong-layout-digest)
        changed-unit
        (unit/make-native-unit
         (unit/nativeunitv0-unit-id target)
         (unit/nativeunitv0-function target)
         (unit/nativeunitv0-layouts target)
         [changed-declaration]
         (unit/nativeunitv0-regions target))
        native-units
        (mapv
         (fn [native]
           (if (core/native-id= (unit/nativeunitv0-unit-id native)
                                (unit/nativeunitv0-unit-id target))
             changed-unit native))
         (:native-units baseline))
        result
        (unit/assemble-unit-payloads
         (:frozen-source baseline)
         (:contracts baseline)
         (:typed-units baseline)
         native-units
         compiler-commit
         (:configuration baseline)
         abi)]
    (require! (unit/native-unit-record-valid? changed-unit)
              "ABI layout-digest witness failed unit-local validation")
    (require-assembly-rejection!
     result "UNIT-ABI-LAYOUT-DIGEST"
     "ABI digest for a different complete layout set")))

(defn assert-unsupported-rejected! [baseline compiler-commit abi]
  (let [source (:source baseline)
        source-units (stages/sourcestagev1-units source)
        altered-source
        (assoc source :units
               (assoc source-units 0 (assoc (nth source-units 0) :kind "def")))
        encoding (stages/encode-source-stage altered-source)
        altered-frozen
        (stages/->FrozenSourceStageV1 altered-source encoding
                                      (stages/content-digest encoding))
        result
        (unit/assemble-unit-payloads
         altered-frozen
         (:contracts baseline)
         (:typed-units baseline)
         (:native-units baseline)
         compiler-commit
         (:configuration baseline)
         abi)]
    (require! (instance? native.unit_reuse.UnitAssemblyRejectedV0 result)
              "non-defn corpus unit was accepted")
    (require! (= "UNIT-CORPUS-UNSUPPORTED"
                 (unit/unitassemblyrejectedv0-code result))
              "non-defn corpus unit received the wrong rejection")))

;; ---------------------------------------------------------------------------
;; Singleton compilation: probes, mechanism self-test, and per-case assertions.
;;
;; The point of these assertions is to FAIL when body compilation is still
;; whole-program.  A wrapper that calls the ordinary lowerer and discards eight
;; of nine units would satisfy a reuse count while proving nothing, so the
;; whole-stage entries throw and the singleton entries are counted.

(def original-attach-body lower/attach-body)
(def original-lower-ready-function lower/lower-ready-function)

(def probe-calls (atom {:attach-body [] :lower-ready-function []}))
(def probe-totals (atom {:attach-body 0 :lower-ready-function 0}))
(def probe-attached-readiness (atom []))

(defn probe-reset! []
  (reset! probe-calls {:attach-body [] :lower-ready-function []})
  (reset! probe-attached-readiness []))

(defn probe-seen [key] (get @probe-calls key))

(defn probe-total [key] (get @probe-totals key))

(defn probe-record! [key identity]
  (swap! probe-calls update key conj identity)
  (swap! probe-totals update key inc))

(defn forbidden [symbol-name]
  (fn [& _]
    (throw (ex-info (str "whole-stage lowering called on the singleton path: "
                         symbol-name)
                    {:probe symbol-name}))))

(defn with-singleton-probes [thunk]
  (with-redefs
   [lower/lower-typed-stage (forbidden "lower/lower-typed-stage")
    lower/lower-native-stage (forbidden "lower/lower-native-stage")
    lower/attach-bodies (forbidden "lower/attach-bodies")
    lower/settle-function-closures
    (forbidden "lower/settle-function-closures")
    lower/lower-ready-functions (forbidden "lower/lower-ready-functions")
    lower/slice-abis (forbidden "lower/slice-abis")
    unit/extract-unit-payloads (forbidden "unit/extract-unit-payloads")
    lower/attach-body
    (fn [env resolution source]
      (probe-record! :attach-body
                     (native-id-text
                      (lower/typedfunctionv0-id
                       (lower/functionresolutionv0-function resolution))))
      (let [attached (original-attach-body env resolution source)]
        (swap! probe-attached-readiness
               conj
               (lower/typedfunctionv0-readiness
                (lower/functionresolutionv0-function attached)))
        attached))
    lower/lower-ready-function
    (fn [function]
      (probe-record! :lower-ready-function
                     (native-id-text (lower/typedfunctionv0-id function)))
      (original-lower-ready-function function))]
    (thunk)))

;; A probe that cannot fire makes every assertion below pass vacuously, which
;; is a worse outcome than having no gate at all.  with-redefs is used nowhere
;; else in this repository, so the mechanism is proven here before anything
;; relies on it: interception across namespaces, interception of the
;; intra-namespace call attach-bodies makes to attach-body (which is what
;; catches a facade that inlines the nine-body loop instead of calling
;; attach-bodies), and restoration afterwards.
(defn assert-probe-mechanism! []
  (let [fired (atom false)]
    (with-redefs [lower/attach-bodies (forbidden "lower/attach-bodies")]
      (try
        (lower/attach-bodies nil [] [])
        (catch Exception e (reset! fired (some? (:probe (ex-data e)))))))
    (require! @fired
              (str "PROBE MECHANISM DEAD: a throwing probe on "
                   "lower/attach-bodies did not intercept")))
  (let [seen (atom [])]
    (with-redefs [lower/attach-body
                  (fn [_env resolution _source]
                    (swap! seen conj resolution)
                    resolution)]
      (lower/attach-bodies :probe-env [:a :b :c] [:x :y :z]))
    (require! (= [:a :b :c] @seen)
              (str "PROBE MECHANISM DEAD: a counting probe on "
                   "lower/attach-body saw " (pr-str @seen)
                   ", expected three delegated calls")))
  (require! (vector? (lower/attach-bodies :probe-env [] []))
            (str "PROBE MECHANISM DEAD: with-redefs did not restore "
                 "lower/attach-bodies"))
  (println "branch-compile-corpus: unit reuse probe mechanism verified"))

(defn decoded-typed [typed]
  (let [result (typed-wire-result (unit/typedunitv0-encoding typed)
                                  (unit/typedunitv0-unit-id typed))]
    (require! (instance? native.unit_reuse.TypedUnitWireDecodedV1 result)
              "an inherited typed payload did not decode through wire v1")
    (unit/typedunitwiredecodedv1-unit result)))

(defn decoded-native [native]
  (let [result (native-wire-result (unit/nativeunitv0-encoding native)
                                   (unit/nativeunitv0-unit-id native))]
    (require! (instance? native.unit_reuse.NativeUnitWireDecodedV1 result)
              "an inherited native payload did not decode through wire v1")
    (unit/nativeunitwiredecodedv1-unit result)))

(defn prepared-candidate [case-data compiler-context]
  (let [result (singleton/prepare-unit-compilation
                (:frozen-source case-data)
                compiler-context
                (:configuration case-data))]
    (require!
     (instance? native.unit_compile.UnitPreparationAcceptedV0 result)
     (str (:id case-data) " unit preparation rejected"
          (when (instance? native.unit_compile.UnitPreparationRejectedV0
                           result)
            (str ": " (singleton/unitpreparationrejectedv0-code result)
                 " " (singleton/unitpreparationrejectedv0-detail result)))))
    (singleton/unitpreparationacceptedv0-prepared result)))

(defn assert-prepared-contracts! [case-data prepared]
  (let [prepared-contracts (singleton/preparedcandidatev0-contracts prepared)
        by-id (into {} (map (juxt #(native-id-text
                                    (unit/unitcontractv0-unit-id %))
                                  identity)
                            prepared-contracts))]
    (require! (= (count (:contracts case-data)) (count prepared-contracts))
              (str (:id case-data) " signature-only preparation produced "
                   (count prepared-contracts) " contracts, expected "
                   (count (:contracts case-data))))
    (doseq [contract (:contracts case-data)]
      (let [identity-text (native-id-text
                           (unit/unitcontractv0-unit-id contract))
            match (get by-id identity-text)]
        (require! (some? match)
                  (str (:id case-data) " preparation omitted contract "
                       identity-text))
        (require! (= (unit/unitcontractv0-encoding contract)
                     (unit/unitcontractv0-encoding match))
                  (str (:id case-data) " prepared contract bytes differ from "
                       "clean extraction for " identity-text))
        (require! (= (unit/unitcontractv0-digest contract)
                     (unit/unitcontractv0-digest match))
                  (str (:id case-data) " prepared contract digest differs "
                       "from clean extraction for " identity-text))))))

(defn read-contracts-for [case-data source-unit]
  (let [wanted (set (map native-id-text
                         (stages/sourceunitv0-read-set source-unit)))]
    (vec (filter #(contains? wanted
                             (native-id-text (unit/unitcontractv0-unit-id %)))
                 (:contracts case-data)))))

(defn expected-result-key [case-data source-unit compiler-context]
  (unit/unit-result-key compiler-context source-unit (:contracts case-data)))

(defn singleton-typed! [candidate prepared row compiler-context]
  (let [source-unit (:source row)
        unit-id (stages/sourceunitv0-id source-unit)
        function-text (native-id-text
                       (lower/function-id
                        unit-id (stages/sourceunitv0-name source-unit)))
        key (expected-result-key candidate source-unit compiler-context)
        _ (probe-reset!)
        result (with-singleton-probes
                (fn []
                  (singleton/compile-typed-unit
                   prepared
                   unit-id
                   (stages/sourceunitv0-semantic-digest source-unit)
                   (stages/sourceunitv0-read-set source-unit)
                   (read-contracts-for candidate source-unit)
                   compiler-context
                   key)))]
    (require!
     (instance? native.unit_compile.TypedUnitCompiledV0 result)
     (str (:name row) " singleton typed compile rejected"
          (when (instance? native.unit_compile.TypedUnitCompileRejectedV0
                           result)
            (str ": " (singleton/typedunitcompilerejectedv0-code result)
                 " " (singleton/typedunitcompilerejectedv0-detail result)))))
    (require! (= [function-text] (probe-seen :attach-body))
              (str (:name row) " typed compile attached "
                   (pr-str (probe-seen :attach-body))
                   ", expected exactly [" function-text "]"))
    (require! (= [] (probe-seen :lower-ready-function))
              (str (:name row) " typed compile lowered a native function"))
    (require! (= [unit-id] (singleton/typedunitcompiledv0-trace result))
              (str (:name row) " typed trace was "
                   (pr-str (map native-id-text
                                (singleton/typedunitcompiledv0-trace result)))))
    (require! (= key (singleton/typedunitcompiledv0-result-key result))
              (str (:name row) " typed result key differs from the request"))
    (let [produced (singleton/typedunitcompiledv0-unit result)]
      (require! (= (unit/typedunitv0-encoding (:typed row))
                   (unit/typedunitv0-encoding produced))
                (str (:name row) " singleton typed bytes differ from clean "
                     "extraction"))
      (require! (= (unit/typedunitv0-digest (:typed row))
                   (unit/typedunitv0-digest produced))
                (str (:name row) " singleton typed digest differs from clean "
                     "extraction"))
      produced)))

(defn singleton-native! [candidate prepared row typed-set compiler-context abi]
  (let [source-unit (:source row)
        unit-id (stages/sourceunitv0-id source-unit)
        function-text (native-id-text
                       (lower/function-id
                        unit-id (stages/sourceunitv0-name source-unit)))
        key (expected-result-key candidate source-unit compiler-context)
        target (first (filter #(core/native-id= unit-id
                                                (unit/typedunitv0-unit-id %))
                              typed-set))
        _ (probe-reset!)
        result (with-singleton-probes
                (fn []
                  (singleton/compile-native-unit
                   prepared unit-id target typed-set compiler-context key
                   abi)))]
    (require!
     (instance? native.unit_compile.NativeUnitCompiledV0 result)
     (str (:name row) " singleton native compile rejected"
          (when (instance? native.unit_compile.NativeUnitCompileRejectedV0
                           result)
            (str ": " (singleton/nativeunitcompilerejectedv0-code result)
                 " " (singleton/nativeunitcompilerejectedv0-detail result)))))
    (require! (= [function-text] (probe-seen :lower-ready-function))
              (str (:name row) " native compile lowered "
                   (pr-str (probe-seen :lower-ready-function))
                   ", expected exactly [" function-text "]"))
    (require! (= [] (probe-seen :attach-body))
              (str (:name row) " native compile attached a body"))
    (require! (= [unit-id] (singleton/nativeunitcompiledv0-trace result))
              (str (:name row) " native trace was "
                   (pr-str
                    (map native-id-text
                         (singleton/nativeunitcompiledv0-trace result)))))
    (let [produced (singleton/nativeunitcompiledv0-unit result)]
      (require! (= (unit/nativeunitv0-encoding (:native row))
                   (unit/nativeunitv0-encoding produced))
                (str (:name row) " singleton native bytes differ from clean "
                     "extraction"))
      (require! (= (unit/nativeunitv0-digest (:native row))
                   (unit/nativeunitv0-digest produced))
                (str (:name row) " singleton native digest differs from clean "
                     "extraction"))
      produced)))

(defn replace-typed-unit [typed-set replacement]
  (mapv (fn [typed]
          (if (core/native-id= (unit/typedunitv0-unit-id typed)
                               (unit/typedunitv0-unit-id replacement))
            replacement
            typed))
        typed-set))

(defn require-native-not-settled! [label thunk]
  (let [attach-before (probe-total :attach-body)
        lower-before (probe-total :lower-ready-function)
        _ (probe-reset!)
        result (with-singleton-probes thunk)]
    (require!
     (instance? native.unit_compile.NativeUnitCompileRejectedV0 result)
     (str label " was admitted outside the singleton settlement subset"))
    (require! (= "UNIT-TARGET-NOT-SETTLED"
                 (singleton/nativeunitcompilerejectedv0-code result))
              (str label " received rejection "
                   (singleton/nativeunitcompilerejectedv0-code result)
                   ", expected UNIT-TARGET-NOT-SETTLED"))
    (require! (= [] (probe-seen :attach-body))
              (str label " rejection attached a body"))
    (require! (= [] (probe-seen :lower-ready-function))
              (str label " rejection lowered a native function"))
    (require! (= attach-before (probe-total :attach-body))
              (str label " rejection changed the body-attach total"))
    (require! (= lower-before (probe-total :lower-ready-function))
              (str label " rejection changed the native-lower total"))))

(defn assert-singleton-subset-rejections!
  [case-data compiler-context abi]
  (let [prepared (prepared-candidate case-data compiler-context)
        row (get (rows-by-name case-data)
                 "corpus.foundation/private-offset")
        source-unit (:source row)
        unit-id (stages/sourceunitv0-id source-unit)
        target (:typed row)
        function (unit/typedunitv0-function target)
        typed-set (:typed-units case-data)
        result-key (expected-result-key case-data source-unit compiler-context)
        invoke (fn [replacement]
                 (singleton/compile-native-unit
                  prepared unit-id replacement
                  (replace-typed-unit typed-set replacement)
                  compiler-context result-key abi))
        not-ready
        (assoc target :function
               (assoc function :readiness
                      (lower/->NativeTodoV0 "UNIT-TEST-NOT-READY"
                                           "settlement rejection witness")))
        not-pure
        (assoc target :function
               (assoc function :effects [(lower/write-effect-id)]))]
    (require! (singleton/at-settlement-fixpoint? function)
              "singleton rejection fixture is not at the settlement fixpoint")
    (require-native-not-settled! "not-ready target"
                                 (fn [] (invoke not-ready)))
    (require-native-not-settled!
     "non-pure target"
     (fn []
       (with-redefs [lower/function-regions (fn [_] [])
                     lower/function-capabilities (fn [_] [])]
         (invoke not-pure))))
    (require-native-not-settled!
     "region-bearing target"
     (fn []
       (with-redefs [lower/function-regions
                     (fn [_] [(lower/arena-region-id)])
                     lower/function-capabilities (fn [_] [])]
         (invoke target))))
    (require-native-not-settled!
     "capability-bearing target"
     (fn []
       (with-redefs [lower/function-regions (fn [_] [])
                     lower/function-capabilities
                     (fn [_] [(lower/write-capability-id)])]
         (invoke target))))
    (println
     (str "branch-compile-corpus: singleton subset rejection PASS "
          "ready+pure+region-free+capability-free only"))))

(defn assert-stale-dependency-context-rejected!
  [baseline public compiler-context]
  (let [prepared (prepared-candidate public compiler-context)
        row (get (rows-by-name public) "corpus.feature/score-value")
        source-unit (:source row)
        unit-id (stages/sourceunitv0-id source-unit)
        stale-contracts
        [(contract-for baseline "corpus.foundation/adjust")]
        result-key
        (unit/unit-result-key compiler-context source-unit stale-contracts)
        attach-before (probe-total :attach-body)
        lower-before (probe-total :lower-ready-function)
        _ (probe-reset!)
        result
        (with-singleton-probes
         (fn []
           (singleton/compile-typed-unit
            prepared
            unit-id
            (stages/sourceunitv0-semantic-digest source-unit)
            (stages/sourceunitv0-read-set source-unit)
            stale-contracts
            compiler-context
            result-key)))]
    (require!
     (instance? native.unit_compile.TypedUnitCompileRejectedV0 result)
     "stale score-value dependency context was accepted")
    (require! (= "UNIT-DEPENDENCY-CONTEXT"
                 (singleton/typedunitcompilerejectedv0-code result))
              (str "stale score-value dependency context rejected with "
                   (singleton/typedunitcompilerejectedv0-code result)
                   ", expected UNIT-DEPENDENCY-CONTEXT"))
    (require! (core/native-id= unit-id
                              (singleton/typedunitcompilerejectedv0-unit-id
                               result))
              "stale dependency context rejection named the wrong unit")
    (require! (= [] (probe-seen :attach-body))
              "stale dependency context rejection attached a body")
    (require! (= [] (probe-seen :lower-ready-function))
              "stale dependency context rejection lowered a native function")
    (require! (= [] @probe-attached-readiness)
              "stale dependency context rejection produced a typed payload")
    (require! (= attach-before (probe-total :attach-body))
              "stale dependency context rejection changed the body total")
    (require! (= lower-before (probe-total :lower-ready-function))
              "stale dependency context rejection changed the native total")
    (println
     "branch-compile-corpus: stale dependency context PASS zero activity")))

(defn prepared-with-empty-do [prepared row]
  (let [source-unit (:source row)
        unit-id (stages/sourceunitv0-id source-unit)
        prelude (singleton/preparedcandidatev0-prelude prepared)
        env (lower/typingpreludev0-env prelude)
        resolutions (lower/typingpreludev0-signature-resolutions prelude)
        target-function
        (lower/function-id unit-id (stages/sourceunitv0-name source-unit))
        position (singleton/signature-index-for resolutions target-function)
        sources (lower/bodyenvv0-signature-sources env)
        _ (require! (and (>= position 0) (< position (count sources)))
                    "empty-do witness could not locate independent-value")
        source-function (nth sources position)
        empty-do (core/->NativeId "unit-gate/independent-value/empty-do")
        empty-body (core/->NativeId "unit-gate/independent-value/empty-body")
        index (lower/bodyenvv0-index env)
        objects
        (assoc (lower/sourceindexv0-first-objects index)
               (lower/source-index-key source-function "body") empty-do
               (lower/source-index-key empty-do "body") empty-body)
        texts
        (assoc (lower/sourceindexv0-first-texts index)
               (lower/source-index-key empty-do "form-kind") "do")
        altered-index (assoc index :first-objects objects :first-texts texts)
        altered-env (assoc env :index altered-index)
        altered-prelude (assoc prelude :env altered-env)]
    (assoc prepared :prelude altered-prelude)))

(defn assert-unrelated-empty-do-locality!
  [baseline compiler-context]
  (let [rows (rows-by-name baseline)
        private-row (get rows "corpus.foundation/private-offset")
        independent-row (get rows "corpus.independent/independent-value")
        prepared
        (prepared-with-empty-do
         (prepared-candidate baseline compiler-context)
         independent-row)
        attach-before (probe-total :attach-body)
        lower-before (probe-total :lower-ready-function)
        private-unit
        (singleton-typed! baseline prepared private-row compiler-context)
        source-unit (:source independent-row)
        unit-id (stages/sourceunitv0-id source-unit)
        function-text
        (native-id-text
         (lower/function-id unit-id (stages/sourceunitv0-name source-unit)))
        reset-probes (probe-reset!)
        result
        (with-singleton-probes
         (fn []
           (singleton/compile-typed-unit
            prepared
            unit-id
            (stages/sourceunitv0-semantic-digest source-unit)
            (stages/sourceunitv0-read-set source-unit)
            (read-contracts-for baseline source-unit)
            compiler-context
            (expected-result-key baseline source-unit compiler-context))))]
    (require!
     (instance? native.unit_compile.TypedUnitCompileRejectedV0 result)
     "empty-do independent-value was accepted")
    (require! (= "UNIT-TARGET-NOT-SETTLED"
                 (singleton/typedunitcompilerejectedv0-code result))
              (str "empty-do independent-value rejected with "
                   (singleton/typedunitcompilerejectedv0-code result)
                   ", expected UNIT-TARGET-NOT-SETTLED"))
    (require! (core/native-id= unit-id
                              (singleton/typedunitcompilerejectedv0-unit-id
                               result))
              "empty-do rejection named the wrong unit")
    (require! (= [function-text] (probe-seen :attach-body))
              (str "empty-do rejection attached "
                   (pr-str (probe-seen :attach-body))
                   ", expected exactly [" function-text "]"))
    (require! (= [] (probe-seen :lower-ready-function))
              "empty-do rejection lowered a native function")
    (require! (= 1 (count @probe-attached-readiness))
              "empty-do rejection did not preserve one readiness result")
    (let [readiness (first @probe-attached-readiness)]
      (require! (instance? native.lower.NativeTodoV0 readiness)
                "empty-do rejection did not preserve its NativeTodo")
      (require! (= "TODO-NATIVE-FUNCTION-BODY"
                   (lower/nativetodov0-code readiness))
                "empty-do rejection changed its outer TODO code")
      (require!
       (= (str "TODO-NATIVE-DO-EMPTY: empty do is outside the native slice "
               "[independent-value]")
          (lower/nativetodov0-detail readiness))
       (str "empty-do rejection changed its TODO detail: "
            (lower/nativetodov0-detail readiness))))
    (require! (= 2 (- (probe-total :attach-body) attach-before))
              "unrelated-body witness did not attach exactly two targets")
    (require! (= lower-before (probe-total :lower-ready-function))
              "unrelated-body witness performed native lowering")
    (println
     (str "branch-compile-corpus: unrelated empty-do PASS private-offset exact, "
          "independent-value rejected with preserved TODO and zero native "
          "lowering"))))

(defn assert-singleton-repetition! [label first-result second-result]
  (require! (= first-result second-result)
            (str label " singleton repetition changed the exact assembly")))

(defn assert-singleton-case!
  [baseline candidate expected compiler-context compiler-commit abi]
  (let [expected-set (set expected)
        candidate-rows (rows-by-name candidate)
        baseline-rows (rows-by-name baseline)
        attach-before (probe-total :attach-body)
        lower-before (probe-total :lower-ready-function)
        prepared (do (probe-reset!)
                     (with-singleton-probes
                      (fn [] (prepared-candidate candidate compiler-context))))]
    (require! (= [] (probe-seen :attach-body))
              (str (:id candidate) " signature-only preparation attached "
                   (pr-str (probe-seen :attach-body))))
    (require! (= [] (probe-seen :lower-ready-function))
              (str (:id candidate)
                   " signature-only preparation lowered a native function"))
    (assert-prepared-contracts! candidate prepared)
    (let [typed-by-name
          (into {} (map (fn [name]
                          [name (singleton-typed! candidate prepared
                                                  (get candidate-rows name)
                                                  compiler-context)])
                        expected-set))
          ;; Inherited units arrive through the wire, never from the clean
          ;; build's heap, so a singleton that secretly needs a non-wire field
          ;; fails here rather than in the cold-process harness.
          typed-set (mapv (fn [row]
                            (if (contains? expected-set (:name row))
                              (get typed-by-name (:name row))
                              (decoded-typed
                               (:typed (get baseline-rows (:name row))))))
                          (:rows candidate))
          native-by-name
          (into {} (map (fn [name]
                          [name (singleton-native! candidate prepared
                                                   (get candidate-rows name)
                                                   typed-set compiler-context
                                                   abi)])
                        expected-set))
          native-set (mapv (fn [row]
                             (if (contains? expected-set (:name row))
                               (get native-by-name (:name row))
                               (decoded-native
                                (:native (get baseline-rows (:name row))))))
                           (:rows candidate))
          mixed {:typed typed-set :native native-set}
          assembly (assembly!
                    (unit/assemble-unit-payloads
                     (:frozen-source candidate)
                     (:contracts candidate)
                     typed-set
                     native-set
                     compiler-commit
                     (:configuration candidate)
                     abi)
                    (str (:id candidate) " singleton"))]
      (require! (= (count expected-set)
                   (- (probe-total :attach-body) attach-before))
                (str (:id candidate) " compiled "
                     (- (probe-total :attach-body) attach-before)
                     " bodies, expected exactly " (count expected-set)))
      (require! (= (count expected-set)
                   (- (probe-total :lower-ready-function) lower-before))
                (str (:id candidate) " lowered "
                     (- (probe-total :lower-ready-function) lower-before)
                     " functions, expected exactly " (count expected-set)))
      (assert-frozen-equality! candidate assembly)
      (assert-obligations! candidate assembly)
      (assert-c17! candidate assembly)
      (assert-reversed! candidate mixed assembly compiler-commit abi)
      assembly)))

(defn -main [& args]
  (require! (= 2 (count args))
            "usage: unit_reuse_gate.clj BUILD_ROOT COMPILER_COMMIT")
  (let [[build-root compiler-commit] args
        abi (core/abi-profile-lp64)
        compiler-context
        (stages/content-digest
         (stages/canonical-record
          "branch-unit-reuse-gate-context-v0"
          [compiler-commit "profile=3" "abi=lp64" "materializer=c17"
           "unit-contract-v0" "typed-unit-wire-v1"
           "native-unit-wire-v1"]))
        baseline (load-case build-root "baseline" compiler-commit abi)
        comment (load-case build-root "comment-layout" compiler-commit abi)
        private (load-case build-root "private-implementation" compiler-commit abi)
        public (load-case build-root "public-interface" compiler-commit abi)]
    (assert-probe-mechanism!)
    (assert-contract-shape! baseline)
    (assert-wire-round-trips! baseline)
    (assert-v0-rejected! baseline)
    (assert-v0-semantic-collision! baseline)
    (assert-wire-rejections! baseline)
    (assert-shared-support! baseline)
    (require! (= #{} (changed-names baseline comment :contract contract-digest))
              "comment/layout changed a unit contract")
    (assert-case! baseline comment [] compiler-context compiler-commit abi)
    (assert-contracts! baseline private public)
    (assert-case! baseline private
                  ["corpus.foundation/private-offset"]
                  compiler-context compiler-commit abi)
    (assert-case! baseline public
                  ["corpus.foundation/adjust"
                   "corpus.feature/score-value"]
                  compiler-context compiler-commit abi)
    (assert-prepared-contracts! baseline
                                (prepared-candidate baseline compiler-context))
    (assert-stale-dependency-context-rejected! baseline public
                                                compiler-context)
    (assert-unrelated-empty-do-locality! baseline compiler-context)
    (reset! probe-totals {:attach-body 0 :lower-ready-function 0})
    (let [comment-first
          (assert-singleton-case! baseline comment [] compiler-context
                                  compiler-commit abi)
          private-first
          (assert-singleton-case! baseline private
                                  ["corpus.foundation/private-offset"]
                                  compiler-context compiler-commit abi)
          public-first
          (assert-singleton-case! baseline public
                                  ["corpus.foundation/adjust"
                                   "corpus.feature/score-value"]
                                  compiler-context compiler-commit abi)]
      (require! (= 3 (probe-total :attach-body))
                (str "singleton first round attached "
                     (probe-total :attach-body)
                     " bodies in total, expected exactly 3 (0 + 1 + 2)"))
      (require! (= 3 (probe-total :lower-ready-function))
                (str "singleton first round lowered "
                     (probe-total :lower-ready-function)
                     " functions in total, expected exactly 3 (0 + 1 + 2)"))
      (reset! probe-totals {:attach-body 0 :lower-ready-function 0})
      (let [comment-second
            (assert-singleton-case! baseline comment [] compiler-context
                                    compiler-commit abi)
            private-second
            (assert-singleton-case! baseline private
                                    ["corpus.foundation/private-offset"]
                                    compiler-context compiler-commit abi)
            public-second
            (assert-singleton-case! baseline public
                                    ["corpus.foundation/adjust"
                                     "corpus.feature/score-value"]
                                    compiler-context compiler-commit abi)]
        (require! (= 3 (probe-total :attach-body))
                  (str "singleton second round attached "
                       (probe-total :attach-body)
                       " bodies in total, expected exactly 3 (0 + 1 + 2)"))
        (require! (= 3 (probe-total :lower-ready-function))
                  (str "singleton second round lowered "
                       (probe-total :lower-ready-function)
                       " functions in total, expected exactly 3 (0 + 1 + 2)"))
        (assert-singleton-repetition! "comment/layout"
                                      comment-first comment-second)
        (assert-singleton-repetition! "private implementation"
                                      private-first private-second)
        (assert-singleton-repetition! "public interface"
                                      public-first public-second)
        (assert-singleton-subset-rejections! baseline compiler-context abi)
        (assert-duplicate-identities-rejected! baseline compiler-commit abi)
        (assert-collision-rejected! baseline compiler-commit abi)
        (assert-layout-digest-rejected! baseline compiler-commit abi)
        (assert-unsupported-rejected! baseline compiler-commit abi)
        (println
         "branch-compile-corpus: unit reuse PASS 9/9, 8/9, 7/9 exact reuse")
        (println
         (str "branch-compile-corpus: singleton PASS 0/1/2 compiled units, "
              (probe-total :attach-body) " attach-body, "
              (probe-total :lower-ready-function)
              " lower-ready-function, deterministic repetition"))))))

(apply -main *command-line-args*)
