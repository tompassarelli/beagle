(ns selfhost.reader
  (:require [selfhost.rt :as rt]
            [selfhost.ast :as ast]
            [clojure.string :as str]))

(def ^String STRING-TAG "#%string")

(def ^String BRACKET-TAG "#%brackets")

(def ^String MAP-TAG "#%map")

(def ^String SET-TAG "#%set")

(def ^String REGEX-TAG "#%regex")

(def ^String CHAR-TAG "#%char")

(def READING-FN-SHORTHAND (atom false))

(def READER-ERRORS (atom []))

(defn- reset-errors! []
  (reset! READER-ERRORS [])
  nil)

(defn- reader-errors []
  (deref READER-ERRORS))

(defn- reader-error! [^String message]
  (swap! READER-ERRORS conj message)
  (selfhost.rt/eprint message)
  nil)

(defn ^String char-at [^String s i]
  (if (and (>= i 0) (< i (count s))) (subs s i (+ i 1)) ""))

(defn ^String substring2 [^String s a b]
  (let [n (count s)
   lo (if (< a 0) 0 (if (> a n) n a))
   hi (if (< b lo) lo (if (> b n) n b))]
  (subs s lo hi)))

(defn ^Boolean whitespace? [^String ch]
  (or (= ch " ") (= ch "\n") (= ch "\r") (= ch "\t") (= ch ",")))

(defn ^Boolean newline? [^String ch]
  (or (= ch "\n") (= ch "\r")))

(defn ^Boolean digit? [^String ch]
  (and (= (count ch) 1) (>= (compare ch "0") 0) (<= (compare ch "9") 0)))

(defn ^Boolean delimiter? [^String ch]
  (or (whitespace? ch) (= ch "(") (= ch ")") (= ch "[") (= ch "]") (= ch "{") (= ch "}") (= ch "\"") (= ch ";") (= ch "~") (= ch "^")))

(defn make-result [value pos]
  {"value" value "pos" pos})

(defn skip-line-comment [^String src pos]
  (let [len (count src)]
  (loop [j pos]
  (if (or (>= j len) (newline? (char-at src j))) (if (and (< j len) (= (char-at src j) "\n")) (+ j 1) j) (recur (+ j 1))))))

(defn skip-ws [^String src pos]
  (let [len (count src)]
  (loop [i pos]
  (if (>= i len) i (let [ch (char-at src i)]
  (cond
  (whitespace? ch) (recur (+ i 1))
  (= ch ";") (recur (skip-line-comment src (+ i 1)))
  :else i))))))

(defn ^String decode-escape [^String ch]
  (cond
  (= ch "n") "\n"
  (= ch "t") "\t"
  (= ch "r") "\r"
  (= ch "b") "\b"
  (= ch "f") "\f"
  (= ch "\\") "\\"
  (= ch "\"") "\""
  :else ch))

(defn hex-val [^String c]
  (cond
  (and (>= (compare c "0") 0) (<= (compare c "9") 0)) (compare c "0")
  (and (>= (compare c "a") 0) (<= (compare c "f") 0)) (let [offset (compare c "a")]
  (+ 10 offset))
  (and (>= (compare c "A") 0) (<= (compare c "F") 0)) (let [offset (compare c "A")]
  (+ 10 offset))
  :else 0))

(defn decode-u4 [^String src i]
  (+ (* 4096 (hex-val (char-at src i))) (* 256 (hex-val (char-at src (+ i 1)))) (* 16 (hex-val (char-at src (+ i 2)))) (hex-val (char-at src (+ i 3)))))

(defn decode-char-lit [^String suffix]
  (cond
  (= suffix "space") 32
  (= suffix "tab") 9
  (= suffix "newline") 10
  (= suffix "return") 13
  (= suffix "formfeed") 12
  (= suffix "backspace") 8
  (and (= (count suffix) 5) (= (char-at suffix 0) "u")) (decode-u4 suffix 1)
  (= (count suffix) 1) (let [ch (char-at suffix 0)]
  (int (first ch)))
  :else 65533))

(declare read-symbol-text)

(defn read-char-literal [^String src pos]
  (if (>= pos (count src)) (make-result [CHAR-TAG 65533] pos) (let [first-char (char-at src pos)]
  (if (delimiter? first-char) (make-result [CHAR-TAG (decode-char-lit first-char)] (+ pos 1)) (let [suffix-result (read-symbol-text src pos)]
  (make-result [CHAR-TAG (decode-char-lit (get suffix-result "value"))] (get suffix-result "pos")))))))

(defn read-string-literal! [^String src pos]
  (let [len (count src)]
  (loop [i (+ pos 1)
   buf []]
  (cond
  (>= i len) (do
  (reader-error! "beagle reader: unterminated string\n")
  (make-result [STRING-TAG (str/join "" buf)] i))
  (= (char-at src i) "\"") (make-result [STRING-TAG (str/join "" buf)] (+ i 1))
  (= (char-at src i) "\\") (let [e (char-at src (+ i 1))]
  (if (= e "u") (recur (+ i 6) (conj buf (str (char (decode-u4 src (+ i 2)))))) (recur (+ i 2) (conj buf (decode-escape e)))))
  :else (recur (+ i 1) (conj buf (char-at src i)))))))

(defn read-regex-literal! [^String src pos]
  (let [len (count src)]
  (loop [i (+ pos 1)
   buf []]
  (cond
  (>= i len) (do
  (reader-error! "beagle reader: unterminated regex literal\n")
  (make-result [REGEX-TAG (str/join "" buf)] i))
  (= (char-at src i) "\"") (make-result [REGEX-TAG (str/join "" buf)] (+ i 1))
  (= (char-at src i) "\\") (recur (+ i 2) (conj buf (str "\\" (char-at src (+ i 1)))))
  :else (recur (+ i 1) (conj buf (char-at src i)))))))

