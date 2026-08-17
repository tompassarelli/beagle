;; roundtrip_test.clj — Triple<->Markdown idempotence guard.
;;
;; Proves that importing, exporting the live occurrence projection, and
;; importing again yields the same Triple set.
;;
;;   bb -cp out tests/roundtrip_test.clj
(require '[fram.types :as t]
         '[fram.fold :as fold]
         '[fram.import :as imp]
         '[fram.export :as exp]
         '[fram.rt]
         '[clojure.java.io :as io]
         '[clojure.set :as set]
         '[clojure.string :as str])

(defn triple-signature [value]
  [(t/triple-t1 value) (t/triple-t2 value) (t/triple-t3 value)])

(defn live-triples [space frames]
  (:live-propositions (fold/fold! space frames)))

(defn triple-set [space frames]
  (set (map triple-signature (live-triples space frames))))

(defn frame-proposition [frame]
  (t/commitoperation-proposition
   (first (t/transactionframe-operations frame))))

(defn identity-triple? [value]
  (contains? #{"predicate_name" "predicate_alias"}
             (t/triple-t2 value)))

(defn title-of [triples subject]
  (some (fn [value]
          (when (and (= subject (t/triple-t1 value))
                     (= "title" (t/triple-t2 value)))
            (t/triple-t3 value)))
        triples))

;; The legacy exporter included title-bearing subjects and predicate metadata
;; subjects. Keep that projection boundary while the kernel stays slot-neutral.
(defn projection-subjects [triples]
  (vec
   (distinct
    (concat
     (map t/triple-t1
          (filter #(= "title" (t/triple-t2 %)) triples))
     (map t/triple-t1 (filter identity-triple? triples))))))

(defn export-corpus! [triples out]
  (.mkdirs (io/file out))
  (doseq [subject (projection-subjects triples)]
    (let [title (title-of triples subject)
          id (if (str/starts-with? subject "@") (subs subject 1) subject)
          filename (str id "-"
                        (fram.rt/slugify (if title title "untitled"))
                        ".md")]
      (spit (str out "/" filename) (exp/thread-md triples subject)))))

(defn require-pass [label ok]
  (println (str "  [" (if ok "PASS" "FAIL") "] " label))
  (when-not ok (System/exit 1)))

;; Predicate identity metadata is imported before dependent triples, aliases
;; canonicalize, and value_kind—not the object's @ sigil—governs both directions.
(let [root (str (System/getProperty "java.io.tmpdir") "/fram-predicate-rt-"
                (System/currentTimeMillis))
      src (str root "/src")
      out (str root "/out")]
  (.mkdirs (io/file src))
  (spit (str src "/01-friend.md")
        "@friend\npredicate_name  friend\npredicate_alias  :friend\ncardinality  multi\nvalue_kind  ref\n---\n")
  (spit (str src "/02-note.md")
        "@note\npredicate_name  note\npredicate_alias  :note\ncardinality  multi\nvalue_kind  literal\n---\n")
  (spit (str src "/03-alice.md")
        "@alice\ntitle  Alice\n:friend  bob\nnote  \"@bob\"\n---\n")
  (let [frames (imp/load-corpus src)
        triples (live-triples "predicate-roundtrip" frames)
        signatures (set (map triple-signature triples))
        frame-triples (map frame-proposition frames)
        identity-count (count (filter identity-triple? frame-triples))
        prefix-count (count (take-while identity-triple? frame-triples))
        first-domain (first (drop-while identity-triple? frame-triples))]
    (require-pass "import emits ordered one-assertion transaction frames"
                  (every?
                   true?
                   (map-indexed
                    (fn [position frame]
                      (let [operations (t/transactionframe-operations frame)]
                        (and (= (+ position 1)
                                (t/transactionframe-sequence frame))
                             (= 1 (count operations))
                             (= t/assert-action
                                (t/commitoperation-action
                                 (first operations)))
                             (t/triple?
                              (t/commitoperation-proposition
                               (first operations))))))
                    frames)))
    (require-pass "identity metadata precedes dependent import triples"
                  (and first-domain
                       (pos? identity-count)
                       (= identity-count prefix-count)))
    (require-pass "alias import resolves to canonical ref predicate"
                  (contains? signatures ["@alice" "friend" "@bob"]))
    (require-pass "explicit literal preserves an @-prefixed value"
                  (contains? signatures ["@alice" "note" "@bob"]))
    (require-pass "identity metadata remains ordinary triples"
                  (and (contains? signatures
                                  ["@friend" "predicate_name" "friend"])
                       (contains? signatures
                                  ["@friend" "predicate_alias" ":friend"])))
    (export-corpus! triples out)
    (require-pass "export includes predicate metadata subjects"
                  (= signatures (triple-set "predicate-reimport"
                                            (imp/load-corpus out))))
    (let [rendered (exp/thread-md triples "@alice")]
      (require-pass "declared ref exports bare"
                    (str/includes? rendered "friend  @bob"))
      (require-pass "declared literal exports quoted"
                    (str/includes? rendered "note  \"@bob\"")))))

(let [legacy [(t/triple "@a" "title" "A")
              (t/triple "@a" "depends_on" "@b")
              (t/triple "@a" "note" "@literal")
              (t/triple "@b" "title" "B")]
      rendered (exp/thread-md legacy "@a")]
  (require-pass "legacy ref fallback renders unchanged"
                (str/includes? rendered "depends_on  @b"))
  (require-pass "legacy literal @ value remains quoted"
                (str/includes? rendered "note  \"@literal\"")))

(let [frames (imp/load-corpus "threads")
      triples (live-triples "fixture-roundtrip" frames)
      before (set (map triple-signature triples))
      out (str (System/getProperty "java.io.tmpdir") "/fram-rt-"
               (System/currentTimeMillis))]
  (export-corpus! triples out)
  (let [after (triple-set "fixture-reimport" (imp/load-corpus out))
        only-before (set/difference before after)
        only-after (set/difference after before)]
    (println "round-trip:" (count before) "triples in," (count after)
             "triples back (" (count (projection-subjects triples))
             "subjects )")
    (when (seq only-before)
      (println "  LOST (in source, not round-trip):")
      (doseq [value (take 10 only-before)] (println "   " (pr-str value))))
    (when (seq only-after)
      (println "  GAINED (in round-trip, not source):")
      (doseq [value (take 10 only-after)] (println "   " (pr-str value))))
    (require-pass "import->export->import is Triple-identical"
                  (and (empty? only-before) (empty? only-after)))))
