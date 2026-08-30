(ns selfhost.types
  (:require [selfhost.rt :as rt]
            [clojure.string :as str]))

(defn ^String char-at [^String s i]
  (if (and (>= i 0) (< i (count s))) (subs s i (+ i 1)) ""))

(defn ^String substring2 [^String s a b]
  (let [n (count s)
   lo (if (< a 0) 0 (if (> a n) n a))
   hi (if (< b lo) lo (if (> b n) n b))]
  (subs s lo hi)))

(defn index-of2 [xs v]
  (let [n (count xs)]
  (loop [i 0]
  (if (>= i n) -1 (if (= (nth xs i) v) i (recur (+ i 1)))))))

(defn str-index-of [^String s ^String sub]
  (let [result (str/index-of s sub)]
  (if (nil? result) -1 result)))

(defn obj-set! [obj k v]
  (swap! obj assoc k v))

(def CLJ-ALIASES {"Long" "Int" "Double" "Float" "Boolean" "Bool" "Integer" "Int"})

(def PARAMETRIC-CTORS ["Vec" "List" "Set" "Map" "Promise" "NixType" "Arr" "Ptr" "Atom" "HVec" "Regex" "Buffer" "JsMap"])

(def BUILTIN-PARAMETRIC-APPLICATION-ARITIES {"Regex" 1 "Buffer" 1 "JsMap" 2})

(defn make-prim [^String name]
  {"kind" "prim" "name" name})

(defn make-fn [params rest-type ret]
  {"kind" "fn" "params" params "rest" rest-type "ret" ret})

(defn make-app [^String ctor args]
  {"kind" "app" "name" ctor "args" args})

(defn make-union [members]
  {"kind" "union" "members" members})

(defn make-var [^String name]
  {"kind" "var" "name" name})

(defn make-poly [vars body bounds]
  {"kind" "poly" "vars" vars "body" body "bounds" bounds})

(def TYPE-PARSE-ERRORS (atom []))

(defn reset-type-parse-errors! []
  (reset! TYPE-PARSE-ERRORS [])
  nil)

(defn type-parse-errors []
  (deref TYPE-PARSE-ERRORS))

(defn invalid-type! [^String message]
  (swap! TYPE-PARSE-ERRORS conj message)
  (selfhost.rt/eprint (str "beagle: " message "\n"))
  {"kind" "invalid" "message" message})

(defn ^Boolean prim? [t]
  (and (not (nil? t)) (not= (get t "kind") nil) (= (get t "kind") "prim")))

(defn ^Boolean fn-type? [t]
  (and (not (nil? t)) (= (get t "kind") "fn")))

(defn ^Boolean app-type? [t]
  (and (not (nil? t)) (= (get t "kind") "app")))

(defn ^Boolean union-type? [t]
  (and (not (nil? t)) (= (get t "kind") "union")))

(defn ^Boolean var-type? [t]
  (and (not (nil? t)) (= (get t "kind") "var")))

(defn ^Boolean poly-type? [t]
  (and (not (nil? t)) (= (get t "kind") "poly")))

(defn ^Boolean any-type? [t]
  (and (prim? t) (= (get t "name") "Any")))

