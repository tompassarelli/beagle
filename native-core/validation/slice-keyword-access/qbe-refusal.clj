(require '[native.body-slice :as body-slice]
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
                     compiler-commit configuration)
      sealed-native (slice/native-sealed native-result)
      world (worlds/nativeworldv0-program
             (worlds/sealednativeworldv0-world sealed-native))
      projected (body-slice/projected-world world)
      result (qbe/materialize-world projected 0)
      expected "native world uses a shape outside the QBE materializer's slice"]
  (if (= expected (get result :detail))
    (println "qbe explicit map-access refusal ok")
    (throw (ex-info "QBE did not explicitly refuse keyword map access"
                    {:result result}))))
