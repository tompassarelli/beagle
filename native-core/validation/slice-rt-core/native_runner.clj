(require '[native.body-slice :as body-slice]
         '[native.lower :as lower]
         '[native.qbe :as qbe]
         '[native.slice :as slice]
         '[native.worlds :as worlds])

(defn qbe-report [facts-path artifacts-dir compiler-commit]
  (let [rows (slice/parse-facts (slurp facts-path))
        configuration ["profile=3"]
        source (slice/source-world rows "fram.rt-core" "fram:src/fram/rt_core.bclj")
        seal-result (lower/seal-source-world source compiler-commit configuration)]
    (cond
      (not (instance? native.lower.SourceSealAcceptedV0 seal-result))
      "qbe-materialize SKIPPED source-seal rejected\n"

      :else
      (let [sealed-source (lower/sourcesealacceptedv0-sealed seal-result)
            typing-result (lower/lower-typed-world sealed-source compiler-commit configuration)]
        (if (not (instance? native.lower.TypingAcceptedV0 typing-result))
          "qbe-materialize SKIPPED source-to-typed rejected\n"
          (let [sealed-typed (lower/typingacceptedv0-sealed typing-result)
                typed-slice (lower/typingacceptedv0-slice typing-result)
                native-result (lower/lower-native-world
                                sealed-typed typed-slice compiler-commit configuration)
                sealed-native (slice/native-sealed native-result)
                program (worlds/nativeworldv0-program
                          (worlds/sealednativeworldv0-world sealed-native))
                projected (body-slice/projected-world program)
                result (qbe/materialize-world projected 0)]
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
  (let [c-report (body-slice/emit-slice! facts-path "fram.rt-core"
                   "fram:src/fram/rt_core.bclj" artifacts-dir compiler-commit)
        backend-report (try
                         (qbe-report facts-path artifacts-dir compiler-commit)
                         (catch Throwable error
                           (str "qbe-materialize ERROR "
                             (.getName (class error)) ": "
                             (or (.getMessage error) "no message") "\n")))]
    (spit report-path (str c-report backend-report))))
