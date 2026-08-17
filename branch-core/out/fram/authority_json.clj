(ns fram.authority-json
  (:require [cheshire.core :as json]
            [cheshire.factory :as factory]))

;; Beagle cannot rebind Cheshire's external dynamic factory var. Keep this host
;; escape decode-only; authority-domain validation remains graph-authored.
(def ^:private strict-factory
  (factory/make-json-factory
   {:strict-duplicate-detection true
    :allow-unquoted-control-chars false}))

(defn decode-strict [raw]
  (binding [factory/*json-factory* strict-factory]
    (with-open [reader (java.io.BufferedReader. (java.io.StringReader. raw))]
      (let [values (doall (json/parsed-seq reader false))]
        (when-not (= 1 (count values))
          (throw (ex-info "expected exactly one JSON value" {})))
        (first values)))))