(defn ^Boolean reader-atom-type-text? [^String text]
  (and (> (count text) 0) (nil? (re-find #"[\\s\\[\\](){}\";,]" text))))

(defn ^String type->string [t]
  (cond
  (nil? t) "?"
  (prim? t) (get t "name")
  (fn-type? t) (let [params (get t "params")
   rest-t (get t "rest")
   ret (get t "ret")
   param-strs (mapv type->string params)]
  (if (not (nil? rest-t)) (str "(Fn [" (str/join " " param-strs) " & " (type->string rest-t) "] " (type->string ret) ")") (str "(Fn [" (str/join " " param-strs) "] " (type->string ret) ")")))
  (app-type? t) (let [ctor (get t "name")
   args (get t "args")
   arg-strs (mapv type->string args)]
  (str "(" ctor " " (str/join " " arg-strs) ")"))
  (union-type? t) (let [members (get t "members")
   all-prim (every? prim? members)
   names (if all-prim (mapv (fn [m] (get m "name")) members) [])]
  (cond
  (and all-prim (= (count members) 2) (>= (index-of2 names "Int") 0) (>= (index-of2 names "Float") 0)) "Number"
  (and (= (count members) 2) (some (fn [m] (and (prim? m) (= (get m "name") "Nil"))) members)) (let [non-nil (first (filter (fn [m] (not (and (prim? m) (= (get m "name") "Nil")))) members))]
  (let [non-nil-text (type->string non-nil)]
  (if (reader-atom-type-text? non-nil-text) (str non-nil-text "?") (str "(U " (str/join " " (mapv type->string members)) ")"))))
  :else (str "(U " (str/join " " (mapv type->string members)) ")")))
  (var-type? t) (get t "name")
  (poly-type? t) (let [vars (get t "vars")
   body (get t "body")
   bounds (get t "bounds")
   var-strs (mapv (fn [^String v] (let [b (if (nil? bounds) nil (get bounds v))]
  (if (nil? b) v (str "(" v " <: " (type->string b) ")")))) vars)]
  (str "(forall [" (str/join " " var-strs) "] " (type->string body) ")"))
  :else "?"))

(defn ^String unqualify-name [^String name]
  (let [idx (str-index-of name "/")]
  (if (= idx -1) name (substring2 name (+ idx 1) (count name)))))

(defn ^Boolean type-invariant-equal? [a b]
  (cond
  (and (prim? a) (prim? b)) (= (unqualify-name (get a "name")) (unqualify-name (get b "name")))
  (and (app-type? a) (app-type? b)) (and (= (get a "name") (get b "name")) (= (count (get a "args")) (count (get b "args"))) (every? (fn [i] (type-invariant-equal? (nth (get a "args") i) (nth (get b "args") i))) (range (count (get a "args")))))
  (and (union-type? a) (union-type? b)) (and (= (count (get a "members")) (count (get b "members"))) (every? (fn [i] (type-invariant-equal? (nth (get a "members") i) (nth (get b "members") i))) (range (count (get a "members")))))
  (and (var-type? a) (var-type? b)) (= (get a "name") (get b "name"))
  :else (= a b)))

(defn ^Boolean type-compatible? [actual expected]
  (cond
  (or (nil? actual) (nil? expected)) true
  (any-type? actual) true
  (any-type? expected) true
  (var-type? actual) true
  (var-type? expected) true
  (poly-type? expected) (type-compatible? actual (get expected "body"))
  (poly-type? actual) (type-compatible? (get actual "body") expected)
  (and (union-type? actual) (union-type? expected)) (every? (fn [a-alt] (some (fn [e-alt] (type-compatible? a-alt e-alt)) (get expected "members"))) (get actual "members"))
  (union-type? expected) (some (fn [alt] (type-compatible? actual alt)) (get expected "members"))
  (union-type? actual) (every? (fn [alt] (type-compatible? alt expected)) (get actual "members"))
  (and (prim? actual) (prim? expected)) (or (= (get actual "name") (get expected "name")) (and (= (get actual "name") "Int") (= (get expected "name") "Float")) (and (= (get actual "name") "Int") (boolean (some (fn [^String name] (= (get expected "name") name)) ["I8" "I16" "I32" "U8" "U16" "U32" "U64" "F32"]))) (and (= (get actual "name") "Float") (= (get expected "name") "F32")) (= (unqualify-name (get actual "name")) (unqualify-name (get expected "name"))))
  (and (fn-type? actual) (fn-type? expected)) (let [ap (get actual "params")
   ep (get expected "params")
   ar (get actual "rest")
   er (get expected "rest")
   an (count ap)
   en (count ep)]
  (and (<= an en) (or (= an en) (some? ar)) (every? (fn [i] (type-compatible? (nth ep i) (nth ap i))) (range an)) (or (nil? ar) (every? (fn [p] (type-compatible? p ar)) (drop an ep))) (or (nil? er) (and (some? ar) (type-compatible? er ar))) (type-compatible? (get actual "ret") (get expected "ret"))))
  (and (app-type? actual) (app-type? expected) (= (get actual "name") "Atom") (= (get expected "name") "Atom")) (and (= (count (get actual "args")) (count (get expected "args"))) (every? (fn [i] (type-invariant-equal? (nth (get actual "args") i) (nth (get expected "args") i))) (range (count (get actual "args")))))
  (and (app-type? actual) (app-type? expected) (= (get actual "name") "Buffer") (= (get expected "name") "Buffer")) (and (= (count (get actual "args")) (count (get expected "args"))) (every? (fn [i] (type-invariant-equal? (nth (get actual "args") i) (nth (get expected "args") i))) (range (count (get actual "args")))))
  (and (app-type? actual) (app-type? expected) (= (get actual "name") "JsMap") (= (get expected "name") "JsMap")) (and (= (count (get actual "args")) (count (get expected "args"))) (every? (fn [i] (type-invariant-equal? (nth (get actual "args") i) (nth (get expected "args") i))) (range (count (get actual "args")))))
  (and (app-type? actual) (= (get actual "name") "HVec") (app-type? expected) (= (get expected "name") "Vec") (= 1 (count (get expected "args")))) (every? (fn [a] (type-compatible? a (nth (get expected "args") 0))) (get actual "args"))
  (and (app-type? expected) (= (get expected "name") "Dyn")) (if (and (app-type? actual) (= (get actual "name") "Dyn")) (and (= (count (get actual "args")) (count (get expected "args"))) (every? (fn [i] (type-invariant-equal? (nth (get actual "args") i) (nth (get expected "args") i))) (range (count (get actual "args"))))) (boolean (some (fn [alt] (type-compatible? actual alt)) (get expected "args"))))
  (and (app-type? actual) (= (get actual "name") "Regex") (prim? expected) (= (get expected "name") "Regex")) true
  (and (app-type? actual) (app-type? expected)) (and (= (get actual "name") (get expected "name")) (= (count (get actual "args")) (count (get expected "args"))) (every? identity (map-indexed (fn [i a] (type-compatible? a (nth (get expected "args") i))) (get actual "args"))))
  :else false))

(def user-parametric {})

(declare parse-type!)

(defn varize-type [t vars]
  (cond
  (nil? t) t
  (and (= (get t "kind") "prim") (>= (index-of2 vars (get t "name")) 0)) (make-var (get t "name"))
  (= (get t "kind") "fn") {"kind" "fn" "params" (mapv (fn [p] (varize-type p vars)) (get t "params")) "rest" (if (nil? (get t "rest")) nil (varize-type (get t "rest") vars)) "ret" (varize-type (get t "ret") vars)}
  (= (get t "kind") "app") {"kind" "app" "name" (get t "name") "args" (mapv (fn [a] (varize-type a vars)) (get t "args"))}
  (= (get t "kind") "union") {"kind" "union" "members" (mapv (fn [m] (varize-type m vars)) (get t "members"))}
  :else t))

(defn forall-entry-var [e]
  (cond
  (string? e) e
  (and (vector? e) (= (count e) 3) (= (nth e 1) "<:") (string? (nth e 0))) (nth e 0)
  :else nil))

(defn parse-fn-params! [items ret]
  (let [amp-pos (index-of2 items "&")]
  (if (> amp-pos -1) (if (= amp-pos (- (count items) 2)) (make-fn (mapv parse-type! (subvec items 0 amp-pos)) (parse-type! (nth items (+ amp-pos 1))) (parse-type! ret)) (invalid-type! "function type: `&` must be followed by exactly one final rest type")) (make-fn (mapv parse-type! items) nil (parse-type! ret)))))

(defn parse-type! [t]
  (cond
  (and (vector? t) (> (count t) 0) (= (nth t 0) "#%brackets")) (invalid-type! "a vector is not a type expression; write (Fn [ParamType ...] ReturnType) for a function type")
  (and (vector? t) (= (count t) 3) (= (nth t 0) "Fn") (vector? (nth t 1)) (> (count (nth t 1)) 0) (= (nth (nth t 1) 0) "#%brackets")) (parse-fn-params! (subvec (nth t 1) 1) (nth t 2))
  (and (vector? t) (> (count t) 0) (= (nth t 0) "Fn")) (invalid-type! "function type requires exactly (Fn [ParamType ...] ReturnType)")
  (and (vector? t) (= (count t) 3) (= (nth t 0) "forall")) (let [vars-form (nth t 1)
   raw-vars (if (and (vector? vars-form) (> (count vars-form) 0) (= (nth vars-form 0) "#%brackets")) (subvec vars-form 1) vars-form)
   reserved? (some (fn [entry] (= (if (string? entry) entry (if (and (vector? entry) (> (count entry) 0)) (nth entry 0) nil)) "Fn")) raw-vars)
   vars (vec (filter (fn [x] (not (nil? x))) (mapv forall-entry-var raw-vars)))
   bounds (reduce (fn [acc e] (if (and (vector? e) (= (count e) 3) (= (nth e 1) "<:") (string? (nth e 0))) (assoc acc (nth e 0) (varize-type (parse-type! (nth e 2)) vars)) acc)) {} raw-vars)]
  (if reserved? (invalid-type! "forall type parameter cannot declare `Fn`; Fn is the built-in function type constructor") (make-poly vars (varize-type (parse-type! (nth t 2)) vars) (if (= (count bounds) 0) nil bounds))))
  (and (vector? t) (> (count t) 1) (= (nth t 0) "U")) (make-union (mapv parse-type! (subvec t 1)))
  (and (vector? t) (> (count t) 0) (string? (nth t 0)) (or (= (nth t 0) "Dyn") (>= (index-of2 PARAMETRIC-CTORS (nth t 0)) 0) (= (get user-parametric (nth t 0)) true))) (let [name (nth t 0)
   expected (get BUILTIN-PARAMETRIC-APPLICATION-ARITIES name)
   actual (- (count t) 1)]
  (if (and (not (nil? expected)) (not (= expected actual))) (invalid-type! (str "type " name " expects " expected " argument" (if (= expected 1) "" "s") ", got " actual)) (make-app name (mapv parse-type! (subvec t 1)))))
  (and (string? t) (> (count t) 1) (= (char-at t (- (count t) 1)) "?")) (let [base (substring2 t 0 (- (count t) 1))]
  (make-union [(parse-type! base) (make-prim "Nil")]))
  (and (string? t) (= t "Number")) (make-union [(make-prim "Int") (make-prim "Float")])
  (and (string? t) (not (nil? (get CLJ-ALIASES t)))) (make-prim (get CLJ-ALIASES t))
  (and (string? t) (= t "Fn")) (invalid-type! "bare Fn is an incomplete function type; write (Fn [ParamType ...] ReturnType)")
  (string? t) (make-prim t)
  :else (make-prim "Any")))

(defn infer-literal-type [e]
  (let [kind (get e "kind")]
  (cond
  (= kind "string") (make-prim "String")
  (= kind "bool") (make-prim "Bool")
  (= kind "number") (make-prim "Int")
  (= kind "float") (make-prim "Float")
  (= kind "nil") (make-prim "Nil")
  (= kind "keyword") (make-prim "Keyword")
  (= kind "symbol") (make-prim "Symbol")
  :else nil)))

(def INVARIANT-TYPE-CONSTRUCTORS #{"Atom" "Buffer" "TransientVec"})

(defn infer-type-var-bindings-context! [expected actual bindings ^Boolean invariant-context?]
  (cond
  (or (nil? expected) (nil? actual)) nil
  (and invariant-context? (var-type? expected) (any-type? actual)) (do
  (if (nil? (get (deref bindings) (get expected "name"))) (do
  (obj-set! bindings (get expected "name") actual)))
  nil)
  (any-type? actual) nil
  (var-type? expected) (do
  (if (nil? (get (deref bindings) (get expected "name"))) (do
  (obj-set! bindings (get expected "name") actual)))
  nil)
  (and (fn-type? expected) (fn-type? actual)) (do
  (if (= (count (get expected "params")) (count (get actual "params"))) (do
  (doseq [i (range (count (get expected "params")))]
  (infer-type-var-bindings-context! (nth (get expected "params") i) (nth (get actual "params") i) bindings invariant-context?))))
  (if (and (not (nil? (get expected "rest"))) (not (nil? (get actual "rest")))) (do
  (infer-type-var-bindings-context! (get expected "rest") (get actual "rest") bindings invariant-context?)))
  (infer-type-var-bindings-context! (get expected "ret") (get actual "ret") bindings invariant-context?)
  nil)
  (and (app-type? expected) (app-type? actual) (= (get expected "name") (get actual "name"))) (let [nested-invariant? (or invariant-context? (contains? INVARIANT-TYPE-CONSTRUCTORS (get expected "name")))]
  (doseq [i (range (count (get expected "args")))]
  (infer-type-var-bindings-context! (nth (get expected "args") i) (nth (get actual "args") i) bindings nested-invariant?))
  nil)
  :else nil))

(defn infer-type-var-bindings! [expected actual bindings]
  (infer-type-var-bindings-context! expected actual bindings false))

(defn apply-type-bindings [t bindings]
  (cond
  (nil? t) nil
  (var-type? t) (let [bound (get bindings (get t "name"))]
  (if (nil? bound) (make-prim "Any") bound))
  (prim? t) t
  (fn-type? t) (make-fn (mapv (fn [p] (apply-type-bindings p bindings)) (get t "params")) (if (nil? (get t "rest")) nil (apply-type-bindings (get t "rest") bindings)) (apply-type-bindings (get t "ret") bindings))
  (app-type? t) (make-app (get t "name") (mapv (fn [a] (apply-type-bindings a bindings)) (get t "args")))
  (union-type? t) (make-union (mapv (fn [m] (apply-type-bindings m bindings)) (get t "members")))
  (poly-type? t) t
  :else t))

(def passes (atom []))

(def failures (atom []))

(defn- expect! [^String label ^Boolean result]
  (if result (do
  (swap! passes conj true)
  nil) (do
  (swap! failures conj label)
  nil)))

(defn run-tests! []
  (reset! passes [])
  (reset! failures [])
  (reset-type-parse-errors!)
  (expect! "ts: prim String" (= (type->string (make-prim "String")) "String"))
  (expect! "ts: prim Int" (= (type->string (make-prim "Int")) "Int"))
  (expect! "ts: prim Any" (= (type->string (make-prim "Any")) "Any"))
  (expect! "ts: prim Nil" (= (type->string (make-prim "Nil")) "Nil"))
  (expect! "ts: fn (Fn [Int] String)" (= (type->string (make-fn [(make-prim "Int")] nil (make-prim "String"))) "(Fn [Int] String)"))
  (expect! "ts: fn (Fn [Int Bool] String)" (= (type->string (make-fn [(make-prim "Int") (make-prim "Bool")] nil (make-prim "String"))) "(Fn [Int Bool] String)"))
  (expect! "ts: fn variadic (Fn [Int & String] Bool)" (= (type->string (make-fn [(make-prim "Int")] (make-prim "String") (make-prim "Bool"))) "(Fn [Int & String] Bool)"))
  (expect! "ts: app (Vec Int)" (= (type->string (make-app "Vec" [(make-prim "Int")])) "(Vec Int)"))
  (expect! "ts: app (Map String Int)" (= (type->string (make-app "Map" [(make-prim "String") (make-prim "Int")])) "(Map String Int)"))
  (expect! "ts: union nullable String?" (= (type->string (make-union [(make-prim "String") (make-prim "Nil")])) "String?"))
  (expect! "ts: union Number" (= (type->string (make-union [(make-prim "Int") (make-prim "Float")])) "Number"))
  (expect! "ts: union (U String Int Nil)" (= (type->string (make-union [(make-prim "String") (make-prim "Int") (make-prim "Nil")])) "(U String Int Nil)"))
  (expect! "ts: var T" (= (type->string (make-var "T")) "T"))
  (expect! "ts: poly (forall [T] (Vec T))" (= (type->string (make-poly ["T"] (make-app "Vec" [(make-var "T")]) nil)) "(forall [T] (Vec T))"))
  (expect! "ts: null type" (= (type->string nil) "?"))
  (expect! "tc: same prim" (type-compatible? (make-prim "String") (make-prim "String")))
  (expect! "tc: diff prim" (not (type-compatible? (make-prim "String") (make-prim "Int"))))
  (expect! "tc: actual Any" (type-compatible? (make-prim "Any") (make-prim "Int")))
  (expect! "tc: expected Any" (type-compatible? (make-prim "Int") (make-prim "Any")))
  (expect! "tc: actual var" (type-compatible? (make-var "T") (make-prim "Int")))
  (expect! "tc: expected var" (type-compatible? (make-prim "Int") (make-var "T")))
  (expect! "tc: null actual" (type-compatible? nil (make-prim "Int")))
  (expect! "tc: null expected" (type-compatible? (make-prim "Int") nil))
  (expect! "tc: prim in union" (type-compatible? (make-prim "String") (make-union [(make-prim "String") (make-prim "Nil")])))
  (expect! "tc: prim not in union" (not (type-compatible? (make-prim "Int") (make-union [(make-prim "String") (make-prim "Nil")]))))
  (expect! "tc: union subset" (type-compatible? (make-union [(make-prim "String")]) (make-union [(make-prim "String") (make-prim "Nil")])))
  (expect! "tc: union not subset" (not (type-compatible? (make-union [(make-prim "String") (make-prim "Int")]) (make-union [(make-prim "String") (make-prim "Nil")]))))
  (expect! "tc: same fn" (type-compatible? (make-fn [(make-prim "Int")] nil (make-prim "String")) (make-fn [(make-prim "Int")] nil (make-prim "String"))))
  (expect! "tc: diff fn param" (not (type-compatible? (make-fn [(make-prim "Int")] nil (make-prim "String")) (make-fn [(make-prim "Bool")] nil (make-prim "String")))))
  (expect! "tc: diff fn arity" (not (type-compatible? (make-fn [(make-prim "Int")] nil (make-prim "String")) (make-fn [(make-prim "Int") (make-prim "Bool")] nil (make-prim "String")))))
  (expect! "tc: same app" (type-compatible? (make-app "Vec" [(make-prim "Int")]) (make-app "Vec" [(make-prim "Int")])))
  (expect! "tc: diff app arg" (not (type-compatible? (make-app "Vec" [(make-prim "Int")]) (make-app "Vec" [(make-prim "String")]))))
  (expect! "tc: diff app ctor" (not (type-compatible? (make-app "Vec" [(make-prim "Int")]) (make-app "Set" [(make-prim "Int")]))))
  (expect! "tc: concrete alternative fits expected Dyn" (type-compatible? (make-prim "String") (make-app "Dyn" [(make-prim "String") (make-prim "Int")])))
  (expect! "tc: value outside expected Dyn is rejected" (not (type-compatible? (make-prim "Float") (make-app "Dyn" [(make-prim "String") (make-prim "Int")]))))
  (expect! "tc: Dyn alternatives are invariant and ordered" (not (type-compatible? (make-app "Dyn" [(make-prim "String") (make-prim "Int")]) (make-app "Dyn" [(make-prim "Int") (make-prim "String")]))))
  (expect! "tc: qualified name" (type-compatible? (make-prim "mymod/Type") (make-prim "Type")))
  (expect! "tc: poly unwrap" (type-compatible? (make-prim "String") (make-poly ["T"] (make-prim "String") nil)))
  (expect! "pt: prim" (= (parse-type! "String") (make-prim "String")))
  (expect! "pt: app Vec" (= (parse-type! ["Vec" "String"]) (make-app "Vec" [(make-prim "String")])))
  (expect! "pt: shaped Regex app" (= (parse-type! ["Regex" ["HVec" "String" "String"]]) (make-app "Regex" [(make-app "HVec" [(make-prim "String") (make-prim "String")])])))
  (expect! "pt: shaped Regex exact arity" (let [before (count (type-parse-errors))
   invalid (parse-type! ["Regex" "String" "String"])]
  (and (= (get invalid "kind") "invalid") (= (count (type-parse-errors)) (+ before 1)))))
  (expect! "pt: union" (= (parse-type! ["U" "String" "Nil"]) (make-union [(make-prim "String") (make-prim "Nil")])))
  (expect! "pt: nullable sugar" (= (parse-type! "String?") (make-union [(make-prim "String") (make-prim "Nil")])))
  (expect! "pt: Number alias" (= (parse-type! "Number") (make-union [(make-prim "Int") (make-prim "Float")])))
  (expect! "pt: CLJ alias Long" (= (parse-type! "Long") (make-prim "Int")))
  (expect! "pt: fn type" (= (parse-type! ["Fn" ["#%brackets" "Int"] "String"]) (make-fn [(make-prim "Int")] nil (make-prim "String"))))
  (expect! "pt: variadic fn" (= (parse-type! ["Fn" ["#%brackets" "Int" "&" "String"] "Bool"]) (make-fn [(make-prim "Int")] (make-prim "String") (make-prim "Bool"))))
  (expect! "pt: malformed Fn rejects" (let [before (count (type-parse-errors))
   invalid (parse-type! ["Fn" "Int" "String"])]
  (and (= (get invalid "kind") "invalid") (= (count (type-parse-errors)) (+ before 1)))))
  (expect! "pt: bare Fn rejects" (let [before (count (type-parse-errors))
   invalid (parse-type! "Fn")]
  (and (= (get invalid "kind") "invalid") (= (count (type-parse-errors)) (+ before 1)))))
  (expect! "pt: nested (Vec (Map String Int))" (= (parse-type! ["Vec" ["Map" "String" "Int"]]) (make-app "Vec" [(make-app "Map" [(make-prim "String") (make-prim "Int")])])))
  (expect! "pt: Dyn" (= (parse-type! ["Dyn" "String" "Int"]) (make-app "Dyn" [(make-prim "String") (make-prim "Int")])))
  (expect! "tc: (Atom Int) ~ (Atom Int)" (type-compatible? (make-app "Atom" [(make-prim "Int")]) (make-app "Atom" [(make-prim "Int")])))
  (expect! "tc: (Atom Int) NOT ~ (Atom Any)" (not (type-compatible? (make-app "Atom" [(make-prim "Int")]) (make-app "Atom" [(make-prim "Any")]))))
  (expect! "tc: (Atom Any) NOT ~ (Atom Int)" (not (type-compatible? (make-app "Atom" [(make-prim "Any")]) (make-app "Atom" [(make-prim "Int")]))))
  (expect! "tc: (Buffer Float) ~ (Buffer Float)" (type-compatible? (make-app "Buffer" [(make-prim "Float")]) (make-app "Buffer" [(make-prim "Float")])))
  (expect! "tc: (Buffer Float) NOT ~ (Buffer Any)" (not (type-compatible? (make-app "Buffer" [(make-prim "Float")]) (make-app "Buffer" [(make-prim "Any")]))))
  (expect! "tc: (Buffer Any) NOT ~ (Buffer Float)" (not (type-compatible? (make-app "Buffer" [(make-prim "Any")]) (make-app "Buffer" [(make-prim "Float")]))))
  (expect! "tc: (HVec Int String) <: (Vec Any)" (type-compatible? (make-app "HVec" [(make-prim "Int") (make-prim "String")]) (make-app "Vec" [(make-prim "Any")])))
  (expect! "tc: (HVec Int String) NOT <: (Vec Int)" (not (type-compatible? (make-app "HVec" [(make-prim "Int") (make-prim "String")]) (make-app "Vec" [(make-prim "Int")]))))
  (expect! "tc: (Vec Int) NOT <: (HVec Int)" (not (type-compatible? (make-app "Vec" [(make-prim "Int")]) (make-app "HVec" [(make-prim "Int")]))))
  (expect! "tc: shaped Regex is compatible with primitive Regex" (type-compatible? (make-app "Regex" [(make-app "HVec" [(make-prim "String") (make-prim "String")])]) (make-prim "Regex")))
  (expect! "pt: bounded forall (T <: Number)" (= (parse-type! ["forall" ["#%brackets" ["T" "<:" "Number"]] ["Fn" ["#%brackets" "T"] "T"]]) (make-poly ["T"] (make-fn [(make-var "T")] nil (make-var "T")) {"T" (make-union [(make-prim "Int") (make-prim "Float")])})))
  (expect! "ts: bounded forall render" (= (type->string (make-poly ["T"] (make-fn [(make-var "T")] nil (make-var "T")) {"T" (make-union [(make-prim "Int") (make-prim "Float")])})) "(forall [(T <: Number)] (Fn [T] T))"))
  (expect! "pt: unbounded forall var-izes body" (= (parse-type! ["forall" ["#%brackets" "T"] ["Fn" ["#%brackets" "T"] "T"]]) (make-poly ["T"] (make-fn [(make-var "T")] nil (make-var "T")) nil)))
  (expect! "lit: string" (= (infer-literal-type {"kind" "string" "value" "hi"}) (make-prim "String")))
  (expect! "lit: int" (= (infer-literal-type {"kind" "number" "value" 42}) (make-prim "Int")))
  (expect! "lit: float" (= (infer-literal-type {"kind" "float" "value" 3.14}) (make-prim "Float")))
  (expect! "lit: bool" (= (infer-literal-type {"kind" "bool" "value" true}) (make-prim "Bool")))
  (expect! "lit: nil" (= (infer-literal-type {"kind" "nil"}) (make-prim "Nil")))
  (expect! "lit: keyword" (= (infer-literal-type {"kind" "keyword" "value" ":foo"}) (make-prim "Keyword")))
  (doseq [f (deref failures)]
  (selfhost.rt/eprint (str "  FAIL: " f "\n")))
  (println (str "  TYPES: " (count (deref passes)) " passed, " (count (deref failures)) " failed"))
  (count (deref failures)))
