(ns selfhost.reader
  (:require [selfhost.rt :as rt]
            [clojure.string :as str]))

(def ^String STRING-TAG "#%string")

(def ^String BRACKET-TAG "#%brackets")

(def ^String MAP-TAG "#%map")

(def ^String SET-TAG "#%set")

(def ^String REGEX-TAG "#%regex")

(defn ^String char-at [^String s i]
  (if (and (>= i 0) (< i (count s))) (subs s i (+ i 1)) ""))

(defn ^String substring2 [^String s a b]
  (let [n (count s)
   lo (if (< a 0) 0 (if (> a n) n a))
   hi (if (< b lo) lo (if (> b n) n b))]
  (subs s lo hi)))

(defn ^Boolean whitespace? [^String ch]
  (or (= ch " ") (= ch "\n") (= ch "\r") (= ch "\t")))

(defn ^Boolean newline? [^String ch]
  (or (= ch "\n") (= ch "\r")))

(defn ^Boolean digit? [^String ch]
  (and (= (count ch) 1) (>= (compare ch "0") 0) (<= (compare ch "9") 0)))

(defn ^Boolean delimiter? [^String ch]
  (or (whitespace? ch) (= ch "(") (= ch ")") (= ch "[") (= ch "]") (= ch "{") (= ch "}") (= ch "\"") (= ch ";")))

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
  (and (>= (compare c "a") 0) (<= (compare c "f") 0)) (+ 10 (compare c "a"))
  (and (>= (compare c "A") 0) (<= (compare c "F") 0)) (+ 10 (compare c "A"))
  :else 0))

(defn decode-u4 [^String src i]
  (+ (* 4096 (hex-val (char-at src i))) (* 256 (hex-val (char-at src (+ i 1)))) (* 16 (hex-val (char-at src (+ i 2)))) (hex-val (char-at src (+ i 3)))))

(defn read-string-literal [^String src pos]
  (let [len (count src)]
  (loop [i (+ pos 1)
   buf []]
  (cond
  (>= i len) (do
  (selfhost.rt/eprint "beagle reader: unterminated string\n")
  (make-result [STRING-TAG (str/join "" buf)] i))
  (= (char-at src i) "\"") (make-result [STRING-TAG (str/join "" buf)] (+ i 1))
  (= (char-at src i) "\\") (let [e (char-at src (+ i 1))]
  (if (= e "u") (recur (+ i 6) (conj buf (str (char (decode-u4 src (+ i 2)))))) (recur (+ i 2) (conj buf (decode-escape e)))))
  :else (recur (+ i 1) (conj buf (char-at src i)))))))

