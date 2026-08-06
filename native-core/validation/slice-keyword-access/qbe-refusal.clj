(require '[native.body-slice :as body-slice]
         '[native.core :as core]
         '[native.lower :as lower]
         '[native.qbe :as qbe]
         '[native.slice :as slice]
         '[native.worlds :as worlds])

(let [[facts-path module-name relative-path compiler-commit] *command-line-args*
      configuration ["profile=3"]
      rows (slice/parse-facts (slurp facts-path))
      source (slice/source-world rows module-name relative-path)
      frozen-source (lower/sourcefreezeacceptedv0-frozen
                      (lower/freeze-source-world source compiler-commit configuration))
      typing (lower/lower-typed-world frozen-source compiler-commit configuration)
      native-result (lower/lower-native-world
                     (lower/typingacceptedv0-frozen typing)
                     (lower/typingacceptedv0-slice typing)
                     compiler-commit configuration
                     (core/abi-profile-lp64))
      frozen-native (slice/native-frozen native-result)
      world (worlds/nativeworldv0-program
             (worlds/frozennativeworldv0-world frozen-native))
      projected (body-slice/projected-world world)
      result (qbe/materialize-world projected 0 "lp64")
      expected "native world uses a shape outside the QBE materializer's slice"]
  (if (= expected (get result :detail))
    (println "qbe explicit map-access refusal ok")
    (throw (ex-info "QBE did not explicitly refuse keyword map access"
                    {:result result}))))
