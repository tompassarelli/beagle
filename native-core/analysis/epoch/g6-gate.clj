;; g6-gate.clj — epoch measurement over the compiler-shaped
;; reference programs (the compiler's own modules and the validation corpus's
;; program-constructing modules).
;;
;; Inputs: --sources <dir>, the compiler's own source directory (the type
;; vocabulary is read out of it), then the epoch maps epoch-stage.clj wrote,
;; one per module. The wrapper native-core/tests/epoch_reference_gate.sh
;; produces the maps and passes both.
;;
;; Three measurements, one verdict:
;;
;;   assignment  — % of allocating sites carrying an epoch assignment
;;                 (gate: >= 90% aggregate).
;;   refusals    — every refusal reason TODO-EPOCH-coded and the fold total:
;;                 assigned + refused == sites, per module (gate: both).
;;   escapes     — G6's substantive claim is "escapes are exactly stage
;;                 products". An escape here is a caller-owned assignment: a
;;                 value that leaves through its region's OWN crossing set, so
;;                 the region allocates it into the caller's epoch. Each is
;;                 classified by the retaining type the analyzer observed:
;;                   product      every named type it mentions is one the
;;                                compiler declares (IR node, stage result,
;;                                receipt, artifact) — the claim holds
;;                   text-only    it mentions no declared type at all, only
;;                                scalars/text and containers of them
;;                   foreign      it names a type no compiler module declares
;;                                (gate: zero — a foreign retainer means the
;;                                escape is carrying something the compiler
;;                                does not own, which is the shape that would
;;                                falsify the claim)
;;                   untyped      the analyzer observed no retaining structure
;;                                (reported, never imputed — LIMITS.md item 8)
;;                 The product share is reported against the TYPED escapes and
;;                 against ALL escapes, and both are printed; the gate floors
;;                 the typed share so a regression is caught, and never credits
;;                 an untyped escape to either side.
(require '[cheshire.core :as json]
         '[clojure.string :as str])

(def assignment-threshold 0.90)
(def product-threshold 0.90)

;; Structural vocabulary: container constructors and scalar/text types. A
;; retaining type built only from these names nothing the compiler owns.
(def structural
  #{"U" "Vec" "Map" "Set" "List" "Seq" "Queue" "Option" "Atom" "Ref"
    "Any" "Bool" "Byte" "Bytes" "Char" "Double" "Float" "Int" "Keyword"
    "Nil" "String" "Text" "Unit"})

