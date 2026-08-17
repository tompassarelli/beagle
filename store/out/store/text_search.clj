(ns store.text-search
  (:require [clojure.string :as str]
            [store.text-index :as text-index]
            [store.types :as t]))

(def WORD-SEPARATOR-RE (re-pattern "[^\\p{L}\\p{Nd}]+"))

(defrecord SearchAnalyzers [token-rows normalized-rows stem-postings trigram-postings bytes])

(defn searchanalyzers-token-rows [r] (:token-rows r))

(defn searchanalyzers-normalized-rows [r] (:normalized-rows r))

(defn searchanalyzers-stem-postings [r] (:stem-postings r))

(defn searchanalyzers-trigram-postings [r] (:trigram-postings r))

(defn searchanalyzers-bytes [r] (:bytes r))

(defrecord TextSearchSource [exact rows maximum analyzers-cell bytes])

(defn textsearchsource-exact [r] (:exact r))

(defn textsearchsource-rows [r] (:rows r))

(defn textsearchsource-maximum [r] (:maximum r))

(defn textsearchsource-analyzers-cell [r] (:analyzers-cell r))

(defn textsearchsource-bytes [r] (:bytes r))

(defrecord SearchBuildState [token-rows normalized-rows stem-postings trigram-postings])

(defn searchbuildstate-token-rows [r] (:token-rows r))

(defn searchbuildstate-normalized-rows [r] (:normalized-rows r))

(defn searchbuildstate-stem-postings [r] (:stem-postings r))

(defn searchbuildstate-trigram-postings [r] (:trigram-postings r))

(defrecord TextSearchSourceResult [ok source error])

(defn textsearchsourceresult-ok [r] (:ok r))

(defn textsearchsourceresult-source [r] (:source r))

(defn textsearchsourceresult-error [r] (:error r))

(defrecord TextSearchHandlesResult [ok handles error])

(defn textsearchhandlesresult-ok [r] (:ok r))

(defn textsearchhandlesresult-handles [r] (:handles r))

(defn textsearchhandlesresult-error [r] (:error r))

(defrecord TextSearchRowsResult [ok rows error])

(defn textsearchrowsresult-ok [r] (:ok r))

(defn textsearchrowsresult-rows [r] (:rows r))

(defn textsearchrowsresult-error [r] (:error r))

(defrecord TextSearchScoreResult [ok score error])

(defn textsearchscoreresult-ok [r] (:ok r))

(defn textsearchscoreresult-score [r] (:score r))

(defn textsearchscoreresult-error [r] (:error r))

(defrecord SearchAnalyzersResult [ok analyzers error])

(defn searchanalyzersresult-ok [r] (:ok r))

(defn searchanalyzersresult-analyzers [r] (:analyzers r))

(defn searchanalyzersresult-error [r] (:error r))

(defrecord StringNeedleResult [ok value error])

(defn stringneedleresult-ok [r] (:ok r))

(defn stringneedleresult-value [r] (:value r))

(defn stringneedleresult-error [r] (:error r))

(defrecord WordNeedleResult [ok tokens error])

(defn wordneedleresult-ok [r] (:ok r))

(defn wordneedleresult-tokens [r] (:tokens r))

(defn wordneedleresult-error [r] (:error r))

(defn ^Boolean source-result-ok? [^TextSearchSourceResult result]
  (textsearchsourceresult-ok result))

(defn source-result-source [^TextSearchSourceResult result]
  (textsearchsourceresult-source result))

(defn source-result-error [^TextSearchSourceResult result]
  (textsearchsourceresult-error result))

(defn ^Boolean handles-result-ok? [^TextSearchHandlesResult result]
  (textsearchhandlesresult-ok result))

(defn handles-result-handles [^TextSearchHandlesResult result]
  (textsearchhandlesresult-handles result))

(defn handles-result-error [^TextSearchHandlesResult result]
  (textsearchhandlesresult-error result))

(defn ^Boolean rows-result-ok? [^TextSearchRowsResult result]
  (textsearchrowsresult-ok result))

(defn rows-result-rows [^TextSearchRowsResult result]
  (textsearchrowsresult-rows result))

(defn rows-result-error [^TextSearchRowsResult result]
  (textsearchrowsresult-error result))

(defn ^TextSearchRowsResult query-text-rows-error [code ^String message]
  (->TextSearchRowsResult false [] (text-index/query-text-error code message)))

