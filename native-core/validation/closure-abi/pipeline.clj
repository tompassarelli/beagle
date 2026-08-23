(ns native.closure-abi-pipeline
  (:require [native.core :as core]
            [native.stages :as stages]
            [native.lower :as lower]
            [native.obligations :as obligations]
            [native.fold-c17 :as c17]
            [native.slice :as slice]
            [native.body-c17 :as body]))

(defn verdicts-pass? [verdicts]
  (every? obligations/obligation-passed? verdicts))

(defn failing-verdict-report [verdicts]
  (apply str
    (keep
      (fn [verdict]
        (when-not (obligations/obligation-passed? verdict)
          (str "obligation-fail " (obligations/verdict-tag verdict)
            (if (instance? native.obligations.ClosedLayoutsDiagnosticV0 verdict)
              (str " "
                (core/nativeid-value
                  (obligations/closedlayoutsdiagnosticv0-type-id verdict)))
              "")
            "\n")))
      verdicts)))

(defn function-report [functions]
  (apply str
    (map-indexed
      (fn [position function]
        (str "lowered fn_" position " " (core/functiondef-name function) "\n"))
      (c17/ordered-functions functions))))

(defn emit! [facts-manifest-path artifacts-dir]
  (let [rows (slice/read-fact-manifest facts-manifest-path)
        configuration ["profile=3" "abi=lp64"]
        source (slice/source-program rows "native.closure-abi"
                 "native-core/validation/closure-abi/fixture.bgl")
        freeze (lower/freeze-source-stage source "native-closure-abi-v0"
                 configuration)]
    (if-not (instance? native.lower.SourceFreezeAcceptedV0 freeze)
      "stage source-freeze REJECTED\n"
      (let [frozen-source (lower/sourcefreezeacceptedv0-frozen freeze)
            typing (lower/lower-typed-stage frozen-source
                     "native-closure-abi-v0" configuration)]
        (if-not (instance? native.lower.TypingAcceptedV0 typing)
          "stage source-freeze ACCEPTED\nstage source-to-typed REJECTED\n"
          (let [abi (core/abi-profile-lp64)
                native-result
                (lower/lower-native-stage
                  (lower/typingacceptedv0-frozen typing)
                  (lower/typingacceptedv0-slice typing)
                  "native-closure-abi-v0" configuration abi)
                epoch
                (lower/epoch-derived-stage (slice/native-frozen native-result)
                  "native-closure-abi-v0" configuration abi)
                program
                (stages/nativestagev0-program
                  (stages/frozennativestagev0-stage
                    (lower/epoch-result-frozen epoch)))
                verdicts (obligations/validate-native-core-program program abi)
                materialized (body/materialize-program program 0)
                complete
                (instance? native.lower.NativeLoweringCompleteV0 native-result)]
            (if (or (not complete) (not (verdicts-pass? verdicts))
                  (not (body/materialization-ok? materialized)))
              (str "stage source-freeze ACCEPTED\n"
                "stage source-to-typed ACCEPTED\n"
                "stage typed-to-native " (if complete "COMPLETE" "PENDING") "\n"
                "obligations " (if (verdicts-pass? verdicts) "PASS" "FAIL") "\n"
                (failing-verdict-report verdicts)
                "materialize "
                (if (body/materialization-ok? materialized) "OK" "REFUSED") "\n"
                (body/materialization-detail materialized) "\n")
              (let [artifact (body/materialization-artifact materialized)]
                (spit (str artifacts-dir "/"
                        (body/bodyartifactv0-header-name artifact))
                  (body/bodyartifactv0-header-text artifact))
                (spit (str artifacts-dir "/"
                        (body/bodyartifactv0-source-name artifact))
                  (body/bodyartifactv0-source-text artifact))
                (str "stage source-freeze ACCEPTED\n"
                  "stage source-to-typed ACCEPTED\n"
                  "stage typed-to-native COMPLETE\n"
                  "obligations PASS\n"
                  (function-report (core/nativecoreprogram-functions program))
                  "materialize OK module_0.h module_0.c\n")))))))))
