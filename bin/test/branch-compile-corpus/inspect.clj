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
                  :simple (last (str/split (nth fields 0) #"/"))
                  :kind (nth fields 1)
                  :reads (if (= "-" (nth fields 3))
                           []
                           (vec (sort (str/split (nth fields 3) #","))))}))
        simple-names (map :simple rows)]
    (when-not (= (count simple-names) (count (distinct simple-names)))
      (fail! "the bounded corpus requires unique unqualified function names"))
    rows))

(defn fact-rows [facts-path]
  (let [file (path facts-path)]
    (when (> (Files/size file) (* 8 1024 1024))
      (fail! "source facts exceed the bounded 8 MiB corpus limit"))
    (mapv
      (fn [line]
        (let [fields (str/split line #"\t" -1)]
          (when-not (= 4 (count fields))
            (fail! (str "malformed source fact row: " line)))
          {:subject (nth fields 0)
           :predicate (nth fields 1)
           :kind (nth fields 2)
           :object (nth fields 3)}))
      (remove str/blank? (str/split-lines (slurp facts-path))))))

(defn one-fact [rows subject predicate expected-kind]
  (let [matches (filterv #(= predicate (:predicate %)) rows)]
    (when-not (= 1 (count matches))
      (fail! (str subject " must have exactly one " predicate " row")))
    (let [row (first matches)]
      (when-not (= expected-kind (:kind row))
        (fail! (str subject " " predicate " must use fact kind " expected-kind)))
      (:object row))))

(defn emit-semantic-units [case-id facts-path units]
  (let [rows (fact-rows facts-path)
        by-subject (group-by :subject rows)
        subjects
        (sort
          (for [[subject subject-rows] by-subject
                :when (some #(= "semantic-unit-name" (:predicate %)) subject-rows)]
            subject))
        partial
        (mapv
          (fn [subject]
            (let [subject-rows (get by-subject subject)
                  module (one-fact subject-rows subject "semantic-unit-module" "t")
                  name (one-fact subject-rows subject "semantic-unit-name" "t")
                  semantic-digest
                  (one-fact subject-rows subject "semantic-unit-sha256" "t")]
              (when-not (re-matches #"semantic-unit-v0:[0-9a-f]{64}" subject)
                (fail! (str "malformed semantic unit identity: " subject)))
              (when-not (re-matches #"sha256:[0-9a-f]{64}" semantic-digest)
                (fail! (str "malformed semantic unit digest for " subject)))
              {:subject subject
               :qualified (str module "/" name)
               :kind (one-fact subject-rows subject "semantic-unit-kind" "t")
               :digest semantic-digest
               :rows subject-rows}))
          subjects)
        by-qualified (group-by :qualified partial)
        expected-qualified (set (map :qualified units))
        actual-qualified (set (keys by-qualified))
        subject-to-qualified
        (into {} (map (juxt :subject :qualified) partial))]
    (when-not (= expected-qualified actual-qualified)
      (fail! (str "semantic unit set differs from units.tsv: expected="
                  (sort expected-qualified) " actual=" (sort actual-qualified))))
    (doseq [{:keys [qualified kind reads]} (sort-by :qualified units)]
      (let [matches (get by-qualified qualified)]
        (when-not (= 1 (count matches))
          (fail! (str "expected one semantic unit named " qualified)))
        (let [unit (first matches)
              read-rows
              (filterv #(= "semantic-read" (:predicate %)) (:rows unit))
              _
              (doseq [row read-rows]
                (when-not (= "n" (:kind row))
                  (fail! (str qualified " semantic-read must use fact kind n"))))
              resolved
              (sort
                (mapv
                  (fn [row]
                    (or (get subject-to-qualified (:object row))
                        (fail! (str qualified " reads unknown unit " (:object row)))))
                  read-rows))]
          (when-not (= (count resolved) (count (distinct resolved)))
            (fail! (str qualified " contains duplicate semantic reads")))
          (when-not (= kind (:kind unit))
            (fail! (str qualified " kind differs from units.tsv: "
                        (:kind unit) " != " kind)))
          (when-not (= reads resolved)
            (fail! (str qualified " read set differs from units.tsv: "
                        resolved " != " reads)))
          (println (str case-id "\tsemantic-unit-id\t" qualified "\t"
                        (:subject unit)))
          (println (str case-id "\tsemantic-unit-content\t" qualified "\t"
                        (:digest unit)))
          (println (str case-id "\tsemantic-unit-read-set\t" qualified "\t"
                        (if (empty? resolved) "-" (str/join "," resolved)))))))))

(let [[case-id program-path facts-path units-path] *command-line-args*]
  (when-not (= 4 (count *command-line-args*))
    (fail! "usage: inspect.clj CASE MODULE.native-program source.facts units.tsv"))
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
                          (:digest function))))))
      (emit-semantic-units case-id facts-path units))))