(defn source-weight [^TextSearchSource source]
  (let [analyzers (deref (textsearchsource-analyzers-cell source))]
  (+ (textsearchsource-bytes source) (if (nil? analyzers) 0 (searchanalyzers-bytes analyzers)))))

(defn- ^String lower [^String value]
  (str/lower-case value))

(defn word-tokens [^String value]
  (let [parts (str/split value WORD-SEPARATOR-RE)]
  (loop [index 0
   tokens []]
  (if (>= index (count parts)) tokens (let [token (nth parts index)]
  (recur (inc index) (if (= "" token) tokens (conj tokens (lower token)))))))))

(defn- ^String drop-last [^String value amount]
  (subs value 0 (- (count value) amount)))

(defn- ^Boolean vowel? [^String character]
  (contains? #{"a" "e" "i" "o" "u"} character))

(defn- ^Boolean vowel-at? [^String value index]
  (vowel? (subs value index (inc index))))

(defn- ^Boolean has-vowel? [^String value]
  (loop [index 0]
  (if (>= index (count value)) false (if (vowel-at? value index) true (recur (inc index))))))

(defn- ^Boolean double-consonant? [^String value]
  (let [size (count value)]
  (and (>= size 2) (let [last-char (subs value (dec size) size)
   prior-char (subs value (- size 2) (dec size))]
  (and (= last-char prior-char) (and (not (vowel? last-char)) (not (contains? #{"l" "s" "z"} last-char))))))))

(defn- ^Boolean short-syllable? [^String value]
  (let [size (count value)]
  (and (>= size 3) (let [first-char (subs value (- size 3) (- size 2))
   middle-char (subs value (- size 2) (dec size))
   last-char (subs value (dec size) size)]
  (and (not (vowel? first-char)) (and (vowel? middle-char) (and (not (vowel? last-char)) (not (contains? #{"w" "x" "y"} last-char)))))))))

(defn- ^String normalize-verb-stem [^String value]
  (if (double-consonant? value) (drop-last value 1) (if (short-syllable? value) (str value "e") value)))

(defn- ^String plural-stem [^String value]
  (cond
  (and (> (count value) 4) (str/ends-with? value "ies")) (str (drop-last value 3) "y")
  (str/ends-with? value "sses") (drop-last value 2)
  (and (> (count value) 3) (and (str/ends-with? value "s") (not (or (str/ends-with? value "ss") (or (str/ends-with? value "us") (str/ends-with? value "is")))))) (drop-last value 1)
  :else value))

(defn ^String english-stem [^String token]
  (let [value (plural-stem (lower token))]
  (cond
  (and (> (count value) 4) (str/ends-with? value "ied")) (str (drop-last value 3) "y")
  (and (> (count value) 5) (str/ends-with? value "ing")) (let [base (drop-last value 3)]
  (if (has-vowel? base) (normalize-verb-stem base) value))
  (and (> (count value) 4) (str/ends-with? value "ed")) (let [base (drop-last value 2)]
  (if (has-vowel? base) (normalize-verb-stem base) value))
  (and (> (count value) 4) (str/ends-with? value "ly")) (drop-last value 2)
  (and (> (count value) 4) (str/ends-with? value "er")) (let [base (drop-last value 2)]
  (if (has-vowel? base) (normalize-verb-stem base) value))
  (and (> (count value) 5) (str/ends-with? value "est")) (let [base (drop-last value 3)]
  (if (has-vowel? base) (normalize-verb-stem base) value))
  :else value)))

(defn- stems [tokens]
  (set (mapv (fn [^String token] (english-stem token)) tokens)))

(defn- trigrams [^String value]
  (loop [index 0
   grams #{}]
  (if (> (+ index 3) (count value)) grams (recur (inc index) (conj grams (subs value index (+ index 3)))))))

(defn- postings-add [postings keys handle]
  (reduce (fn [current ^String key] (assoc current key (conj (get current key []) handle))) postings keys))

(defn- postings-weight [postings]
  (reduce-kv (fn [total ^String key handles] (+ total 84 (* 4 (count key)) (* 42 (count handles)))) 0 postings))

(defn- token-rows-weight [rows]
  (reduce (fn [total tokens] (let [token-weight (loop [remaining tokens
   subtotal 0]
  (if (empty? remaining) subtotal (recur (vec (rest remaining)) (+ subtotal 42 (* 4 (count (first remaining)))))))]
  (+ total 42 token-weight))) 0 rows))

(defn- strings-weight [values]
  (reduce (fn [total ^String value] (+ total 70 (* 4 (count value)))) 0 values))

(defn- index-limit-error [weight maximum]
  (if (> weight maximum) (text-index/text-index-limit-error "text search index exceeds the snapshot cache budget" weight maximum) nil))

(defn- index-limit [weight maximum]
  (if (> weight maximum) (text-index/raise-text-error (text-index/text-index-limit-error "text search index exceeds the snapshot cache budget" weight maximum)) nil))

(defn- ^SearchBuildState build-state [rows]
  (loop [handle 0
   state (->SearchBuildState [] [] {} {})]
  (if (>= handle (count rows)) state (let [value (t/triple-t3 (nth rows handle))]
  (if (string? value) (let [tokens (word-tokens value)
   normalized (lower value)
   stem-keys (stems tokens)
   gram-keys (trigrams normalized)]
  (recur (inc handle) (->SearchBuildState (conj (searchbuildstate-token-rows state) tokens) (conj (searchbuildstate-normalized-rows state) normalized) (postings-add (searchbuildstate-stem-postings state) (vec stem-keys) handle) (postings-add (searchbuildstate-trigram-postings state) (vec gram-keys) handle)))) (recur (inc handle) (->SearchBuildState (conj (searchbuildstate-token-rows state) []) (conj (searchbuildstate-normalized-rows state) "") (searchbuildstate-stem-postings state) (searchbuildstate-trigram-postings state))))))))

(defn ^TextSearchSourceResult build-source-result! [propositions maximum]
  (let [rows (vec propositions)
   exact-result (text-index/build-source-result! rows maximum)
   exact (text-index/source-result-source exact-result)]
  (if (nil? exact) (->TextSearchSourceResult false nil (text-index/source-result-error exact-result)) (let [weight (+ (text-index/source-weight exact) 112 (* 28 (count rows)))
   error (index-limit-error weight maximum)]
  (if error (->TextSearchSourceResult false nil error) (let [empty-analyzers nil
   cell (atom empty-analyzers)]
  (->TextSearchSourceResult true (->TextSearchSource exact rows maximum cell weight) (text-index/no-text-error))))))))

(defn propositions-for-attributes [propositions attributes]
  (filterv (fn [proposition] (contains? attributes (t/triple-t2 proposition))) propositions))

(defn ^TextSearchSourceResult build-source-for-attributes-result! [propositions attributes maximum]
  (build-source-result! (propositions-for-attributes propositions attributes) maximum))

(defn ^TextSearchSource build-source! [propositions maximum]
  (let [rows (vec propositions)
   exact (text-index/build-source! rows maximum)
   weight (+ (text-index/source-weight exact) 112 (* 28 (count rows)))
   empty-analyzers nil
   cell (atom empty-analyzers)]
  (index-limit weight maximum)
  (->TextSearchSource exact rows maximum cell weight)))

(defn ^TextSearchSource build-source-for-attributes! [propositions attributes maximum]
  (build-source! (propositions-for-attributes propositions attributes) maximum))

(defn- ^SearchAnalyzersResult analyzers-of-result! [^TextSearchSource source]
  (let [current (deref (textsearchsource-analyzers-cell source))]
  (if (nil? current) (let [state (build-state (textsearchsource-rows source))
   token-rows (searchbuildstate-token-rows state)
   normalized-rows (searchbuildstate-normalized-rows state)
   stem-postings (searchbuildstate-stem-postings state)
   trigram-postings (searchbuildstate-trigram-postings state)
   weight (+ (token-rows-weight token-rows) (strings-weight normalized-rows) (postings-weight stem-postings) (postings-weight trigram-postings))
   analyzers (->SearchAnalyzers token-rows normalized-rows stem-postings trigram-postings weight)
   error (index-limit-error (+ (textsearchsource-bytes source) weight) (textsearchsource-maximum source))]
  (if error (->SearchAnalyzersResult false analyzers error) (do
  (reset! (textsearchsource-analyzers-cell source) analyzers)
  (->SearchAnalyzersResult true analyzers (text-index/no-text-error))))) (->SearchAnalyzersResult true current (text-index/no-text-error)))))

(defn- ^SearchAnalyzers analyzers-of! [^TextSearchSource source]
  (let [result (analyzers-of-result! source)]
  (if (searchanalyzersresult-ok result) (searchanalyzersresult-analyzers result) (text-index/raise-text-error (searchanalyzersresult-error result)))))

(defn- ^StringNeedleResult string-needle-result [^String relation needle]
  (if (string? needle) (->StringNeedleResult true needle (text-index/no-text-error)) (->StringNeedleResult false "" (text-index/query-text-error :query-text-invalid-needle (str relation " needle must be a string")))))

(defn- ^String string-needle [^String relation needle]
  (let [result (string-needle-result relation needle)]
  (if (stringneedleresult-ok result) (stringneedleresult-value result) (text-index/raise-text-error (stringneedleresult-error result)))))

(defn- ^WordNeedleResult word-needle-result [^String relation needle]
  (let [string-result (string-needle-result relation needle)]
  (if (not (stringneedleresult-ok string-result)) (->WordNeedleResult false [] (stringneedleresult-error string-result)) (let [tokens (word-tokens (stringneedleresult-value string-result))]
  (if (empty? tokens) (->WordNeedleResult false [] (text-index/query-text-error :query-text-invalid-needle (str relation " needle must contain at least one word token"))) (->WordNeedleResult true tokens (text-index/no-text-error)))))))

(defn- word-needle [^String relation needle]
  (let [result (word-needle-result relation needle)]
  (if (wordneedleresult-ok result) (wordneedleresult-tokens result) (text-index/raise-text-error (wordneedleresult-error result)))))

(defn- ^StringNeedleResult substring-needle-result [^String relation needle]
  (let [string-result (string-needle-result relation needle)]
  (if (not (stringneedleresult-ok string-result)) string-result (let [value (lower (stringneedleresult-value string-result))]
  (if (empty? (str/trim value)) (->StringNeedleResult false "" (text-index/query-text-error :query-text-invalid-needle (str relation " needle must contain non-whitespace text"))) (->StringNeedleResult true value (text-index/no-text-error)))))))

(defn- ^String substring-needle [^String relation needle]
  (let [result (substring-needle-result relation needle)]
  (if (stringneedleresult-ok result) (stringneedleresult-value result) (text-index/raise-text-error (stringneedleresult-error result)))))

(defn ^Boolean word-needle-valid? [needle]
  (and (string? needle) (not (empty? (word-tokens needle)))))

(defn ^Boolean substring-needle-valid? [needle]
  (if (string? needle) (let [text needle]
  (not (empty? (str/trim text)))) false))

(defn- shortest-posting [vectors]
  (let [empty-handles []]
  (if (empty? vectors) empty-handles (loop [index 1
   best (nth vectors 0)]
  (if (>= index (count vectors)) best (let [candidate (nth vectors index)]
  (recur (inc index) (if (< (count candidate) (count best)) candidate best))))))))

(defn- postings-handles [postings keys]
  (let [wanted (vec (sort (vec (set keys))))]
  (if (empty? wanted) [] (let [vectors (mapv (fn [^String key] (get postings key [])) wanted)
   seed (shortest-posting vectors)]
  (if (or (empty? seed) (= 1 (count vectors))) seed (let [sets (mapv (fn [handles] (set handles)) vectors)]
  (filterv (fn [handle] (every? (fn [handles] (contains? handles handle)) sets)) seed)))))))

(defn- all-handles [^TextSearchSource source]
  (vec (range (count (textsearchsource-rows source)))))

(defn- ^Boolean sequence-at? [haystack needle start]
  (loop [offset 0]
  (if (>= offset (count needle)) true (if (= (nth haystack (+ start offset)) (nth needle offset)) (recur (inc offset)) false))))

(defn- ^Boolean sequence-contains? [haystack needle]
  (if (or (empty? needle) (> (count needle) (count haystack))) false (loop [start 0]
  (if (> (+ start (count needle)) (count haystack)) false (if (sequence-at? haystack needle start) true (recur (inc start)))))))

(defn- ^TextSearchHandlesResult handles-ok [handles]
  (->TextSearchHandlesResult true handles (text-index/no-text-error)))

(defn- ^TextSearchHandlesResult handles-error [error]
  (->TextSearchHandlesResult false [] error))

(defn- ^TextSearchRowsResult rows-ok [rows]
  (->TextSearchRowsResult true rows (text-index/no-text-error)))

(defn- ^TextSearchRowsResult rows-error [error]
  (->TextSearchRowsResult false [] error))

(defn ^TextSearchHandlesResult phrase-handles-result! [^TextSearchSource source needle]
  (let [needle-result (word-needle-result "text-phrase" needle)]
  (if (not (wordneedleresult-ok needle-result)) (handles-error (wordneedleresult-error needle-result)) (let [indexed-result (text-index/indexed-handles-result! (textsearchsource-exact source) needle)]
  (if (not (text-index/handles-result-ok? indexed-result)) (handles-error (text-index/handles-result-error indexed-result)) (let [analyzers-result (analyzers-of-result! source)]
  (if (not (searchanalyzersresult-ok analyzers-result)) (handles-error (searchanalyzersresult-error analyzers-result)) (let [tokens (wordneedleresult-tokens needle-result)
   candidates (text-index/handles-result-handles indexed-result)
   rows (searchanalyzers-token-rows (searchanalyzersresult-analyzers analyzers-result))]
  (handles-ok (filterv (fn [handle] (sequence-contains? (nth rows handle) tokens)) candidates))))))))))

(defn phrase-handles! [^TextSearchSource source needle]
  (let [result (phrase-handles-result! source needle)]
  (if (handles-result-ok? result) (handles-result-handles result) (text-index/raise-text-error (handles-result-error result)))))

(defn ^TextSearchHandlesResult phrase-scan-handles-result! [^TextSearchSource source needle]
  (let [needle-result (word-needle-result "text-phrase" needle)]
  (if (not (wordneedleresult-ok needle-result)) (handles-error (wordneedleresult-error needle-result)) (let [analyzers-result (analyzers-of-result! source)]
  (if (not (searchanalyzersresult-ok analyzers-result)) (handles-error (searchanalyzersresult-error analyzers-result)) (let [tokens (wordneedleresult-tokens needle-result)
   rows (searchanalyzers-token-rows (searchanalyzersresult-analyzers analyzers-result))]
  (handles-ok (filterv (fn [handle] (sequence-contains? (nth rows handle) tokens)) (all-handles source)))))))))

(defn phrase-scan-handles! [^TextSearchSource source needle]
  (let [result (phrase-scan-handles-result! source needle)]
  (if (handles-result-ok? result) (handles-result-handles result) (text-index/raise-text-error (handles-result-error result)))))

(defn ^TextSearchHandlesResult substring-handles-result! [^TextSearchSource source needle]
  (let [needle-result (substring-needle-result "text-substring" needle)]
  (if (not (stringneedleresult-ok needle-result)) (handles-error (stringneedleresult-error needle-result)) (let [value (stringneedleresult-value needle-result)
   grams (vec (trigrams value))
   analyzers-result (analyzers-of-result! source)]
  (if (not (searchanalyzersresult-ok analyzers-result)) (handles-error (searchanalyzersresult-error analyzers-result)) (let [analyzers (searchanalyzersresult-analyzers analyzers-result)
   candidates (if (empty? grams) (all-handles source) (postings-handles (searchanalyzers-trigram-postings analyzers) grams))
   rows (searchanalyzers-normalized-rows analyzers)]
  (handles-ok (filterv (fn [handle] (str/includes? (nth rows handle) value)) candidates))))))))

(defn substring-handles! [^TextSearchSource source needle]
  (let [result (substring-handles-result! source needle)]
  (if (handles-result-ok? result) (handles-result-handles result) (text-index/raise-text-error (handles-result-error result)))))

(defn ^TextSearchHandlesResult substring-scan-handles-result! [^TextSearchSource source needle]
  (let [needle-result (substring-needle-result "text-substring" needle)]
  (if (not (stringneedleresult-ok needle-result)) (handles-error (stringneedleresult-error needle-result)) (let [analyzers-result (analyzers-of-result! source)]
  (if (not (searchanalyzersresult-ok analyzers-result)) (handles-error (searchanalyzersresult-error analyzers-result)) (let [value (stringneedleresult-value needle-result)
   rows (searchanalyzers-normalized-rows (searchanalyzersresult-analyzers analyzers-result))]
  (handles-ok (filterv (fn [handle] (str/includes? (nth rows handle) value)) (all-handles source)))))))))

(defn substring-scan-handles! [^TextSearchSource source needle]
  (let [result (substring-scan-handles-result! source needle)]
  (if (handles-result-ok? result) (handles-result-handles result) (text-index/raise-text-error (handles-result-error result)))))

(defn ^TextSearchHandlesResult stem-handles-result! [^TextSearchSource source needle]
  (let [needle-result (word-needle-result "text-stem" needle)]
  (if (not (wordneedleresult-ok needle-result)) (handles-error (wordneedleresult-error needle-result)) (let [keys (vec (stems (wordneedleresult-tokens needle-result)))
   analyzers-result (analyzers-of-result! source)]
  (if (not (searchanalyzersresult-ok analyzers-result)) (handles-error (searchanalyzersresult-error analyzers-result)) (handles-ok (postings-handles (searchanalyzers-stem-postings (searchanalyzersresult-analyzers analyzers-result)) keys)))))))

(defn stem-handles! [^TextSearchSource source needle]
  (let [result (stem-handles-result! source needle)]
  (if (handles-result-ok? result) (handles-result-handles result) (text-index/raise-text-error (handles-result-error result)))))

(defn ^TextSearchHandlesResult stem-scan-handles-result! [^TextSearchSource source needle]
  (let [needle-result (word-needle-result "text-stem" needle)]
  (if (not (wordneedleresult-ok needle-result)) (handles-error (wordneedleresult-error needle-result)) (let [analyzers-result (analyzers-of-result! source)]
  (if (not (searchanalyzersresult-ok analyzers-result)) (handles-error (searchanalyzersresult-error analyzers-result)) (let [keys (vec (stems (wordneedleresult-tokens needle-result)))
   rows (searchanalyzers-token-rows (searchanalyzersresult-analyzers analyzers-result))]
  (handles-ok (filterv (fn [handle] (let [row-stems (stems (nth rows handle))]
  (every? (fn [^String key] (contains? row-stems key)) keys))) (all-handles source)))))))))

(defn stem-scan-handles! [^TextSearchSource source needle]
  (let [result (stem-scan-handles-result! source needle)]
  (if (handles-result-ok? result) (handles-result-handles result) (text-index/raise-text-error (handles-result-error result)))))

(defn- count-token [tokens ^String wanted]
  (reduce (fn [total ^String token] (if (= token wanted) (inc total) total)) 0 tokens))

(defn- ^TextSearchScoreResult score-at-result! [^TextSearchSource source handle needle]
  (let [needle-result (substring-needle-result "text-search" needle)]
  (if (not (stringneedleresult-ok needle-result)) (->TextSearchScoreResult false 0 (stringneedleresult-error needle-result)) (let [analyzers-result (analyzers-of-result! source)]
  (if (not (searchanalyzersresult-ok analyzers-result)) (->TextSearchScoreResult false 0 (searchanalyzersresult-error analyzers-result)) (let [value (stringneedleresult-value needle-result)
   query-tokens (word-tokens value)
   query-stems (vec (stems query-tokens))
   analyzers (searchanalyzersresult-analyzers analyzers-result)
   document-tokens (nth (searchanalyzers-token-rows analyzers) handle)
   document-token-set (set document-tokens)
   document-stems (stems document-tokens)
   normalized (nth (searchanalyzers-normalized-rows analyzers) handle)
   substring-match (str/includes? normalized value)
   stem-covered (and (not (empty? query-stems)) (every? (fn [^String key] (contains? document-stems key)) query-stems))
   phrase-match (and (not (empty? query-tokens)) (sequence-contains? document-tokens query-tokens))
   score (if (not (or substring-match stem-covered)) 0 (let [token-score (reduce (fn [total ^String token] (let [match-score (cond
  (contains? document-token-set token) 100
  (contains? document-stems (english-stem token)) 60
  :else 0)
   match-count (min 3 (count-token document-tokens token))]
  (+ total match-score (* 5 match-count)))) 0 query-tokens)
   phrase-score (if phrase-match 250 0)
   substring-score (if substring-match 80 0)
   exact-score (if (= normalized value) 400 0)
   raw (+ token-score phrase-score substring-score exact-score)
   penalty (min 40 (max 0 (- (count document-tokens) (count query-tokens))))]
  (max 1 (- raw penalty))))]
  (->TextSearchScoreResult true score (text-index/no-text-error))))))))

(defn- score-at! [^TextSearchSource source handle needle]
  (let [result (score-at-result! source handle needle)]
  (if (textsearchscoreresult-ok result) (textsearchscoreresult-score result) (text-index/raise-text-error (textsearchscoreresult-error result)))))

(defn- union-handles [left right]
  (vec (sort (vec (set (concat left right))))))

(defn- ^TextSearchHandlesResult matching-score-handles-result! [^TextSearchSource source needle candidates]
  (loop [position 0
   matches []]
  (if (>= position (count candidates)) (handles-ok matches) (let [handle (nth candidates position)
   result (score-at-result! source handle needle)]
  (if (not (textsearchscoreresult-ok result)) (handles-error (textsearchscoreresult-error result)) (recur (inc position) (if (pos? (textsearchscoreresult-score result)) (conj matches handle) matches)))))))

(defn ^TextSearchHandlesResult ranked-handles-result! [^TextSearchSource source needle]
  (let [needle-result (substring-needle-result "text-search" needle)]
  (if (not (stringneedleresult-ok needle-result)) (handles-error (stringneedleresult-error needle-result)) (let [analyzers-result (analyzers-of-result! source)]
  (if (not (searchanalyzersresult-ok analyzers-result)) (handles-error (searchanalyzersresult-error analyzers-result)) (let [value (stringneedleresult-value needle-result)
   query-tokens (word-tokens value)
   analyzers (searchanalyzersresult-analyzers analyzers-result)
   stem-candidates (if (empty? query-tokens) [] (postings-handles (searchanalyzers-stem-postings analyzers) (vec (stems query-tokens))))
   gram-keys (vec (trigrams value))
   substring-candidates (if (empty? gram-keys) (all-handles source) (postings-handles (searchanalyzers-trigram-postings analyzers) gram-keys))
   candidates (union-handles stem-candidates substring-candidates)]
  (matching-score-handles-result! source needle candidates)))))))

(defn ranked-handles! [^TextSearchSource source needle]
  (let [result (ranked-handles-result! source needle)]
  (if (handles-result-ok? result) (handles-result-handles result) (text-index/raise-text-error (handles-result-error result)))))

(defn ^TextSearchHandlesResult ranked-scan-handles-result! [^TextSearchSource source needle]
  (matching-score-handles-result! source needle (all-handles source)))

(defn ranked-scan-handles! [^TextSearchSource source needle]
  (let [result (ranked-scan-handles-result! source needle)]
  (if (handles-result-ok? result) (handles-result-handles result) (text-index/raise-text-error (handles-result-error result)))))

(defn- rows-for-handles [^TextSearchSource source needle handles]
  (let [rows (textsearchsource-rows source)]
  (mapv (fn [handle] (let [proposition (nth rows handle)]
  [(t/triple-t1 proposition) (t/triple-t2 proposition) needle])) handles)))

(defn- ^TextSearchRowsResult ranked-rows-for-handles-result! [^TextSearchSource source needle handles]
  (let [source-rows (textsearchsource-rows source)]
  (loop [position 0
   result-rows []]
  (if (>= position (count handles)) (rows-ok result-rows) (let [handle (nth handles position)
   score-result (score-at-result! source handle needle)]
  (if (not (textsearchscoreresult-ok score-result)) (rows-error (textsearchscoreresult-error score-result)) (let [proposition (nth source-rows handle)]
  (recur (inc position) (conj result-rows [(t/triple-t1 proposition) (t/triple-t2 proposition) needle (textsearchscoreresult-score score-result)])))))))))

(defn- ranked-rows-for-handles! [^TextSearchSource source needle handles]
  (let [result (ranked-rows-for-handles-result! source needle handles)]
  (if (rows-result-ok? result) (rows-result-rows result) (text-index/raise-text-error (rows-result-error result)))))

(defn ^TextSearchRowsResult exact-indexed-rows-result! [^TextSearchSource source needle]
  (let [result (text-index/indexed-rows-result! (textsearchsource-exact source) needle)]
  (if (text-index/rows-result-ok? result) (rows-ok (text-index/rows-result-rows result)) (rows-error (text-index/rows-result-error result)))))

(defn ^TextSearchRowsResult exact-scan-rows-result! [^TextSearchSource source needle]
  (let [result (text-index/scan-rows-result! (textsearchsource-exact source) needle)]
  (if (text-index/rows-result-ok? result) (rows-ok (text-index/rows-result-rows result)) (rows-error (text-index/rows-result-error result)))))

(defn exact-indexed-rows! [^TextSearchSource source needle]
  (let [result (exact-indexed-rows-result! source needle)]
  (if (rows-result-ok? result) (rows-result-rows result) (text-index/raise-text-error (rows-result-error result)))))

(defn exact-scan-rows! [^TextSearchSource source needle]
  (let [result (exact-scan-rows-result! source needle)]
  (if (rows-result-ok? result) (rows-result-rows result) (text-index/raise-text-error (rows-result-error result)))))

(defn- ^TextSearchRowsResult rows-for-handles-result [^TextSearchSource source needle ^TextSearchHandlesResult result]
  (if (handles-result-ok? result) (rows-ok (rows-for-handles source needle (handles-result-handles result))) (rows-error (handles-result-error result))))

(defn ^TextSearchRowsResult phrase-indexed-rows-result! [^TextSearchSource source needle]
  (rows-for-handles-result source needle (phrase-handles-result! source needle)))

(defn ^TextSearchRowsResult phrase-scan-rows-result! [^TextSearchSource source needle]
  (rows-for-handles-result source needle (phrase-scan-handles-result! source needle)))

(defn ^TextSearchRowsResult substring-indexed-rows-result! [^TextSearchSource source needle]
  (rows-for-handles-result source needle (substring-handles-result! source needle)))

(defn ^TextSearchRowsResult substring-scan-rows-result! [^TextSearchSource source needle]
  (rows-for-handles-result source needle (substring-scan-handles-result! source needle)))

(defn ^TextSearchRowsResult stem-indexed-rows-result! [^TextSearchSource source needle]
  (rows-for-handles-result source needle (stem-handles-result! source needle)))

(defn ^TextSearchRowsResult stem-scan-rows-result! [^TextSearchSource source needle]
  (rows-for-handles-result source needle (stem-scan-handles-result! source needle)))

(defn ^TextSearchRowsResult ranked-indexed-rows-result! [^TextSearchSource source needle]
  (let [handles-result (ranked-handles-result! source needle)]
  (if (handles-result-ok? handles-result) (ranked-rows-for-handles-result! source needle (handles-result-handles handles-result)) (rows-error (handles-result-error handles-result)))))

(defn ^TextSearchRowsResult ranked-scan-rows-result! [^TextSearchSource source needle]
  (let [handles-result (ranked-scan-handles-result! source needle)]
  (if (handles-result-ok? handles-result) (ranked-rows-for-handles-result! source needle (handles-result-handles handles-result)) (rows-error (handles-result-error handles-result)))))

(defn phrase-indexed-rows! [^TextSearchSource source needle]
  (let [result (phrase-indexed-rows-result! source needle)]
  (if (rows-result-ok? result) (rows-result-rows result) (text-index/raise-text-error (rows-result-error result)))))

(defn phrase-scan-rows! [^TextSearchSource source needle]
  (let [result (phrase-scan-rows-result! source needle)]
  (if (rows-result-ok? result) (rows-result-rows result) (text-index/raise-text-error (rows-result-error result)))))

(defn substring-indexed-rows! [^TextSearchSource source needle]
  (let [result (substring-indexed-rows-result! source needle)]
  (if (rows-result-ok? result) (rows-result-rows result) (text-index/raise-text-error (rows-result-error result)))))

(defn substring-scan-rows! [^TextSearchSource source needle]
  (let [result (substring-scan-rows-result! source needle)]
  (if (rows-result-ok? result) (rows-result-rows result) (text-index/raise-text-error (rows-result-error result)))))

(defn stem-indexed-rows! [^TextSearchSource source needle]
  (let [result (stem-indexed-rows-result! source needle)]
  (if (rows-result-ok? result) (rows-result-rows result) (text-index/raise-text-error (rows-result-error result)))))

(defn stem-scan-rows! [^TextSearchSource source needle]
  (let [result (stem-scan-rows-result! source needle)]
  (if (rows-result-ok? result) (rows-result-rows result) (text-index/raise-text-error (rows-result-error result)))))

(defn ranked-indexed-rows! [^TextSearchSource source needle]
  (let [result (ranked-indexed-rows-result! source needle)]
  (if (rows-result-ok? result) (rows-result-rows result) (text-index/raise-text-error (rows-result-error result)))))

(defn ranked-scan-rows! [^TextSearchSource source needle]
  (let [result (ranked-scan-rows-result! source needle)]
  (if (rows-result-ok? result) (rows-result-rows result) (text-index/raise-text-error (rows-result-error result)))))