(defn count-hashes [^String src pos]
  (loop [i pos
   n 0]
  (if (and (< i (count src)) (= (char-at src i) "#")) (recur (+ i 1) (+ n 1)) n)))

(defn ^String hashes-str [n]
  (loop [k n
   acc ""]
  (if (<= k 0) acc (recur (- k 1) (str acc "#")))))

(defn read-raw-string! [^String src pos]
  (let [hc (count-hashes src pos)
   open-pos (+ pos hc)
   len (count src)]
  (if (or (>= open-pos len) (not= (char-at src open-pos) "\"")) (do
  (reader-error! "beagle reader: expected '\"' after #r hashes\n")
  (make-result "" open-pos)) (loop [i (+ open-pos 1)
   buf []]
  (if (>= i len) (do
  (reader-error! "beagle reader: unterminated raw string\n")
  (make-result [STRING-TAG (str/join "" buf)] i)) (if (= (char-at src i) "\"") (let [found (count-hashes src (+ i 1))]
  (if (>= found hc) (make-result [STRING-TAG (str/join "" buf)] (+ i 1 found)) (recur (+ i 1 found) (conj buf (str "\"" (hashes-str found)))))) (recur (+ i 1) (conj buf (char-at src i)))))))))

(defn num-value [^String src start end ^Boolean is-float]
  (let [text (subs src start end)]
  (if is-float (let [n (parse-double text)]
  (if (nil? n) 0.0 n)) (let [n (parse-long text)]
  (if (nil? n) 0 n)))))

(defn read-number [^String src pos]
  (let [len (count src)
   start (if (= (char-at src pos) "-") (+ pos 1) pos)]
  (loop [i start
   has-dot false
   has-exp false]
  (if (>= i len) (make-result (num-value src pos i (or has-dot has-exp)) i) (let [ch (char-at src i)]
  (cond
  (digit? ch) (recur (+ i 1) has-dot has-exp)
  (and (= ch ".") (not has-dot) (not has-exp) (< (+ i 1) len) (digit? (char-at src (+ i 1)))) (recur (+ i 1) true has-exp)
  (and (or (= ch "e") (= ch "E")) (not has-exp) (> i start)) (let [n1 (char-at src (+ i 1))]
  (cond
  (digit? n1) (recur (+ i 2) has-dot true)
  (and (or (= n1 "+") (= n1 "-")) (< (+ i 2) len) (digit? (char-at src (+ i 2)))) (recur (+ i 3) has-dot true)
  :else (make-result (num-value src pos i (or has-dot has-exp)) i)))
  :else (make-result (num-value src pos i (or has-dot has-exp)) i)))))))

(defn read-symbol-text [^String src pos]
  (let [len (count src)]
  (loop [i pos]
  (if (>= i len) (make-result (subs src pos i) i) (if (delimiter? (char-at src i)) (make-result (subs src pos i) i) (recur (+ i 1)))))))

(defn classify-atom [^String text]
  (cond
  (= text "true") true
  (= text "false") false
  :else text))

(declare read-datum-with-context!)

(defn read-delimited-with-context! [^String src pos ^String close ^Boolean reading-fn-shorthand]
  (let [len (count src)]
  (loop [p (skip-ws src pos)
   items []]
  (cond
  (>= p len) (do
  (reader-error! (str "beagle reader: expected " close " before EOF\n"))
  (make-result items p))
  (= (char-at src p) close) (make-result items (+ p 1))
  :else (let [result (read-datum-with-context! src p reading-fn-shorthand)]
  (if (nil? result) (make-result items p) (recur (skip-ws src (get result "pos")) (conj items (get result "value")))))))))

