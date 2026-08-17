(ns fram.text-index
  (:require [clojure.string :as str]
            [fram.types :as t]))

(def text-index-max-bytes (* 64 1024 1024))

(defrecord TextCandidateSource [rows postings bytes])

(defn textcandidatesource-rows [r] (:rows r))

(defn textcandidatesource-postings [r] (:postings r))

(defn textcandidatesource-bytes [r] (:bytes r))

(defrecord TextError [type code message bytes maximum limit-data])

(defn texterror-type [r] (:type r))

(defn texterror-code [r] (:code r))

(defn texterror-message [r] (:message r))

(defn texterror-bytes [r] (:bytes r))

(defn texterror-maximum [r] (:maximum r))

(defn texterror-limit-data [r] (:limit-data r))

(defrecord TextCandidateSourceResult [ok source error])

(defn textcandidatesourceresult-ok [r] (:ok r))

(defn textcandidatesourceresult-source [r] (:source r))

(defn textcandidatesourceresult-error [r] (:error r))

(defrecord TextNeedleResult [ok tokens error])

(defn textneedleresult-ok [r] (:ok r))

(defn textneedleresult-tokens [r] (:tokens r))

(defn textneedleresult-error [r] (:error r))

(defrecord TextHandlesResult [ok handles error])

(defn texthandlesresult-ok [r] (:ok r))

(defn texthandlesresult-handles [r] (:handles r))

(defn texthandlesresult-error [r] (:error r))

(defrecord TextRowsResult [ok rows error])

(defn textrowsresult-ok [r] (:ok r))

(defn textrowsresult-rows [r] (:rows r))

(defn textrowsresult-error [r] (:error r))

(defn ^TextError no-text-error []
  (->TextError :query-text-none :query-text-none "" 0 0 false))

(defn ^TextError query-text-error [code ^String message]
  (->TextError :fram-query-abort code message 0 0 false))

(defn ^TextError text-index-limit-error [^String message bytes maximum]
  (->TextError :query-text-index-limit :query-text-index-limit message bytes maximum true))

(defn text-error-data [^TextError error]
  (if (texterror-limit-data error) {:type (texterror-type error) :fram/code (texterror-code error) :bytes (texterror-bytes error) :maximum (texterror-maximum error)} {:type (texterror-type error) :code (texterror-code error)}))

(defn raise-text-error [^TextError error]
  (throw (ex-info (texterror-message error) (text-error-data error))))

(defn ^Boolean source-result-ok? [^TextCandidateSourceResult result]
  (textcandidatesourceresult-ok result))

(defn source-result-source [^TextCandidateSourceResult result]
  (textcandidatesourceresult-source result))

(defn ^TextError source-result-error [^TextCandidateSourceResult result]
  (textcandidatesourceresult-error result))

(defn ^Boolean handles-result-ok? [^TextHandlesResult result]
  (texthandlesresult-ok result))

(defn handles-result-handles [^TextHandlesResult result]
  (texthandlesresult-handles result))

(defn ^TextError handles-result-error [^TextHandlesResult result]
  (texthandlesresult-error result))

(defn ^Boolean rows-result-ok? [^TextRowsResult result]
  (textrowsresult-ok result))

(defn rows-result-rows [^TextRowsResult result]
  (textrowsresult-rows result))

(defn ^TextError rows-result-error [^TextRowsResult result]
  (textrowsresult-error result))

(defn source-weight [^TextCandidateSource source]
  (textcandidatesource-bytes source))

