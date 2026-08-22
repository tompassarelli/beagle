(require '[clojure.string :as str])

(defn fail! [message data]
  (throw (ex-info message data)))

(let [[inventory-path report-path output-path] *command-line-args*]
  (when (or (nil? inventory-path) (nil? report-path) (nil? output-path))
    (fail! "usage: frontier.clj INVENTORY REPORT OUTPUT" {}))
  (let [inventory-lines (str/split-lines (slurp inventory-path))
        report-lines (str/split-lines (slurp report-path))
        functions (mapv #(subs % (count "function "))
                    (filter #(str/starts-with? % "function ") inventory-lines))
        complete? (some #(= "stage typed-to-native COMPLETE" %) report-lines)
        lowered (into {}
                  (keep (fn [line]
                          (when-let [[_ symbol name blocks]
                                     (re-matches #"^lowered (fn_[0-9]+) ([^ ]+) ([0-9]+) blocks$" line)]
                            [name {:state (if complete? "LOWERED" "LOWERED-NONEXECUTABLE")
                                   :symbol symbol
                                   :detail (str blocks " blocks")}]))
                    report-lines))
        pending (into {}
                  (keep (fn [line]
                          (when-let [[_ detail name]
                                     (re-matches #"^pending (.+) \[([^]]+)\]$" line)]
                            [name {:state "PENDING" :symbol "-" :detail detail}]))
                    report-lines))
        overlap (filter #(and (contains? lowered %) (contains? pending %)) functions)
        unreported (filter #(not (or (contains? lowered %) (contains? pending %))) functions)
        obligation-lines (filter #(str/starts-with? % "obligation-projection ") report-lines)
        states (mapv #(or (get lowered %) (get pending %)) functions)]
    (when (seq overlap)
      (fail! "functions are both lowered and pending" {:functions overlap}))
    (when (seq unreported)
      (fail! "functions are absent from the native frontier" {:functions unreported}))
    (when-not (= (if complete? 10 0) (count obligation-lines))
      (fail! "native report obligation count disagrees with lowering status"
        {:complete complete? :actual (count obligation-lines)}))
    (spit output-path
      (str
        "source-functions " (count functions) "\n"
        "lowered-functions " (count lowered) "\n"
        "pending-functions " (count pending) "\n"
        (str/join ""
          (map (fn [name state]
                 (str "function " name " " (:state state) " " (:symbol state)
                   " " (:detail state) "\n"))
            functions states))
        (str/join "" (map #(str % "\n") obligation-lines))
        (str/join ""
          (map #(str % "\n")
            (filter #(or (str/starts-with? % "materialize ")
                       (str/starts-with? % "qbe-materialize "))
              report-lines)))
        "frontier-accounting PASS accounted=" (+ (count lowered) (count pending))
        "\n"))))
