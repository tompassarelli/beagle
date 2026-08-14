(ns selfhost.emit-clj
  (:require [clojure.string :as str]))

(def record-fields (atom {}))

(def scalar-fns (atom {}))

(def match-counter (atom 0))

(def emit-target (atom "clj"))

(def checked-program-ref (atom false))

(def ^String CLJ-HOST-REST "$beagle$rest$host")

(def loop-constraint-arity (atom nil))

(def emit-expr-ref (atom nil))

(defn ^String emit-expr* [e]
  (let [f (deref emit-expr-ref)]
  (f e)))

(def ^String HEX-DIGITS "0123456789abcdef")

(defn ^String hex4 [code]
  (str "00" (subs HEX-DIGITS (quot code 16) (+ (quot code 16) 1)) (subs HEX-DIGITS (mod code 16) (+ (mod code 16) 1))))

(defn ^String escape-char [^String c]
  (let [cs c
   code (int (first cs))]
  (cond
  (= c "\"") "\\\""
  (= c "\\") "\\\\"
  (= code 8) "\\b"
  (= code 9) "\\t"
  (= code 10) "\\n"
  (= code 12) "\\f"
  (= code 13) "\\r"
  (or (< code 32) (= code 127)) (str "\\u" (hex4 code))
  :else c)))

(defn ^String write-clj-string [^String s]
  (let [n (count s)]
  (loop [i 0
   acc ["\""]]
  (if (>= i n) (str/join "" (conj acc "\"")) (recur (+ i 1) (conj acc (escape-char (subs s i (+ i 1)))))))))

(defn ^String emit-float [v]
  (let [s (str v)]
  (if (or (str/includes? s ".") (str/includes? s "E") (str/includes? s "e")) s (str s ".0"))))

(defn clj-tag-for-type [t]
  (if (or (nil? t) (not (= (get t "kind") "prim"))) nil (let [n (get t "name")]
  (cond
  (= n "Bool") "Boolean"
  (= n "String") "String"
  (= n "Char") "Character"
  (= n "Int") nil
  (= n "Float") nil
  (= n "Nil") nil
  (= n "Any") nil
  :else (if (contains? (deref record-fields) n) n nil)))))

(defn ^String clj-tag-prefix [t]
  (let [tag (clj-tag-for-type t)]
  (if (nil? tag) "" (str "^" tag " "))))

(defn param-binding-target [p]
  (if (= (get p "type") "param") (get p "name") p))

(defn ^String emit-binding-form [target]
  (if (string? target) target (let [t (get target "type")]
  (cond
  (= t "map-destructure") (let [keys-str (str/join " " (get target "keys"))
   as (get target "as")
   defaults (get target "or")
   default-str (if (> (count defaults) 0) (str " :or {" (str/join " " (mapv (fn [entry] (str (get entry "key") " " (emit-expr* (get entry "value")))) defaults)) "}") "")]
  (str "{:keys [" keys-str "]" default-str (if as (str " :as " as) "") "}"))
  (= t "seq-destructure") (let [names (str/join " " (mapv emit-binding-form (get target "names")))
   rest-name (get target "rest")]
  (if rest-name (str "[" names " & " rest-name "]") (str "[" names "]")))
  :else "_"))))

(defn ^String emit-param [p]
  (let [target (param-binding-target p)]
  (if (and (= (get p "type") "param") (string? target)) (str (clj-tag-prefix (get p "ann")) target) (emit-binding-form target))))

(defn ^String emit-params-with-rest [params rest-p]
  (let [fixed (str/join " " (mapv emit-param params))]
  (if rest-p (if (= fixed "") (str "& " (emit-binding-form (param-binding-target rest-p))) (str fixed " & " (emit-binding-form (param-binding-target rest-p)))) fixed)))

(defn ^String emit-binding-target! [target]
  (emit-binding-form (param-binding-target target)))

(defn checked-binding-constraint [binding]
  (let [constraint (get binding "constraint")
   present? (and (not (nil? constraint)) (not (false? constraint)))]
  (if (deref checked-program-ref) (do
  (if (not (contains? binding "constraint")) (do
  (throw (ex-info "checked binding declaration lacks its constraint field" {}))))
  (if (not (contains? binding "constraintSynchronous")) (do
  (throw (ex-info "checked binding declaration lacks its constraintSynchronous proof" {}))))
  (let [synchronous? (get binding "constraintSynchronous")]
  (if (not (boolean? synchronous?)) (do
  (throw (ex-info "checked binding declaration has an invalid constraintSynchronous proof" {}))))
  (if (not (= synchronous? present?)) (do
  (throw (ex-info "checked binding declaration constraintSynchronous does not match its constraint" {})))))))
  (if present? constraint nil)))

(defn ^Boolean constraint-present? [binding]
  (not (nil? (checked-binding-constraint binding))))

(defn binding-target [binding]
  (cond
  (= (get binding "type") "param") (get binding "name")
  (= (get binding "type") "binding") (get binding "name")
  (contains? binding "value") (get binding "name")
  :else (param-binding-target binding)))

(defn ^String binding-target-label [binding]
  (emit-binding-form (binding-target binding)))

(defn ^String binding-constraint-failure [binding ^String raw-name]
  (let [label (binding-target-label binding)]
  (str "(throw (ex-info " (write-clj-string (str "Binding constraint failed: " label)) " {:binding " (write-clj-string label) " :value " raw-name "}))")))

(defn ^String emit-guarded-binding-value [binding ^String predicate-name ^String raw-name]
  (str "(if (" predicate-name " " raw-name ") " raw-name " " (binding-constraint-failure binding raw-name) ")"))

(defn ^Boolean bindings-have-constraints? [bindings]
  (> (count (filterv constraint-present? bindings)) 0))

(defn params+rest [params rest-p]
  (if (or (nil? rest-p) (false? rest-p)) (vec params) (conj (vec params) rest-p)))

(defn ^Boolean callable-has-constraints? [params rest-p]
  (bindings-have-constraints? (params+rest params rest-p)))

(defn ^String callable-raw-name [index fixed-count]
  (if (= index fixed-count) "$beagle$constraint$raw-rest" (str "$beagle$constraint$raw-param$" index)))

(defn emit-constrained-callable [params rest-p ^String body-str]
  (let [all (params+rest params rest-p)
   fixed-count (count params)
   raw-names (mapv (fn [index] (callable-raw-name index fixed-count)) (range (count all)))
   fixed-raw (mapv (fn [index] (let [raw (nth raw-names index)
   param (nth params index)
   target (param-binding-target param)]
  (if (and (= (get param "type") "param") (string? target)) (str (clj-tag-prefix (get param "ann")) raw) raw))) (range fixed-count))
   params-str (str/join " " (if (or (nil? rest-p) (false? rest-p)) fixed-raw (into fixed-raw ["&" CLJ-HOST-REST])))
   rest-normalization (if (or (nil? rest-p) (false? rest-p)) [] [(str (nth raw-names fixed-count) " (vec " CLJ-HOST-REST ")")])
   predicate-bindings (loop [index 0
   acc []]
  (if (>= index (count all)) acc (let [binding (nth all index)]
  (recur (+ index 1) (if (constraint-present? binding) (conj acc (str "$beagle$constraint$predicate$" index " " (emit-expr* (checked-binding-constraint binding)))) acc)))))
   checked-bindings (mapv (fn [index] (let [binding (nth all index)
   raw (nth raw-names index)
   checked (str "$beagle$constraint$checked-param$" index)]
  (str checked " " (if (constraint-present? binding) (emit-guarded-binding-value binding (str "$beagle$constraint$predicate$" index) raw) raw)))) (range (count all)))
   target-bindings (mapv (fn [index] (str (emit-binding-form (binding-target (nth all index))) " " "$beagle$constraint$checked-param$" index)) (range (count all)))]
  {"params" params-str "body" (str "(let [" (str/join "\n       " (into rest-normalization predicate-bindings)) "]\n" "  (let [" (str/join "\n       " checked-bindings) "]\n" "    (let [" (str/join "\n       " target-bindings) "]\n" "      " body-str ")))")}))

