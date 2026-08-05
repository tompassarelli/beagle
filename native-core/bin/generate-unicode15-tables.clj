(require '[clojure.java.io :as io]
         '[clojure.string :as str])

(import '(java.math BigInteger)
        '(java.security MessageDigest))

(def unicode-version "15.0.0")
(def maximum-code-point 0x10ffff)

(def source-contracts
  {:unicode-data
   {:filename "UnicodeData.txt"
    :sha256 "806e9aed65037197f1ec85e12be6e8cd870fc5608b4de0fffd990f689f376a73"}
   :special-casing
   {:filename "SpecialCasing.txt"
    :sha256 "78b29c64b5840d25c11a9f31b665ee551b8a499eca6c70d770fcad7dd710f494"}
   :derived-core-properties
   {:filename "DerivedCoreProperties.txt"
    :sha256 "d367290bc0867e6b484c68370530bdd1a08b6b32404601b8c7accaf83e05628d"}})

(def flag-values
  {:letter 0x001
   :decimal 0x002
   :spacing-mark 0x004
   :enclosing-mark 0x008
   :format 0x010
   :number 0x020
   :dash 0x040
   :connector 0x080
   :cased 0x100})

(def code-point-flags (int-array (inc maximum-code-point)))

(defn fail! [message data]
  (throw (ex-info message data)))

(defn sha256 [path]
  (let [digest (MessageDigest/getInstance "SHA-256")
        buffer (byte-array 65536)]
    (with-open [input (io/input-stream path)]
      (loop []
        (let [read-count (.read input buffer)]
          (when (pos? read-count)
            (.update digest buffer 0 read-count)
            (recur)))))
    (format "%064x" (BigInteger. 1 (.digest digest)))))

(defn verify-source! [[source-name source]]
  (let [{:keys [path] expected-sha256 :sha256} source
        file (io/file path)]
    (when-not (.isFile file)
      (fail! "Unicode source is missing"
             {:source source-name :path path}))
    (let [actual (sha256 path)]
      (when-not (= expected-sha256 actual)
        (fail! "Unicode source checksum mismatch"
               {:source source-name
                :path path
                :expected expected-sha256
                :actual actual})))))

(defn parse-hex [value context]
  (try
    (let [code-point (Integer/parseInt value 16)]
      (when-not (<= 0 code-point maximum-code-point)
        (fail! "Unicode code point is out of range"
               (assoc context :value value)))
      code-point)
    (catch NumberFormatException _
      (fail! "Invalid hexadecimal Unicode code point"
             (assoc context :value value)))))

(defn parse-code-point-range [spelling context]
  (let [bounds (str/split (str/trim spelling) #"\.\." -1)]
    (when-not (<= 1 (count bounds) 2)
      (fail! "Invalid Unicode code point range"
             (assoc context :value spelling)))
    (let [first-code-point (parse-hex (first bounds) context)
          last-code-point (parse-hex (or (second bounds) (first bounds)) context)]
      (when (> first-code-point last-code-point)
        (fail! "Unicode code point range is reversed"
               (assoc context :value spelling)))
      [first-code-point last-code-point])))

(defn category-flags [category]
  (bit-or
   (if (str/starts-with? category "L") (:letter flag-values) 0)
   (if (= category "Nd") (:decimal flag-values) 0)
   (if (= category "Mc") (:spacing-mark flag-values) 0)
   (if (#{"Mn" "Me"} category) (:enclosing-mark flag-values) 0)
   (if (= category "Cf") (:format flag-values) 0)
   (if (str/starts-with? category "N") (:number flag-values) 0)
   (if (= category "Pd") (:dash flag-values) 0)
   (if (= category "Pc") (:connector flag-values) 0)))

(defn add-flags! [first-code-point last-code-point flags]
  (loop [code-point first-code-point]
    (when (<= code-point last-code-point)
      (aset-int code-point-flags code-point
                (int (bit-or (aget code-point-flags code-point) flags)))
      (recur (inc code-point)))))

(defn unicode-data-fields [line line-number]
  (let [fields (vec (.split ^String line ";" -1))]
    (when-not (= 15 (count fields))
      (fail! "UnicodeData record does not have 15 fields"
             {:source :unicode-data
              :line line-number
              :field-count (count fields)}))
    fields))

(defn parse-unicode-data! [sources]
  (let [path (get-in sources [:unicode-data :path])]
    (loop [records (map-indexed vector (str/split-lines (slurp path)))
           pending-range nil
           simple-lower (transient [])]
      (if-let [[zero-based-line-number line] (first records)]
        (let [line-number (inc zero-based-line-number)
              fields (unicode-data-fields line line-number)
              source (parse-hex (nth fields 0)
                                {:source :unicode-data :line line-number})
              name (nth fields 1)
              category (nth fields 2)
              first-record? (str/ends-with? name ", First>")
              last-record? (str/ends-with? name ", Last>")
              simple-target-spelling (nth fields 13)]
          (cond
            first-record?
            (do
              (when pending-range
                (fail! "Nested UnicodeData First record"
                       {:source :unicode-data
                        :line line-number
                        :pending pending-range}))
              (recur (next records)
                     {:first source
                      :category category
                      :line line-number}
                     simple-lower))

            last-record?
            (do
              (when-not pending-range
                (fail! "UnicodeData Last record has no First record"
                       {:source :unicode-data :line line-number}))
              (when-not (= category (:category pending-range))
                (fail! "UnicodeData range categories disagree"
                       {:source :unicode-data
                        :line line-number
                        :first-record pending-range
                        :last-category category}))
              (when (> (:first pending-range) source)
                (fail! "UnicodeData range is reversed"
                       {:source :unicode-data
                        :line line-number
                        :first-record pending-range
                        :last source}))
              (add-flags! (:first pending-range) source
                          (category-flags category))
              (recur (next records) nil simple-lower))

            :else
            (do
              (when pending-range
                (fail! "UnicodeData First record is not followed by Last"
                       {:source :unicode-data
                        :line line-number
                        :pending pending-range}))
              (add-flags! source source (category-flags category))
              (let [next-simple-lower
                    (if (str/blank? simple-target-spelling)
                      simple-lower
                      (conj! simple-lower
                             [source
                              (parse-hex simple-target-spelling
                                         {:source :unicode-data
                                          :line line-number
                                          :field :simple-lower})]))]
                (recur (next records) nil next-simple-lower)))))
        (do
          (when pending-range
            (fail! "UnicodeData ends inside a First/Last range"
                   {:source :unicode-data :pending pending-range}))
          (persistent! simple-lower))))))

(defn record-data [line]
  (str/trim (first (str/split line #"#" 2))))

(defn parse-derived-core-properties! [sources]
  (let [path (get-in sources [:derived-core-properties :path])]
    (doseq [[zero-based-line-number line]
            (map-indexed vector (str/split-lines (slurp path)))]
      (let [data (record-data line)]
        (when-not (str/blank? data)
          (let [fields (vec (.split ^String data ";" -1))
                line-number (inc zero-based-line-number)]
            (when-not (= 2 (count fields))
              (fail! "DerivedCoreProperties record does not have two fields"
                     {:source :derived-core-properties
                      :line line-number
                      :field-count (count fields)}))
            (when (= "Cased" (str/trim (nth fields 1)))
              (let [[first-code-point last-code-point]
                    (parse-code-point-range
                     (nth fields 0)
                     {:source :derived-core-properties :line line-number})]
                (add-flags! first-code-point last-code-point
                            (:cased flag-values))))))))))

(defn parse-special-casing [sources]
  (let [path (get-in sources [:special-casing :path])]
    (->> (str/split-lines (slurp path))
         (map-indexed
          (fn [zero-based-line-number line]
            (let [data (record-data line)]
              (when-not (str/blank? data)
                (let [fields (vec (.split ^String data ";" -1))
                      line-number (inc zero-based-line-number)]
                  (when (< (count fields) 4)
                    (fail! "SpecialCasing record has too few fields"
                           {:source :special-casing
                            :line line-number
                            :field-count (count fields)}))
                  (let [condition (str/trim (nth fields 4 ""))
                        mapping (->> (str/split (str/trim (nth fields 1)) #"\s+")
                                     (remove str/blank?)
                                     (mapv #(parse-hex
                                             %
                                             {:source :special-casing
                                              :line line-number
                                              :field :lower})))]
                    (when (and (str/blank? condition) (> (count mapping) 1))
                      (when (> (count mapping) 3)
                        (fail! "Special lowercase mapping exceeds contract"
                               {:source :special-casing
                                :line line-number
                                :mapping mapping}))
                      [(parse-hex (str/trim (nth fields 0))
                                  {:source :special-casing :line line-number})
                       mapping])))))))
         (remove nil?)
         (sort-by first)
         vec)))

(defn compress-ranges []
  (loop [code-point 0
         ranges (transient [])]
    (if (> code-point maximum-code-point)
      (persistent! ranges)
      (let [flags (aget code-point-flags code-point)]
        (if (zero? flags)
          (recur (inc code-point) ranges)
          (let [after-range
                (loop [candidate (inc code-point)]
                  (if (and (<= candidate maximum-code-point)
                           (= flags (aget code-point-flags candidate)))
                    (recur (inc candidate))
                    candidate))]
            (recur after-range
                   (conj! ranges [code-point (dec after-range) flags]))))))))

(defn ensure-strictly-sorted! [entries label]
  (doseq [[[left] [right]] (partition 2 1 entries)]
    (when (>= left right)
      (fail! "Generated Unicode table is not strictly sorted"
             {:table label :left left :right right}))))

(defn append-line! [builder line]
  (.append builder line)
  (.append builder \newline))

(defn code-point-literal [code-point]
  (format "UINT32_C(0x%06X)" code-point))

(defn render-header [sources ranges simple-lower special-lower]
  (let [builder (StringBuilder.)]
    (append-line! builder "/* Generated by native-core/bin/generate-unicode15-tables.clj.")
    (append-line! builder "   Inputs are Unicode 15.0.0 data pinned by the SHA-256 macros below.")
    (append-line! builder "   Unicode data copyright (c) 1991-2022 Unicode, Inc.")
    (append-line! builder "   License: native-core/shim/UNICODE-LICENSE.txt. Do not edit by hand.")
    (append-line! builder "*/")
    (append-line! builder "#ifndef NATIVE_UNICODE15_DATA_H")
    (append-line! builder "#define NATIVE_UNICODE15_DATA_H")
    (append-line! builder "")
    (append-line! builder "#include <stddef.h>")
    (append-line! builder "#include <stdint.h>")
    (append-line! builder "")
    (append-line! builder "#define NATIVE_UNICODE15_CONTRACT_VERSION UINT32_C(1)")
    (append-line! builder (str "#define NATIVE_UNICODE15_VERSION \"" unicode-version "\""))
    (append-line! builder "#define NATIVE_UNICODE15_UNICODE_DATA_FILE \"UnicodeData.txt\"")
    (append-line! builder
                  (str "#define NATIVE_UNICODE15_UNICODE_DATA_SHA256 \""
                       (get-in sources [:unicode-data :sha256]) "\""))
    (append-line! builder "#define NATIVE_UNICODE15_SPECIAL_CASING_FILE \"SpecialCasing.txt\"")
    (append-line! builder
                  (str "#define NATIVE_UNICODE15_SPECIAL_CASING_SHA256 \""
                       (get-in sources [:special-casing :sha256]) "\""))
    (append-line! builder "#define NATIVE_UNICODE15_DERIVED_CORE_PROPERTIES_FILE \"DerivedCoreProperties.txt\"")
    (append-line! builder
                  (str "#define NATIVE_UNICODE15_DERIVED_CORE_PROPERTIES_SHA256 \""
                       (get-in sources [:derived-core-properties :sha256]) "\""))
    (append-line! builder "")
    (append-line! builder "#define NATIVE_UNICODE15_LETTER UINT32_C(0x001)")
    (append-line! builder "#define NATIVE_UNICODE15_DECIMAL UINT32_C(0x002)")
    (append-line! builder "#define NATIVE_UNICODE15_SPACING_MARK UINT32_C(0x004)")
    (append-line! builder "#define NATIVE_UNICODE15_ENCLOSING_MARK UINT32_C(0x008)")
    (append-line! builder "#define NATIVE_UNICODE15_FORMAT UINT32_C(0x010)")
    (append-line! builder "#define NATIVE_UNICODE15_NUMBER UINT32_C(0x020)")
    (append-line! builder "#define NATIVE_UNICODE15_DASH UINT32_C(0x040)")
    (append-line! builder "#define NATIVE_UNICODE15_CONNECTOR UINT32_C(0x080)")
    (append-line! builder "#define NATIVE_UNICODE15_CASED UINT32_C(0x100)")
    (append-line! builder "")
    (append-line! builder "#if defined(__GNUC__) || defined(__clang__)")
    (append-line! builder "#define NATIVE_UNICODE15_UNUSED __attribute__((unused))")
    (append-line! builder "#else")
    (append-line! builder "#define NATIVE_UNICODE15_UNUSED")
    (append-line! builder "#endif")
    (append-line! builder "")
    (append-line! builder "typedef struct native_unicode15_range {")
    (append-line! builder "  uint32_t first;")
    (append-line! builder "  uint32_t last;")
    (append-line! builder "  uint32_t flags;")
    (append-line! builder "} native_unicode15_range;")
    (append-line! builder "")
    (append-line! builder
                  "static const struct native_unicode15_range native_unicode15_ranges[] NATIVE_UNICODE15_UNUSED = {")
    (doseq [[first-code-point last-code-point flags] ranges]
      (append-line! builder
                    (format "  {%s, %s, UINT32_C(0x%03X)},"
                            (code-point-literal first-code-point)
                            (code-point-literal last-code-point)
                            flags)))
    (append-line! builder "};")
    (append-line! builder
                  (format "#define NATIVE_UNICODE15_RANGE_COUNT ((size_t)%d)"
                          (count ranges)))
    (append-line! builder "")
    (append-line! builder "typedef struct native_unicode15_lower {")
    (append-line! builder "  uint32_t source;")
    (append-line! builder "  uint32_t target;")
    (append-line! builder "} native_unicode15_lower;")
    (append-line! builder "")
    (append-line! builder
                  "static const native_unicode15_lower native_unicode15_lowers[] NATIVE_UNICODE15_UNUSED = {")
    (doseq [[source target] simple-lower]
      (append-line! builder
                    (format "  {%s, %s},"
                            (code-point-literal source)
                            (code-point-literal target))))
    (append-line! builder "};")
    (append-line! builder
                  (format "#define NATIVE_UNICODE15_LOWER_COUNT ((size_t)%d)"
                          (count simple-lower)))
    (append-line! builder "")
    (append-line! builder "typedef struct native_unicode15_special_lower {")
    (append-line! builder "  uint32_t source;")
    (append-line! builder "  uint32_t mapping[3];")
    (append-line! builder "  uint8_t length;")
    (append-line! builder "} native_unicode15_special_lower;")
    (append-line! builder "")
    (append-line! builder
                  "static const native_unicode15_special_lower native_unicode15_special_lowers[] NATIVE_UNICODE15_UNUSED = {")
    (doseq [[source mapping] special-lower]
      (let [padded (take 3 (concat mapping (repeat 0)))]
        (append-line! builder
                      (format "  {%s, {%s, %s, %s}, UINT8_C(%d)},"
                              (code-point-literal source)
                              (code-point-literal (nth padded 0))
                              (code-point-literal (nth padded 1))
                              (code-point-literal (nth padded 2))
                              (count mapping)))))
    (append-line! builder "};")
    (append-line! builder
                  (format "#define NATIVE_UNICODE15_SPECIAL_LOWER_COUNT ((size_t)%d)"
                          (count special-lower)))
    (append-line! builder "")
    (append-line! builder "#undef NATIVE_UNICODE15_UNUSED")
    (append-line! builder "")
    (append-line! builder "#endif")
    (str builder)))

(defn main! []
  (when-not (= 4 (count *command-line-args*))
    (fail! (str "Usage: clojure -M native-core/bin/generate-unicode15-tables.clj "
                "UnicodeData.txt SpecialCasing.txt DerivedCoreProperties.txt OUTPUT")
           {:arguments *command-line-args*}))
  (let [[unicode-data-path special-path properties-path output-path]
        *command-line-args*
        sources (-> source-contracts
                    (assoc-in [:unicode-data :path] unicode-data-path)
                    (assoc-in [:special-casing :path] special-path)
                    (assoc-in [:derived-core-properties :path]
                              properties-path))]
    (doseq [source sources]
      (verify-source! source))
    (when-not (str/includes? (first (str/split-lines (slurp special-path)))
                             (str "SpecialCasing-" unicode-version ".txt"))
      (fail! "SpecialCasing version does not match the table contract"
             {:path special-path :version unicode-version}))
    (when-not (str/includes? (first (str/split-lines (slurp properties-path)))
                             (str "DerivedCoreProperties-" unicode-version ".txt"))
      (fail! "DerivedCoreProperties version does not match the table contract"
             {:path properties-path :version unicode-version}))
    (let [simple-lower (-> (parse-unicode-data! sources) sort vec)
          _ (parse-derived-core-properties! sources)
          ranges (compress-ranges)
          special-lower (parse-special-casing sources)
          output-file (io/file output-path)
          rendered (render-header sources ranges simple-lower special-lower)]
      (ensure-strictly-sorted! simple-lower :simple-lower)
      (ensure-strictly-sorted! special-lower :special-lower)
      (when-not (.isDirectory (.getParentFile (.getAbsoluteFile output-file)))
        (fail! "Unicode table output directory is missing"
               {:output output-path}))
      (when (or (not (.isFile output-file))
                (not= rendered (slurp output-file)))
        (spit output-file rendered))
      (println (format "unicode=%s ranges=%d simple-lower=%d special-lower=%d bytes=%d output=%s"
                       unicode-version
                       (count ranges)
                       (count simple-lower)
                       (count special-lower)
                       (.length output-file)
                       (.getPath output-file))))))

(main!)
