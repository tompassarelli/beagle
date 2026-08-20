(ns receipt-keys
  (:require [native.core :as core]
            [native.stages :as stages]
            [native.unit-reuse :as unit]))

(defn require! [condition message]
  (when-not condition
    (throw (ex-info message {}))))

(defn digest [text]
  (stages/content-digest text))

(def profile
  (unit/core-profile-identity-v1))

(def contracts
  (unit/five-form-semantic-contracts profile))

(def module-id
  (core/->NativeId "fixture/module"))

(def leaf-id
  (core/->NativeId "fixture/leaf"))

(def dependent-id
  (core/->NativeId "fixture/dependent"))

(def independent-id
  (core/->NativeId "fixture/independent"))

(defn source-unit [id name semantic-digest reads]
  (stages/->SourceUnitV0
   id module-id "defn" name semantic-digest
   (core/->NativeId (str "fixture/root/" name)) reads))

(defn dependency-contract [semantic-digest]
  (let [encoding
        (stages/canonical-record
         "fixture-unit-contract-v0"
         [(core/nativeid-value leaf-id) semantic-digest])]
    (unit/->UnitContractV0
     leaf-id "fixture/leaf" "public" []
     (core/->NativeId "type/Int")
     (core/->NativeId "type/Never")
     [] encoding (digest encoding))))

(defn receipt [source read-contracts rule-epoch]
  (unit/make-unit-derivation-receipt
   profile source read-contracts contracts
   (digest "fixture-typing-environment-v1")
   rule-epoch
   (digest "fixture-materialization-v1")
   []))

(defn identity-state [leaf-semantic rule-epoch]
  (let [leaf (source-unit leaf-id "leaf" leaf-semantic [])
        leaf-contract (dependency-contract leaf-semantic)
        dependent
        (source-unit dependent-id "dependent"
                     (digest "fixture-dependent-body-v1") [leaf-id])
        independent
        (source-unit independent-id "independent"
                     (digest "fixture-independent-body-v1") [])
        receipts
        {:leaf (receipt leaf [] rule-epoch)
         :dependent (receipt dependent [leaf-contract] rule-epoch)
         :independent (receipt independent [] rule-epoch)}]
    (into {}
          (map (fn [[name derived]]
                 [name {:receipt-id
                        (unit/unitderivationreceiptv1-receipt-id derived)
                        :result-key (unit/unit-result-key derived)}])
               receipts))))

(defn -main [& args]
  (require! (= 3 (count args))
            "usage: receipt_keys.clj BASELINE_EPOCH OUTSIDE_EPOCH INSIDE_EPOCH")
  (let [[baseline-epoch outside-epoch inside-epoch] args
        leaf-v1 (digest "fixture-leaf-body-v1")
        leaf-v2 (digest "fixture-leaf-body-v2")
        clean (identity-state leaf-v1 baseline-epoch)
        warm (identity-state leaf-v1 baseline-epoch)
        outside (identity-state leaf-v1 outside-epoch)
        rule-edit (identity-state leaf-v1 inside-epoch)
        source-edit (identity-state leaf-v2 baseline-epoch)]
    (require! (= clean warm)
              "warm receipt/result reconstruction differs from clean")
    (require! (= clean outside)
              "an edit outside the unit-rule closure changed receipt/result identity")
    (require! (not= (get-in clean [:leaf :result-key])
                    (get-in rule-edit [:leaf :result-key]))
              "an edit inside the compiler-rule closure kept the leaf result key")
    (require! (not= (get-in clean [:dependent :result-key])
                    (get-in rule-edit [:dependent :result-key]))
              "an edit inside the compiler-rule closure kept the dependent result key")
    (require! (not= (get-in clean [:leaf :result-key])
                    (get-in source-edit [:leaf :result-key]))
              "an inside-closure semantic edit kept the edited unit result key")
    (require! (not= (get-in clean [:dependent :result-key])
                    (get-in source-edit [:dependent :result-key]))
              "an inside-closure semantic edit kept the dependent result key")
    (require! (= (get clean :independent) (get source-edit :independent))
              "an inside-closure semantic edit changed an independent unit")
    (println "dev-unit-rule-identity: outside-closure receipt/result stability PASS")
    (println "dev-unit-rule-identity: inside-closure unit/dependent invalidation PASS")
    (println "dev-unit-rule-identity: warm/clean receipt/result identity equality PASS")))

(apply -main *command-line-args*)
