(require '[clojure.java.io :as io]
         '[clojure.string :as str]
         '[native.bitwise-roots :as bitwise])

(with-open [reader (io/reader (first *command-line-args*))]
  (doseq [line (line-seq reader)]
    (let [[value distance first-mask second-mask]
          (mapv #(Long/parseLong %) (str/split line #"\t"))]
      (println
        (bitwise/codec-word value distance first-mask second-mask)))))