(defn- token-set! [^String value]
  (persistent! (reduce (fn [folded ^String token] (conj! folded (str/lower-case token))) (transient #{}) (re-seq #"[\p{L}\p{Nd}]+" value))))

(defn tokenize! [^String value]
  (vec (sort (vec (token-set! value)))))

(defn ^Boolean text-needle-valid?! [needle]
  (and (string? needle) (not (empty? (tokenize! needle)))))

(defn- postings-weight [postings]
  (reduce-kv (fn [total ^String token handles] (+ total 84 (* 4 (count token)) (* 42 (count handles)))) 0 postings))

(defn- index-limit-error [weight maximum]
  (if (> weight maximum) (text-index-limit-error "text index exceeds the snapshot cache budget" weight maximum) nil))

(defn ^TextCandidateSourceResult build-source-result! [propositions maximum]
  (let [rows propositions
   row-count (count rows)
   empty-postings {}
   postings (persistent! (loop [handle 0
   current (transient empty-postings)]
  (if (>= handle row-count) current (let [value (t/triple-t3 (nth rows handle))]
  (recur (inc handle) (if (string? value) (reduce (fn [index ^String token] (assoc! index token (conj (get index token []) handle))) current (token-set! value)) current))))))
   weight (+ 112 (* 14 row-count) (postings-weight postings))
   error (index-limit-error weight maximum)]
  (if error (->TextCandidateSourceResult false nil error) (->TextCandidateSourceResult true (->TextCandidateSource rows postings weight) (no-text-error)))))

(defn ^TextCandidateSource build-source! [propositions maximum]
  (let [result (build-source-result! propositions maximum)
   source (source-result-source result)]
  (if source source (raise-text-error (source-result-error result)))))

(defn ^TextNeedleResult needle-tokens-result! [needle]
  (if (string? needle) (let [tokens (tokenize! needle)]
  (if (empty? tokens) (->TextNeedleResult false [] (query-text-error :query-text-invalid-needle "text-match needle must contain at least one word token")) (->TextNeedleResult true tokens (no-text-error)))) (->TextNeedleResult false [] (query-text-error :query-text-invalid-needle "text-match needle must be a string"))))

(defn- shortest-posting [posting-vectors]
  (let [empty-handles []]
  (if (empty? posting-vectors) empty-handles (loop [position 1
   best (nth posting-vectors 0)]
  (if (>= position (count posting-vectors)) best (let [candidate (nth posting-vectors position)]
  (recur (inc position) (if (< (count candidate) (count best)) candidate best))))))))

(defn ^TextHandlesResult indexed-handles-result! [^TextCandidateSource source needle]
  (let [needle-result (needle-tokens-result! needle)]
  (if (not (textneedleresult-ok needle-result)) (->TextHandlesResult false [] (textneedleresult-error needle-result)) (let [tokens (textneedleresult-tokens needle-result)
   postings (textcandidatesource-postings source)
   posting-vectors (mapv (fn [^String token] (get postings token [])) tokens)
   seed (shortest-posting posting-vectors)
   handles (if (or (empty? seed) (= 1 (count posting-vectors))) seed (let [posting-sets (mapv (fn [values] (set values)) posting-vectors)]
  (filterv (fn [handle] (every? (fn [values] (contains? values handle)) posting-sets)) seed)))]
  (->TextHandlesResult true handles (no-text-error))))))

(defn indexed-handles! [^TextCandidateSource source needle]
  (let [result (indexed-handles-result! source needle)]
  (if (handles-result-ok? result) (handles-result-handles result) (raise-text-error (handles-result-error result)))))

(defn ^TextHandlesResult scan-handles-result! [^TextCandidateSource source needle]
  (let [needle-result (needle-tokens-result! needle)]
  (if (not (textneedleresult-ok needle-result)) (->TextHandlesResult false [] (textneedleresult-error needle-result)) (let [tokens (textneedleresult-tokens needle-result)
   rows (textcandidatesource-rows source)
   handles (loop [handle 0
   matches []]
  (if (>= handle (count rows)) matches (let [value (t/triple-t3 (nth rows handle))
   matched (if (string? value) (let [haystack (token-set! value)]
  (every? (fn [^String token] (contains? haystack token)) tokens)) false)]
  (recur (inc handle) (if matched (conj matches handle) matches)))))]
  (->TextHandlesResult true handles (no-text-error))))))

(defn scan-handles! [^TextCandidateSource source needle]
  (let [result (scan-handles-result! source needle)]
  (if (handles-result-ok? result) (handles-result-handles result) (raise-text-error (handles-result-error result)))))

(defn- rows-for-handles [^TextCandidateSource source needle handles]
  (let [rows (textcandidatesource-rows source)]
  (mapv (fn [handle] (let [proposition (nth rows handle)]
  [(t/triple-t1 proposition) (t/triple-t2 proposition) needle])) handles)))

(defn ^TextRowsResult indexed-rows-result! [^TextCandidateSource source needle]
  (let [result (indexed-handles-result! source needle)]
  (if (handles-result-ok? result) (->TextRowsResult true (rows-for-handles source needle (handles-result-handles result)) (no-text-error)) (->TextRowsResult false [] (handles-result-error result)))))

(defn ^TextRowsResult scan-rows-result! [^TextCandidateSource source needle]
  (let [result (scan-handles-result! source needle)]
  (if (handles-result-ok? result) (->TextRowsResult true (rows-for-handles source needle (handles-result-handles result)) (no-text-error)) (->TextRowsResult false [] (handles-result-error result)))))

(defn indexed-rows! [^TextCandidateSource source needle]
  (let [result (indexed-rows-result! source needle)]
  (if (rows-result-ok? result) (rows-result-rows result) (raise-text-error (rows-result-error result)))))

(defn scan-rows! [^TextCandidateSource source needle]
  (let [result (scan-rows-result! source needle)]
  (if (rows-result-ok? result) (rows-result-rows result) (raise-text-error (rows-result-error result)))))
