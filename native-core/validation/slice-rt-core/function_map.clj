(require '[clojure.string :as str])

(defn macro-name [function-name]
  (str "RT_"
    (-> function-name
      (str/replace "?" "_P")
      (str/replace #"[^A-Za-z0-9]+" "_")
      (str/upper-case))))

(let [[report-path output-path] *command-line-args*]
  (when (or (nil? report-path) (nil? output-path))
    (throw (ex-info "usage: function_map.clj REPORT OUTPUT" {})))
  (let [lowered
        (keep (fn [line]
                (when-let [[_ symbol name]
                           (re-matches #"^lowered (fn_[0-9]+) ([^ ]+) [0-9]+ blocks$" line)]
                  [name symbol]))
          (str/split-lines (slurp report-path)))]
    (spit output-path
      (str
        "#ifndef NATIVE_RT_CORE_FUNCTION_MAP_H\n"
        "#define NATIVE_RT_CORE_FUNCTION_MAP_H\n\n"
        "#include \"module_0.h\"\n\n"
        (str/join ""
          (for [[name symbol] lowered]
            (str "#define " (macro-name name) " native_m0_" symbol "\n")))
        "\n#endif\n"))))
