(ns store.code-commit-gate
  "Sealed Beagle admission and one-batch OCC commit for native code candidates."
  (:require [cheshire.core :as json]
            [clojure.java.shell :as shell]
            [clojure.set :as set]
            [clojure.string :as str]
            [store.rpc :as rpc]
            [store.candidate-transformer :as transformer]
            [store.code-reader :as code-reader]
            [store.rt :as rt]
            [store.types :as t])
  (:import (java.nio.charset StandardCharsets)
           (java.security MessageDigest)))

(def ^:private verifier-request-schema "beagle-store-edit-verifier-request-v1")
(def ^:private verifier-command-protocol "beagle-store-edit-verifier-command-v1")
(def ^:private verifier-receipt-schema "beagle-store-edit-verifier-receipt-v1")
(def ^:private default-max-conflicts 8)

(defn- fail! [type message data]
  (throw (ex-info message (assoc data :type type))))

(defn- sha256 [value]
  (let [bytes (.getBytes ^String value StandardCharsets/UTF_8)
        digest (.digest (MessageDigest/getInstance "SHA-256") bytes)]
    (apply str (map #(format "%02x" %) digest))))

(defn- triple->row [triple]
  [(t/triple-t1 triple) (t/triple-t2 triple) (t/triple-t3 triple)])

(defn transformer-snapshot
  "Adapt a cited native reader result to the stage-2 transformer's immutable input."
  [module-snapshot]
  (let [version (get-in module-snapshot [:snapshot :version])
        module (:module module-snapshot)
        facts (into #{} (map triple->row) (:triples module-snapshot))]
    (when-not (and (string? module) (integer? version) (set? facts))
      (fail! :invalid-native-candidate
             "native code snapshot lacks module, version, or facts"
             {:module module :version version}))
    {:version version :module module :facts facts}))

(defn- rows->triples [rows]
  (mapv (fn [[t1 t2 t3]] (t/triple t1 t2 t3)) rows))

(defn candidate-edn
  "Project one stage-2 candidate through the native reader's Beagle projection."
  [module-snapshot candidate]
  (let [module (:module module-snapshot)
        base-version (get-in module-snapshot [:snapshot :version])]
    (when-not (and (= module (:module candidate))
                   (= base-version (:base-version candidate)))
      (fail! :invalid-native-candidate
             "candidate identity does not match its cited native snapshot"
             {:snapshot-module module
              :candidate-module (:module candidate)
              :snapshot-version base-version
              :candidate-version (:base-version candidate)}))
    (code-reader/project-module-edn
     {:module module
      :snapshot (:snapshot module-snapshot)
      :triples (rows->triples (:ast candidate))})))

(defn- only-value [index node predicate]
  (let [values (get index [node predicate] #{})]
    (when (= 1 (count values)) (first values))))

(defn- candidate-namespace [facts]
  (let [index (reduce (fn [result [subject predicate object]]
                        (update result [subject predicate] (fnil conj #{}) object))
                      {} facts)
        matches
        (->> facts
             (keep (fn [[subject predicate head]]
                     (when (and (= "f0" predicate)
                                (= "list" (only-value index subject "kind"))
                                (= "ns" (only-value index head "v")))
                       (when-let [namespace-node
                                  (only-value index subject "f1")]
                         (only-value index namespace-node "v")))))
             distinct
             vec)]
    (when-not (and (= 1 (count matches))
                   (string? (first matches))
                   (not (str/blank? (first matches))))
      (fail! :invalid-native-candidate
             "candidate must contain exactly one namespace form"
             {:namespaces matches}))
    (first matches)))

(defn- action-rows [candidate]
  (into []
        (concat
         (map (fn [row] [:rpc/retract row])
              (sort-by pr-str (:retracts candidate)))
         (map (fn [row] [:rpc/assert row])
              (sort-by pr-str (:asserts candidate))))))

(defn verifier-request
  "Seal the candidate projection and exact net operations into verifier v1 input."
  [module-snapshot candidate]
  (let [edn (candidate-edn module-snapshot candidate)
        source (get-in module-snapshot [:snapshot :root])
        namespace (candidate-namespace (:ast candidate))
        source-digest (sha256 edn)
        actions (action-rows candidate)
        ops-digest (sha256 (pr-str actions))
        candidate-id (str "native-" (subs ops-digest 0 24))
        closure [{:source source
                  :namespace namespace
                  :source-digest source-digest}]
        overlay [(assoc (first closure) :edn edn)]
        closure-digest
        (sha256 (pr-str (mapv (juxt :source :namespace :source-digest)
                               closure)))
        overlay-digest
        (sha256 (pr-str (mapv (juxt :source :namespace :source-digest)
                               overlay)))
        input-digest
        (sha256
         (pr-str [verifier-request-schema candidate-id
                  (:base-version candidate) ops-digest source-digest
                  closure-digest overlay-digest]))]
    {:schema verifier-request-schema
     :protocol verifier-command-protocol
     :input-digest input-digest
     :candidate candidate-id
     :base-version (:base-version candidate)
     :ops-digest ops-digest
     :edn-digest source-digest
     :closure-digest closure-digest
     :overlay-digest overlay-digest
     :checked-modules [source]
     :closure closure
     :overlay overlay}))

(defn- parse-receipt! [result request]
  (let [receipt
        (try
          (json/parse-string (:out result) true)
          (catch Throwable _
            (fail! :sealed-verifier-protocol
                   "sealed verifier emitted malformed JSON"
                   {:exit (:exit result) :stderr (:err result)})))
        success-keys
        #{:schema :ok :input-digest :overlay-digest
          :toolchain-closure-digest :modules}
        rejection-keys #{:schema :ok :input-digest :code :errors}
        expected-keys (if (zero? (:exit result)) success-keys rejection-keys)]
    (when-not (and (= expected-keys (set (keys receipt)))
                   (= verifier-receipt-schema (:schema receipt))
                   (= (:input-digest request) (:input-digest receipt))
                   (= (zero? (:exit result)) (:ok receipt)))
      (fail! :sealed-verifier-protocol
             "sealed verifier receipt is not closed or input-bound"
             {:exit (:exit result) :receipt receipt}))
    receipt))

(defn sealed-check!
  "Run the launch-sealed verifier. Rejection is typed and never reaches commit."
  [request {:keys [verifier verifier-env]}]
  (let [verifier (or verifier
                     (System/getenv "BEAGLE_STORE_EDIT_VERIFIER")
                     (str (System/getProperty "user.dir")
                          "/bin/beagle-store-edit-verifier"))
        environment (merge (into {} (System/getenv)) verifier-env)
        result (shell/sh verifier
                         :in (str (json/generate-string request) "\n")
                         :env environment)]
    (case (:exit result)
      0 {:accepted true :receipt (parse-receipt! result request)}
      1 {:accepted false :receipt (parse-receipt! result request)}
      {:accepted false
       :receipt {:schema verifier-receipt-schema
                 :ok false
                 :input-digest (:input-digest request)
                 :code "verifier-infrastructure-failure"
                 :errors [(str/trim (str (:err result)))]}})))

(defn- batch-actions [candidate]
  (mapv (fn [[operation [t1 t2 t3]]]
          (rpc/rpc-action! operation
                            (t/triple t1 t2 t3)
                            rpc/rpc-subject-any))
        (action-rows candidate)))

(defn commit-candidate!
  "Attempt exactly one expected-version :rpc/batch for this candidate."
  [port space candidate]
  (let [actions (batch-actions candidate)]
    (when (empty? actions)
      (fail! :invalid-native-candidate
             "candidate net delta must not be empty"
             {:module (:module candidate)
              :base-version (:base-version candidate)}))
    (rt/native-call! port space :rpc/batch
                     (rpc/rpc-batch! actions nil)
                     (:base-version candidate) nil nil)))

(defn- mutation-results [response]
  (let [[results]
        (rt/rpc-record-fields! (rt/native-payload response)
                               :rpc/mutation-result 1)]
    (mapv #(rt/rpc-record-fields! % :rpc/action-result 3)
          (rt/rpc-list-values! results))))

(defn- attempt-summary [candidate]
  {:base-version (:base-version candidate)
   :next-node-int (:next-node-int candidate)
   :assert-count (count (:asserts candidate))
   :retract-count (count (:retracts candidate))})

(defn- postcommit-outcome
  [port space checkout-root module base candidate response proof conflicts attempts]
  (let [fresh (code-reader/read-module-snapshot!
               port space checkout-root module)
        fresh-facts (:facts (transformer-snapshot fresh))
        base-facts (:facts base)
        actual-asserts (set/difference fresh-facts base-facts)
        actual-retracts (set/difference base-facts fresh-facts)
        results (try (mutation-results response) (catch Throwable _ nil))
        expected-count (+ (count (:asserts candidate))
                          (count (:retracts candidate)))
        receipt-exact?
        (and (= expected-count (count results))
             (= (vec (range expected-count)) (mapv first results))
             (every? true? (map second results)))
        state-exact?
        (and (= (:ast candidate) fresh-facts)
             (= (:asserts candidate) actual-asserts)
             (= (:retracts candidate) actual-retracts))
        version-exact?
        (= (inc (:base-version candidate))
           (t/rpcresponse-served-version response))]
    (if (and receipt-exact? state-exact? version-exact?)
      {:type :committed
       :module module
       :base-version (:base-version candidate)
       :committed-version (t/rpcresponse-served-version response)
       :observed-version (get-in fresh [:snapshot :version])
       :conflicts conflicts
       :attempts attempts
       :candidate candidate
       :proof proof
       :committed-delta {:asserts actual-asserts
                         :retracts actual-retracts}}
      {:type :postcommit-divergence
       :module module
       :base-version (:base-version candidate)
       :committed-version (t/rpcresponse-served-version response)
       :observed-version (get-in fresh [:snapshot :version])
       :conflicts conflicts
       :attempts attempts
       :receipt-exact receipt-exact?
       :version-exact version-exact?
       :expected-delta {:asserts (:asserts candidate)
                        :retracts (:retracts candidate)}
       :observed-delta {:asserts actual-asserts
                        :retracts actual-retracts}})))

(defn- gate-candidate-and-commit!
  [port space checkout-root module transform
   {:keys [max-conflicts before-commit] :as options}]
   (let [max-conflicts (or max-conflicts default-max-conflicts)]
     (when-not (fn? transform)
       (fail! :invalid-native-gate-options
              "candidate transform must be callable" {}))
     (when-not (and (integer? max-conflicts) (not (neg? max-conflicts)))
       (fail! :invalid-native-gate-options
              "max-conflicts must be a nonnegative integer"
              {:max-conflicts max-conflicts}))
     (loop [conflicts 0 attempts []]
       (let [module-snapshot
             (code-reader/read-module-snapshot!
              port space checkout-root module)
             base (transformer-snapshot module-snapshot)
             candidate (transform base)
             attempts (conj attempts (attempt-summary candidate))
             request (verifier-request module-snapshot candidate)
             check (sealed-check! request options)]
         (if-not (:accepted check)
           {:type :precommit-rejection
            :module module
            :base-version (:base-version candidate)
            :conflicts conflicts
            :attempts attempts
            :candidate candidate
            :rejection (:receipt check)}
           (do
             (when before-commit
               (before-commit {:attempt conflicts
                               :snapshot module-snapshot
                               :base base
                               :candidate candidate}))
             (let [response (commit-candidate! port space candidate)
                   error (rt/native-error-code response)]
               (cond
                 (= :rpc/conflict error)
                 (if (< conflicts max-conflicts)
                   (recur (inc conflicts) attempts)
                   {:type :commit-conflict
                    :module module
                    :conflicts (inc conflicts)
                    :attempts attempts
                    :last-base-version (:base-version candidate)})

                 error
                 {:type :commit-rejection
                  :module module
                  :base-version (:base-version candidate)
                  :conflicts conflicts
                  :attempts attempts
                  :code error}

                 :else
                 (postcommit-outcome
                  port space checkout-root module base candidate response
                  (:receipt check) conflicts attempts)))))))))

(defn gate-and-commit!
  "Read, transform, seal-check, and atomically commit one native body edit.

   A conflict discards the entire candidate and repeats from a fresh snapshot.
   before-commit is an integration seam for coordinating a concurrent writer."
  ([port space checkout-root module edits]
   (gate-and-commit! port space checkout-root module edits {}))
  ([port space checkout-root module edits options]
   (gate-candidate-and-commit!
    port space checkout-root module
    #(transformer/multi-set-body % edits) options)))

(defn gate-top-level-and-commit!
  "Seal and atomically commit one add-only or replace-only top-level definition."
  ([port space checkout-root module mode form]
   (gate-top-level-and-commit! port space checkout-root module mode form {}))
  ([port space checkout-root module mode form options]
   (gate-candidate-and-commit!
    port space checkout-root module
    #(transformer/top-level-def % mode form) options)))

(def edit-module! gate-and-commit!)
