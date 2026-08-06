(require '[clojure.string :as str]
         '[native.body-slice :as body-slice]
         '[native.core :as core]
         '[native.lower :as lower]
         '[native.qbe :as qbe]
         '[native.slice :as slice]
         '[native.worlds :as worlds])

(let [[facts-path module-name relative-path compiler-commit] *command-line-args*
      configuration ["profile=3"]
      rows (slice/parse-facts (slurp facts-path))
      source (slice/source-world rows module-name relative-path)
      sealed-source (lower/sourcesealacceptedv0-sealed
                      (lower/seal-source-world source compiler-commit configuration))
      typing (lower/lower-typed-world sealed-source compiler-commit configuration)
      native-result (lower/lower-native-world
                     (lower/typingacceptedv0-sealed typing)
                     (lower/typingacceptedv0-slice typing)
                     compiler-commit configuration
                     (core/abi-profile-lp64))
      sealed-native (slice/native-sealed native-result)
      world (worlds/nativeworldv0-program
             (worlds/sealednativeworldv0-world sealed-native))
      projected (body-slice/projected-world world)
      result (qbe/materialize-world projected 0 "lp64")
      detail (get result :detail)]
  (if (and (string? detail)
           (str/starts-with? detail "QBE codec primitive is unsupported: "))
    (println detail)
    (throw (ex-info "QBE did not explicitly refuse codec primitives"
                    {:result result}))))