;; The compiler's declared type vocabulary, read out of its own sources: every
;; defrecord name, every defunion name, and every variant inside a defunion.
;; Cross-checked against the generated Clojure (356 defrecords) — this scan is
;; a superset of it by exactly the union names, which are types too.
(defn- strip-noise [s]
  (-> s
      (str/replace #"\"(\\.|[^\"\\])*\"" "\"\"")
      (str/replace #";[^\n]*" "")))

(defn- balanced-end [s start]
  (loop [i start depth 0]
    (if (>= i (count s))
      (count s)
      (let [c (.charAt ^String s i)]
        (cond (= c \() (recur (inc i) (inc depth))
              (= c \)) (if (= depth 1) i (recur (inc i) (dec depth)))
              :else (recur (inc i) depth))))))

(defn declared-types [text]
  (let [s (strip-noise text)
        records (set (map second (re-seq #"\(defrecord\s+([A-Z][A-Za-z0-9]*)" s)))]
    (loop [m (re-matcher #"\(defunion\s+([A-Z][A-Za-z0-9]*)" s)
           acc records]
      (if-not (.find m)
        acc
        (let [body (subs s (.start m) (balanced-end s (.start m)))]
          (recur m (into (conj acc (.group m 1))
                         (map second (re-seq #"\(\s*([A-Z][A-Za-z0-9]*)\s*\[" body)))))))))

(defn source-vocabulary [dir]
  (->> (file-seq (java.io.File. ^String dir))
       (filter #(str/ends-with? (.getName ^java.io.File %) ".bclj"))
       (map #(declared-types (slurp %)))
       (reduce into #{})))

(defn type-tokens
  "Capitalized names a retaining-type spelling mentions, namespace prefixes
   ('core/NativeId', 't/Triple') dropped."
  [spelling]
  (->> (str/split (str/replace (str spelling) #"[A-Za-z0-9_.-]+/" "") #"[^A-Za-z0-9]+")
       (filter #(re-matches #"[A-Z][A-Za-z0-9]*" %))
       distinct
       vec))

(defn classify-escape [declared spelling]
  (if (str/blank? (str spelling))
    {:class :untyped}
    (let [tokens (type-tokens spelling)
          named (remove structural tokens)
          unknown (remove declared named)]
      (cond
        (seq unknown) {:class :foreign :names (vec unknown)}
        (seq named) {:class :product :names (vec named)}
        :else {:class :text-only}))))

(let [args *command-line-args*
      [sources-flag sources-dir & map-paths] args]
  (when-not (and (= "--sources" sources-flag) sources-dir (seq map-paths))
    (binding [*out* *err*]
      (println "usage: bb g6-gate.clj --sources <native-src-dir> <epoch-map.json>..."))
    (System/exit 2))
  (let [declared (source-vocabulary sources-dir)
        maps (mapv #(json/parse-string (slurp %)) map-paths)
        row (fn [m]
              (let [kinds (get m "assignedByKind" {})]
                {:item (get m "item")
                 :sites (get m "totalSites")
                 :assigned (get m "assigned")
                 :refused (get m "refused")
                 :static (get kinds "static" 0)
                 :stage (get kinds "stage" 0)
                 :loop (get kinds "loop" 0)
                 :caller (get kinds "caller-owned" 0)
                 :refusals (get m "refusalProfile" {})
                 :total? (= (get m "totalSites")
                            (+ (get m "assigned") (get m "refused")))}))
        rows (mapv row maps)
        pct (fn [a t] (if (zero? t) 100.0 (* 100.0 (/ (double a) t))))
        sum (fn [k] (reduce + 0 (map k rows)))
        agg-sites (sum :sites)
        agg-assigned (sum :assigned)
        agg-rate (pct agg-assigned agg-sites)
        census (reduce (fn [acc r] (merge-with + acc (into {} (:refusals r))))
                       (sorted-map) rows)
        uncoded (vec (remove #(str/starts-with? % "TODO-EPOCH-") (keys census)))
        partial- (vec (keep #(when-not (:total? %) (:item %)) rows))
        escapes (vec (mapcat (fn [m]
                               (keep (fn [a]
                                       (when (= "caller-owned" (get a "kind"))
                                         (assoc (classify-escape declared (get a "retainingType"))
                                                :item (get m "item")
                                                :type (get a "retainingType")
                                                :site (get a "site"))))
                                     (get m "assignments")))
                             maps))
        by-class (frequencies (map :class escapes))
        n-escapes (count escapes)
        n-product (get by-class :product 0)
        n-text (get by-class :text-only 0)
        n-foreign (get by-class :foreign 0)
        n-untyped (get by-class :untyped 0)
        n-typed (+ n-product n-text n-foreign)
        line (apply str (repeat 81 "-"))]
    (println "=== G6: epoch assignment over the compiler-shaped reference programs ===")
    (println (format "%-32s %6s %9s %8s %7s %6s %5s %7s %8s"
                     "module" "sites" "assigned" "pct" "static" "stage" "loop"
                     "caller" "refused"))
    (println line)
    (doseq [r (sort-by :item rows)]
      (println (format "%-32s %6d %9d %7.1f%% %7d %6d %5d %7d %8d"
                       (:item r) (:sites r) (:assigned r)
                       (pct (:assigned r) (:sites r))
                       (:static r) (:stage r) (:loop r) (:caller r)
                       (:refused r))))
    (println line)
    (println (format "%-32s %6d %9d %7.1f%%" "TOTAL" agg-sites agg-assigned agg-rate))
    (println)
    (if (empty? census)
      (println "refusal census: none")
      (do (println "refusal census by code:")
          (doseq [[code n] (sort-by (comp - val) census)]
            (println (format "  %4d  %s" n code)))))
    (println)
    (println "escapes census (caller-owned sites: the region's own product)")
    (println (format "  escapes                 %5d" n-escapes))
    (println (format "  stage product           %5d  (%.1f%% of typed, %.1f%% of all)"
                     n-product (pct n-product n-typed) (pct n-product n-escapes)))
    (println (format "  text/scalar only        %5d" n-text))
    (println (format "  foreign retainer        %5d" n-foreign))
    (println (format "  untyped (not imputed)   %5d  (%.1f%% of all)"
                     n-untyped (pct n-untyped n-escapes)))
    (when (pos? n-product)
      (println "  stage-product retainers (top 12, so the label can be judged):")
      (doseq [[t n] (take 12 (sort-by (comp - val)
                                      (frequencies (map :type (filter #(= :product (:class %)) escapes)))))]
        (println (format "    %4d  %s" n t))))
    (when (pos? n-text)
      (println "  text/scalar retainers:")
      (doseq [[t n] (sort-by (comp - val) (frequencies (map :type (filter #(= :text-only (:class %)) escapes))))]
        (println (format "    %4d  %s" n t))))
    (when (pos? n-foreign)
      (println "  FOREIGN retainers:")
      (doseq [[t n] (sort-by (comp - val) (frequencies (map :type (filter #(= :foreign (:class %)) escapes))))]
        (println (format "    %4d  %s" n t))))
    (println)
    (let [fail (cond-> []
                 (< agg-rate (* 100.0 assignment-threshold))
                 (conj (format "aggregate assignment %.1f%% < %.0f%%"
                               agg-rate (* 100.0 assignment-threshold)))
                 (seq uncoded)
                 (conj (str "refusal codes not TODO-EPOCH-*: " (str/join ", " uncoded)))
                 (seq partial-)
                 (conj (str "fold not total (unexplained sites) in: " (str/join ", " partial-)))
                 (pos? n-foreign)
                 (conj (format "%d escapes retain a type no compiler module declares" n-foreign))
                 (< (pct n-product n-typed) (* 100.0 product-threshold))
                 (conj (format "stage-product share of typed escapes %.1f%% < %.0f%%"
                               (pct n-product n-typed) (* 100.0 product-threshold))))]
      (if (empty? fail)
        (println (format (str "G6 PASS: %.1f%% assigned, every refusal TODO-EPOCH-coded, "
                              "zero unexplained sites; escapes %.1f%% stage products "
                              "of the %d typed (%d untyped, reported not imputed)")
                         agg-rate (pct n-product n-typed) n-typed n-untyped))
        (do (doseq [f fail] (println (str "G6 FAIL: " f)))
            (System/exit 1))))))