(defn- ^Boolean inert-literal-datum? [datum]
  (and (vector? datum) (> (count datum) 0) (some? (get #{STRING-TAG REGEX-TAG CHAR-TAG} (nth datum 0)))))

(defn- fn-placeholder-index [datum]
  (cond
  (= datum "%") 1
  (and (string? datum) (some? (re-matches #"^%[1-9][0-9]*$" datum))) (let [parsed (parse-long (subs datum 1))]
  (if (nil? parsed) 0 parsed))
  :else 0))

(defn- max-fn-placeholder-index [datum]
  (if (and (vector? datum) (not (inert-literal-datum? datum))) (reduce (fn [best child] (max best (max-fn-placeholder-index child))) 0 datum) (fn-placeholder-index datum)))

(defn- ^Boolean fn-rest-placeholder? [datum]
  (if (and (vector? datum) (not (inert-literal-datum? datum))) (reduce (fn [^Boolean found child] (or found (fn-rest-placeholder? child))) false datum) (= datum "%&")))

(defn- rewrite-fn-placeholders [datum]
  (cond
  (= datum "%") "%1"
  (and (vector? datum) (not (inert-literal-datum? datum))) (mapv (fn [child] (rewrite-fn-placeholders child)) datum)
  :else datum))

(defn- fn-shorthand-params [max-index ^Boolean rest-used]
  (let [fixed (loop [index 1
   params [BRACKET-TAG]]
  (if (> index max-index) params (recur (+ index 1) (conj (conj params (str "%" index)) "Any"))))]
  (if rest-used (into fixed ["&" "%&" "Any"]) fixed)))

(defn- fn-shorthand->fn [items]
  (let [max-index (max-fn-placeholder-index items)
   rest-used (fn-rest-placeholder? items)
   body (rewrite-fn-placeholders items)]
  ["fn" (fn-shorthand-params max-index rest-used) "Any" body]))

(defn- reject-nested-fn-shorthand! []
  (if (deref READING-FN-SHORTHAND) (do
  (throw (ex-info "beagle reader: nested #(...) is not supported; use an explicit fn for the inner function" {})))))

(defn read-hash-dispatch-with-context! [^String src pos ^Boolean reading-fn-shorthand]
  (let [len (count src)]
  (if (>= (+ pos 1) len) (make-result "#" (+ pos 1)) (let [nxt (char-at src (+ pos 1))]
  (cond
  (= nxt "{") (let [result (read-delimited-with-context! src (+ pos 2) "}" reading-fn-shorthand)]
  (make-result (into [SET-TAG] (get result "value")) (get result "pos")))
  (= nxt "(") (do
  (if reading-fn-shorthand (do
  (throw (ex-info "beagle reader: nested #(...) is not supported; use an explicit fn for the inner function" {}))))
  (let [result (read-delimited-with-context! src (+ pos 2) ")" true)]
  (make-result (fn-shorthand->fn (get result "value")) (get result "pos"))))
  (= nxt "'") (let [inner (read-datum-with-context! src (+ pos 2) reading-fn-shorthand)]
  (if (nil? inner) (do
  (reader-error! "beagle reader: unexpected EOF after `#'` (Var quote needs a following name)\n")
  (make-result ["syntax" nil] (+ pos 2))) (make-result ["syntax" (get inner "value")] (get inner "pos"))))
  (= nxt "\"") (read-regex-literal! src (+ pos 1))
  (= nxt "r") (read-raw-string! src (+ pos 2))
  :else (let [sym-result (read-symbol-text src pos)]
  (make-result (get sym-result "value") (get sym-result "pos"))))))))

(defn read-datum-with-context! [^String src pos ^Boolean reading-fn-shorthand]
  (let [p (skip-ws src pos)
   len (count src)]
  (if (>= p len) nil (let [ch (char-at src p)]
  (cond
  (= ch "(") (read-delimited-with-context! src (+ p 1) ")" reading-fn-shorthand)
  (= ch "[") (let [result (read-delimited-with-context! src (+ p 1) "]" reading-fn-shorthand)]
  (make-result (into [BRACKET-TAG] (get result "value")) (get result "pos")))
  (= ch "{") (let [result (read-delimited-with-context! src (+ p 1) "}" reading-fn-shorthand)]
  (make-result (into [MAP-TAG] (get result "value")) (get result "pos")))
  (= ch "\"") (read-string-literal! src p)
  (= ch "#") (read-hash-dispatch-with-context! src p reading-fn-shorthand)
  (= ch "'") (let [inner (read-datum-with-context! src (+ p 1) reading-fn-shorthand)]
  (if (nil? inner) (do
  (reader-error! "beagle reader: unexpected EOF after quote\n")
  (make-result ["quote" nil] (+ p 1))) (make-result ["quote" (get inner "value")] (get inner "pos"))))
  (= ch "`") (let [inner (read-datum-with-context! src (+ p 1) reading-fn-shorthand)]
  (if (nil? inner) (do
  (reader-error! "beagle reader: unexpected EOF after quasiquote\n")
  (make-result ["quasiquote" nil] (+ p 1))) (make-result ["quasiquote" (get inner "value")] (get inner "pos"))))
  (= ch "@") (let [inner (read-datum-with-context! src (+ p 1) reading-fn-shorthand)]
  (if (nil? inner) (do
  (reader-error! "beagle reader: unexpected EOF after deref\n")
  (make-result ["deref" nil] (+ p 1))) (make-result ["deref" (get inner "value")] (get inner "pos"))))
  (= ch "~") (if (= (char-at src (+ p 1)) "@") (let [inner (read-datum-with-context! src (+ p 2) reading-fn-shorthand)]
  (if (nil? inner) (do
  (reader-error! "beagle reader: unexpected EOF after `~@` (unquote-splicing needs a following datum)\n")
  (make-result ["unquote-splicing" nil] (+ p 2))) (make-result ["unquote-splicing" (get inner "value")] (get inner "pos")))) (let [inner (read-datum-with-context! src (+ p 1) reading-fn-shorthand)]
  (if (nil? inner) (do
  (reader-error! "beagle reader: unexpected EOF after `~` (unquote needs a following datum)\n")
  (make-result ["unquote" nil] (+ p 1))) (make-result ["unquote" (get inner "value")] (get inner "pos")))))
  (= ch "^") (let [meta-r (read-datum-with-context! src (+ p 1) reading-fn-shorthand)]
  (if (nil? meta-r) (do
  (reader-error! "beagle reader: unexpected EOF after `^` (metadata needs a value and a target form)\n")
  nil) (let [form-r (read-datum-with-context! src (get meta-r "pos") reading-fn-shorthand)]
  (if (nil? form-r) (do
  (reader-error! "beagle reader: unexpected EOF after `^` metadata (needs a target form to attach to)\n")
  nil) (make-result ["#%meta" (get meta-r "value") (get form-r "value")] (get form-r "pos"))))))
  (or (digit? ch) (and (= ch "-") (< (+ p 1) len) (digit? (char-at src (+ p 1))))) (read-number src p)
  (or (= ch ")") (= ch "]") (= ch "}")) (do
  (reader-error! (str "beagle reader: unexpected '" ch "'\n"))
  nil)
  (= ch "\\") (read-char-literal src (+ p 1))
  :else (let [sym-result (read-symbol-text src p)
   text (get sym-result "value")]
  (make-result (classify-atom text) (get sym-result "pos"))))))))

(defn read-datum! [^String src pos]
  (read-datum-with-context! src pos false))

(declare read-syntax-datum!)

(def SOURCE-LOCATIONS (atom []))

(defn- build-source-locations [^String src]
  (loop [i 0
   line 1
   column 0
   locations [[1 0]]]
  (if (>= i (count src)) locations (if (newline? (char-at src i)) (recur (+ i 1) (+ line 1) 0 (conj locations [(+ line 1) 0])) (recur (+ i 1) line (+ column 1) (conj locations [line (+ column 1)]))))))

(defn- source-line-column [^String src pos]
  (let [locations (deref SOURCE-LOCATIONS)]
  (if (and (>= pos 0) (< pos (count locations))) (nth locations pos) [1 pos])))

(defn- syntax-span! [^String src source-id start end]
  (let [location (source-line-column src start)]
  (ast/make-source-span! source-id start end (nth location 0) (nth location 1))))

(defn- syntax-properties [^String src start end delimiter]
  {"reader" (ast/make-reader-metadata (subs src start end) delimiter)})

(defn- syntax-head! [^String name span properties]
  (ast/datum->beagle-syntax! name span ast/EMPTY-SCOPE-SET nil properties))

(defn- attach-syntax! [^String src source-id start result]
  (if (nil? result) nil (let [end (get result "pos")
   value (get result "value")
   ch (char-at src start)
   children (or (get result "syntaxChildren") [])
   delimiter (cond
  (= ch "(") "paren"
  (= ch "[") "bracket"
  (= ch "{") "brace"
  (and (= ch "#") (= (char-at src (+ start 1)) "{")) "set"
  (and (= ch "#") (= (char-at src (+ start 1)) "(")) "fn-shorthand"
  (and (= ch "#") (= (char-at src (+ start 1)) "'")) "var-quote"
  (= ch "'") "quote"
  (= ch "`") "quasiquote"
  (and (= ch "~") (= (char-at src (+ start 1)) "@")) "unquote-splicing"
  (= ch "~") "unquote"
  :else "atom")
   span (syntax-span! src source-id start end)
   properties (syntax-properties src start end delimiter)
   syntax (cond
  (= ch "(") (ast/make-syntax-list! children span ast/EMPTY-SCOPE-SET nil properties)
  (= ch "[") (ast/make-syntax-vector! children span ast/EMPTY-SCOPE-SET nil properties)
  (= ch "{") (ast/make-syntax-list! (into [(syntax-head! MAP-TAG span properties)] children) span ast/EMPTY-SCOPE-SET nil properties)
  (and (= ch "#") (= (char-at src (+ start 1)) "{")) (ast/make-syntax-list! (into [(syntax-head! SET-TAG span properties)] children) span ast/EMPTY-SCOPE-SET nil properties)
  (and (= ch "#") (= (char-at src (+ start 1)) "(")) (ast/datum->beagle-syntax! value span ast/EMPTY-SCOPE-SET nil properties)
  (and (= ch "#") (= (char-at src (+ start 1)) "'")) (ast/make-syntax-list! (into [(syntax-head! "syntax" span properties)] children) span ast/EMPTY-SCOPE-SET nil properties)
  (= ch "'") (ast/make-syntax-quote! (if (> (count value) 1) (nth value 1) nil) span ast/EMPTY-SCOPE-SET nil properties)
  (or (= ch "~") (and (= ch "~") (= (char-at src (+ start 1)) "@"))) (ast/make-syntax-unquote! (if (> (count children) 0) (nth children 0) (ast/datum->beagle-syntax! nil span ast/EMPTY-SCOPE-SET nil properties)) (= delimiter "unquote-splicing") span ast/EMPTY-SCOPE-SET nil properties)
  (or (= ch "`") (= ch "@") (= ch "^")) (let [head (nth value 0)]
  (ast/make-syntax-list! (into [(syntax-head! head span properties)] children) span ast/EMPTY-SCOPE-SET nil properties))
  :else (ast/datum->beagle-syntax! value span ast/EMPTY-SCOPE-SET nil properties))]
  (assoc result "syntax" syntax))))

(defn- read-syntax-delimited! [^String src pos ^String close source-id]
  (let [len (count src)]
  (loop [p (skip-ws src pos)
   items []
   syntaxes []]
  (cond
  (>= p len) (do
  (reader-error! (str "beagle reader: expected " close " before EOF\n"))
  (assoc (make-result items p) "syntaxChildren" syntaxes))
  (= (char-at src p) close) (assoc (make-result items (+ p 1)) "syntaxChildren" syntaxes)
  :else (let [result (read-syntax-datum! src p source-id)]
  (if (nil? result) (assoc (make-result items p) "syntaxChildren" syntaxes) (recur (skip-ws src (get result "pos")) (conj items (get result "value")) (conj syntaxes (get result "syntax")))))))))

(defn- read-syntax-hash-dispatch! [^String src pos source-id]
  (let [len (count src)]
  (if (>= (+ pos 1) len) (make-result "#" (+ pos 1)) (let [nxt (char-at src (+ pos 1))]
  (cond
  (= nxt "{") (let [result (read-syntax-delimited! src (+ pos 2) "}" source-id)]
  (assoc (make-result (into [SET-TAG] (get result "value")) (get result "pos")) "syntaxChildren" (get result "syntaxChildren")))
  (= nxt "(") (do
  (reject-nested-fn-shorthand!)
  (reset! READING-FN-SHORTHAND true)
  (let [result (try
  (read-syntax-delimited! src (+ pos 2) ")" source-id)
  (finally
    (reset! READING-FN-SHORTHAND false)))]
  (assoc (make-result (fn-shorthand->fn (get result "value")) (get result "pos")) "syntaxChildren" (get result "syntaxChildren"))))
  (= nxt "'") (let [inner (read-syntax-datum! src (+ pos 2) source-id)]
  (if (nil? inner) (do
  (reader-error! "beagle reader: unexpected EOF after `#'` (Var quote needs a following name)\n")
  (make-result ["syntax" nil] (+ pos 2))) (assoc (make-result ["syntax" (get inner "value")] (get inner "pos")) "syntaxChildren" [(get inner "syntax")])))
  (= nxt "\"") (read-regex-literal! src (+ pos 1))
  (= nxt "r") (read-raw-string! src (+ pos 2))
  :else (let [sym-result (read-symbol-text src pos)]
  (make-result (get sym-result "value") (get sym-result "pos"))))))))

(defn read-syntax-datum! [^String src pos source-id]
  (let [p (skip-ws src pos)
   len (count src)]
  (if (>= p len) nil (let [ch (char-at src p)
   result (cond
  (= ch "(") (read-syntax-delimited! src (+ p 1) ")" source-id)
  (= ch "[") (let [inner (read-syntax-delimited! src (+ p 1) "]" source-id)]
  (assoc (make-result (into [BRACKET-TAG] (get inner "value")) (get inner "pos")) "syntaxChildren" (get inner "syntaxChildren")))
  (= ch "{") (let [inner (read-syntax-delimited! src (+ p 1) "}" source-id)]
  (assoc (make-result (into [MAP-TAG] (get inner "value")) (get inner "pos")) "syntaxChildren" (get inner "syntaxChildren")))
  (= ch "\"") (read-string-literal! src p)
  (= ch "#") (read-syntax-hash-dispatch! src p source-id)
  (= ch "'") (let [inner (read-syntax-datum! src (+ p 1) source-id)]
  (if (nil? inner) (do
  (reader-error! "beagle reader: unexpected EOF after quote\n")
  (make-result ["quote" nil] (+ p 1))) (assoc (make-result ["quote" (get inner "value")] (get inner "pos")) "syntaxChildren" [(get inner "syntax")])))
  (= ch "`") (let [inner (read-syntax-datum! src (+ p 1) source-id)]
  (if (nil? inner) (do
  (reader-error! "beagle reader: unexpected EOF after quasiquote\n")
  (make-result ["quasiquote" nil] (+ p 1))) (assoc (make-result ["quasiquote" (get inner "value")] (get inner "pos")) "syntaxChildren" [(get inner "syntax")])))
  (= ch "@") (let [inner (read-syntax-datum! src (+ p 1) source-id)]
  (if (nil? inner) (do
  (reader-error! "beagle reader: unexpected EOF after deref\n")
  (make-result ["deref" nil] (+ p 1))) (assoc (make-result ["deref" (get inner "value")] (get inner "pos")) "syntaxChildren" [(get inner "syntax")])))
  (= ch "~") (let [splicing (= (char-at src (+ p 1)) "@")
   inner (read-syntax-datum! src (+ p (if splicing 2 1)) source-id)]
  (if (nil? inner) (do
  (reader-error! (if splicing "beagle reader: unexpected EOF after `~@` (unquote-splicing needs a following datum)\n" "beagle reader: unexpected EOF after `~` (unquote needs a following datum)\n"))
  (make-result [(if splicing "unquote-splicing" "unquote") nil] (+ p (if splicing 2 1)))) (assoc (make-result [(if splicing "unquote-splicing" "unquote") (get inner "value")] (get inner "pos")) "syntaxChildren" [(get inner "syntax")])))
  (= ch "^") (let [meta-r (read-syntax-datum! src (+ p 1) source-id)]
  (if (nil? meta-r) (do
  (reader-error! "beagle reader: unexpected EOF after `^` (metadata needs a value and a target form)\n")
  nil) (let [form-r (read-syntax-datum! src (get meta-r "pos") source-id)]
  (if (nil? form-r) (do
  (reader-error! "beagle reader: unexpected EOF after `^` metadata (needs a target form to attach to)\n")
  nil) (assoc (make-result ["#%meta" (get meta-r "value") (get form-r "value")] (get form-r "pos")) "syntaxChildren" [(get meta-r "syntax") (get form-r "syntax")])))))
  (or (digit? ch) (and (= ch "-") (< (+ p 1) len) (digit? (char-at src (+ p 1))))) (read-number src p)
  (or (= ch ")") (= ch "]") (= ch "}")) (do
  (reader-error! (str "beagle reader: unexpected '" ch "'\n"))
  nil)
  (= ch "\\") (read-char-literal src (+ p 1))
  :else (let [sym-result (read-symbol-text src p)]
  (make-result (classify-atom (get sym-result "value")) (get sym-result "pos"))))]
  (attach-syntax! src source-id p result)))))

(defn lang-target [^String lang-text]
  (cond
  (= lang-text "beagle") "core"
  (= lang-text "beagle/clj") "clj"
  (= lang-text "beagle/js") "js"
  (= lang-text "beagle/nix") "nix"
  :else nil))

(defn target-lang-line [^String target]
  (cond
  (= target "core") "#lang beagle"
  (or (= target "clj") (= target "js") (= target "nix")) (str "#lang beagle/" target)
  :else nil))

(defn parse-lang-line [^String src]
  (let [len (count src)]
  (if (str/starts-with? src "#lang") (loop [i 5]
  (if (or (>= i len) (newline? (char-at src i))) {"target" (lang-target (str/trim (substring2 src 5 i))) "pos" (if (and (< i len) (= (char-at src i) "\n")) (+ i 1) i)} (recur (+ i 1)))) {"target" nil "pos" 0})))

(defn read-all! [^String src]
  (reset-errors!)
  (let [lang-info (parse-lang-line src)
   target (get lang-info "target")
   start-pos (get lang-info "pos")]
  (loop [p (skip-ws src start-pos)
   datums []]
  (if (>= p (count src)) {"target" target "datums" datums} (let [result (read-datum! src p)]
  (if (nil? result) {"target" target "datums" datums} (recur (skip-ws src (get result "pos")) (conj datums (get result "value")))))))))

(defn- ^Boolean has-define-target? [datums]
  (loop [i 0]
  (if (>= i (count datums)) false (let [d (nth datums i)]
  (if (and (vector? d) (> (count d) 0) (= (nth d 0) "define-target")) true (recur (+ i 1)))))))

(defn read-program! [^String src]
  (let [all (read-all! src)
   target (get all "target")
   datums (get all "datums")]
  (if (and (some? target) (not= target "clj") (not (has-define-target? datums))) (into [["define-target" target]] datums) datums)))

(defn read-program-with-syntax! [^String src source-id]
  (reset-errors!)
  (reset! SOURCE-LOCATIONS (build-source-locations src))
  (let [lang-info (parse-lang-line src)
   target (get lang-info "target")
   start-pos (get lang-info "pos")
   read-result (loop [p (skip-ws src start-pos)
   datums []
   syntaxes []]
  (if (>= p (count src)) {"datums" datums "syntaxes" syntaxes} (let [result (read-syntax-datum! src p source-id)]
  (if (nil? result) {"datums" datums "syntaxes" syntaxes} (recur (skip-ws src (get result "pos")) (conj datums (get result "value")) (conj syntaxes (get result "syntax")))))))
   datums (get read-result "datums")
   syntaxes (get read-result "syntaxes")
   program (if (and (some? target) (not= target "clj") (not (has-define-target? datums))) {"datums" (into [["define-target" target]] datums) "syntaxes" (into [(ast/datum->beagle-syntax! ["define-target" target] nil ast/EMPTY-SCOPE-SET nil {"reader" (ast/make-reader-metadata "" "synthetic")})] syntaxes)} {"datums" datums "syntaxes" syntaxes})]
  (assoc program "errors" (reader-errors))))

(def passes (atom []))

(def failures (atom []))

(defn- expect! [^String label ^Boolean result]
  (if result (do
  (swap! passes conj true)
  nil) (do
  (swap! failures conj label)
  nil)))

(defn- rd! [^String src]
  (get (read-all! src) "datums"))

(defn- rd1! [^String src]
  (nth (rd! src) 0))

(defn run-tests! []
  (reset! passes [])
  (reset! failures [])
  (expect! "number: integer" (= (rd1! "42") 42))
  (expect! "number: float" (= (rd1! "3.14") 3.14))
  (expect! "number: negative" (= (rd1! "-7") -7))
  (expect! "number: negative float" (= (rd1! "-3.14") -3.14))
  (expect! "boolean: true" (= (rd1! "true") true))
  (expect! "boolean: false" (= (rd1! "false") false))
  (expect! "symbol" (= (rd1! "foo") "foo"))
  (expect! "nil symbol" (= (rd1! "nil") "nil"))
  (expect! "keyword" (= (rd1! ":name") ":name"))
  (expect! "auto-resolved keyword ::kw stays one keyword" (= (rd1! "::kw") "::kw"))
  (expect! "keyword" (= (rd1! ":foo") ":foo"))
  (expect! "<: stays one symbol" (= (rd1! "<:") "<:"))
  (expect! "<: inside a forall bound" (= (rd1! "(forall [T <: Num] T)") ["forall" [BRACKET-TAG "T" "<:" "Num"] "T"]))
  (expect! "< unchanged" (= (rd1! "(< a b)") ["<" "a" "b"]))
  (expect! "<= unchanged" (= (rd1! "(<= a b)") ["<=" "a" "b"]))
  (expect! "<- unchanged" (= (rd1! "<-") "<-"))
  (expect! "<:foo is one symbol" (= (rd1! "<:foo") "<:foo"))
  (expect! "char literal \\: unaffected" (= (rd1! "\\:") [CHAR-TAG 58]))
  (expect! "string literal" (= (rd1! "\"hello\"") [STRING-TAG "hello"]))
  (expect! "string with escapes" (= (rd1! "\"a\\nb\"") [STRING-TAG "a\nb"]))
  (expect! "string with tab" (= (rd1! "\"a\\tb\"") [STRING-TAG "a\tb"]))
  (expect! "string with escaped quote" (= (rd1! "\"say \\\"hi\\\"\"") [STRING-TAG "say \"hi\""]))
  (expect! "string with \\u0001 escape" (= (rd1! "\"\\u0001\"") [STRING-TAG "\u0001"]))
  (expect! "\\uXXXX in context" (= (rd1! "\"a\\u0041b\"") [STRING-TAG "aAb"]))
  (expect! "\\uXXXX yields real control char (len 1)" (= (count (nth (rd1! "\"\\u0001\"") 1)) 1))
  (expect! "1.0 stays float (not int)" (not (= (rd1! "1.0") 1)))
  (expect! "1.0 equals 1.0 float" (= (rd1! "1.0") 1.0))
  (expect! "1 stays int" (= (rd1! "1") 1))
  (expect! "exponent 1e5" (= (rd1! "1e5") 100000.0))
  (expect! "exponent 1E5 upper" (= (rd1! "1E5") 100000.0))
  (expect! "float exponent 1.5e-3" (= (rd1! "1.5e-3") 0.0015))
  (expect! "negative exponent -2e3" (= (rd1! "-2e3") -2000.0))
  (expect! "exponent classifies as float" (not (= (rd1! "1e2") 100)))
  (expect! "simple list" (= (rd1! "(+ 1 2)") ["+" 1 2]))
  (expect! "nested list" (= (rd1! "(+ (* 2 3) 4)") ["+" ["*" 2 3] 4]))
  (expect! "bracket vector" (= (rd1! "[1 2 3]") [BRACKET-TAG 1 2 3]))
  (expect! "map literal" (= (rd1! "{:a 1 :b 2}") [MAP-TAG ":a" 1 ":b" 2]))
  (expect! "set literal" (= (rd1! "#{1 2 3}") [SET-TAG 1 2 3]))
  (expect! "regex literal" (= (rd1! "#\"[a-z]+\"") [REGEX-TAG "[a-z]+"]))
  (expect! "regex preserves backslash" (= (rd1! "#\"\\d+\"") [REGEX-TAG "\\d+"]))
  (expect! "fn shorthand: bare percent" (= (rd1! "#(inc %)") ["fn" [BRACKET-TAG "%1" "Any"] "Any" ["inc" "%1"]]))
  (expect! "fn shorthand: max positional index defines arity" (= (rd1! "#(str %2)") ["fn" [BRACKET-TAG "%1" "Any" "%2" "Any"] "Any" ["str" "%2"]]))
  (expect! "fn shorthand: rest placeholder" (= (rd1! "#(apply + %1 %&)") ["fn" [BRACKET-TAG "%1" "Any" "&" "%&" "Any"] "Any" ["apply" "+" "%1" "%&"]]))
  (expect! "fn shorthand: no placeholders is a thunk" (= (rd1! "#(rand)") ["fn" [BRACKET-TAG] "Any" ["rand"]]))
  (expect! "fn shorthand: enclosing call retains following arguments" (= (rd1! "(map #(inc %) xs ys)") ["map" ["fn" [BRACKET-TAG "%1" "Any"] "Any" ["inc" "%1"]] "xs" "ys"]))
  (expect! "fn shorthand: string contents are not placeholders" (= (rd1! "#(str \"%\")") ["fn" [BRACKET-TAG] "Any" ["str" [STRING-TAG "%"]]]))
  (expect! "fn shorthand: nested form is rejected" (try
  (do
  (rd1! "#(map #(inc %) xs)")
  false)
  (catch Exception _
    true)))
  (expect! "fn shorthand: syntax path is a rewritten tree with source span" (let [source "#(inc %)"
   output (read-program-with-syntax! source "shorthand.bclj")
   syntax (nth (get output "syntaxes") 0)
   span (ast/beagle-syntax-span syntax)]
  (and (= (get syntax "variant") "list") (= (ast/beagle-syntax->datum! syntax) ["fn" [BRACKET-TAG "%1" "Any"] "Any" ["inc" "%1"]]) (= (get span "start") 0) (= (get span "end") (count source)))))
  (expect! "quote" (= (rd1! "'foo") ["quote" "foo"]))
  (expect! "deref" (= (rd1! "@state") ["deref" "state"]))
  (expect! "Var quote" (= (rd1! "#'service/run") ["syntax" "service/run"]))
  (expect! "Var quote EOF is a reader error in datum mode" (let [output (read-all! "#'")
   errors (reader-errors)]
  (and (= (get output "datums") [["syntax" nil]]) (= (count errors) 1) (str/includes? (nth errors 0) "Var quote needs a following name"))))
  (expect! "Var quote EOF is a reader error in syntax mode" (let [output (read-program-with-syntax! "#'" "var-quote-eof.bclj")]
  (and (= (get output "datums") [["syntax" nil]]) (= (count (get output "errors")) 1) (str/includes? (nth (get output "errors") 0) "Var quote needs a following name"))))
  (expect! "quasiquote" (= (rd1! "`foo") ["quasiquote" "foo"]))
  (expect! "unquote" (= (rd1! "~x") ["unquote" "x"]))
  (expect! "unquote-splicing" (= (rd1! "~@xs") ["unquote-splicing" "xs"]))
  (expect! "unquote terminates symbols" (= (rd1! "`(f ~x)") ["quasiquote" ["f" ["unquote" "x"]]]))
  (expect! "meta: keyword" (= (rd1! "^:dynamic *x*") ["#%meta" ":dynamic" "*x*"]))
  (expect! "meta: map (true classifies to boolean per datum encoding)" (= (rd1! "^{:dynamic true} *x*") ["#%meta" [MAP-TAG ":dynamic" true] "*x*"]))
  (expect! "comma is whitespace" (= (rd1! "[1, 2,3]") [BRACKET-TAG 1 2 3]))
  (expect! "trailing comma before close" (= (rd1! "{:a 1,}") [MAP-TAG ":a" 1]))
  (expect! "line comment skipped" (= (rd! "; ignore\n42") [42]))
  (expect! "inline comment" (= (rd! "1 ; comment\n2") [1 2]))
  (expect! "multiple comment lines" (= (rd! ";; first\n;; second\n42") [42]))
  (expect! "char: named tab" (= (rd1! "\\tab") [CHAR-TAG 9]))
  (expect! "char: named space" (= (rd1! "\\space") [CHAR-TAG 32]))
  (expect! "char: named newline" (= (rd1! "\\newline") [CHAR-TAG 10]))
  (expect! "char: named return" (= (rd1! "\\return") [CHAR-TAG 13]))
  (expect! "char: named formfeed" (= (rd1! "\\formfeed") [CHAR-TAG 12]))
  (expect! "char: named backspace" (= (rd1! "\\backspace") [CHAR-TAG 8]))
  (expect! "char: single printable A" (= (rd1! "\\A") [CHAR-TAG 65]))
  (expect! "char: single printable z" (= (rd1! "\\z") [CHAR-TAG 122]))
  (expect! "char: opening parenthesis consumes the delimiter" (= (rd1! "(int \\()") ["int" [CHAR-TAG 40]]))
  (expect! "char: closing parenthesis consumes the delimiter" (= (rd1! "(int \\))") ["int" [CHAR-TAG 41]]))
  (expect! "char: semicolon is data rather than a comment" (= (rd1! "(int \\;)") ["int" [CHAR-TAG 59]]))
  (expect! "char: \\uNNNN printable" (= (rd1! "\\u0041") [CHAR-TAG 65]))
  (expect! "char: \\uNNNN non-ascii" (= (rd1! "\\u00e9") [CHAR-TAG 233]))
  (expect! "char: in list" (= (rd1! "(str \\A \\space)") ["str" [CHAR-TAG 65] [CHAR-TAG 32]]))
  (expect! "bare #lang beagle selects Core" (= (get (read-all! "#lang beagle\n") "target") "core"))
  (expect! "#lang beagle/clj" (= (get (read-all! "#lang beagle/clj\n") "target") "clj"))
  (expect! "#lang beagle/js" (let [result (read-all! "#lang beagle/js\n(ns app)")]
  (and (= (get result "target") "js") (= (get result "datums") [["ns" "app"]]))))
  (expect! "no #lang" (let [result (read-all! "(ns app)")]
  (and (nil? (get result "target")) (= (get result "datums") [["ns" "app"]]))))
  (expect! "Core renders as bare #lang beagle" (= (target-lang-line "core") "#lang beagle"))
  (expect! "hosted targets render with explicit language paths" (= (target-lang-line "clj") "#lang beagle/clj"))
  (expect! "unknown targets have no language path" (nil? (target-lang-line "missing")))
  (expect! "declare-extern with fn type" (let [result (rd1! "(declare-extern fetch (Fn [String] (Promise Any)))")]
  (and (= (nth result 0) "declare-extern") (= (nth result 1) "fetch") (= (nth result 2) ["Fn" [BRACKET-TAG "String"] ["Promise" "Any"]]))))
  (expect! "method call" (= (rd1! "(.toString x)") [".toString" "x"]))
  (expect! "property access" (= (rd1! "(.-length arr)") [".-length" "arr"]))
  (expect! "static call" (= (rd1! "(Math/abs x)") ["Math/abs" "x"]))
  (expect! "qualified symbol stays intact for semantic parse lowering" (= (rd1! "odd.ns/->thing?!") "odd.ns/->thing?!"))
  (expect! "quoted qualified symbol stays literal data" (= (rd1! "'odd.ns/->thing?!") ["quote" "odd.ns/->thing?!"]))
  (expect! "qualified require alias" (= (rd1! "(:tx a)") [":tx" "a"]))
  (expect! "threading macro" (= (rd1! "(-> x inc str)") ["->" "x" "inc" "str"]))
  (expect! "negative number in list" (= (rd1! "(+ x -5)") ["+" "x" -5]))
  (expect! "minus as symbol" (= (rd1! "(- 5 3)") ["-" 5 3]))
  (expect! "dot method symbol" (= (rd1! ".charAt") ".charAt"))
  (expect! "static JavaScript selector remains a dot-prefixed token" (= (rd1! "(.-raw_name obj)") [".-raw_name" "obj"]))
  (expect! "dynamic var" (= (rd1! "*state*") "*state*"))
  (expect! "constructor symbol" (= (rd1! "Point.") "Point."))
  (expect! "empty list" (= (rd1! "()") []))
  (expect! "empty vector" (= (rd1! "[]") [BRACKET-TAG]))
  (expect! "empty map" (= (rd1! "{}") [MAP-TAG]))
  (expect! "multiple top-level forms" (let [result (rd! "(def x 1)\n(def y 2)")]
  (and (= (count result) 2) (= (nth (nth result 0) 1) "x") (= (nth (nth result 1) 1) "y"))))
  (expect! "string in list" (let [result (rd1! "(str \"hello\" \" world\")")]
  (and (= (nth result 0) "str") (= (nth result 1) [STRING-TAG "hello"]) (= (nth result 2) [STRING-TAG " world"]))))
  (expect! "keyword :else in map" (= (rd1! "{:else true}") [MAP-TAG ":else" true]))
  (expect! "str concat call" (let [result (rd1! "(str \"Hello, \" name \"!\")")]
  (and (= (nth result 0) "str") (= (nth result 1) [STRING-TAG "Hello, "]) (= (nth result 2) "name") (= (nth result 3) [STRING-TAG "!"]))))
  (expect! "full clj header" (let [result (read-all! "#lang beagle/clj\n(ns app.main)\n(def x 1)")]
  (and (= (get result "target") "clj") (= (count (get result "datums")) 2) (= (nth (nth (get result "datums") 0) 0) "ns") (= (nth (nth (get result "datums") 1) 0) "def"))))
  (expect! "read-program! returns datum vector" (= (read-program! "#lang beagle/clj\n(ns app)\n(def x 1)") [["ns" "app"] ["def" "x" 1]]))
  (expect! "read-program!: clj target injects NO define-target (parser default)" (= (read-program! "#lang beagle/clj\n(ns app)") [["ns" "app"]]))
  (expect! "read-program!: Core prepends (define-target core)" (= (read-program! "#lang beagle\n(def x 1)") [["define-target" "core"] ["def" "x" 1]]))
  (expect! "read-program!: nix target prepends (define-target nix)" (= (read-program! "#lang beagle/nix\n(ns app)") [["define-target" "nix"] ["ns" "app"]]))
  (expect! "read-program!: no #lang -> no injection" (= (read-program! "(ns app)") [["ns" "app"]]))
  (expect! "read-program!: explicit define-target present -> no double injection" (= (read-program! "#lang beagle/js\n(define-target js)\n(ns app)") [["define-target" "js"] ["ns" "app"]]))
  (expect! "read-datum! returns value+pos" (let [r (read-datum! "42 rest" 0)]
  (and (= (get r "value") 42) (= (get r "pos") 2))))
  (expect! "syntax reader keeps exact caller bytes and child span" (let [source "#lang beagle/clj\n(identity (+ 1 2))"
   result (read-program-with-syntax! source "reader-fixture.bclj")
   call-syntax (nth (get result "syntaxes") 0)
   child (nth (get call-syntax "payload") 1)
   reader (get (ast/beagle-syntax-properties child) "reader")
   span (ast/beagle-syntax-span child)]
  (and (= (get reader "sourceBytes") "(+ 1 2)") (= (get span "start") 27) (= (get span "end") 34))))
  (doseq [f (deref failures)]
  (selfhost.rt/eprint (str "  FAIL: " f "\n")))
  (println (str "  READER: " (count (deref passes)) " passed, " (count (deref failures)) " failed"))
  (count (deref failures)))