(defn emit-callable-signature+body [params rest-p ^String body-str]
  (if (callable-has-constraints? params rest-p) (emit-constrained-callable params rest-p body-str) (let [fixed (emit-params-with-rest params nil)
   params-str (if (or (nil? rest-p) (false? rest-p)) fixed (if (= fixed "") (str "& " CLJ-HOST-REST) (str fixed " & " CLJ-HOST-REST)))]
  {"params" params-str "body" (if (or (nil? rest-p) (false? rest-p)) body-str (str "(let [" (emit-binding-form (binding-target rest-p)) " (vec " CLJ-HOST-REST ")]\n  " body-str ")"))})))

(defn ^String emit-body-with-loop-context! [exprs ^String indent context]
  (let [previous (deref loop-constraint-arity)]
  (reset! loop-constraint-arity context)
  (let [result (str/join (str "\n" indent) (mapv emit-expr* exprs))]
  (reset! loop-constraint-arity previous)
  result)))

(defn ^String emit-let-bindings! [bindings]
  (str/join "\n   " (loop [index 0
   acc []]
  (if (>= index (count bindings)) acc (let [b (nth bindings index)
   target (emit-binding-target! (get b "name"))
   value (emit-expr* (get b "value"))]
  (if (constraint-present? b) (let [raw-name (str "$beagle$constraint$raw-binding$" index)
   predicate-name (str "$beagle$constraint$predicate$" index)]
  (recur (+ index 1) (into acc [(str raw-name " " value) (str predicate-name " " (emit-expr* (checked-binding-constraint b))) (str target " " (emit-guarded-binding-value b predicate-name raw-name))]))) (recur (+ index 1) (conj acc (str target " " value)))))))))

(defn ^String emit-with-open-chain! [bindings ^String body-str index]
  (if (= 0 (count bindings)) body-str (let [b (nth bindings 0)
   target (emit-binding-target! (get b "name"))
   value (emit-expr* (get b "value"))
   inner (emit-with-open-chain! (subvec (vec bindings) 1) body-str (+ index 1))]
  (if (constraint-present? b) (let [predicate-name (str "$beagle$constraint$predicate$" index)
   raw-name (str "$beagle$constraint$raw-open$" index)]
  (str "(with-open [" raw-name " " value "]\n" "  (let [" predicate-name " " (emit-expr* (checked-binding-constraint b)) "\n" "        " target " " (emit-guarded-binding-value b predicate-name raw-name) "]\n" "    " inner "))")) (str "(with-open [" target " " value "]\n  " inner ")")))))

(defn ^String emit-dynamic-binding-chain! [bindings ^String body-str]
  (let [capture-bindings (loop [index 0
   acc []]
  (if (>= index (count bindings)) acc (let [binding (nth bindings index)
   raw-name (str "$beagle$constraint$raw-dynamic$" index)
   base (conj acc (str raw-name " " (emit-expr* (get binding "value"))))]
  (if (constraint-present? binding) (let [predicate-name (str "$beagle$constraint$predicate$" index)]
  (recur (+ index 1) (into base [(str predicate-name " " (emit-expr* (checked-binding-constraint binding))) (str "$beagle$constraint$checked-dynamic$" index " " (emit-guarded-binding-value binding predicate-name raw-name))]))) (recur (+ index 1) base)))))
   dynamic-bindings (mapv (fn [index] (let [binding (nth bindings index)]
  (str (emit-binding-target! (get binding "name")) " " (if (constraint-present? binding) (str "$beagle$constraint$checked-dynamic$" index) (str "$beagle$constraint$raw-dynamic$" index))))) (range (count bindings)))]
  (str "(let [" (str/join "\n       " capture-bindings) "]\n" "  (binding [" (str/join "\n            " dynamic-bindings) "]\n" "    " body-str "))")))

(defn ^String emit-for-clauses! [clauses]
  (str/join "\n   " (loop [index 0
   acc []]
  (if (>= index (count clauses)) acc (let [c (nth clauses index)
   t (get c "type")]
  (cond
  (= t "binding") (if (constraint-present? c) (let [raw-name (str "$beagle$constraint$raw-for$" index)
   predicate-name (str "$beagle$constraint$predicate$" index)]
  (recur (+ index 1) (into acc [(str raw-name " " (emit-expr* (get c "expr"))) (str ":let [" predicate-name " " (emit-expr* (checked-binding-constraint c)) "\n" "         " (emit-binding-target! (get c "name")) " " (emit-guarded-binding-value c predicate-name raw-name) "]")]))) (recur (+ index 1) (conj acc (str (emit-binding-target! (get c "name")) " " (emit-expr* (get c "expr"))))))
  (= t "when") (recur (+ index 1) (conj acc (str ":when " (emit-expr* (get c "test")))))
  (= t "let") (recur (+ index 1) (conj acc (str ":let [" (emit-let-bindings! (get c "bindings")) "]")))
  :else (recur (+ index 1) acc)))))))

(defn ^String emit-loop-with-constraints! [e]
  (let [bindings (get e "bindings")]
  (if (not (bindings-have-constraints? bindings)) (str "(loop [" (emit-let-bindings! bindings) "]\n  " (emit-body-with-loop-context! (get e "body") "  " nil) ")") (let [raw-names (mapv (fn [index] (str "$beagle$constraint$raw-loop$" index)) (range (count bindings)))
   init-bindings (loop [index 0
   acc []]
  (if (>= index (count bindings)) acc (let [binding (nth bindings index)
   raw (nth raw-names index)
   target (emit-binding-target! (get binding "name"))
   base (conj acc (str raw " " (emit-expr* (get binding "value"))))]
  (if (constraint-present? binding) (let [predicate-name (str "$beagle$constraint$init-predicate$" index)]
  (recur (+ index 1) (into base [(str predicate-name " " (emit-expr* (checked-binding-constraint binding))) (str target " " (emit-guarded-binding-value binding predicate-name raw))]))) (recur (+ index 1) (conj base (str target " " raw)))))))
   iteration-bindings (mapv (fn [index] (let [binding (nth bindings index)
   raw (nth raw-names index)
   target (emit-binding-target! (get binding "name"))]
  (str target " " (if (constraint-present? binding) (str "(if $beagle$constraint$first-iteration " raw " " "(let [$beagle$constraint$predicate$" index " " (emit-expr* (checked-binding-constraint binding)) "] " (emit-guarded-binding-value binding (str "$beagle$constraint$predicate$" index) raw) "))") raw)))) (range (count bindings)))
   loop-bindings (mapv (fn [index] (str (nth raw-names index) " (nth $beagle$constraint$initial-values " index ")")) (range (count bindings)))
   body (emit-body-with-loop-context! (get e "body") "    " (count bindings))]
  (str "(let [$beagle$constraint$initial-values (let [" (str/join "\n       " init-bindings) "] [" (str/join " " raw-names) "])]\n" "  (loop [" (str/join " " loop-bindings) " $beagle$constraint$first-iteration true]\n" "    (let [" (str/join "\n         " iteration-bindings) "]\n" "      " body ")))")))))

