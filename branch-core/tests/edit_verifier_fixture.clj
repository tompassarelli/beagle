#!/usr/bin/env bb
;; Closed-protocol verifier fixture for server state-machine tests.
;; It is selected only by pointing the production FRAM_EDIT_VERIFIER launch seam
;; at this executable; the server contains no test-success mode.
(require '[cheshire.core :as json]
         '[clojure.string :as str]
         '[babashka.process :as process])

(def receipt-schema "fram-edit-verifier-receipt-v1")
(def request (json/parse-string (or (read-line) "") true))
(def mode (or (System/getenv "FRAM_EDIT_VERIFIER_FIXTURE_MODE") "delegate"))
(def required-source (System/getenv "FRAM_EDIT_VERIFIER_REQUIRE_SOURCE"))

(defn sha256-hex [value]
  (let [digest (.digest
                (java.security.MessageDigest/getInstance "SHA-256")
                (.getBytes (pr-str value) "UTF-8"))]
    (apply str (map #(format "%02x" %) digest))))

(def toolchain-closure-digest
  (sha256-hex ["fram-edit-verifier-fixture" 1]))

(def modules
  (mapv
   (fn [{:keys [source namespace source-digest]}]
     {:source source
      :namespace namespace
      :source-digest source-digest
      :interface-digest
      (sha256-hex ["fixture-interface" source namespace source-digest])
      :emitted-digest
      (sha256-hex ["fixture-emitted" source source-digest])})
   (:closure request)))

(when-let [path (System/getenv "FRAM_EDIT_VERIFIER_COUNT_FILE")]
  (spit path (str (:candidate request) "\n") :append true))

(when-let [raw (System/getenv "FRAM_EDIT_VERIFIER_SLEEP_MS")]
  (Thread/sleep (Long/parseLong raw)))

(when (and (not (str/blank? required-source))
           (not (some #(= required-source (:source %))
                      (:overlay request))))
  (println
   (json/generate-string
    {:schema receipt-schema
     :ok false
     :input-digest (:input-digest request)
     :code "incomplete-overlay"
     :errors [(str "required untouched provider absent: "
                   required-source)]}))
  (System/exit 1))

(case mode
  "delegate"
  (let [adapter (System/getenv "FRAM_EDIT_VERIFIER_FIXTURE_DELEGATE")]
    (when (str/blank? adapter)
      (binding [*out* *err*]
        (println "FRAM_EDIT_VERIFIER_FIXTURE_DELEGATE is required"))
      (System/exit 2))
    (let [result
          (process/shell
           {:in (json/generate-string request)
            :out :string
            :err :string
            :continue true}
           adapter)]
      (print (:out result))
      (flush)
      (when-not (str/blank? (:err result))
        (binding [*out* *err*]
          (print (:err result))
          (flush)))
      (System/exit (:exit result))))

  "reject"
  (do
    (println
     (json/generate-string
      {:schema receipt-schema
       :ok false
       :input-digest (:input-digest request)
       :code "fixture-rejected"
       :errors ["controlled deterministic verifier rejection"]}))
    (System/exit 1))

  "malformed"
  (do (println "{\"ok\":true}") (System/exit 0))

  "accept"
  (println
   (json/generate-string
    {:schema receipt-schema
     :ok true
     :input-digest (:input-digest request)
     :overlay-digest
     (sha256-hex [(:overlay-digest request)
                  toolchain-closure-digest
                  modules])
     :toolchain-closure-digest toolchain-closure-digest
     :modules modules}))

  (do
    (binding [*out* *err*]
      (println (str "unknown fixture mode " (pr-str mode))))
    (System/exit 2)))
