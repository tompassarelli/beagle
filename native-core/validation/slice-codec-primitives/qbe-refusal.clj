(require '[clojure.string :as str]
         '[native.body-slice :as body-slice]
         '[native.core :as core]
         '[native.lower :as lower]
         '[native.qbe :as qbe]
         '[native.slice :as slice]
         '[native.stages :as stages])

(let [[facts-manifest-path module-name relative-path compiler-commit] *command-line-args*
      configuration ["profile=3"]
      rows (slice/read-fact-manifest facts-manifest-path)
      source (slice/source-program rows module-name relative-path)
      frozen-source (lower/sourcefreezeacceptedv0-frozen
                      (lower/freeze-source-stage source compiler-commit configuration))
      typing (lower/lower-typed-stage frozen-source compiler-commit configuration)
      native-result (lower/lower-native-stage
                     (lower/typingacceptedv0-frozen typing)
                     (lower/typingacceptedv0-slice typing)
                     compiler-commit configuration
                     (core/abi-profile-lp64))
      frozen-native (lower/epoch-result-frozen
                      (lower/epoch-identity-stage
                        (slice/require-native-complete native-result)
                        compiler-commit configuration
                        (core/abi-profile-lp64)))
      program (stages/nativestagev0-program
             (stages/frozennativestagev0-stage frozen-native))
      projected (body-slice/projected-program program)
      result (qbe/materialize-program projected 0 "lp64")
      detail (get result :detail)]
  (if (and (string? detail)
           (str/starts-with? detail "QBE codec primitive is unsupported: "))
    (println detail)
    (throw (ex-info "QBE did not explicitly refuse codec primitives"
                    {:result result}))))
