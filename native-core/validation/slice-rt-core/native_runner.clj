(require '[native.body-slice :as body-slice]
         '[native.core :as core]
         '[native.lower :as lower]
         '[native.qbe :as qbe]
         '[native.slice :as slice]
         '[native.stages :as stages])

(defn qbe-report [facts-path artifacts-dir compiler-commit abi]
  (let [rows (slice/parse-facts (slurp facts-path))
        configuration ["profile=3" (str "abi=" (core/abiprofilev0-id abi))]
        source (slice/source-program rows "fram.rt-core" "fram:src/fram/rt_core.bclj")
        freeze-result (lower/freeze-source-stage source compiler-commit configuration)]
    (cond
      (not (instance? native.lower.SourceFreezeAcceptedV0 freeze-result))
      "qbe-materialize SKIPPED source-freeze rejected\n"

      :else
      (let [frozen-source (lower/sourcefreezeacceptedv0-frozen freeze-result)
            typing-result (lower/lower-typed-stage frozen-source compiler-commit configuration)]
        (if (not (instance? native.lower.TypingAcceptedV0 typing-result))
          "qbe-materialize SKIPPED source-to-typed rejected\n"
          (let [frozen-typed (lower/typingacceptedv0-frozen typing-result)
                typed-slice (lower/typingacceptedv0-slice typing-result)
                native-result (lower/lower-native-stage
                                frozen-typed typed-slice compiler-commit configuration
                                abi)
                frozen-native (slice/native-frozen native-result)
                program (stages/nativestagev0-program
                          (stages/frozennativestagev0-stage frozen-native))
                projected (body-slice/projected-program program)
                result (qbe/materialize-program projected 0 (core/abiprofilev0-id abi))]
            (if (instance? native.qbe.QbeSuccess result)
              (let [artifact (qbe/qbesuccess-artifact result)
                    name (qbe/qbeartifact-module-name artifact)]
                (spit (str artifacts-dir "/" name)
                  (qbe/qbeartifact-module-text artifact))
                (str "qbe-materialize OK " name "\n"))
              (str "qbe-materialize REFUSED "
                (qbe/qbefailure-detail result) "\n"))))))))

(let [[facts-path artifacts-dir compiler-commit report-path] *command-line-args*]
  (when (some nil? [facts-path artifacts-dir compiler-commit report-path])
    (throw (ex-info
      "usage: native_runner.clj FACTS ARTIFACTS COMPILER-COMMIT REPORT" {})))
  (let [abi-id (or (System/getenv "NATIVE_SLICE_ABI") "lp64")
        abi (core/abi-profile-for abi-id)
        c-report (body-slice/emit-slice! facts-path "fram.rt-core"
                   "fram:src/fram/rt_core.bclj" artifacts-dir compiler-commit
                   abi-id)
        backend-report (try
                         (qbe-report facts-path artifacts-dir compiler-commit abi)
                         (catch Throwable error
                           (str "qbe-materialize ERROR "
                             (.getName (class error)) ": "
                             (or (.getMessage error) "no message") "\n")))]
    (spit report-path (str c-report backend-report))))
