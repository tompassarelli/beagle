 (require '[native.slice-types-pipeline :as pipeline]
          '[native.lower :as lower])

 (let [[facts-path source-path report-path] *command-line-args*
       facts (read-string (slurp facts-path))
       source (pipeline/source-program facts (slurp source-path))
       result (lower/freeze-source-stage
                source
                "source-freeze-path-test"
                ["profile=3" "module=fram.types" "slice=Instant"])]
   (spit report-path
     (if (instance? native.lower.SourceFreezeAcceptedV0 result)
       "stage source-freeze ACCEPTED\n"
       "stage source-freeze REJECTED\n")))
