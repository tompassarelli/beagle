(require '[native.body-slice :as body-slice]
         '[native.core :as core]
         '[native.lower :as lower]
         '[native.qbe :as qbe]
         '[native.slice :as slice]
         '[native.stages :as stages])

(let [[facts-path module-name relative-path compiler-commit] *command-line-args*
      configuration ["profile=3"]
      rows (slice/parse-facts (slurp facts-path))
      source (slice/source-program rows module-name relative-path)
      frozen-source (lower/sourcefreezeacceptedv0-frozen
                      (lower/freeze-source-stage source compiler-commit configuration))
      typing (lower/lower-typed-stage frozen-source compiler-commit configuration)
      native-result (lower/lower-native-stage
                     (lower/typingacceptedv0-frozen typing)
                     (lower/typingacceptedv0-slice typing)
                     compiler-commit configuration
                     (core/abi-profile-lp64))
      frozen-native (slice/native-frozen native-result)
      program (stages/nativestagev0-program
             (stages/frozennativestagev0-stage frozen-native))
      projected (body-slice/projected-program program)
      result (qbe/materialize-program projected 0 "lp64")
      expected "native program uses a shape outside the QBE materializer's slice"]
  (if (= expected (get result :detail))
    (println "qbe explicit map-access refusal ok")
    (throw (ex-info "QBE did not explicitly refuse keyword map access"
                    {:result result}))))
