(require '[clojure.edn :as edn]
         '[store.types :as t])

(when-not (= 2 (count *command-line-args*))
  (throw (ex-info "usage: tamper.clj REPO_ROOT STORE" {})))

(def repo-root (first *command-line-args*))
(def log-path (second *command-line-args*))
(load-file (str repo-root "/store/database.clj"))

(let [database (database/open-database!
                log-path "beagle-dev-compile-facts-v1")
        result-subject? (fn [value]
                          (and (t/triple? value)
                               (= "store.dev-compile-facts/result-v1"
                                  (t/triple-t1 value))
                               (= "typed" (t/triple-t2 value))))
        proposition
        (first
         (filter
          (fn [value]
            (and (t/triple? value)
                 (result-subject? (t/triple-t1 value))
                 (= "DevCompileUnitResultV1" (t/triple-t2 value))))
          (database/live-propositions database)))]
    (when-not proposition
      (throw (ex-info "no typed development compile fact to tamper" {})))
    (let [subject (t/triple-t1 proposition)
          envelope (edn/read-string (t/triple-t3 proposition))
          tampered (assoc envelope 8 (str (nth envelope 8) "tampered"))]
      (database/commit!
       database
       {:actor "dev-fact-compile-tamper"
        :operations
        [{:action :assert
          :proposition
          (t/triple subject "DevCompileUnitResultV1" (pr-str tampered))}]})
      (println (t/triple-t3 subject))))
