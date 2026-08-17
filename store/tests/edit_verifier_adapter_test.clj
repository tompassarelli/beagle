#!/usr/bin/env bb
;; Real closed-protocol adapter smoke. This uses Beagle's module-overlay checker,
;; not the server's controlled verifier fixture.

(require '[babashka.fs :as fs]
         '[babashka.process :as p]
         '[cheshire.core :as json]
         '[clojure.string :as str])

(import '(java.nio.charset StandardCharsets)
        '(java.security MessageDigest))

(def root (.getCanonicalPath (java.io.File. ".")))
(def beagle-home
  (or (System/getenv "BEAGLE_HOME")
      (str (System/getProperty "user.home") "/code/beagle")))
(def beagle-bin
  (or (System/getenv "BEAGLE_STORE_BEAGLE")
      (str beagle-home "/bin/beagle")))
(def racket
  (or (System/getenv "BEAGLE_STORE_EDIT_VERIFIER_RACKET")
      (System/getenv "BEAGLE_STORE_RACKET")))
(def verifier (str root "/bin/beagle-store-edit-verifier"))

(when-not (and racket (.canExecute (java.io.File. racket)))
  (binding [*out* *err*]
    (println "edit_verifier_adapter_test: set BEAGLE_STORE_RACKET to Beagle's pinned Racket"))
  (System/exit 2))

(def failures (atom []))
(def checks (atom 0))

(defn check! [label condition]
  (swap! checks inc)
  (if condition
    (println "PASS" label)
    (do
      (swap! failures conj label)
      (println "FAIL" label))))

(defn sha256 [value]
  (let [bytes (.getBytes ^String value StandardCharsets/UTF_8)
        digest (.digest (MessageDigest/getInstance "SHA-256") bytes)]
    (apply str (map #(format "%02x" %) digest))))

(defn facts-edn [path]
  (let [result
        (p/shell
         {:continue true :out :string :err :string}
         beagle-bin "facts-roundtrip" "--emit-edn" path)]
    (when-not (zero? (:exit result))
      (throw
       (ex-info
        (str "facts-roundtrip failed for " path ": " (:err result))
        {:result result})))
    (:out result)))

(defn source-id [edn]
  (let [line (first (str/split-lines edn))]
    (when-not (str/starts-with? line "@file ")
      (throw (ex-info "facts EDN lacks @file header" {:line line})))
    (subs line (count "@file "))))

(defn overlay-row [namespace edn]
  {:source (source-id edn)
   :namespace namespace
   :source-digest (sha256 edn)
   :edn edn})

(defn request [closure overlay]
  (let [closure (->> closure (sort-by :source) vec)
        overlay (->> overlay (sort-by :source) vec)
        closure-digest
        (sha256
         (pr-str
          (mapv (juxt :source :namespace :source-digest) closure)))
        overlay-digest
        (sha256
         (pr-str
          (mapv (juxt :source :namespace :source-digest) overlay)))
        ops-digest (sha256 "adapter-smoke-ops")
        edn-digest (sha256 "adapter-smoke-edn")
        input-digest
        (sha256
         (pr-str
          ["beagle-store-edit-verifier-request-v1"
           "adapter-smoke-candidate"
           7
           ops-digest
           edn-digest
           closure-digest
           overlay-digest]))]
    {:schema "beagle-store-edit-verifier-request-v1"
     :protocol "beagle-store-edit-verifier-command-v1"
     :input-digest input-digest
     :candidate "adapter-smoke-candidate"
     :base-version 7
     :ops-digest ops-digest
     :edn-digest edn-digest
     :closure-digest closure-digest
     :overlay-digest overlay-digest
     :checked-modules (mapv :source closure)
     :closure closure
     :overlay overlay}))

(def verifier-env
  (merge
   (into {} (System/getenv))
   {"BEAGLE_HOME" beagle-home
    "BEAGLE_STORE_EDIT_VERIFIER_RACKET" racket
    "BEAGLE_STORE_EDIT_VERIFIER_OVERLAY_CHECK"
    (str beagle-home "/beagle-lib/private/facts-check-overlay.rkt")
    ;; The adapter must launch its measured Racket/checker pair from a closed
    ;; environment rather than inheriting caller-controlled collection roots.
    "PLTCOLLECTS" "/definitely/hostile-racket-collects"
    "PLTUSERHOME" "/definitely/hostile-racket-home"}))

(defn invoke [request]
  (p/shell
   {:continue true
    :in (str (json/generate-string request) "\n")
    :out :string
    :err :string
    :env verifier-env
    :dir root}
   verifier))

(let [tmp (fs/create-temp-dir {:prefix "beagle-store-edit-verifier-adapter-"})]
  (try
    (let [provider-path (str (fs/path tmp "00_provider.bclj"))
          consumer-path (str (fs/path tmp "10_consumer.bclj"))
          bad-consumer-path (str (fs/path tmp "20_bad_consumer.bclj"))
          _ (spit
             provider-path
             (str "#lang beagle/clj\n"
                  "(ns adapter.provider)\n"
                  "(defn answer [] Int 42)\n"))
          _ (spit
             consumer-path
             (str "#lang beagle/clj\n"
                  "(ns adapter.consumer "
                  "(:require [adapter.provider :as provider]))\n"
                  "(defn consume [] Int (provider/answer))\n"))
          _ (spit
             bad-consumer-path
             (str "#lang beagle/clj\n"
                  "(ns adapter.bad-consumer "
                  "(:require [adapter.provider :as provider]))\n"
                  "(defn consume [] Int \"not-an-int\")\n"))
          provider (overlay-row "adapter.provider" (facts-edn provider-path))
          consumer (overlay-row "adapter.consumer" (facts-edn consumer-path))
          bad-consumer
          (overlay-row "adapter.bad-consumer"
                       (facts-edn bad-consumer-path))
          full-request (request [(dissoc consumer :edn)]
                                [provider consumer])
          accepted (invoke full-request)
          receipt (when (zero? (:exit accepted))
                    (json/parse-string (:out accepted) true))]
      (when-not (zero? (:exit accepted))
        (binding [*out* *err*]
          (println "unexpected complete-overlay verifier result:"
                   (pr-str accepted))))
      (check! "complete overlay with an unselected imported provider verifies"
              (zero? (:exit accepted)))
      (check! "success receipt is closed and input-bound"
              (and
               (= #{:schema :ok :input-digest :overlay-digest
                    :toolchain-closure-digest :modules}
                  (set (keys receipt)))
               (true? (:ok receipt))
               (= (:input-digest full-request) (:input-digest receipt))
               (re-matches #"[0-9a-f]{64}" (:overlay-digest receipt))
               (re-matches #"[0-9a-f]{64}"
                           (:toolchain-closure-digest receipt))))
      (check! "receipt module row is exact and follows selected closure order"
              (let [module (first (:modules receipt))]
                (and
                 (= 1 (count (:modules receipt)))
                 (= #{:source :namespace :source-digest
                      :interface-digest :emitted-digest}
                    (set (keys module)))
                 (= (:source consumer) (:source module))
                 (= (:source-digest consumer) (:source-digest module))
                 (re-matches #"[0-9a-f]{64}"
                             (:interface-digest module))
                 (re-matches #"[0-9a-f]{64}"
                             (:emitted-digest module)))))

      (let [partial (invoke (request [(dissoc consumer :edn)] [consumer]))
            partial-receipt
            (when (zero? (:exit partial))
              (json/parse-string (:out partial) true))]
        ;; Unknown host/runtime requires remain a legal Beagle compatibility
        ;; surface, so a deliberately incomplete request can parse as an
        ;; external dependency. The server—not this stateless adapter—owns
        ;; proof that :overlay is the complete graph. What the adapter must prove
        ;; is that every supplied overlay row participates in the overlay receipt.
        (check! "complete overlay is bound into the overlay digest"
                (or
                 (= 1 (:exit partial))
                 (and
                  (zero? (:exit partial))
                  (not= (:overlay-digest receipt)
                        (:overlay-digest partial-receipt))))))

      (let [red-request
            (request [(dissoc bad-consumer :edn)]
                     [provider bad-consumer])
            red-result (invoke red-request)
            rejected (when (= 1 (:exit red-result))
                       (json/parse-string (:out red-result) true))]
        (check! "typed candidate failure is deterministic rejection"
                (= 1 (:exit red-result)))
        (check! "deterministic overlay rejection uses the closed failure receipt"
                (and
                 (= #{:schema :ok :input-digest :code :errors}
                    (set (keys rejected)))
                 (false? (:ok rejected))
                 (= "beagle-overlay-rejected" (:code rejected))
                 (seq (:errors rejected)))))

      (let [tampered
            (update-in full-request [:overlay 0 :edn] str "\n")
            result (invoke tampered)]
        (check! "request digest tampering is infrastructure-red, never proof"
                (and (= 2 (:exit result))
                     (str/blank? (:out result))
                     (str/includes? (:err result)
                                    "source-digest does not match")))))
    (finally
      (fs/delete-tree tmp))))

(when (seq @failures)
  (binding [*out* *err*]
    (println
     (str "edit_verifier_adapter_test: "
          (count @failures)
          " failure(s): "
          (str/join ", " @failures))))
  (System/exit 1))

(println
 (str "edit_verifier_adapter_test: "
      @checks
      "/"
      @checks
      " checks passed"))
