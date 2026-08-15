#!/usr/bin/env bb

(require '[clojure.string :as str])

(import '[java.nio.charset StandardCharsets]
        '[java.nio.file Files Path]
        '[java.security MessageDigest])

(defn fail! [detail]
  (binding [*out* *err*]
    (println (str "branch-compile-corpus inspector: " detail)))
  (System/exit 2))

(defn path [value]
  (Path/of value (into-array String [])))

(defn read-sized [text offset]
  (let [colon (.indexOf ^String text ":" (int offset))]
    (when (and (>= colon offset)
               (re-matches #"0|[1-9][0-9]*" (subs text offset colon)))
      (let [size (Long/parseLong (subs text offset colon))
            start (inc colon)
            end (+ start size)]
        (when (<= end (count text))
          [(subs text start end) end])))))

(defn parse-record [text]
  (try
    (when-let [[tag after-tag] (read-sized text 0)]
      (when (and (< after-tag (count text))
                 (= \: (nth text after-tag)))
        (loop [offset (inc after-tag) fields []]
          (if (= offset (count text))
            {:tag tag :fields fields :encoding text}
            (when-let [[field next-offset] (read-sized text offset)]
              (recur next-offset (conj fields field)))))))
    (catch Throwable _ nil)))

(defn nested-records [text depth]
  (when (> depth 128)
    (fail! "canonical record nesting exceeds 128"))
  (if-let [record (parse-record text)]
    (cons record
          (mapcat #(nested-records % (inc depth)) (:fields record)))
    []))

(defn sha256 [text]
  (let [digest (MessageDigest/getInstance "SHA-256")]
    (.update digest (.getBytes text StandardCharsets/UTF_8))
    (str "sha256:"
         (apply str
                (map #(format "%02x" (bit-and (int %) 0xff))
                     (.digest digest))))))

(defn unit-manifest [value]
  (let [rows (for [line (str/split-lines (slurp value))
                   :when (and (not (str/blank? line))
                              (not (str/starts-with? line "#")))]
               (let [fields (str/split line #"\t")]
                 (when-not (= 4 (count fields))
                   (fail! (str "malformed units.tsv row: " line)))
                 {:qualified (nth fields 0)
                  :simple (last (str/split (nth fields 0) #"/"))}))
        simple-names (map :simple rows)]
    (when-not (= (count simple-names) (count (distinct simple-names)))
      (fail! "the bounded corpus requires unique unqualified function names"))
    rows))

(let [[case-id program-path units-path] *command-line-args*]
  (when-not (= 3 (count *command-line-args*))
    (fail! "usage: inspect.clj CASE MODULE.native-program units.tsv"))
  (let [bytes (Files/readAllBytes (path program-path))]
    (when (> (alength bytes) (* 8 1024 1024))
      (fail! "native program exceeds the bounded 8 MiB corpus limit"))
    (let [text (String. bytes StandardCharsets/UTF_8)
          functions
          (for [record (nested-records text 0)
                :when (= "native-function-v0" (:tag record))]
            (let [fields (:fields record)]
              (when-not (= 9 (count fields))
                (fail! "native-function-v0 changed shape"))
              {:id (nth fields 0)
               :name (nth fields 1)
               :digest (sha256 (:encoding record))}))
          by-name (group-by :name functions)
          units (unit-manifest units-path)
          expected (set (map :simple units))
          actual (set (keys by-name))]
      (when-not (= expected actual)
        (fail! (str "native function set differs from units.tsv: expected="
                    (sort expected) " actual=" (sort actual))))
      (doseq [{:keys [qualified simple]} (sort-by :qualified units)]
        (let [matches (get by-name simple)]
          (when-not (= 1 (count matches))
            (fail! (str "expected one native function named " simple)))
          (let [function (first matches)]
            (println (str case-id "\tfunction-id\t" qualified "\t"
                          (:id function)))
            (println (str case-id "\tfunction-encoding\t" qualified "\t"
                          (:digest function)))))))))
