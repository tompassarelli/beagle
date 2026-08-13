(ns selfhost.facts-roundtrip
  (:require [clojure.string :as str]
            [selfhost.rt :as rt]
            [selfhost.reader :as rd]
            [selfhost.ast :as ast]))

(def ^String EXACT-NUMBER-TAG "#%exact-number")

(def CODEPOINT-OFFSETS (atom []))

(def LINE-COLS (atom []))

(defn- ^Boolean surrogate-pair-at? [^String src i]
  (if (>= (+ i 1) (count src)) false (let [hi (int (.charAt src i))
   lo (int (.charAt src (+ i 1)))]
  (and (>= hi 55296) (<= hi 56319) (>= lo 56320) (<= lo 57343)))))

(defn- build-codepoint-offsets [^String src]
  (loop [i 0
   codepoints 0
   out [0]]
  (if (>= i (count src)) out (let [next-count (+ codepoints 1)]
  (if (surrogate-pair-at? src i) (recur (+ i 2) next-count (conj (conj out next-count) next-count)) (recur (+ i 1) next-count (conj out next-count)))))))

(defn- build-line-cols [^String src]
  (loop [i 0
   line 1
   col 0
   out [[1 0]]]
  (if (>= i (count src)) out (if (= (rd/char-at src i) "\n") (recur (+ i 1) (+ line 1) 0 (conj out [(+ line 1) 0])) (let [next-col (+ col 1)]
  (if (surrogate-pair-at? src i) (recur (+ i 2) line next-col (conj (conj out [line next-col]) [line next-col])) (recur (+ i 1) line next-col (conj out [line next-col]))))))))

(defn- codepoint-offset [^String src off]
  (let [offsets (deref CODEPOINT-OFFSETS)]
  (if (= (count offsets) (+ (count src) 1)) (nth offsets off) (loop [i 0
   result 0]
  (if (>= i off) result (recur (+ i (if (surrogate-pair-at? src i) 2 1)) (+ result 1)))))))

(defn- line-col [^String src off]
  (let [line-cols (deref LINE-COLS)]
  (if (= (count line-cols) (+ (count src) 1)) (nth line-cols off) (loop [i 0
   line 1
   col 0]
  (if (>= i off) [line col] (if (= (rd/char-at src i) "\n") (recur (+ i 1) (+ line 1) 0) (recur (+ i (if (surrogate-pair-at? src i) 2 1)) line (+ col 1))))))))

(defn- source-loc [^String src start end]
  (let [lc (line-col src start)
   base {"line" (nth lc 0) "col" (nth lc 1) "pos" (+ (codepoint-offset src start) 1) "source-start" start}]
  (if (some? end) (assoc base "span" (- (codepoint-offset src end) (codepoint-offset src start)) "source-end" end) base)))

(defn- pos-loc [start end]
  (let [base {"pos" (+ start 1) "relative" true}]
  (if (some? end) (assoc base "span" (- end start)) base)))

(defn- make-node [^String kind value loc children]
  {"kind" kind "value" value "loc" loc "children" children})

(defn- leaf-node [^String kind value ^String src start end]
  (make-node kind value (source-loc src start end) nil))

(defn- synthetic-leaf [^String value loc]
  (make-node "symbol" value loc nil))

(defn- child-values [children]
  (loop [i 0
   out []]
  (if (>= i (count children)) out (recur (+ i 1) (conj out (get (nth children i) "value"))))))

(defn- list-node [children loc]
  (if (= (count children) 0) (make-node "nil" [] loc nil) (make-node "list" (child-values children) loc children)))

(defn- tagged-node [^String tag items loc tag-loc]
  (list-node (into [(synthetic-leaf tag tag-loc)] items) loc))

(defn- replace-loc [node loc]
  (let [children (get node "children")]
  (assoc node "loc" loc "children" (if (some? children) (mapv (fn [child] (replace-loc child loc)) children) nil))))

(defn- map-context-node [node loc]
  (let [children (get node "children")
   bool? (= (get node "kind") "bool")]
  (assoc node "kind" (if bool? "symbol" (get node "kind")) "value" (if bool? (if (get node "value") "true" "false") (get node "value")) "loc" loc "children" (if (some? children) (mapv (fn [child] (map-context-node child loc)) children) nil))))

(defn- relative-loc [node base-codepoint]
  (let [loc (get node "loc")
   pos (get loc "pos")
   span (get loc "span")
   rel (if (some? pos) (- pos (+ base-codepoint 1)) 0)
   next-loc (if (some? span) (pos-loc rel (+ rel span)) (pos-loc rel nil))
   children (get node "children")]
  (assoc node "loc" next-loc "children" (if (some? children) (mapv (fn [child] (relative-loc child base-codepoint)) children) nil))))

(defn- result-leaf [^String src start result]
  (let [value (get result "value")
   end (get result "pos")]
  (cond
  (and (vector? value) (= (count value) 2) (= (nth value 0) rd/STRING-TAG)) (leaf-node "string" (nth value 1) src start end)
  (and (vector? value) (= (count value) 2) (= (nth value 0) rd/CHAR-TAG)) (leaf-node "char" (nth value 1) src start end)
  (boolean? value) (leaf-node "symbol" (if value "true" "false") src start end)
  (number? value) (leaf-node "number" value src start end)
  :else (leaf-node "symbol" value src start end))))

(declare scan-datum)

(defn- scan-delimited [^String src pos ^String close]
  (loop [p (rd/skip-ws src pos)
   out []]
  (cond
  (>= p (count src)) {"nodes" out "pos" p}
  (= (rd/char-at src p) close) {"nodes" out "pos" (+ p 1)}
  :else (let [node (scan-datum src p)
   next (get node "next")]
  (recur (rd/skip-ws src next) (conj out (dissoc node "next")))))))

(defn- prefixed-node [^String src start ^String prefix inner-start]
  (let [inner (scan-datum src inner-start)
   child (dissoc inner "next")
   children [(synthetic-leaf prefix (source-loc src start nil)) child]]
  (assoc (list-node children (source-loc src start nil)) "next" (get inner "next"))))