(defn ^String emit-body [exprs ^String indent]
  (str/join (str "\n" indent) (mapv emit-expr* exprs)))

(defn ^String emit-args [args]
  (if (= (count args) 0) "" (str " " (str/join " " (mapv emit-expr* args)))))

(defn ^String datum-clj [d]
  (cond
  (string? d) (write-clj-string d)
  (boolean? d) (if d "true" "false")
  (number? d) (if (double? d) (emit-float d) (str d))
  (and (map? d) (= (get d "type") "symbol")) (get d "value")
  (and (map? d) (= (get d "type") "keyword")) (str ":" (get d "value"))
  (vector? d) (cond
  (and (> (count d) 0) (= (nth d 0) "#%brackets")) (str "[" (str/join " " (mapv datum-clj (subvec d 1))) "]")
  (and (> (count d) 0) (= (nth d 0) "#%map")) (str "{" (str/join " " (mapv datum-clj (subvec d 1))) "}")
  (and (> (count d) 0) (= (nth d 0) "#%set")) (str "#{" (str/join " " (mapv datum-clj (subvec d 1))) "}")
  :else (str "(" (str/join " " (mapv datum-clj d)) ")"))
  (nil? d) "nil"
  :else (str d)))

(defn ^String emit-quoted-top [d]
  (if (and (vector? d) (> (count d) 0) (or (= (nth d 0) "#%brackets") (= (nth d 0) "#%map") (= (nth d 0) "#%set"))) (datum-clj d) (str "'" (datum-clj d))))

(defn ^String last-dot-segment [^String s]
  (let [idx (str/last-index-of s ".")]
  (if (nil? idx) s (subs s (+ idx 1)))))

(defn ^String emit-require [r]
  (let [ns-name (get r "ns")
   refer (get r "refer")
   alias0 (get r "alias")
   alias (if (or (nil? alias0) (false? alias0)) (if refer nil (last-dot-segment ns-name)) alias0)]
  (str "[" ns-name (if (nil? alias) "" (str " :as " alias)) (if (and refer (> (count refer) 0)) (str " :refer [" (str/join " " refer) "]") "") "]")))

(defn ^String emit-import [^String class-name]
  (let [idx (str/last-index-of class-name ".")]
  (if (nil? idx) class-name (str "[" (subs class-name 0 idx) " " (subs class-name (+ idx 1)) "]"))))

(defn ^Boolean has-clojure-string? [rs]
  (> (count (filterv (fn [r] (= "clojure.string" (get r "ns"))) rs)) 0))

