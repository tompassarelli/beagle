(ns pipeline
  (:require [clojure.string :as str]
            [native.body-c17 :as body]
            [native.body-slice :as body-slice]
            [native.core :as core]
            [native.lower :as lower]
            [native.qbe :as qbe]
            [native.slice :as slice]
            [native.worlds :as worlds]))

(def obligation-names
  ["valid-ssa"
   "exhaustive-matches"
   "closed-layouts"
   "checked-arithmetic"
   "legal-abi"
   "discharged-tokens"
   "bounded-effects"])

(defn form-count [facts kind]
  (count (re-seq (re-pattern (str "\\tform-kind\\tt\\t" kind "(?:\\n|$)")) facts)))

(defn receipt-lines [receipt]
  (concat
    (map (fn [diagnostic]
           (str "diagnostic "
                (core/diagnosticv0-code diagnostic)
                " | "
                (core/diagnosticv0-detail diagnostic)))
         (core/passreceiptv0-diagnostics receipt))
    (keep (fn [obligation]
            (when-not (core/receiptobligationv0-passed obligation)
              (str "pending " (core/receiptobligationv0-detail obligation))))
          (core/passreceiptv0-obligations receipt))))

(defn unavailable-lines [detail]
  (concat
    (for [label ["obligation-world" "obligation-projection"]
          obligation obligation-names]
      (str label " UNAVAILABLE " obligation " | " detail))
    [(str "c17 REFUSED " detail)
     (str "qbe REFUSED " detail)]))

(defn write-c17! [world artifacts-dir]
  (let [result (body/materialize-world world 0)]
    (if-not (body/materialization-ok? result)
      (str "c17 REFUSED " (body/materialization-detail result))
      (let [artifact (body/materialization-artifact result)]
        (spit (str artifacts-dir "/" (body/bodyartifactv0-header-name artifact))
              (body/bodyartifactv0-header-text artifact))
        (spit (str artifacts-dir "/" (body/bodyartifactv0-source-name artifact))
              (body/bodyartifactv0-source-text artifact))
        (str "c17 OK "
             (body/bodyartifactv0-header-name artifact)
             " "
             (body/bodyartifactv0-source-name artifact))))))

(defn write-qbe! [world artifacts-dir]
  (let [result (qbe/materialize-world world 0)]
    (if (instance? native.qbe.QbeSuccess result)
      (let [artifact (qbe/qbesuccess-artifact result)]
        (spit (str artifacts-dir "/" (qbe/qbeartifact-module-name artifact))
              (qbe/qbeartifact-module-text artifact))
        (str "qbe OK " (qbe/qbeartifact-module-name artifact)))
      (str "qbe REFUSED " (qbe/qbefailure-detail result)))))

(defn accepted-lines [typing-result artifacts-dir]
  (let [sealed-typed (lower/typingacceptedv0-sealed typing-result)
        typed-slice (lower/typingacceptedv0-slice typing-result)
        native-result (lower/lower-native-world
                        sealed-typed typed-slice "native-codegraph-full-v0"
                        ["profile=3"])
        sealed-native (slice/native-sealed native-result)
        world (worlds/nativeworldv0-program
               (worlds/sealednativeworldv0-world sealed-native))
        projected (body-slice/projected-world world)
        complete? (instance? native.lower.NativeLoweringCompleteV0 native-result)]
    (concat
      [(str "stage typed-to-native " (if complete? "COMPLETE" "PENDING"))
       (str "world-types " (count (core/nativeworld-types world)))
       (str "world-layouts " (count (core/nativeworld-layouts world)))
       (str "world-functions " (count (core/nativeworld-functions world)))
       (str "world-abis " (count (core/nativeworld-abis world)))
       (str "projected-types " (count (core/nativeworld-types projected)))]
      (str/split-lines
       (body-slice/function-report (core/nativeworld-functions projected)))
      (str/split-lines (slice/obligation-report "obligation-world" world))
      (str/split-lines
       (slice/obligation-report "obligation-projection" projected))
      (str/split-lines (slice/pending-reports (slice/native-pending native-result)))
      (if complete?
        [(write-c17! projected artifacts-dir)
         (write-qbe! projected artifacts-dir)]
        ["c17 SKIPPED native-world-incomplete"
         "qbe SKIPPED native-world-incomplete"]))))

(let [[facts-path artifacts-dir report-path] *command-line-args*
      facts (slurp facts-path)
      source (slice/source-world
              (slice/parse-facts facts)
              "codegraph"
              "fram:codegraph/src/codegraph.bclj")
      source-lines [(str "source-modules "
                         (count (worlds/sourceprogramworldv0-modules source)))
                    (str "source-imports "
                         (count (worlds/sourceprogramworldv0-imports source)))
                    (str "source-records " (form-count facts "record"))
                    (str "source-functions " (form-count facts "defn"))
                    (str "source-defs " (form-count facts "def"))]
      seal-result (lower/seal-source-world
                   source "native-codegraph-full-v0" ["profile=3"])
      lines
      (if-not (instance? native.lower.SourceSealAcceptedV0 seal-result)
        (concat
          ["stage source-seal REJECTED"]
          source-lines
          (receipt-lines (lower/sourcesealrejectedv0-receipt seal-result))
          (unavailable-lines "source-seal rejected"))
        (let [sealed-source (lower/sourcesealacceptedv0-sealed seal-result)
              typing-result (lower/lower-typed-world
                             sealed-source "native-codegraph-full-v0"
                             ["profile=3"])]
          (if (instance? native.lower.TypingRejectedV0 typing-result)
            (concat
              ["stage source-seal ACCEPTED"
               "stage source-to-typed REJECTED"]
              source-lines
              (receipt-lines (lower/typingrejectedv0-receipt typing-result))
              (unavailable-lines "source-to-typed rejected"))
            (concat
              ["stage source-seal ACCEPTED"
               "stage source-to-typed ACCEPTED"]
              source-lines
              (accepted-lines typing-result artifacts-dir)))))]
  (spit report-path (str (str/join "\n" lines) "\n")))