(defn- metadata-node [^String src start meta-start]
  (let [meta-r (scan-datum src meta-start)
   form-r (scan-datum src (get meta-r "next"))
   children [(synthetic-leaf "#%meta" (source-loc src start nil)) (dissoc meta-r "next") (dissoc form-r "next")]]
  (assoc (list-node children (source-loc src start nil)) "next" (get form-r "next"))))

(defn- conditional-node [^String src start ^Boolean splice?]
  (let [open (+ start (if splice? 3 2))
   result (scan-delimited src (+ open 1) ")")
   loc (source-loc src start nil)
   items (mapv (fn [child] (replace-loc child loc)) (get result "nodes"))
   tag (if splice? "reader-conditional-splice" "reader-conditional")]
  (assoc (tagged-node tag items loc loc) "next" (get result "pos"))))

(defn- symbolic-value-node [^String src start]
  (let [sym-r (rd/read-symbol-text src (+ start 2))
   loc (source-loc src start nil)
   value (get sym-r "value")
   children [(synthetic-leaf "#%symbolic-val" loc) (synthetic-leaf value loc)]]
  (assoc (list-node children loc) "next" (get sym-r "pos"))))

(defn- syntax-quote-node [^String src start]
  (let [inner-r (scan-datum src (+ start 2))
   next (get inner-r "next")
   child (relative-loc (dissoc inner-r "next") (codepoint-offset src start))
   head (make-node "symbol" "syntax" (pos-loc 0 2) nil)
   wrapper (list-node [head child] (pos-loc 0 (- next start)))]
  (assoc wrapper "next" next)))

(defn- regex-node [^String src start]
  (let [result (rd/read-regex-literal src (+ start 1))
   next (get result "pos")
   loc (source-loc src start next)
   value (nth (get result "value") 1)
   children [(synthetic-leaf "#%regex" loc) (make-node "string" value loc nil)]]
  (assoc (list-node children loc) "next" next)))

(defn- set-node [^String src start]
  (let [result (scan-delimited src (+ start 2) "}")
   loc (source-loc src start nil)
   items (mapv (fn [child] (replace-loc child loc)) (get result "nodes"))]
  (assoc (tagged-node ast/SET-TAG items loc loc) "next" (get result "pos"))))

(defn- js-node [^String src start]
  (let [inner-r (scan-datum src (+ start 3))
   child0 (dissoc inner-r "next")
   child-pos (- (get (get child0 "loc") "pos") 1)
   child-loc (source-loc src child-pos nil)
   child (replace-loc child0 child-loc)
   loc (source-loc src start nil)]
  (assoc (list-node [(synthetic-leaf "#%js" loc) child] loc) "next" (get inner-r "next"))))