(defn ^String emit-ns-form [prog ^String body]
  (let [needs (some? (re-find #"[( \t\n]str/" body))
   rs0 (vec (get prog "requires"))
   rs (if (and needs (not (has-clojure-string? rs0))) (conj rs0 {"ns" "clojure.string" "alias" "str" "refer" nil}) rs0)
   ns-name (get prog "namespace")
   gen-class (get prog "gen-class")
   req-clause (if (= 0 (count rs)) nil (str "(:require " (str/join "\n            " (mapv emit-require rs)) ")"))
   imports (vec (get prog "imports"))
   import-clause (if (= 0 (count imports)) nil (str "(:import " (str/join "\n           " (mapv emit-import imports)) ")"))
   clauses (filterv some? [(if gen-class "(:gen-class)" nil) req-clause import-clause])]
  (if (= 0 (count clauses)) (str "(ns " ns-name ")") (str "(ns " ns-name "\n  " (str/join "\n  " clauses) ")"))))

(defn field-names-of [fields]
  (mapv (fn [f] (get f "name")) fields))

(defn ^String unqualify-name [^String name]
  (let [index (str/last-index-of name "/")]
  (if (nil? index) name (subs name (+ index 1)))))

(defn ^String record-validator-name [^String name]
  (str "$beagle$record$" (unqualify-name name) "$validate"))

(defn emit-record-constructor-guards [^String name fields]
  (let [constrained (filterv (fn [entry] (constraint-present? (nth entry 1))) (mapv (fn [index] [index (nth fields index)]) (range (count fields))))]
  (if (= 0 (count constrained)) [] (let [positional (str "->" name)
   map-factory (str "map->" name)
   raw-positional (str "$beagle$record$" name "$raw-constructor")
   raw-map (str "$beagle$record$" name "$raw-map-constructor")
   validator (record-validator-name name)
   guarded (emit-callable-signature+body fields false (str "(" raw-positional (if (= 0 (count fields)) "" (str " " (str/join " " (field-names-of fields)))) ")"))
   validation-bindings (loop [i 0
   acc []]
  (if (>= i (count constrained)) acc (let [entry (nth constrained i)
   index (nth entry 0)
   field (nth entry 1)
   field-name (get field "name")
   raw-name (str "$beagle$record$field$" index)
   predicate-name (str "$beagle$record$constraint$" index)
   checked-name (str "$beagle$record$checked-field$" index)]
  (recur (+ i 1) (into acc [(str raw-name " (:" field-name " $beagle$record$value)") (str predicate-name " " (emit-expr* (checked-binding-constraint field))) (str checked-name " " (emit-guarded-binding-value field predicate-name raw-name))])))))]
  [(str "(def ^:private " raw-positional " " positional ")") (str "(def ^:private " raw-map " " map-factory ")") (str "(defn " validator " [$beagle$record$value]\n" "  (let [" (str/join "\n       " validation-bindings) "]\n" "    $beagle$record$value))") (str "(defn " positional " [" (get guarded "params") "]\n" "  " (get guarded "body") ")") (str "(defn " map-factory " [$beagle$record$raw-map]\n" "  (" raw-map " (" validator " $beagle$record$raw-map)))")]))))

(defn ^String emit-record-form [e]
  (let [name (get e "name")
   fields (get e "fields")
   fnames (field-names-of fields)
   name-lower (str/lower-case name)
   record-line (str "(defrecord " name " [" (str/join " " fnames) "])")
   accessors (mapv (fn [^String fname] (str "(defn " name-lower "-" fname " [r] (:" fname " r))")) fnames)]
  (str/join "\n\n" (into (into [record-line] (emit-record-constructor-guards name fields)) accessors))))

(defn ^String emit-defenum [e]
  (let [vals-str (str/join " " (mapv (fn [v] (str ":" v)) (get e "values")))]
  (str "(def " (get e "name") "-values #{" vals-str "})")))

(defn ^String emit-variant-defrecord [^String m fields]
  (let [fnames (field-names-of fields)
   m-lower (str/lower-case m)
   record-line (str "(defrecord " m " [" (str/join " " fnames) "])")
   accessors (mapv (fn [^String fname] (str "(defn " m-lower "-" fname " [r] (:" fname " r))")) fnames)]
  (str/join "\n\n" (into (into [record-line] (emit-record-constructor-guards m fields)) accessors))))

(defn ^String emit-defunion! [e]
  (let [comment (str ";; " (get e "name") " = " (str/join " | " (get e "members")))
   mf (get e "member-fields")]
  (if (nil? mf) comment (str comment "\n" (str/join "\n" (mapv (fn [^String m] (emit-variant-defrecord m (vec (get mf m)))) (get e "members")))))))

(defn ^String emit-deferror! [e]
  (let [comment (str ";; error " (get e "name") " = " (str/join " | " (get e "members")))
   mf (get e "member-fields")]
  (if (nil? mf) comment (str comment "\n" (str/join "\n" (mapv (fn [^String m] (emit-variant-defrecord m (vec (get mf m)))) (get e "members")))))))

(defn ^String scalar-backing-label [backing]
  (let [name (get backing "name")]
  (if (string? name) name (str backing))))

(defn ^String emit-defscalar [e]
  (let [name (get e "name")
   predicates (vec (get e "predicates"))]
  (if (= 0 (count predicates)) (str ";; " name " : " (scalar-backing-label (get e "backing")) " (scalar)") (let [pre-exprs (mapv (fn [predicate] (let [value (get predicate "value")]
  (str "(" (get predicate "op") " v " (if (double? value) (emit-float value) (str value)) ")"))) predicates)]
  (str "(defn ->" name " [v]\n" "  {:pre [" (str/join " " pre-exprs) "]}\n" "  v)")))))

(defn ^String protocol-raw-method-name [^String protocol-name ^String method-name]
  (str "$beagle$protocol$" (unqualify-name protocol-name) "$" method-name))

(defn ^String emit-protocol-wrapper [^String protocol-name method]
  (let [params (get method "params")
   rest-p (get method "rest")
   all (params+rest params rest-p)
   fixed-count (count params)
   raw-names (mapv (fn [index] (callable-raw-name index fixed-count)) (range (count all)))
   rest-normalization (if (or (nil? rest-p) (false? rest-p)) [] [(str (nth raw-names fixed-count) " (vec " CLJ-HOST-REST ")")])
   predicate-bindings (loop [index 0
   acc []]
  (if (>= index (count all)) acc (let [param (nth all index)]
  (recur (+ index 1) (if (constraint-present? param) (conj acc (str "$beagle$constraint$predicate$" index " " (emit-expr* (checked-binding-constraint param)))) acc)))))
   checked-names (mapv (fn [index] (str "$beagle$constraint$checked-param$" index)) (range (count all)))
   checked-bindings (mapv (fn [index] (let [param (nth all index)
   raw (nth raw-names index)]
  (str (nth checked-names index) " " (if (constraint-present? param) (emit-guarded-binding-value param (str "$beagle$constraint$predicate$" index) raw) raw)))) (range (count all)))
   call-args (if (= 0 (count predicate-bindings)) raw-names checked-names)
   raw-method (protocol-raw-method-name protocol-name (get method "name"))
   call (if (or (nil? rest-p) (false? rest-p)) (str "(" raw-method (if (= 0 (count call-args)) "" (str " " (str/join " " call-args))) ")") (str "(apply " raw-method " " (str/join " " call-args) ")"))
   signature (str/join " " (if (or (nil? rest-p) (false? rest-p)) (subvec raw-names 0 fixed-count) (into (subvec raw-names 0 fixed-count) ["&" CLJ-HOST-REST])))]
  (str "(defn " (get method "name") " [" signature "]\n  " (cond
  (and (= 0 (count rest-normalization)) (= 0 (count predicate-bindings))) call
  (= 0 (count predicate-bindings)) (str "(let [" (str/join "\n       " rest-normalization) "]\n" "    " call ")")
  :else (str "(let [" (str/join "\n       " (into rest-normalization predicate-bindings)) "]\n" "    (let [" (str/join "\n         " checked-bindings) "]\n" "      " call "))")) ")")))

(defn ^String emit-protocol [e]
  (let [protocol-name (get e "name")
   methods (get e "methods")
   raw-sigs (mapv (fn [method] (let [params (get method "params")
   rest-p (get method "rest")
   fixed (mapv (fn [index] (str "$beagle$constraint$raw-param$" index)) (range (count params)))
   all (if (or (nil? rest-p) (false? rest-p)) fixed (into fixed ["&" "$beagle$constraint$raw-rest"]))]
  (str "(" (protocol-raw-method-name protocol-name (get method "name")) " [" (str/join " " all) "])"))) methods)]
  (str "(defprotocol " protocol-name "\n  " (str/join "\n  " raw-sigs) ")\n\n" (str/join "\n\n" (mapv (fn [method] (emit-protocol-wrapper protocol-name method)) methods)))))

(defn ^String emit-type-impl! [impl]
  (let [protocol-name (get impl "protocol")
   method-lines (mapv (fn [method] (let [body (emit-body-with-loop-context! (get method "body") "    " nil)
   callable (emit-callable-signature+body (get method "params") (get method "rest") body)]
  (str "(" (protocol-raw-method-name protocol-name (get method "name")) " [" (get callable "params") "]\n" "    " (get callable "body") ")"))) (get impl "methods"))]
  (str protocol-name "\n  " (str/join "\n  " method-lines))))

(defn ^String emit-extend-type [e]
  (str "(extend-type " (get e "type-name") "\n  " (str/join "\n  " (mapv emit-type-impl! (get e "impls"))) ")"))

(defn ^String fresh-match-sym! []
  (let [n (deref match-counter)]
  (swap! match-counter inc)
  (str "match__" n)))

(defn ^Boolean case-foldable-pattern? [pat]
  (let [t (get pat "type")]
  (cond
  (= t "literal") true
  (= t "or") (= 0 (count (filterv (fn [alt] (let [at (get alt "type")]
  (not (or (= at "literal") (= at "wildcard"))))) (get pat "alternatives"))))
  :else false)))

(defn ^Boolean case-foldable-match? [clauses]
  (let [n (count clauses)]
  (if (= n 0) false (let [cs (vec clauses)
   non-tail (subvec cs 0 (- n 1))
   tail-pat (get (nth cs (- n 1)) "pattern")
   tt (get tail-pat "type")
   bad (count (filterv (fn [c] (not (case-foldable-pattern? (get c "pattern")))) non-tail))]
  (and (= bad 0) (or (case-foldable-pattern? tail-pat) (= tt "wildcard") (= tt "var")))))))

(defn ^String emit-pat-literal-value [pat]
  (let [val (get pat "value")]
  (cond
  (and (map? val) (= (get val "type") "symbol")) (get val "value")
  (and (map? val) (= (get val "type") "keyword")) (str ":" (get val "value"))
  (string? val) (write-clj-string val)
  (boolean? val) (if val "true" "false")
  (number? val) (if (double? val) (emit-float val) (str val))
  :else (str val))))

(defn ^String emit-pat-literal-test [pat ^String target-sym]
  (let [val (get pat "value")]
  (cond
  (and (map? val) (= (get val "type") "symbol")) (let [s (get val "value")]
  (cond
  (= s "nil") (str "(nil? " target-sym ")")
  (str/starts-with? s ":") (str "(= " target-sym " " s ")")
  :else (str "(= " target-sym " " s ")")))
  (and (map? val) (= (get val "type") "keyword")) (str "(= " target-sym " :" (get val "value") ")")
  (string? val) (str "(= " target-sym " " (write-clj-string val) ")")
  (boolean? val) (if val (str "(true? " target-sym ")") (str "(false? " target-sym ")"))
  (number? val) (str "(= " target-sym " " (if (double? val) (emit-float val) (str val)) ")")
  :else (str "(= " target-sym " " val ")"))))

(defn ^String emit-case-folded-match [clauses ^String target-sym ^String target-str]
  (let [cs (vec clauses)
   n (count cs)
   tail (nth cs (- n 1))
   tail-pat (get tail "pattern")
   tt (get tail-pat "type")
   has-default (or (= tt "wildcard") (= tt "var"))
   dispatch (if has-default (subvec cs 0 (- n 1)) cs)
   clause-strs (mapv (fn [c] (let [pat (get c "pattern")
   body-str (emit-body (get c "body") "      ")
   key-str (if (= (get pat "type") "literal") (emit-pat-literal-value pat) (str "(" (str/join " " (mapv emit-pat-literal-value (filterv (fn [alt] (= (get alt "type") "literal")) (get pat "alternatives")))) ")"))]
  (str key-str " " body-str))) dispatch)
   default-str (cond
  (not has-default) ""
  (= tt "wildcard") (str "\n    " (emit-body (get tail "body") "      "))
  :else (str "\n    (let [" (get tail-pat "name") " " target-sym "] " (emit-body (get tail "body") "      ") ")"))]
  (str "(case " target-str "\n    " (str/join "\n    " clause-strs) default-str ")")))

(defn ^String emit-match-arm! [clause ^String target-sym]
  (let [pat (get clause "pattern")
   body-str (emit-body (get clause "body") "      ")
   pt (get pat "type")]
  (cond
  (= pt "wildcard") (str ":else " body-str)
  (= pt "var") (str ":else (let [" (get pat "name") " " target-sym "] " body-str ")")
  (= pt "literal") (str (emit-pat-literal-test pat target-sym) " " body-str)
  (= pt "or") (let [tests (mapv (fn [alt] (if (= (get alt "type") "wildcard") "true" (emit-pat-literal-test alt target-sym))) (get pat "alternatives"))]
  (str "(or " (str/join " " tests) ") " body-str))
  (= pt "record") (let [rec-name (get pat "name")
   bindings (vec (get pat "bindings"))
   fields (get (deref record-fields) rec-name)
   test (str "(instance? " rec-name " " target-sym ")")]
  (if (or (= 0 (count bindings)) (nil? fields)) (str test " " body-str) (let [pairs (loop [i 0
   acc []]
  (if (or (>= i (count bindings)) (>= i (count fields))) acc (recur (+ i 1) (conj acc (str (get (nth bindings i) "name") " (:" (nth fields i) " " target-sym ")")))))]
  (str test " (let [" (str/join " " pairs) "] " body-str ")"))))
  (= pt "map") (let [entries (vec (get pat "entries"))
   key-of (fn [en] (let [k (get en "key")]
  (if (map? k) (get k "value") (str k))))
   tests (mapv (fn [en] (str "(some? (" (key-of en) " " target-sym "))")) entries)
   test (if (= 1 (count tests)) (nth tests 0) (str "(and " (str/join " " tests) ")"))
   binds (mapv (fn [en] (str (get en "name") " (" (key-of en) " " target-sym ")")) entries)]
  (if (= 0 (count binds)) (str test " " body-str) (str test " (let [" (str/join " " binds) "] " body-str ")")))
  :else (str ":else " body-str))))

(defn ^String emit-match! [e]
  (let [target-str (emit-expr* (get e "target"))
   clauses (get e "clauses")]
  (if (case-foldable-match? clauses) (let [target-sym (fresh-match-sym!)]
  (emit-case-folded-match clauses target-sym target-str)) (let [target-sym (fresh-match-sym!)
   cond-pairs (mapv (fn [c] (emit-match-arm! c target-sym)) clauses)]
  (str "(let [" target-sym " " target-str "]\n  (cond\n    " (str/join "\n    " cond-pairs) "))")))))

(defn ^Boolean absent? [x]
  (or (nil? x) (false? x)))

(defn ^Boolean exact-object-keys? [value expected]
  (and (map? value) (= (count (keys value)) (count expected)) (every? (fn [^String key] (contains? value key)) expected)))

(defn ^Boolean valid-record-update-contract? [contract]
  (and (exact-object-keys? contract ["recordName" "fieldOrder" "validator"]) (string? (get contract "recordName")) (vector? (get contract "fieldOrder")) (every? string? (get contract "fieldOrder")) (or (nil? (get contract "validator")) (string? (get contract "validator")))))

(defn record-update-contract [node]
  (if (and (deref checked-program-ref) (not (contains? node "recordUpdate"))) (do
  (throw (ex-info "checked with node lacks its recordUpdate semantic contract" {}))))
  (let [contract (get node "recordUpdate")]
  (if (and (not (nil? contract)) (not (valid-record-update-contract? contract))) (do
  (throw (ex-info "checked with node has an invalid recordUpdate semantic contract" {}))))
  contract))

(defn record-field-access-contract [node]
  (if (and (deref checked-program-ref) (not (contains? node "recordFieldAccess"))) (do
  (throw (ex-info "checked kw-access lacks its recordFieldAccess semantic contract" {}))))
  (let [contract (get node "recordFieldAccess")]
  (if (and (not (nil? contract)) (not (and (exact-object-keys? contract ["recordName"]) (string? (get contract "recordName"))))) (do
  (throw (ex-info "checked kw-access has an invalid recordFieldAccess semantic contract" {}))))
  contract))

(defn ^Boolean else-less-if? [els]
  (or (nil? els) (false? els) (and (= (get els "node") "literal") (= (get els "kind") "bool") (false? (get els "value")))))

(defn ^String emit-char-lit [n]
  (cond
  (= n 32) "\\space"
  (= n 9) "\\tab"
  (= n 10) "\\newline"
  (= n 13) "\\return"
  (= n 12) "\\formfeed"
  (= n 8) "\\backspace"
  (and (>= n 33) (<= n 126)) (str "\\" (str (char n)))
  :else (str "\\u" (format "%04x" n))))

(defn ^String emit-expr! [e]
  (let [node (get e "node")]
  (cond
  (= node "literal") (let [kind (get e "kind")]
  (cond
  (= kind "string") (write-clj-string (get e "value"))
  (= kind "number") (str (get e "value"))
  (= kind "float") (emit-float (get e "value"))
  (= kind "bool") (if (get e "value") "true" "false")
  (= kind "nil") "nil"
  (= kind "keyword") (str ":" (get e "value"))
  (= kind "char") (emit-char-lit (get e "value"))
  :else "nil"))
  (= node "ref") (get e "name")
  (= node "def") (let [doc (get e "doc")]
  (str "(def " (if (= (get e "dynamic") true) "^:dynamic " "") (clj-tag-prefix (get e "ann")) (get e "name") (if (string? doc) (str " " (write-clj-string doc)) "") " " (emit-expr* (get e "value")) ")"))
  (= node "defonce") (let [doc (get e "doc")]
  (str "(defonce " (clj-tag-prefix (get e "ann")) (get e "name") (if (string? doc) (str " " (write-clj-string doc)) "") " " (emit-expr* (get e "value")) ")"))
  (= node "defn") (let [kw (if (get e "private") "defn-" "defn")
   name (get e "name")
   name-tag (clj-tag-prefix (get e "ret"))
   body (emit-body-with-loop-context! (get e "body") "  " nil)
   callable (emit-callable-signature+body (get e "params") (get e "rest") body)
   doc (get e "doc")]
  (str "(" kw " " name-tag name (if (string? doc) (str "\n  " (write-clj-string doc)) "") " [" (get callable "params") "]\n  " (get callable "body") ")"))
  (= node "defn-multi") (let [kw (if (get e "private") "defn-" "defn")
   name (get e "name")
   arity-strs (mapv (fn [a] (let [body (emit-body-with-loop-context! (get a "body") "    " nil)
   callable (emit-callable-signature+body (get a "params") (get a "rest") body)]
  (str "  ([" (get callable "params") "]\n    " (get callable "body") ")"))) (get e "arities"))
   doc (get e "doc")]
  (str "(" kw " " name (if (string? doc) (str "\n  " (write-clj-string doc)) "") "\n" (str/join "\n" arity-strs) ")"))
  (= node "fn") (let [body (emit-body-with-loop-context! (get e "body") "  " nil)
   callable (emit-callable-signature+body (get e "params") (get e "rest") body)]
  (str "(fn [" (get callable "params") "] " (get callable "body") ")"))
  (= node "let") (str "(let [" (emit-let-bindings! (get e "bindings")) "]\n  " (emit-body (get e "body") "  ") ")")
  (= node "if") (let [els (get e "else")]
  (if (else-less-if? els) (str "(if " (emit-expr* (get e "cond")) " " (emit-expr* (get e "then")) ")") (str "(if " (emit-expr* (get e "cond")) " " (emit-expr* (get e "then")) " " (emit-expr* els) ")")))
  (= node "when") (str "(when " (emit-expr* (get e "cond")) "\n  " (emit-body (get e "body") "  ") ")")
  (= node "when-let") (str "(when-let [" (get e "name") " " (emit-expr* (get e "expr")) "]\n  " (emit-body (get e "body") "  ") ")")
  (= node "when-some") (str "(when-some [" (get e "name") " " (emit-expr* (get e "expr")) "]\n  " (emit-body (get e "body") "  ") ")")
  (= node "if-let") (let [then-str (emit-expr* (get e "then"))
   els (get e "else")]
  (if (absent? els) (str "(if-let [" (get e "name") " " (emit-expr* (get e "expr")) "]\n  " then-str ")") (str "(if-let [" (get e "name") " " (emit-expr* (get e "expr")) "]\n  " then-str "\n  " (emit-expr* els) ")")))
  (= node "if-some") (let [then-str (emit-expr* (get e "then"))
   els (get e "else")]
  (if (else-less-if? els) (str "(if-some [" (get e "name") " " (emit-expr* (get e "expr")) "]\n  " then-str ")") (str "(if-some [" (get e "name") " " (emit-expr* (get e "expr")) "]\n  " then-str "\n  " (emit-expr* els) ")")))
  (= node "binding") (let [bindings (get e "bindings")
   body (emit-body (get e "body") "  ")]
  (if (bindings-have-constraints? bindings) (emit-dynamic-binding-chain! bindings body) (str "(binding [" (emit-let-bindings! bindings) "]\n  " body ")")))
  (= node "with-open") (let [bindings (get e "bindings")
   body (emit-body (get e "body") "  ")]
  (if (bindings-have-constraints? bindings) (emit-with-open-chain! bindings body 0) (str "(with-open [" (emit-let-bindings! bindings) "]\n  " body ")")))
  (= node "doto") (str "(doto " (emit-expr* (get e "target")) "\n  " (str/join "\n  " (mapv emit-expr* (get e "forms"))) ")")
  (= node "do") (str "(do\n  " (emit-body (get e "body") "  ") ")")
  (= node "cond") (let [pairs (mapv (fn [c] (let [test (get c "test")
   test-str (cond
  (and (= (get test "node") "literal") (= (get test "kind") "keyword") (= (get test "value") "else")) ":else"
  (and (= (get test "node") "ref") (= (get test "name") "else")) ":else"
  :else (emit-expr* test))]
  (str test-str " " (emit-body (get c "body") "  ")))) (get e "clauses"))]
  (str "(cond\n  " (str/join "\n  " pairs) ")"))
  (= node "loop") (emit-loop-with-constraints! e)
  (= node "recur") (let [args (get e "args")
   context (deref loop-constraint-arity)]
  (str "(recur" (emit-args args) (if (and (number? context) (= (count args) context)) " false" "") ")"))
  (= node "for") (str "(for [" (emit-for-clauses! (get e "clauses")) "]\n  " (emit-body (get e "body") "  ") ")")
  (= node "doseq") (str "(doseq [" (emit-for-clauses! (get e "clauses")) "]\n  " (emit-body (get e "body") "  ") ")")
  (= node "call") (let [fn-expr (get e "fn")
   args (get e "args")]
  (if (= (get fn-expr "node") "ref") (let [fname (get fn-expr "name")]
  (if (and (= 1 (count args)) (or (contains? (deref scalar-fns) fname) (= "bgl/promote" fname))) (emit-expr* (nth args 0)) (str "(" fname (emit-args args) ")"))) (str "(" (emit-expr* fn-expr) (emit-args args) ")")))
  (= node "vec") (str "[" (str/join " " (mapv emit-expr* (get e "items"))) "]")
  (= node "map") (let [strs (mapv (fn [p] (str (emit-expr* (get p "key")) " " (emit-expr* (get p "val")))) (get e "pairs"))]
  (str "{" (str/join " " strs) "}"))
  (= node "set") (str "#{" (str/join " " (mapv emit-expr* (get e "items"))) "}")
  (= node "record") (emit-record-form e)
  (= node "quoted") (emit-quoted-top (get e "datum"))
  (= node "regex") (str "#\"" (get e "pattern") "\"")
  (= node "method-call") (str "(" (get e "method") " " (emit-expr* (get e "target")) (emit-args (get e "args")) ")")
  (= node "static-call") (str "(" (get e "name") (emit-args (get e "args")) ")")
  (= node "new") (str "(" (get e "class") (emit-args (get e "args")) ")")
  (= node "kw-access") (let [_contract (record-field-access-contract e)
   dflt (get e "default")]
  (if (absent? dflt) (str "(" (get e "kw") " " (emit-expr* (get e "target")) ")") (str "(" (get e "kw") " " (emit-expr* (get e "target")) " " (emit-expr* dflt) ")")))
  (= node "threading") (let [args (get e "args")]
  (if (= (count args) 0) (str "(" (get e "kind") ")") (str "(" (get e "kind") " " (str/join " " (mapv emit-expr* args)) ")")))
  (= node "try") (let [body-str (emit-body (get e "body") "  ")
   catch-strs (mapv (fn [c] (str "\n  (catch " (get c "type") " " (get c "name") "\n    " (emit-body (get c "body") "    ") ")")) (get e "catches"))
   fin (get e "finally")
   finally-str (if (absent? fin) "" (str "\n  (finally\n    " (emit-body fin "    ") ")"))]
  (str "(try\n  " body-str (str/join "" catch-strs) finally-str ")"))
  (= node "condp") (let [pred (emit-expr* (get e "pred"))
   test-val (emit-expr* (get e "test"))
   clause-strs (mapv (fn [c] (str (emit-expr* (get c "test")) " " (emit-expr* (get c "body")))) (get e "clauses"))
   body (str/join "\n  " clause-strs)
   dflt (get e "default")]
  (if (absent? dflt) (str "(condp " pred " " test-val "\n  " body ")") (str "(condp " pred " " test-val "\n  " body "\n  " (emit-expr* dflt) ")")))
  (= node "match") (emit-match! e)
  (= node "with") (let [update-strs (mapv (fn [u] (str (get u "field") " " (emit-expr* (get u "value")))) (get e "updates"))
   updated (str "(assoc " (emit-expr* (get e "target")) " " (str/join " " update-strs) ")")
   contract (record-update-contract e)
   validator (if (nil? contract) nil (get contract "validator"))]
  (if (not (nil? contract)) (do
  (doseq [update (get e "updates")]
  (if (not (some? (some (fn [^String field] (if (= field (get update "field")) (do
  field))) (get contract "fieldOrder")))) (do
  (throw (ex-info "checked with node updates a field outside its recordUpdate fieldOrder" {})))))))
  (if (nil? validator) updated (str "(let [$beagle$record$update$candidate " updated "]\n" "  (" validator " $beagle$record$update$candidate))")))
  (= node "defenum") (emit-defenum e)
  (= node "defunion") (emit-defunion! e)
  (= node "deferror") (emit-deferror! e)
  (= node "defscalar") (emit-defscalar e)
  (= node "defprotocol") (emit-protocol e)
  (= node "extend-type") (emit-extend-type e)
  (= node "set!") (let [target (get e "target")
   val (emit-expr* (get e "value"))]
  (if (= (get target "node") "method-call") (str "(set! (" (get target "method") " " (emit-expr* (get target "target")) ") " val ")") (str "(set! " (emit-expr* target) " " val ")")))
  (= node "letfn") (let [fn-strs (mapv (fn [f] (let [body (emit-body-with-loop-context! (get f "body") "    " nil)
   callable (emit-callable-signature+body (get f "params") (get f "rest") body)]
  (str "(" (get f "name") " [" (get callable "params") "] " (get callable "body") ")"))) (get e "fns"))]
  (str "(letfn [" (str/join "\n          " fn-strs) "]\n  " (emit-body (get e "body") "  ") ")"))
  (= node "target-case") (let [cases (vec (get e "cases"))
   want (deref emit-target)
   pick (fn [^String t] (first (filterv (fn [c] (= (get c "target") t)) cases)))
   branch0 (pick want)
   branch (if (nil? branch0) (pick "clj") branch0)]
  (if (nil? branch) "nil" (emit-expr* (get branch "body"))))
  (= node "dynamic-var") (get e "name")
  (= node "check") (str "(let [r__check " (emit-expr* (get e "expr")) "]\n" "  (if (instance? Ok r__check)\n" "    (ok-value r__check)\n" "    (throw (ex-info (str \"check failed: \" (err-error r__check)) {:error r__check}))))")
  (= node "rescue") (let [err-name (let [en (get e "err")]
  (if (absent? en) "_" en))]
  (str "(let [r__rescue " (emit-expr* (get e "expr")) "]\n" "  (if (instance? Ok r__rescue)\n" "    (ok-value r__rescue)\n" "    (let [" err-name " r__rescue] " (emit-expr* (get e "fallback")) ")))"))
  (= node "block-string") (write-clj-string (get e "text"))
  (= node "await") "(throw (ex-info \"await not supported for Clojure target\" {}))"
  :else (str ";; unknown node: " node))))

(defn register-tables! [forms]
  (doseq [f forms]
  (let [node (get f "node")]
  (cond
  (= node "record") (let [name (get f "name")
   fields (get f "fields")]
  (swap! record-fields assoc name (field-names-of fields)))
  (or (= node "defunion") (= node "deferror")) (let [mf (get f "member-fields")]
  (if mf (do
  (doseq [m (get f "members")]
  (let [fields (vec (get mf m))]
  (swap! record-fields assoc m (field-names-of fields)))))))
  (= node "defscalar") (let [nm (get f "name")
   predicates (vec (get f "predicates"))]
  (if (= 0 (count predicates)) (do
  (swap! scalar-fns assoc (str "->" nm) true)))
  (swap! scalar-fns assoc (str (str/lower-case nm) "-value") true))
  :else nil)))
  nil)

(defn ^String emit-program! [prog]
  (reset! emit-expr-ref emit-expr!)
  (reset! record-fields {})
  (reset! scalar-fns {})
  (reset! match-counter 0)
  (reset! loop-constraint-arity nil)
  (reset! emit-target (get prog "target"))
  (reset! checked-program-ref (and (= (get prog "kind") "beagle.checked-program") (= (get prog "schemaVersion") 3) (= (get prog "phase") "checked")))
  (register-tables! (get prog "forms"))
  (let [body (str/join "\n\n" (mapv emit-expr! (get prog "forms")))]
  (str (emit-ns-form prog body) "\n\n" body "\n")))

(def passes (atom []))

(def failures (atom []))

(defn expect! [^String label ^Boolean result]
  (if result (do
  (swap! passes conj true)
  nil) (do
  (swap! failures conj label)
  nil))
  nil)

(defn run-tests! []
  (reset! emit-expr-ref emit-expr!)
  (reset! record-fields {})
  (reset! scalar-fns {})
  (reset! match-counter 0)
  (reset! loop-constraint-arity nil)
  (reset! emit-target "clj")
  (reset! checked-program-ref false)
  (reset! passes [])
  (reset! failures [])
  (expect! "string: plain" (= (write-clj-string "hi") "\"hi\""))
  (expect! "string: newline" (= (write-clj-string "a\nb") "\"a\\nb\""))
  (expect! "string: tab+quote+backslash" (= (write-clj-string "a\tb\"c\\d") "\"a\\tb\\\"c\\\\d\""))
  (expect! "string: u0001" (= (write-clj-string (str "x" (char 1) "y")) "\"x\\u0001y\""))
  (expect! "string: u007f" (= (write-clj-string (str (char 127))) "\"\\u007f\""))
  (expect! "string: bell unicode" (= (write-clj-string (str (char 7))) "\"\\u0007\""))
  (expect! "string: vertical-tab unicode" (= (write-clj-string (str (char 11))) "\"\\u000b\""))
  (expect! "string: escape unicode" (= (write-clj-string (str (char 27))) "\"\\u001b\""))
  (expect! "char: named space" (= (emit-char-lit 32) "\\space"))
  (expect! "char: named tab" (= (emit-char-lit 9) "\\tab"))
  (expect! "char: named newline" (= (emit-char-lit 10) "\\newline"))
  (expect! "char: named return" (= (emit-char-lit 13) "\\return"))
  (expect! "char: named formfeed" (= (emit-char-lit 12) "\\formfeed"))
  (expect! "char: named backspace" (= (emit-char-lit 8) "\\backspace"))
  (expect! "char: printable A" (= (emit-char-lit 65) "\\A"))
  (expect! "char: printable z" (= (emit-char-lit 122) "\\z"))
  (expect! "char: printable !" (= (emit-char-lit 33) "\\!"))
  (expect! "char: printable ~" (= (emit-char-lit 126) "\\~"))
  (expect! "char: non-ascii e-acute" (= (emit-char-lit 233) "\\u00e9"))
  (expect! "char: non-ascii U+0001" (= (emit-char-lit 1) "\\u0001"))
  (expect! "char: \\u0041 canonicalizes to \\A" (= (emit-char-lit 65) "\\A"))
  (expect! "float: whole" (= (emit-float 1.0) "1.0"))
  (expect! "float: frac" (= (emit-float 3.14) "3.14"))
  (expect! "require: alias" (= (emit-require {"ns" "fram.kernel" "alias" "k" "refer" nil}) "[fram.kernel :as k]"))
  (expect! "require: default alias" (= (emit-require {"ns" "fram.rt" "alias" nil "refer" nil}) "[fram.rt :as rt]"))
  (expect! "require: refer" (= (emit-require {"ns" "x.y" "alias" nil "refer" ["a" "b"]}) "[x.y :refer [a b]]"))
  (expect! "import: qualified class" (= (emit-import "java.util.zip.CRC32") "[java.util.zip CRC32]"))
  (expect! "ns: imports follow requires" (= (emit-ns-form {"namespace" "fixture.imports" "requires" [{"ns" "clojure.string" "alias" "str" "refer" nil}] "imports" ["java.nio.charset.StandardCharsets" "java.util.zip.CRC32"] "gen-class" false} "") (str "(ns fixture.imports\n" "  (:require [clojure.string :as str])\n" "  (:import [java.nio.charset StandardCharsets]\n" "           [java.util.zip CRC32]))")))
  (expect! "defenum keywords" (= (emit-defenum {"name" "Color" "values" ["red" "blue"]}) "(def Color-values #{:red :blue})"))
  (expect! "record accessors" (= (emit-record-form {"name" "Pt" "fields" [{"name" "x"} {"name" "y"}]}) "(defrecord Pt [x y])\n\n(defn pt-x [r] (:x r))\n\n(defn pt-y [r] (:y r))"))
  (expect! "if: else-less encodes 2-arity" (= (emit-expr! {"node" "if" "cond" {"node" "ref" "name" "p"} "then" {"node" "ref" "name" "t"} "else" {"node" "literal" "kind" "bool" "value" false}}) "(if p t)"))
  (expect! "call: keyword access in function position" (= (emit-expr! {"node" "call" "fn" {"node" "kw-access" "kw" ":k" "target" {"node" "ref" "name" "m"} "default" false} "args" []}) "((:k m))"))
  (expect! "def: dynamic metadata survives emission" (= (emit-expr! {"node" "def" "name" "*arity-check?*" "ann" {"kind" "prim" "name" "Bool"} "doc" false "dynamic" true "value" {"node" "literal" "kind" "bool" "value" true}}) "(def ^:dynamic ^Boolean *arity-check?* true)"))
  (expect! "match temps deterministic" (do
  (reset! match-counter 0)
  (= (fresh-match-sym!) "match__0")))
  (expect! "binding-target: plain name passes through" (= (emit-binding-target! "x") "x"))
  (expect! "binding-target: seq-destructure -> [a b]" (= (emit-binding-target! {"type" "seq-destructure" "names" ["a" "b"] "rest" false}) "[a b]"))
  (expect! "binding-target: map-destructure -> {:keys [id b]}" (= (emit-binding-target! {"type" "map-destructure" "keys" ["id" "b"] "as" false}) "{:keys [id b]}"))
  (expect! "param: typed sequential aggregate unwraps to binding form" (= (emit-param {"type" "param" "name" {"type" "seq-destructure" "names" ["x" "y"] "rest" false} "ann" {"kind" "hvec" "members" [{"kind" "prim" "name" "Int"} {"kind" "prim" "name" "String"}]}}) "[x y]"))
  (expect! "param: nested map defaults and as survive aggregate annotation" (= (emit-param {"type" "param" "name" {"type" "seq-destructure" "names" ["x" {"type" "map-destructure" "keys" ["y"] "or" [{"key" "y" "value" {"node" "literal" "kind" "number" "value" 3}}] "as" "row"}] "rest" false} "ann" {"kind" "any"}}) "[x {:keys [y] :or {y 3} :as row}]"))
  (expect! "let-bindings: seq-destructure binder (no raw JSON leak)" (= (emit-let-bindings! [{"name" {"type" "seq-destructure" "names" ["a" "b"] "rest" false} "value" {"node" "ref" "name" "p"}}]) "[a b] p"))
  (expect! "let-bindings: map-destructure binder (no raw JSON leak)" (= (emit-let-bindings! [{"name" {"type" "map-destructure" "keys" ["id" "b"] "as" false} "value" {"node" "ref" "name" "m"}}]) "{:keys [id b]} m"))
  (expect! "constrained callable captures predicate before authored binder" (let [output (emit-expr! {"node" "defn" "name" "keep" "params" [{"type" "param" "name" "value" "ann" {"kind" "prim" "name" "Int"} "constraint" {"node" "ref" "name" "positive?"}}] "rest" false "ret" {"kind" "prim" "name" "Int"} "body" [{"node" "ref" "name" "value"}] "private" false "doc" false})]
  (and (str/includes? output "[$beagle$constraint$raw-param$0]") (str/includes? output "$beagle$constraint$predicate$0 positive?") (str/includes? output "Binding constraint failed: value"))))
  (expect! "constrained let evaluates raw value once before projection" (let [output (emit-let-bindings! [{"name" "value" "constraint" {"node" "ref" "name" "positive?"} "value" {"node" "call" "fn" {"node" "ref" "name" "next-value"} "args" []}}])]
  (and (str/includes? output "$beagle$constraint$raw-binding$0 (next-value)") (str/includes? output "$beagle$constraint$predicate$0 positive?"))))
  (expect! "record field constraint guards both constructor ABIs" (let [output (emit-record-form {"name" "Account" "fields" [{"type" "param" "name" "id" "ann" {"kind" "prim" "name" "Int"} "constraint" {"node" "ref" "name" "positive?"}}]})]
  (and (str/includes? output "$beagle$record$Account$raw-constructor") (str/includes? output "$beagle$record$Account$raw-map-constructor") (str/includes? output "$beagle$record$Account$validate"))))
  (expect! "constrained loop revalidates recur values" (let [output (emit-loop-with-constraints! {"bindings" [{"name" "value" "constraint" {"node" "ref" "name" "positive?"} "value" {"node" "literal" "kind" "number" "value" 1}}] "body" [{"node" "recur" "args" [{"node" "ref" "name" "value"}]}]})]
  (and (str/includes? output "$beagle$constraint$first-iteration true") (str/includes? output "(recur value false)"))))
  (expect! "protocol constraint uses raw dispatch ABI plus guarded wrapper" (let [output (emit-protocol {"name" "Measured" "methods" [{"name" "measure" "params" [{"type" "param" "name" "value" "ann" {"kind" "prim" "name" "Int"} "constraint" {"node" "ref" "name" "positive?"}}] "rest" false "ret" {"kind" "prim" "name" "Bool"}}]})]
  (and (str/includes? output "$beagle$protocol$Measured$measure") (str/includes? output "(defn measure") (str/includes? output "Binding constraint failed: value"))))
  (doseq [f (deref failures)]
  (println (str "  FAIL: " f)))
  (println (str "  EMIT-CLJ: " (count (deref passes)) " passed, " (count (deref failures)) " failed"))
  (count (deref failures)))
