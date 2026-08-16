(ns unit-reuse-gate
  (:require [clojure.set :as set]
            [native.core :as core]
            [native.stages :as stages]
            [native.lower :as lower]
            [native.obligations :as obligations]
            [native.slice :as slice]
            [native.unit-reuse :as unit]
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
             (str case-id " unit extraction rejected"))
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
           "unit-contract-v0" "typed-unit-v0" "native-unit-v0"]))
        baseline (load-case build-root "baseline" compiler-commit abi)
        comment (load-case build-root "comment-layout" compiler-commit abi)
        private (load-case build-root "private-implementation" compiler-commit abi)
        public (load-case build-root "public-interface" compiler-commit abi)]
    (assert-contract-shape! baseline)
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
    (assert-collision-rejected! baseline compiler-commit abi)
    (assert-unsupported-rejected! baseline compiler-commit abi)
    (println "branch-compile-corpus: unit reuse PASS 9/9, 8/9, 7/9 exact reuse")))

(apply -main *command-line-args*)