(defn- fn-placeholder-index [node]
  (if (= (get node "kind") "symbol") (let [value (get node "value")]
  (cond
  (= value "%") 1
  (some? (re-matches #"^%[1-9][0-9]*$" value)) (let [parsed (parse-long (subs value 1))]
  (if (nil? parsed) 0 parsed))
  :else 0)) 0))

(defn- max-placeholder-index [node]
  (let [own (fn-placeholder-index node)
   children (get node "children")]
  (if (some? children) (reduce (fn [best child] (max best (max-placeholder-index child))) own children) own)))

(defn- ^Boolean rest-placeholder? [node]
  (let [own (and (= (get node "kind") "symbol") (= (get node "value") "%&"))
   children (get node "children")]
  (if own true (if (some? children) (reduce (fn [found child] (or found (rest-placeholder? child))) false children) false))))

(defn- rewrite-fn-placeholders [node]
  (let [children (get node "children")
   rewritten (if (and (= (get node "kind") "symbol") (= (get node "value") "%")) (assoc node "value" "%1") node)]
  (if (some? children) (assoc rewritten "children" (mapv (fn [child] (rewrite-fn-placeholders child)) children)) rewritten)))

(defn- fn-param-nodes [max-index ^Boolean rest? loc]
  (let [positional (loop [i 1
   out []]
  (if (> i max-index) out (recur (+ i 1) (conj out (synthetic-leaf (str "%" i) loc)))))]
  (if rest? (into positional [(synthetic-leaf "&" loc) (synthetic-leaf "%&" loc)]) positional)))

(defn- anonymous-fn-node [^String src start]
  (let [result (scan-delimited src (+ start 2) ")")
   raw-body (list-node (get result "nodes") nil)
   max-index (max-placeholder-index raw-body)
   rest? (rest-placeholder? raw-body)
   loc (source-loc src start nil)
   body (replace-loc (rewrite-fn-placeholders raw-body) loc)
   params (tagged-node ast/BRACKET-TAG (fn-param-nodes max-index rest? loc) loc loc)
   expanded (list-node [(synthetic-leaf "fn" loc) params body] loc)]
  (assoc expanded "next" (get result "pos"))))

(defn scan-datum [^String src pos]
  (let [p (rd/skip-ws src pos)
   ch (rd/char-at src p)
   next1 (rd/char-at src (+ p 1))
   next2 (rd/char-at src (+ p 2))
   atom-r (rd/read-symbol-text src p)
   atom-text (get atom-r "value")]
  (cond
  (= ch "(") (let [result (scan-delimited src (+ p 1) ")")]
  (assoc (list-node (get result "nodes") (source-loc src p (get result "pos"))) "next" (get result "pos")))
  (= ch "[") (let [result (scan-delimited src (+ p 1) "]")
   loc (source-loc src p nil)]
  (assoc (tagged-node ast/BRACKET-TAG (get result "nodes") loc loc) "next" (get result "pos")))
  (= ch "{") (let [result (scan-delimited src (+ p 1) "}")
   loc (source-loc src p nil)
   items (mapv (fn [child] (map-context-node child loc)) (get result "nodes"))]
  (assoc (tagged-node ast/MAP-TAG items loc loc) "next" (get result "pos")))
  (= ch "'") (prefixed-node src p "quote" (+ p 1))
  (= ch "`") (prefixed-node src p "quasiquote" (+ p 1))
  (= ch "@") (prefixed-node src p "deref" (+ p 1))
  (= ch "~") (if (= next1 "@") (prefixed-node src p "unquote-splicing" (+ p 2)) (prefixed-node src p "unquote" (+ p 1)))
  (= ch "^") (metadata-node src p (+ p 1))
  (and (= ch "#") (= next1 "^")) (metadata-node src p (+ p 2))
  (and (= ch "#") (= next1 "'")) (syntax-quote-node src p)
  (and (= ch "#") (= next1 "?") (= next2 "@")) (conditional-node src p true)
  (and (= ch "#") (= next1 "?")) (conditional-node src p false)
  (and (= ch "#") (= next1 "_")) (prefixed-node src p "#%discard" (+ p 2))
  (and (= ch "#") (= next1 "j") (= next2 "s")) (js-node src p)
  (and (= ch "#") (= next1 "#")) (symbolic-value-node src p)
  (and (= ch "#") (= next1 "{")) (set-node src p)
  (and (= ch "#") (= next1 "(")) (anonymous-fn-node src p)
  (and (= ch "#") (= next1 "\"")) (regex-node src p)
  (some? (re-matches #"^-?[0-9]+/[0-9]+$" atom-text)) (assoc (leaf-node "number" atom-text src p (get atom-r "pos")) "next" (get atom-r "pos"))
  (and (some? (re-matches #"^-?[0-9]+$" atom-text)) (nil? (parse-long atom-text))) (assoc (leaf-node "number" atom-text src p (get atom-r "pos")) "next" (get atom-r "pos"))
  :else (let [result (rd/read-datum src p)]
  (assoc (result-leaf src p result) "next" (get result "pos"))))))

(defn- shift-node-location [node shift]
  (let [loc (get node "loc")
   children (get node "children")
   next-loc (if (or (nil? loc) (= true (get loc "relative"))) loc (assoc loc "line" (+ (get loc "line") 1) "pos" (+ (get loc "pos") shift)))]
  (assoc node "loc" next-loc "children" (if (some? children) (mapv (fn [child] (shift-node-location child shift)) children) nil))))

(defn- located-program [^String src]
  (let [lang (rd/parse-lang-line src)
   target (get lang "target")
   start (get lang "pos")
   forms (loop [p (rd/skip-ws src start)
   out []]
  (if (>= p (count src)) out (let [node (scan-datum src p)]
  (recur (rd/skip-ws src (get node "next")) (conj out (dissoc node "next"))))))
   target-form (if (some? target) [(list-node [(synthetic-leaf "define-target" nil) (synthetic-leaf target nil)] nil)] [])]
  (if (some? target) (into target-form forms) forms)))

(defn- ^String hex-digit [n]
  (nth ["0" "1" "2" "3" "4" "5" "6" "7" "8" "9" "a" "b" "c" "d" "e" "f"] n))

(defn- ^String hex4 [n]
  (str (hex-digit (mod (quot n 4096) 16)) (hex-digit (mod (quot n 256) 16)) (hex-digit (mod (quot n 16) 16)) (hex-digit (mod n 16))))

(defn- ^String edn-string [^String s]
  (loop [i 0
   out "\""]
  (if (>= i (count s)) (str out "\"") (let [ch (rd/char-at s i)
   code (int (.charAt s i))
   escaped (cond
  (= ch "\"") "\\\""
  (= ch "\\") "\\\\"
  (= ch "\n") "\\n"
  (= ch "\r") "\\r"
  (= ch "\t") "\\t"
  (or (< code 32) (= code 127)) (str "\\u" (hex4 code))
  :else ch)]
  (recur (+ i 1) (str out escaped))))))

(defn- ^String fact-line [subject ^String predicate object]
  (str "[" subject " " (edn-string predicate) " " (if (number? object) (str object) (edn-string object)) "]"))

(defn- ^String encoded-value [^String kind value]
  (cond
  (= kind "bool") (if value "true" "false")
  (= kind "char") (str (char value))
  :else (str value)))

(defn- add-fact! [out subject ^String predicate object]
  (swap! out conj (fact-line subject predicate object))
  nil)

(defn- fresh-id! [counter]
  (swap! counter inc)
  (deref counter))

(declare emit-node!)

(defn- emit-loc! [out id loc]
  (if (some? loc) (do
  (doseq [key ["line" "col" "pos" "span"]]
  (let [value (get loc key)]
  (if (some? value) (do
  (add-fact! out id key value)))))))
  nil)

(defn- emit-node! [node counter out]
  (let [id (fresh-id! counter)
   kind (get node "kind")
   children (get node "children")]
  (add-fact! out id "kind" kind)
  (if (some? children) (doseq [indexed (map-indexed vector children)]
  (let [slot (nth indexed 0)
   child (nth indexed 1)
   child-id (emit-node! child counter out)]
  (add-fact! out id (str "f" slot) child-id)
  (add-fact! out id "child" child-id))) (if (not= kind "nil") (do
  (add-fact! out id "v" (encoded-value kind (get node "value"))))))
  (emit-loc! out id (get node "loc"))
  id))

(defn- form-spans [forms shift]
  (loop [i 0
   out []]
  (if (>= i (count forms)) out (let [loc (get (nth forms i) "loc")
   pos (get loc "pos")
   span (get loc "span")
   source-start (get loc "source-start")
   source-end (get loc "source-end")]
  (recur (+ i 1) (cond
  (and (some? source-start) (some? source-end)) (conj out [i source-start source-end])
  (and (some? pos) (some? span)) (conj out [i (- pos 1 shift) (+ (- pos 1 shift) span)])
  :else out))))))

(defn- ^Boolean in-span? [off spans]
  (loop [i 0]
  (if (>= i (count spans)) false (let [span (nth spans i)]
  (if (and (>= off (nth span 1)) (< off (nth span 2))) true (recur (+ i 1)))))))

(defn- source-lines [^String src]
  (loop [i 0
   start 0
   out []]
  (cond
  (>= i (count src)) (conj out [start (subs src start i)])
  (= (rd/char-at src i) "\n") (recur (+ i 1) (+ i 1) (conj out [start (subs src start i)]))
  :else (recur (+ i 1) start out))))

(defn- line-comments [^String src spans]
  (reduce (fn [out line] (let [start (nth line 0)
   text (nth line 1)
   hit (loop [j 0]
  (cond
  (>= j (count text)) nil
  (and (= (rd/char-at text j) ";") (not (in-span? (+ start j) spans))) j
  :else (recur (+ j 1))))]
  (if (some? hit) (conj out [(+ start hit) (str/trimr (subs text hit))]) out))) [] (source-lines src)))

(defn- line-number [^String src off]
  (nth (line-col src off) 0))

(defn- nearest-preceding [off spans]
  (loop [i 0
   best nil]
  (if (>= i (count spans)) best (let [span (nth spans i)]
  (recur (+ i 1) (if (and (<= (nth span 2) off) (or (nil? best) (> (nth span 2) (nth best 2)))) span best))))))

(defn- nearest-following [off spans]
  (loop [i 0
   best nil]
  (if (>= i (count spans)) best (let [span (nth spans i)]
  (recur (+ i 1) (if (and (>= (nth span 1) off) (or (nil? best) (< (nth span 1) (nth best 1)))) span best))))))

(defn- classify-comments [^String src spans]
  (mapv (fn [comment] (let [off (nth comment 0)
   text (nth comment 1)
   before (nearest-preceding off spans)
   after (nearest-following off spans)]
  (cond
  (and (some? before) (= (line-number src (- (nth before 2) 1)) (line-number src off))) ["trailing" (nth before 0) text]
  (some? after) ["leading" (nth after 0) text]
  :else ["trailing" "file" text]))) (line-comments src spans)))

(defn- ^Boolean symbol-char? [^String ch]
  (some? (re-matches #"[\p{L}\p{N}_\-*+!?<>=/.&%$]" ch)))

(defn- raw-comment-segments [^String text]
  (loop [i 0
   out []]
  (if (>= i (count text)) out (if (symbol-char? (rd/char-at text i)) (let [end (loop [j i]
  (if (and (< j (count text)) (symbol-char? (rd/char-at text j))) (recur (+ j 1)) j))
   quoted? (and (> i 0) (= (rd/char-at text (- i 1)) "\"") (< end (count text)) (= (rd/char-at text end) "\""))]
  (recur end (conj out [(if quoted? "text" "symbol") (subs text i end)]))) (let [end (loop [j i]
  (if (and (< j (count text)) (not (symbol-char? (rd/char-at text j)))) (recur (+ j 1)) j))]
  (recur end (conj out ["text" (subs text i end)])))))))

(defn- comment-segments [^String text]
  (reduce (fn [out segment] (if (and (> (count out) 0) (= (nth (peek out) 0) "text") (= (nth segment 0) "text")) (conj (pop out) ["text" (str (nth (peek out) 1) (nth segment 1))]) (conj out segment))) [] (raw-comment-segments text)))

(defn- emit-comments! [comments form-ids root counter out]
  (let [indexes (atom {})]
  (doseq [comment comments]
  (let [placement (nth comment 0)
   spec (nth comment 1)
   text (nth comment 2)
   anchor (if (= spec "file") root (nth form-ids spec))
   idx (get (deref indexes) anchor 0)
   cid (fresh-id! counter)]
  (swap! indexes assoc anchor (+ idx 1))
  (add-fact! out cid "kind" "comment")
  (add-fact! out cid "style" "line")
  (add-fact! out cid "placement" placement)
  (add-fact! out anchor (str "comment" idx) cid)
  (doseq [indexed (map-indexed vector (comment-segments text))]
  (let [seg-idx (nth indexed 0)
   segment (nth indexed 1)
   sid (fresh-id! counter)]
  (add-fact! out sid "kind" (nth segment 0))
  (add-fact! out sid "v" (nth segment 1))
  (add-fact! out cid (str "seg" seg-idx) sid))))))
  nil)

(defn- projection-lines! [^String src]
  (let [_offsets (reset! CODEPOINT-OFFSETS (build-codepoint-offsets src))
   _line-cols (reset! LINE-COLS (build-line-cols src))
   shift 0
   forms (located-program src)
   counter (atom 0)
   out (atom [])
   root (fresh-id! counter)
   head (synthetic-leaf "beagle-file" nil)]
  (add-fact! out root "kind" "list")
  (let [head-id (emit-node! head counter out)]
  (add-fact! out root "f0" head-id)
  (add-fact! out root "child" head-id))
  (let [form-ids (loop [i 0
   ids []]
  (if (>= i (count forms)) ids (let [id (emit-node! (nth forms i) counter out)]
  (add-fact! out root (str "f" (+ i 1)) id)
  (add-fact! out root "child" id)
  (recur (+ i 1) (conj ids id)))))]
  (emit-comments! (classify-comments src (form-spans forms shift)) form-ids root counter out))
  (deref out)))

(defn emit-edn-file! [^String path]
  (let [src (selfhost.rt/slurp-file path)]
  (println (str "@file " path))
  (doseq [line (projection-lines! src)]
  (println line)))
  nil)

(defn- ^Boolean tagged-string? [value]
  (and (vector? value) (= (count value) 2) (= (nth value 0) rd/STRING-TAG)))

(defn- edn-value [value]
  (if (tagged-string? value) (nth value 1) value))

(defn- parse-triple [^String line]
  (let [forms (rd/read-program line)
   datum (nth forms 0)
   items (ast/bracket-body datum)]
  [(nth items 0) (edn-value (nth items 1)) (edn-value (nth items 2))]))

(defn- read-triples [^String path]
  (reduce (fn [out line] (if (and (> (count line) 0) (= (rd/char-at line 0) "[")) (conj out (parse-triple line)) out)) [] (str/split-lines (selfhost.rt/slurp-file path))))

(defn- triples-props [triples]
  (reduce (fn [props triple] (assoc-in props [(nth triple 0) (nth triple 1)] (nth triple 2))) {} triples))

(defn- slot-key [^String predicate]
  (let [crdt (re-matches #"^f([0-9]+(?:\.[0-9]+)*)~([0-9]+)$" predicate)
   legacy (re-matches #"^f([0-9]+)$" predicate)]
  (cond
  (some? crdt) [(mapv (fn [part] (parse-long part)) (str/split (nth crdt 1) #"\.")) (parse-long (nth crdt 2))]
  (some? legacy) [[(* (+ (parse-long (nth legacy 1)) 1) 65536)] 0]
  :else nil)))

(defn- ordered-children [props id]
  (let [entries (reduce (fn [out entry] (let [key (slot-key (nth entry 0))]
  (if (some? key) (conj out [key (nth entry 1)]) out))) [] (get props id {}))]
  (mapv (fn [entry] (nth entry 1)) (sort-by (fn [entry] (nth entry 0)) entries))))

(defn- ^Boolean ref-predicate? [^String predicate]
  (or (= predicate "child") (= predicate "tail") (some? (slot-key predicate))))

(defn- root-id [props]
  (let [refs (reduce (fn [out subject-entry] (reduce (fn [inner entry] (let [predicate (nth entry 0)
   object (nth entry 1)]
  (if (and (number? object) (ref-predicate? predicate)) (assoc inner object true) inner))) out (nth subject-entry 1))) {} props)
   candidates (reduce (fn [out entry] (let [id (nth entry 0)]
  (if (= true (get refs id)) out (conj out id)))) [] props)
   wrappers (filterv (fn [id] (let [head (get (get props id {}) "f0")]
  (and (number? head) (= (get (get props head {}) "v") "beagle-file")))) candidates)
   structural (filterv (fn [id] (let [kind (get (get props id {}) "kind")]
  (or (= kind "list") (= kind "vector")))) candidates)]
  (if (> (count wrappers) 0) (nth wrappers 0) (if (> (count structural) 0) (nth structural 0) (if (> (count candidates) 0) (nth candidates 0) nil)))))

(defn- decode-number [^String text]
  (cond
  (str/includes? text "/") [EXACT-NUMBER-TAG text]
  (or (str/includes? text ".") (str/includes? text "e") (str/includes? text "E")) (parse-double text)
  :else (let [parsed (parse-long text)]
  (if (nil? parsed) [EXACT-NUMBER-TAG text] parsed))))

(declare build-datum)

(defn- build-datum [props id]
  (let [node (get props id)
   kind (get node "kind")]
  (cond
  (= kind "symbol") (get node "v")
  (= kind "string") [rd/STRING-TAG (get node "v")]
  (= kind "keyword") (str ":" (get node "v"))
  (= kind "bool") (= (get node "v") "true")
  (= kind "char") [rd/CHAR-TAG (int (.charAt (get node "v") 0))]
  (= kind "number") (decode-number (get node "v"))
  (= kind "other") [rd/STRING-TAG (get node "v")]
  (= kind "nil") []
  (or (= kind "list") (= kind "vector")) (mapv (fn [child] (build-datum props child)) (ordered-children props id))
  :else [])))

(defn- ^Boolean datum-list? [datum]
  (and (vector? datum) (not (tagged-string? datum)) (not (and (= (count datum) 2) (= (nth datum 0) rd/CHAR-TAG))) (not (and (= (count datum) 2) (= (nth datum 0) EXACT-NUMBER-TAG)))))

(defn- ^Boolean head-is? [datum ^String head]
  (and (datum-list? datum) (> (count datum) 0) (= (nth datum 0) head)))

(defn- datum-tail [datum]
  (if (> (count datum) 1) (subvec datum 1) []))

(defn- ^Boolean symbol-trigger-char? [^String ch]
  (or (rd/whitespace? ch) (= ch "(") (= ch ")") (= ch "[") (= ch "]") (= ch "{") (= ch "}") (= ch "\"") (= ch "|") (= ch ";") (= ch "\\") (= ch ",") (= ch ":") (= ch "`")))

(defn- ^Boolean symbol-escape-char? [^String ch]
  (or (symbol-trigger-char? ch) (= ch "'")))

(defn- ^Boolean symbol-needs-bars? [^String text]
  (or (= (count text) 0) (= (rd/char-at text 0) "'") (loop [i 0]
  (cond
  (>= i (count text)) false
  (symbol-trigger-char? (rd/char-at text i)) true
  :else (recur (+ i 1))))))

(defn- ^String symbol-source [^String text]
  (cond
  (= (count text) 0) "||"
  (and (symbol-needs-bars? text) (some? (str/index-of text ":")) (nil? (str/index-of text "|"))) (str "|" text "|")
  (symbol-needs-bars? text) (loop [i 0
   out ""]
  (if (>= i (count text)) out (let [ch (rd/char-at text i)
   unsafe? (symbol-escape-char? ch)]
  (recur (+ i 1) (str out (if unsafe? "\\" "") ch)))))
  :else text))

(defn- ^Boolean metadata-form? [datum]
  (and (head-is? datum "#%meta") (= (count datum) 3)))

(defn- ^Boolean reader-conditional? [datum]
  (head-is? datum "reader-conditional"))

(defn- ^Boolean reader-conditional-splice? [datum]
  (head-is? datum "reader-conditional-splice"))

(defn- prefix-text [datum]
  (if (and (datum-list? datum) (= (count datum) 2)) (let [head (nth datum 0)]
  (cond
  (= head "quasiquote") "`"
  (= head "unquote") "~"
  (= head "unquote-splicing") "~@"
  (= head "syntax") "#'"
  :else nil)) nil))

(defn- hash-prefix-text [datum]
  (if (and (datum-list? datum) (= (count datum) 2)) (let [head (nth datum 0)]
  (cond
  (= head "#%discard") "#_"
  (= head "#%js") "#js "
  (= head "#%symbolic-val") "##"
  :else nil)) nil))

(defn- group-anns [items]
  items)

(declare datum-source)

(defn- ^String joined-source [items]
  (str/join " " (mapv (fn [item] (datum-source item)) items)))

(defn ^String datum-source [datum]
  (cond
  (= datum rd/ANN-MARKER) ":"
  (tagged-string? datum) (edn-string (nth datum 1))
  (and (vector? datum) (= (count datum) 2) (= (nth datum 0) EXACT-NUMBER-TAG)) (nth datum 1)
  (and (vector? datum) (= (count datum) 2) (= (nth datum 0) rd/CHAR-TAG)) (str "\\" (char (nth datum 1)))
  (ast/bracketed? datum) (str "[" (joined-source (group-anns (ast/bracket-body datum))) "]")
  (ast/map-tagged? datum) (str "{" (joined-source (group-anns (ast/map-body datum))) "}")
  (ast/set-tagged? datum) (str "#{" (joined-source (group-anns (ast/set-body datum))) "}")
  (head-is? datum rd/REGEX-TAG) (str "#\"" (if (tagged-string? (nth datum 1)) (nth (nth datum 1) 1) (nth datum 1)) "\"")
  (metadata-form? datum) (str "^" (datum-source (nth datum 1)) " " (datum-source (nth datum 2)))
  (some? (prefix-text datum)) (str (prefix-text datum) (datum-source (nth datum 1)))
  (reader-conditional? datum) (str "#?(" (joined-source (datum-tail datum)) ")")
  (reader-conditional-splice? datum) (str "#?@(" (joined-source (datum-tail datum)) ")")
  (some? (hash-prefix-text datum)) (str (hash-prefix-text datum) (datum-source (nth datum 1)))
  (datum-list? datum) (str "(" (joined-source (group-anns datum)) ")")
  (string? datum) (if (and (> (count datum) 1) (str/starts-with? datum ":")) datum (symbol-source datum))
  (boolean? datum) (if datum "true" "false")
  :else (str datum)))

(defn- sequence-parts [datum]
  (cond
  (ast/bracketed? datum) {"open" "[" "close" "]" "items" (group-anns (ast/bracket-body datum))}
  (ast/map-tagged? datum) {"open" "{" "close" "}" "items" (group-anns (ast/map-body datum))}
  (ast/set-tagged? datum) {"open" "#{" "close" "}" "items" (group-anns (ast/set-body datum))}
  (reader-conditional? datum) {"open" "#?(" "close" ")" "items" (datum-tail datum)}
  (reader-conditional-splice? datum) {"open" "#?@(" "close" ")" "items" (datum-tail datum)}
  (and (datum-list? datum) (not (head-is? datum rd/REGEX-TAG)) (nil? (prefix-text datum)) (nil? (hash-prefix-text datum)) (not (metadata-form? datum))) {"open" "(" "close" ")" "items" (group-anns datum)}
  :else nil))

(defn- ^Boolean bracket-datum? [datum]
  (ast/bracketed? datum))

(defn- bracket-items [datum]
  (group-anns (ast/bracket-body datum)))

(defn- logical-vector-items [datum]
  (let [items (bracket-items datum)]
  (loop [i 0
   out []]
  (cond
  (>= i (count items)) out
  (and (= (nth items i) "&") (< (+ i 1) (count items))) (recur (+ i 2) (conj out [(nth items i) (nth items (+ i 1))]))
  :else (recur (+ i 1) (conj out [(nth items i)]))))))

(defn- ^Boolean grammar-vector-context? [^String ctx]
  (or (= ctx "params") (= ctx "fields")))

(defn- ^Boolean grammar-vector-break? [datum ^String ctx]
  (and (grammar-vector-context? ctx) (bracket-datum? datum) (>= (count (logical-vector-items datum)) 3)))

(defn- ^Boolean grammar-vector? [datum ^String ctx]
  (and (grammar-vector-context? ctx) (bracket-datum? datum)))

(defn- ^String logical-item-source [item]
  (str/join " " (mapv (fn [part] (datum-source part)) item)))

(defn- ^String grammar-vector-pretty [datum col]
  (let [items (logical-vector-items datum)
   inner-col (+ col 1)
   pad (loop [i 0
   out ""]
  (if (>= i inner-col) out (recur (+ i 1) (str out " "))))]
  (if (= (count items) 0) "[]" (str "[" (logical-item-source (nth items 0)) (reduce (fn [out item] (str out "\n" pad (logical-item-source item))) "" (subvec items 1)) "]"))))

(defn- list-items [datum]
  (if (datum-list? datum) (group-anns datum) []))

(defn- ^Boolean arity-clause? [datum]
  (let [items (list-items datum)]
  (and (> (count items) 0) (bracket-datum? (nth items 0)))))

(defn- first-bracket-index [items start]
  (loop [i start]
  (cond
  (>= i (count items)) nil
  (bracket-datum? (nth items i)) i
  :else (recur (+ i 1)))))

(defn- ^Boolean contains-retired-return-marker? [items]
  (loop [i 0]
  (cond
  (>= i (count items)) false
  (or (= (nth items i) ":-") (= (nth items i) "->")) true
  :else (recur (+ i 1)))))

(defn- ^Boolean contains-index? [items idx]
  (loop [i 0]
  (cond
  (>= i (count items)) false
  (= (nth items i) idx) true
  :else (recur (+ i 1)))))

(defn- bare-arity-vector-indexes [items]
  (if (or (< (count items) 4) (not (some? (get #{"defn" "defn-"} (nth items 0))))) [] (let [docstring? (and (> (count items) 2) (string? (nth items 2)))
   start (if docstring? 3 2)
   tail (subvec items start)]
  (if (or (= (count tail) 0) (not (bracket-datum? (nth tail 0))) (contains-retired-return-marker? tail)) [] (loop [offset 0
   current? false
   forms-after 0
   indexes []]
  (if (>= offset (count tail)) (if (and current? (>= forms-after 2) (>= (count indexes) 2)) indexes []) (let [item (nth tail offset)]
  (cond
  (bracket-datum? item) (if (and current? (< forms-after 2)) [] (recur (+ offset 1) true 0 (conj indexes (+ start offset))))
  current? (recur (+ offset 1) true (+ forms-after 1) indexes)
  :else []))))))))

(defn- ^Boolean symbol-owner-vector? [datum]
  (let [items (list-items datum)]
  (and (>= (count items) 2) (string? (nth items 0)) (some? (first-bracket-index items 1)))))

(defn- ^String grammar-child-context [datum ^String ctx i child]
  (let [items (if (= ctx "data") [] (list-items datum))]
  (cond
  (= ctx "letfn-bindings") (if (symbol-owner-vector? child) "method" "normal")
  (= ctx "arity-clause") (if (and (= i 0) (bracket-datum? child)) "params" "normal")
  (= ctx "method") (if (and (bracket-datum? child) (= i (first-bracket-index items 1))) "params" "normal")
  (= ctx "variant") (if (and (bracket-datum? child) (= i (first-bracket-index items 1))) "fields" "normal")
  (= (count items) 0) "normal"
  :else (let [head (if (and (> (count items) 0) (string? (nth items 0))) (nth items 0) nil)
   vector-index (first-bracket-index items 1)
   bare-indexes (bare-arity-vector-indexes items)]
  (cond
  (and (contains-index? bare-indexes i) (bracket-datum? child)) "params"
  (and (some? (get #{"defn" "defn-" "defmacro" "fn"} head)) (bracket-datum? child) (= i vector-index)) "params"
  (and (= head "defrecord") (bracket-datum? child) (= i vector-index)) "fields"
  (and (some? (get #{"defn" "defn-" "fn"} head)) (arity-clause? child)) "arity-clause"
  (and (= head "letfn") (= i 1) (bracket-datum? child)) "letfn-bindings"
  (and (some? (get #{"defprotocol" "extend-type"} head)) (symbol-owner-vector? child)) "method"
  (and (= head "defunion") (symbol-owner-vector? child)) "variant"
  :else "normal")))))

(declare canonical-layout-needed?)

(defn- ^Boolean children-need-layout? [datum ^String ctx items]
  (loop [i 0]
  (cond
  (>= i (count items)) false
  (canonical-layout-needed? (nth items i) (grammar-child-context datum ctx i (nth items i))) true
  :else (recur (+ i 1)))))

(defn- ^Boolean canonical-layout-needed? [datum ^String ctx]
  (cond
  (= ctx "data") false
  (grammar-vector-break? datum ctx) true
  :else (let [parts (sequence-parts datum)]
  (and (some? parts) (children-need-layout? datum ctx (get parts "items"))))))

(defn- head-keep [^String head after]
  (let [n (count after)
   vector-index (first-bracket-index after 0)]
  (cond
  (or (= head "defn") (= head "defn-")) (cond
  (nil? vector-index) (if (and (>= n 2) (arity-clause? (nth after 1))) 1 (min 1 n))
  :else (min (+ vector-index 2) n))
  (= head "defmacro") (if (some? vector-index) (+ vector-index 1) (min 1 n))
  (or (= head "def") (= head "defonce")) (cond
  (< n 1) n
  (>= n 3) 2
  :else 1)
  (= head "fn") (cond
  (and (> n 0) (arity-clause? (nth after 0))) 0
  (and (>= n 2) (string? (nth after 0)) (arity-clause? (nth after 1))) 1
  :else (if (some? vector-index) (min (+ vector-index 2) n) (min 1 n)))
  (or (= head "defrecord") (= head "deftype")) (if (some? vector-index) (+ vector-index 1) (min 1 n))
  (some? (get #{"let" "loop" "letfn" "binding" "for" "doseq" "with-open" "with-local-vars" "when-let" "if-let" "when-some" "if-some"} head)) (min 1 n)
  (= head "defunion") (if (and (> n 0) (= (nth after 0) ":throwable")) (min 2 n) (min 1 n))
  (some? (get #{"if" "when" "when-not" "when-first" "while" "if-not" "match" "doto" "defprotocol" "extend-type"} head)) (min 1 n)
  (or (= head "condp") (= head "as->")) (min 2 n)
  (or (= head "do") (= head "try") (= head "cond")) 0
  :else (min 1 n))))

(defn- ^String spaces [n]
  (loop [i 0
   out ""]
  (if (>= i n) out (recur (+ i 1) (str out " ")))))

(defn- context-head-keep [^String ctx ^String head after]
  (let [n (count after)]
  (cond
  (= ctx "method") (min 2 n)
  (= ctx "variant") (min 1 n)
  :else (head-keep head after))))

(defn- current-col [^String text initial]
  (let [idx (str/last-index-of text "\n")]
  (if (nil? idx) (+ initial (count text)) (- (count text) (+ idx 1)))))

(declare datum-pretty-context)

(defn- ^String pretty-many [items ^String prefix col]
  (reduce (fn [out item] (str out "\n" prefix (datum-pretty-context item col "normal"))) "" items))

(defn- ^String pretty-context-items [parent ^String ctx items start ^String prefix col]
  (loop [i 0
   out ""]
  (if (>= i (count items)) out (let [item (nth items i)
   child-index (+ start i)
   child-ctx (grammar-child-context parent ctx child-index item)]
  (recur (+ i 1) (str out "\n" prefix (datum-pretty-context item col child-ctx)))))))

(defn- ^String signature-pretty [parent ^String ctx after keep col ^String pad]
  (let [inline-signature (reduce (fn [out item] (str out " " (datum-source item))) (str "(" (datum-source (nth (list-items parent) 0))) (subvec after 0 keep))
   signature-over-width? (> (+ col (count inline-signature)) 80)]
  (loop [i 0
   out (str "(" (datum-source (nth (list-items parent) 0)))]
  (if (>= i keep) out (let [item (nth after i)
   child-index (+ i 1)
   child-ctx (grammar-child-context parent ctx child-index item)]
  (cond
  (and (grammar-vector? item child-ctx) (or (grammar-vector-break? item child-ctx) signature-over-width?)) (recur (+ i 1) (str out "\n" pad (datum-pretty-context item (+ col 2) child-ctx)))
  (canonical-layout-needed? item child-ctx) (recur (+ i 1) (str out " " (datum-pretty-context item (+ 1 (current-col out col)) child-ctx)))
  :else (recur (+ i 1) (str out " " (datum-source item)))))))))

(defn- ^String datum-pretty-context [datum col ^String ctx]
  (let [one-line (datum-source datum)
   parts (sequence-parts datum)]
  (cond
  (grammar-vector-break? datum ctx) (grammar-vector-pretty datum col)
  (and (not (canonical-layout-needed? datum ctx)) (<= (+ col (count one-line)) 80)) one-line
  (some? (prefix-text datum)) (str (prefix-text datum) (datum-pretty-context (nth datum 1) (+ col (count (prefix-text datum))) "data"))
  (some? (hash-prefix-text datum)) (str (hash-prefix-text datum) (datum-pretty-context (nth datum 1) (+ col (count (hash-prefix-text datum))) "data"))
  (metadata-form? datum) (let [prefix (str "^" (datum-source (nth datum 1)) " ")]
  (str prefix (datum-pretty-context (nth datum 2) (+ col (count prefix)) ctx)))
  (nil? parts) one-line
  (= (count (get parts "items")) 0) (str (get parts "open") (get parts "close"))
  (and (= (get parts "open") "(") (string? (nth (get parts "items") 0))) (let [items (get parts "items")
   head (nth items 0)
   after (subvec items 1)
   keep (min (context-head-keep ctx head after) (count after))
   body (subvec after keep)
   pad (spaces (+ col 2))]
  (str (signature-pretty datum ctx after keep col pad) (pretty-context-items datum ctx body (+ keep 1) pad (+ col 2)) (get parts "close")))
  (and (= ctx "arity-clause") (> (count (get parts "items")) 0) (bracket-datum? (nth (get parts "items") 0))) (let [items (get parts "items")
   keep (min 2 (count items))
   inner-col (+ col (count (get parts "open")))
   pad (spaces inner-col)
   inline-signature (str (get parts "open") (joined-source (subvec items 0 keep)))
   signature-over-width? (> (+ col (count inline-signature)) 80)]
  (str (get parts "open") (if (and (grammar-vector? (nth items 0) "params") (or (grammar-vector-break? (nth items 0) "params") signature-over-width?)) (grammar-vector-pretty (nth items 0) inner-col) (datum-pretty-context (nth items 0) inner-col "params")) (if (> keep 1) (str " " (joined-source (subvec items 1 keep))) "") (pretty-context-items datum ctx (subvec items keep) keep pad inner-col) (get parts "close")))
  :else (let [items (get parts "items")
   inner-col (+ col (count (get parts "open")))
   pad (spaces inner-col)]
  (str (get parts "open") (datum-pretty-context (nth items 0) inner-col (grammar-child-context datum ctx 0 (nth items 0))) (pretty-context-items datum ctx (subvec items 1) 1 pad inner-col) (get parts "close"))))))

(defn ^String datum-pretty [datum col]
  (datum-pretty-context datum col "normal"))

(defn- ^String comment-text [props cid]
  (loop [i 0
   out ""]
  (let [sid (get (get props cid {}) (str "seg" i))]
  (if (nil? sid) out (recur (+ i 1) (str out (get (get props sid) "v")))))))

(defn- node-comments [props id]
  (loop [i 0
   out []]
  (let [cid (get (get props id {}) (str "comment" i))]
  (if (nil? cid) out (recur (+ i 1) (conj out [(get (get props cid) "placement") (comment-text props cid)]))))))

(defn- comments-with [comments ^String placement]
  (filterv (fn [comment] (= (nth comment 0) placement)) comments))

(defn- ^String rendered-block [props id]
  (let [comments (node-comments props id)
   leading (comments-with comments "leading")
   trailing (comments-with comments "trailing")
   lead-text (reduce (fn [out c] (str out (nth c 1) "\n")) "" leading)
   trail-text (reduce (fn [out c] (str out " " (nth c 1))) "" trailing)]
  (str lead-text (datum-pretty (build-datum props id) 0) trail-text)))

(defn render-edn! [^String path]
  (let [props (triples-props (read-triples path))
   root (root-id props)
   children (ordered-children props root)
   wrapped? (and (> (count children) 0) (= (get (get props (nth children 0)) "v") "beagle-file"))
   form-ids (if wrapped? (subvec children 1) [root])
   first-datum (if (> (count form-ids) 0) (build-datum props (nth form-ids 0)) [])
   lang? (and (datum-list? first-datum) (> (count first-datum) 1) (= (nth first-datum 0) "define-target"))
   lang-line (if lang? (rd/target-lang-line (nth first-datum 1)) nil)
   body-ids (if (some? lang-line) (subvec form-ids 1) form-ids)
   file-comments (if wrapped? (node-comments props root) [])
   header (mapv (fn [c] (nth c 1)) (comments-with file-comments "leading"))
   footer (mapv (fn [c] (nth c 1)) (comments-with file-comments "trailing"))
   blocks (mapv (fn [id] (rendered-block props id)) body-ids)
   rendered (str/join "\n\n" (into (into header blocks) footer))]
  (if (some? lang-line) (print (str lang-line "\n\n" rendered "\n")) (print (str rendered "\n"))))
  nil)

(defn run! [args]
  (let [mode (if (> (count args) 0) (nth args 0) "")
   path (if (> (count args) 1) (nth args 1) "")]
  (cond
  (= mode "--emit-edn") (emit-edn-file! path)
  (= mode "--render") (render-edn! path)
  :else (do
  (selfhost.rt/eprint "usage: beagle facts-roundtrip --emit-edn FILE | --render EDN\n")
  (selfhost.rt/exit 2))))
  nil)

(defn- ^Boolean beagle-file-wrapper? [props id]
  (let [head (get (get props id {}) "f0")]
  (and (number? head) (= (get (get props head {}) "v") "beagle-file"))))