(defn read-regex-literal [^String src pos]
  (let [len (count src)]
  (loop [i (+ pos 1)
   buf []]
  (cond
  (>= i len) (do
  (selfhost.rt/eprint "beagle reader: unterminated regex literal\n")
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

(defn read-raw-string [^String src pos]
  (let [hc (count-hashes src pos)
   open-pos (+ pos hc)
   len (count src)]
  (if (or (>= open-pos len) (not= (char-at src open-pos) "\"")) (do
  (selfhost.rt/eprint "beagle reader: expected '\"' after #r hashes\n")
  (make-result "" open-pos)) (loop [i (+ open-pos 1)
   buf []]
  (if (>= i len) (make-result [STRING-TAG (str/join "" buf)] i) (if (= (char-at src i) "\"") (let [found (count-hashes src (+ i 1))]
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

(declare read-datum)

(defn read-delimited [^String src pos ^String close]
  (let [len (count src)]
  (loop [p (skip-ws src pos)
   items []]
  (cond
  (>= p len) (do
  (selfhost.rt/eprint (str "beagle reader: expected " close " before EOF\n"))
  (make-result items p))
  (= (char-at src p) close) (make-result items (+ p 1))
  :else (let [result (read-datum src p)]
  (if (nil? result) (make-result items p) (recur (skip-ws src (get result "pos")) (conj items (get result "value")))))))))

(defn read-hash-dispatch [^String src pos]
  (let [len (count src)]
  (if (>= (+ pos 1) len) (make-result "#" (+ pos 1)) (let [nxt (char-at src (+ pos 1))]
  (cond
  (= nxt "{") (let [result (read-delimited src (+ pos 2) "}")]
  (make-result (into [SET-TAG] (get result "value")) (get result "pos")))
  (= nxt "\"") (read-regex-literal src (+ pos 1))
  (= nxt "r") (read-raw-string src (+ pos 2))
  :else (let [sym-result (read-symbol-text src pos)]
  (make-result (get sym-result "value") (get sym-result "pos"))))))))

(defn read-datum [^String src pos]
  (let [p (skip-ws src pos)
   len (count src)]
  (if (>= p len) nil (let [ch (char-at src p)]
  (cond
  (= ch "(") (read-delimited src (+ p 1) ")")
  (= ch "[") (let [result (read-delimited src (+ p 1) "]")]
  (make-result (into [BRACKET-TAG] (get result "value")) (get result "pos")))
  (= ch "{") (let [result (read-delimited src (+ p 1) "}")]
  (make-result (into [MAP-TAG] (get result "value")) (get result "pos")))
  (= ch "\"") (read-string-literal src p)
  (= ch "#") (read-hash-dispatch src p)
  (= ch "'") (let [inner (read-datum src (+ p 1))]
  (if (nil? inner) (make-result ["quote" nil] (+ p 1)) (make-result ["quote" (get inner "value")] (get inner "pos"))))
  (= ch "`") (let [inner (read-datum src (+ p 1))]
  (if (nil? inner) (make-result ["quasiquote" nil] (+ p 1)) (make-result ["quasiquote" (get inner "value")] (get inner "pos"))))
  (= ch "@") (let [inner (read-datum src (+ p 1))]
  (if (nil? inner) (make-result ["deref" nil] (+ p 1)) (make-result ["deref" (get inner "value")] (get inner "pos"))))
  (or (digit? ch) (and (= ch "-") (< (+ p 1) len) (digit? (char-at src (+ p 1))))) (read-number src p)
  (and (= ch ":") (or (>= (+ p 1) len) (delimiter? (char-at src (+ p 1))))) (make-result ":" (+ p 1))
  (= ch ":") (let [sym-result (read-symbol-text src (+ p 1))]
  (make-result (str ":" (get sym-result "value")) (get sym-result "pos")))
  (or (= ch ")") (= ch "]") (= ch "}")) (do
  (selfhost.rt/eprint (str "beagle reader: unexpected '" ch "'\n"))
  nil)
  :else (let [sym-result (read-symbol-text src p)
   text (get sym-result "value")]
  (make-result (classify-atom text) (get sym-result "pos"))))))))

(defn lang-target [^String lang-text]
  (let [sp (str/index-of lang-text "/")]
  (if (nil? sp) nil (subs lang-text (+ sp 1)))))

(defn parse-lang-line [^String src]
  (let [len (count src)]
  (if (str/starts-with? src "#lang") (loop [i 5]
  (if (or (>= i len) (newline? (char-at src i))) {"target" (lang-target (str/trim (substring2 src 5 i))) "pos" (if (and (< i len) (= (char-at src i) "\n")) (+ i 1) i)} (recur (+ i 1)))) {"target" nil "pos" 0})))

(defn read-all [^String src]
  (let [lang-info (parse-lang-line src)
   target (get lang-info "target")
   start-pos (get lang-info "pos")]
  (loop [p (skip-ws src start-pos)
   datums []]
  (if (>= p (count src)) {"target" target "datums" datums} (let [result (read-datum src p)]
  (if (nil? result) {"target" target "datums" datums} (recur (skip-ws src (get result "pos")) (conj datums (get result "value")))))))))

(defn read-program [^String src]
  (get (read-all src) "datums"))

(def passes (atom []))

(def failures (atom []))

(defn- expect! [^String label ^Boolean result]
  (if result (do
  (swap! passes conj true)
  nil) (do
  (swap! failures conj label)
  nil)))

(defn- rd [^String src]
  (get (read-all src) "datums"))

(defn- rd1 [^String src]
  (nth (rd src) 0))

(defn run-tests! []
  (reset! passes [])
  (reset! failures [])
  (expect! "number: integer" (= (rd1 "42") 42))
  (expect! "number: float" (= (rd1 "3.14") 3.14))
  (expect! "number: negative" (= (rd1 "-7") -7))
  (expect! "number: negative float" (= (rd1 "-3.14") -3.14))
  (expect! "boolean: true" (= (rd1 "true") true))
  (expect! "boolean: false" (= (rd1 "false") false))
  (expect! "symbol" (= (rd1 "foo") "foo"))
  (expect! "nil symbol" (= (rd1 "nil") "nil"))
  (expect! "keyword" (= (rd1 ":name") ":name"))
  (expect! "standalone colon" (= (rd1 ":") ":"))
  (expect! "type marker :-" (= (rd1 ":-") ":-"))
  (expect! "string literal" (= (rd1 "\"hello\"") [STRING-TAG "hello"]))
  (expect! "string with escapes" (= (rd1 "\"a\\nb\"") [STRING-TAG "a\nb"]))
  (expect! "string with tab" (= (rd1 "\"a\\tb\"") [STRING-TAG "a\tb"]))
  (expect! "string with escaped quote" (= (rd1 "\"say \\\"hi\\\"\"") [STRING-TAG "say \"hi\""]))
  (expect! "string with \\u0001 escape" (= (rd1 "\"\\u0001\"") [STRING-TAG "\u0001"]))
  (expect! "\\uXXXX in context" (= (rd1 "\"a\\u0041b\"") [STRING-TAG "aAb"]))
  (expect! "\\uXXXX yields real control char (len 1)" (= (count (nth (rd1 "\"\\u0001\"") 1)) 1))
  (expect! "1.0 stays float (not int)" (not (= (rd1 "1.0") 1)))
  (expect! "1.0 equals 1.0 float" (= (rd1 "1.0") 1.0))
  (expect! "1 stays int" (= (rd1 "1") 1))
  (expect! "exponent 1e5" (= (rd1 "1e5") 100000.0))
  (expect! "exponent 1E5 upper" (= (rd1 "1E5") 100000.0))
  (expect! "float exponent 1.5e-3" (= (rd1 "1.5e-3") 0.0015))
  (expect! "negative exponent -2e3" (= (rd1 "-2e3") -2000.0))
  (expect! "exponent classifies as float" (not (= (rd1 "1e2") 100)))
  (expect! "simple list" (= (rd1 "(+ 1 2)") ["+" 1 2]))
  (expect! "nested list" (= (rd1 "(+ (* 2 3) 4)") ["+" ["*" 2 3] 4]))
  (expect! "bracket vector" (= (rd1 "[1 2 3]") [BRACKET-TAG 1 2 3]))
  (expect! "map literal" (= (rd1 "{:a 1 :b 2}") [MAP-TAG ":a" 1 ":b" 2]))
  (expect! "set literal" (= (rd1 "#{1 2 3}") [SET-TAG 1 2 3]))
  (expect! "regex literal" (= (rd1 "#\"[a-z]+\"") [REGEX-TAG "[a-z]+"]))
  (expect! "regex preserves backslash" (= (rd1 "#\"\\d+\"") [REGEX-TAG "\\d+"]))
  (expect! "quote" (= (rd1 "'foo") ["quote" "foo"]))
  (expect! "deref" (= (rd1 "@state") ["deref" "state"]))
  (expect! "quasiquote" (= (rd1 "`foo") ["quasiquote" "foo"]))
  (expect! "line comment skipped" (= (rd "; ignore\n42") [42]))
  (expect! "inline comment" (= (rd "1 ; comment\n2") [1 2]))
  (expect! "multiple comment lines" (= (rd ";; first\n;; second\n42") [42]))
  (expect! "#lang beagle/clj" (= (get (read-all "#lang beagle/clj\n") "target") "clj"))
  (expect! "#lang beagle/js" (let [result (read-all "#lang beagle/js\n(ns app)")]
  (and (= (get result "target") "js") (= (get result "datums") [["ns" "app"]]))))
  (expect! "no #lang" (let [result (read-all "(ns app)")]
  (and (nil? (get result "target")) (= (get result "datums") [["ns" "app"]]))))
  (expect! "defn form flat params" (let [result (rd1 "(defn foo [x :- Int] :- String x)")]
  (and (= (nth result 0) "defn") (= (nth result 1) "foo") (= (nth result 2) [BRACKET-TAG "x" ":-" "Int"]) (= (nth result 3) ":-") (= (nth result 4) "String") (= (nth result 5) "x"))))
  (expect! "defrecord flat fields" (let [result (rd1 "(defrecord Point [x :- Int y :- Int])")]
  (and (= (nth result 0) "defrecord") (= (nth result 1) "Point") (= (nth result 2) [BRACKET-TAG "x" ":-" "Int" "y" ":-" "Int"]))))
  (expect! "def with string value" (let [result (rd1 "(def greeting :- String \"hello\")")]
  (and (= (nth result 0) "def") (= (nth result 1) "greeting") (= (nth result 2) ":-") (= (nth result 3) "String") (= (nth result 4) [STRING-TAG "hello"]))))
  (expect! "declare-extern with fn type" (let [result (rd1 "(declare-extern fetch [String -> (Promise Any)])")]
  (and (= (nth result 0) "declare-extern") (= (nth result 1) "fetch") (= (nth result 2) [BRACKET-TAG "String" "->" ["Promise" "Any"]]))))
  (expect! "method call" (= (rd1 "(.toString x)") [".toString" "x"]))
  (expect! "property access" (= (rd1 "(.-length arr)") [".-length" "arr"]))
  (expect! "static call" (= (rd1 "(Math/abs x)") ["Math/abs" "x"]))
  (expect! "qualified require alias" (= (rd1 "(:tx a)") [":tx" "a"]))
  (expect! "threading macro" (= (rd1 "(-> x inc str)") ["->" "x" "inc" "str"]))
  (expect! "negative number in list" (= (rd1 "(+ x -5)") ["+" "x" -5]))
  (expect! "minus as symbol" (= (rd1 "(- 5 3)") ["-" 5 3]))
  (expect! "dot method symbol" (= (rd1 ".charAt") ".charAt"))
  (expect! "dynamic var" (= (rd1 "*state*") "*state*"))
  (expect! "constructor symbol" (= (rd1 "Point.") "Point."))
  (expect! "empty list" (= (rd1 "()") []))
  (expect! "empty vector" (= (rd1 "[]") [BRACKET-TAG]))
  (expect! "empty map" (= (rd1 "{}") [MAP-TAG]))
  (expect! "multiple top-level forms" (let [result (rd "(def x 1)\n(def y 2)")]
  (and (= (count result) 2) (= (nth (nth result 0) 1) "x") (= (nth (nth result 1) 1) "y"))))
  (expect! "string in list" (let [result (rd1 "(str \"hello\" \" world\")")]
  (and (= (nth result 0) "str") (= (nth result 1) [STRING-TAG "hello"]) (= (nth result 2) [STRING-TAG " world"]))))
  (expect! "keyword :else in map" (= (rd1 "{:else true}") [MAP-TAG ":else" true]))
  (expect! "str concat call" (let [result (rd1 "(str \"Hello, \" name \"!\")")]
  (and (= (nth result 0) "str") (= (nth result 1) [STRING-TAG "Hello, "]) (= (nth result 2) "name") (= (nth result 3) [STRING-TAG "!"]))))
  (expect! "full clj header" (let [result (read-all "#lang beagle/clj\n(ns app.main)\n(define-mode strict)")]
  (and (= (get result "target") "clj") (= (count (get result "datums")) 2) (= (nth (nth (get result "datums") 0) 0) "ns") (= (nth (nth (get result "datums") 1) 0) "define-mode"))))
  (expect! "read-program returns datum vector" (= (read-program "#lang beagle/clj\n(ns app)\n(def x 1)") [["ns" "app"] ["def" "x" 1]]))
  (expect! "read-datum returns value+pos" (let [r (read-datum "42 rest" 0)]
  (and (= (get r "value") 42) (= (get r "pos") 2))))
  (doseq [f (deref failures)]
  (selfhost.rt/eprint (str "  FAIL: " f "\n")))
  (println (str "  READER: " (count (deref passes)) " passed, " (count (deref failures)) " failed"))
  (count (deref failures)))
