(require '[clojure.java.io :as io]
         '[clojure.string :as str]
         '[native.body-c17 :as body]
         '[native.body-slice :as body-slice]
         '[native.core :as core]
         '[native.lower :as lower]
         '[native.obligations :as obligations]
         '[native.qbe :as qbe]
         '[native.slice :as slice]
         '[native.worlds :as worlds])

(defn one-line [value]
  (-> (str value)
      (str/replace "\\" "\\\\")
      (str/replace "\n" "\\n")
      (str/replace "\r" "\\r")
      (str/replace "\t" "\\t")))

(defn receipt-report [label receipt]
  (str
   (apply str
          (for [diagnostic (core/passreceiptv0-diagnostics receipt)]
            (str "receipt-diagnostic " label " "
                 (core/diagnosticv0-code diagnostic) " "
                 (one-line (core/diagnosticv0-detail diagnostic)) "\n")))
   (apply str
          (for [obligation (core/passreceiptv0-obligations receipt)]
            (str "receipt-obligation " label " "
                 (if (core/receiptobligationv0-passed obligation) "PASS" "FAIL")
                 " " (one-line (core/receiptobligationv0-detail obligation)) "\n")))))

(defn source-report [source]
  (let [modules (worlds/sourceprogramworldv0-modules source)
        imports (worlds/sourceprogramworldv0-imports source)]
    (str "source-modules " (count modules) "\n"
         (apply str
                (map-indexed
                 (fn [index module]
                   (str "source-module " index " "
                        (worlds/sourcemodulev0-name module) " "
                        (worlds/sourcemodulev0-relative-path module) "\n"))
                 modules))
         "source-imports " (count imports) "\n"
         (apply str
                (map-indexed
                 (fn [index import-id]
                   (str "source-import " index " "
                        (core/nativeid-value import-id) "\n"))
                 imports)))))

(defn function-report [world]
  (let [functions (sort-by
                   (fn [function]
                     [(core/functiondef-name function)
                      (core/nativeid-value (core/functiondef-id function))])
                   (core/nativeworld-functions world))]
    (apply str
           (for [function functions]
             (str "world-function " (core/functiondef-name function) " "
                  (count (core/functiondef-blocks function)) " blocks\n")))))

(defn obligation-report [world]
  (let [names (slice/obligation-names)
        verdicts (obligations/validate-native-world world)]
    (apply str
           (map (fn [name verdict]
                  (str "obligation " name " "
                       (if (obligations/obligation-passed? verdict) "PASS" "FAIL")
                       (if (obligations/obligation-passed? verdict)
                         ""
                         (str " " (body-slice/verdict-subject verdict)))
                       "\n"))
                names verdicts))))

(defn all-obligations-pass? [world]
  (every? obligations/obligation-passed?
          (obligations/validate-native-world world)))

(defn clear-materializations! [artifacts-dir]
  (doseq [file (or (.listFiles (io/file artifacts-dir)) [])
          :when (re-matches #"module_[0-9]+\.(?:h|c|ssa)" (.getName file))]
    (io/delete-file file true)))

(defn c17-materializations! [world module-count artifacts-dir]
  (loop [module-index 0
         all-ok? true
         report ""]
    (if (>= module-index module-count)
      [all-ok? report]
      (let [result (body/materialize-world world module-index)]
        (if (body/materialization-ok? result)
          (let [artifact (body/materialization-artifact result)]
            (spit (io/file artifacts-dir
                           (body/bodyartifactv0-header-name artifact))
                  (body/bodyartifactv0-header-text artifact))
            (spit (io/file artifacts-dir
                           (body/bodyartifactv0-source-name artifact))
                  (body/bodyartifactv0-source-text artifact))
            (recur (inc module-index) all-ok?
                   (str report "c17 module_" module-index " OK\n")))
          (recur (inc module-index) false
                 (str report "c17 module_" module-index " REFUSED "
                      (one-line (body/materialization-detail result)) "\n")))))))

(defn qbe-materializations! [world module-count artifacts-dir]
  (loop [module-index 0 report ""]
    (if (>= module-index module-count)
      report
      (let [result (qbe/materialize-world world module-index)]
        (if (instance? native.qbe.QbeSuccess result)
          (let [artifact (qbe/qbesuccess-artifact result)]
            (spit (io/file artifacts-dir
                           (qbe/qbeartifact-module-name artifact))
                  (qbe/qbeartifact-module-text artifact))
            (recur (inc module-index)
                   (str report "qbe module_" module-index " OK\n")))
          (recur (inc module-index)
                 (str report "qbe module_" module-index " UNSUPPORTED "
                      (one-line (qbe/qbefailure-detail result)) "\n")))))))

(defn blocked-materialization-report [backend module-count detail]
  (apply str
         (for [module-index (range module-count)]
           (str backend " module_" module-index " REFUSED " detail "\n"))))

(defn project! [facts-path module-name relative-path artifacts-dir compiler-commit]
  (clear-materializations! artifacts-dir)
  (let [rows (slice/parse-facts (slurp facts-path))
        configuration ["profile=3"]
        source (slice/source-world rows module-name relative-path)
        source-text (source-report source)
        seal-result (lower/seal-source-world source compiler-commit configuration)]
    (if (instance? native.lower.SourceSealRejectedV0 seal-result)
      {:status "FRONTIER"
       :report (str "stage source-seal REJECTED\n"
                    source-text
                    (receipt-report
                     "source-seal"
                     (lower/sourcesealrejectedv0-receipt seal-result)))}
      (let [seal-receipt (lower/sourcesealacceptedv0-receipt seal-result)
            sealed-source (lower/sourcesealacceptedv0-sealed seal-result)
            typing-result (lower/lower-typed-world
                           sealed-source compiler-commit configuration)]
        (if (instance? native.lower.TypingRejectedV0 typing-result)
          {:status "FRONTIER"
           :report (str "stage source-seal ACCEPTED\n"
                        "stage source-to-typed REJECTED\n"
                        source-text
                        (receipt-report "source-seal" seal-receipt)
                        (receipt-report
                         "source-to-typed"
                         (lower/typingrejectedv0-receipt typing-result)))}
          (let [typing-receipt (lower/typingacceptedv0-receipt typing-result)
                sealed-typed (lower/typingacceptedv0-sealed typing-result)
                typed-slice (lower/typingacceptedv0-slice typing-result)
                native-result (lower/lower-native-world
                               sealed-typed typed-slice compiler-commit configuration)
                native-complete? (instance? native.lower.NativeLoweringCompleteV0
                                            native-result)
                native-receipt (if native-complete?
                                 (lower/nativeloweringcompletev0-receipt native-result)
                                 (lower/nativeloweringpendingv0-receipt native-result))
                sealed-native (slice/native-sealed native-result)
                world (worlds/nativeworldv0-program
                       (worlds/sealednativeworldv0-world sealed-native))
                projected (body-slice/projected-world world)
                module-count (count (worlds/sourceprogramworldv0-modules source))
                obligations-ok? (all-obligations-pass? projected)
                [c17-ok? c17-report]
                (if (and native-complete? obligations-ok?)
                  (c17-materializations! projected module-count artifacts-dir)
                  [false (blocked-materialization-report
                          "c17" module-count
                          "native world is not complete")])
                qbe-report
                (if (and native-complete? obligations-ok?)
                  (qbe-materializations! projected module-count artifacts-dir)
                  (blocked-materialization-report
                   "qbe" module-count "native world is not complete"))
                complete? (and native-complete? obligations-ok? c17-ok?)]
            {:status (if complete? "COMPLETE" "FRONTIER")
             :report
             (str "stage source-seal ACCEPTED\n"
                  "stage source-to-typed ACCEPTED\n"
                  "stage typed-to-native "
                  (if native-complete? "COMPLETE" "PENDING") "\n"
                  source-text
                  "world-types " (count (core/nativeworld-types world)) "\n"
                  "world-layouts " (count (core/nativeworld-layouts world)) "\n"
                  "world-functions " (count (core/nativeworld-functions world)) "\n"
                  "world-abis " (count (core/nativeworld-abis world)) "\n"
                  "projected-types "
                  (count (core/nativeworld-types projected)) "\n"
                  (function-report projected)
                  (obligation-report projected)
                  (slice/pending-reports (slice/native-pending native-result))
                  c17-report qbe-report
                  (receipt-report "source-seal" seal-receipt)
                  (receipt-report "source-to-typed" typing-receipt)
                  (receipt-report "typed-to-native" native-receipt))}))))))

(if (= 5 (count *command-line-args*))
  (let [[facts-path module-name relative-path artifacts-dir compiler-commit]
        *command-line-args*
        result (project! facts-path module-name relative-path artifacts-dir
                         compiler-commit)]
    (spit (io/file artifacts-dir "report.txt") (:report result))
    (spit (io/file artifacts-dir "native-status.txt")
          (str (:status result) "\n"))
    (print (:report result)))
  (do
    (binding [*out* *err*]
      (println "usage: project.clj FACTS MODULE RELATIVE-PATH ARTIFACTS COMMIT"))
    (System/exit 2)))
