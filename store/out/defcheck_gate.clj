(ns store.defcheck
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.edn :as edn]
            [cheshire.core :as json]))

(def BEAGLE-MESSAGE-RE (re-pattern "^beagle:\\s*"))

(def BEAGLE-SOURCE-RE (re-pattern "(?m)^#lang[ \\t]+beagle(?:[/ \\t]|$)"))

(def DOT-RE (re-pattern "\\."))

(def ANON-ARG-RE (re-pattern "%\\d*|%&"))

(def CLASS-LIKE-RE (re-pattern "[A-Z].*"))

(defn- env-int [^String k d]
  (or (some-> (System/getenv k) Integer/parseInt) d))

(defrecord DefcheckState [server-port sidecar-port gwdir autostart? render-fn modules-fn arity-check?])

(defn defcheckstate-server-port [r] (:server-port r))

(defn defcheckstate-sidecar-port [r] (:sidecar-port r))

(defn defcheckstate-gwdir [r] (:gwdir r))

(defn defcheckstate-autostart? [r] (:autostart? r))

(defn defcheckstate-render-fn [r] (:render-fn r))

(defn defcheckstate-modules-fn [r] (:modules-fn r))

(defn defcheckstate-arity-check? [r] (:arity-check? r))

(def ^String beagle-home (or (System/getenv "BEAGLE_HOME") (str (System/getProperty "user.home") "/code/beagle")))

(def ^String repo-root (or (System/getenv "BEAGLE_STORE_HOME") (System/getProperty "user.dir")))

(defn- rpc [port ^String line]
  (with-open [s (java.net.Socket.)] (.connect s (java.net.InetSocketAddress. "127.0.0.1" (int port)) 3000) (let [w (io/writer (.getOutputStream s))
   r (io/reader (.getInputStream s))]
  (.write w (str line "\n"))
  (.flush w)
  (.readLine r))))

(defn server-with-state [^DefcheckState state req]
  (edn/read-string (rpc (:server-port state) (pr-str req))))

(defn sidecar-with-state [^DefcheckState state ^String line]
  (json/parse-string (rpc (:sidecar-port state) line) true))

(defn ^Boolean sidecar-up-with-state? [^DefcheckState state]
  (try
  (:ok (sidecar-with-state state "ping"))
  (catch Exception _
    false)))

(defn ^Boolean ensure-sidecar-with-state! [^DefcheckState state]
  (or (sidecar-up-with-state? state) (if (:autostart? state) (do
  (let [launcher (str repo-root "/bin/beagle-store-defcheck")]
  (let [pb (ProcessBuilder. ["setsid" launcher (str (:sidecar-port state))])]
  (.redirectOutput pb (java.io.File. "/dev/null"))
  (.redirectError pb (java.io.File. "/dev/null"))
  (.start pb))
  (loop [n 0]
  (cond
  (sidecar-up-with-state? state) true
  (>= n 60) (throw (ex-info "beagle-store-defcheck sidecar failed to start" {:port (:sidecar-port state)}))
  :else (do
  (Thread/sleep 500)
  (recur (inc n))))))))))

(defn ^String gwdir-with-state [^DefcheckState state]
  (or (:gwdir state) (str (System/getProperty "java.io.tmpdir") "/beagle-store-defcheck-gw-" (:server-port state))))

(defn ^String src-path-with-state [^DefcheckState state ^String module]
  (str (gwdir-with-state state) "/" module ".bclj"))

(defn ^String edn-path-with-state [^DefcheckState state ^String module]
  (str (gwdir-with-state state) "/.edn/" module ".edn"))

(defn live-modules-with-state [^DefcheckState state]
  (if (:modules-fn state) (vec ((:modules-fn state))) (let [r (server-with-state state {:op :render :module "__nonexistent__"})]
  (vec (or (:srcs r) [])))))

(defn ^String render-edn-with-state! [^DefcheckState state ^String module]
  (let [edn (if (:render-fn state) ((:render-fn state) module) (let [resp (server-with-state state {:op :render :module module})]
  (if (:error resp) (do
  (throw (ex-info (str "render failed for " module ": " (:error resp)) {:module module}))))
  (:edn resp)))]
  (if (str/blank? (str edn)) (do
  (throw (ex-info (str "render returned no source for " module) {:module module}))))
  (let [p (edn-path-with-state state module)]
  (io/make-parents (io/file p))
  (spit p edn)
  p)))

(defn ^String refresh-sibling-with-state! [^DefcheckState state ^String module]
  (let [epath (render-edn-with-state! state module)]
  (io/make-parents (io/file (src-path-with-state state module)))
  (try
  (sidecar-with-state state (str "render " epath " " (src-path-with-state state module)))
  (catch Exception _
    nil))
  epath))

(defn ^String prime-gwdir-with-state! [^DefcheckState state]
  (ensure-sidecar-with-state! state)
  (doseq [m (live-modules-with-state state)]
  (try
  (refresh-sibling-with-state! state m)
  (catch Exception _
    nil)))
  (gwdir-with-state state))

(def parse-kinds #{"parse-error" "reader" "structural" "syntax" "read-error"})

(defn- diag->error [^String module diag]
  (let [kind (:kind diag)
   stage (if (contains? parse-kinds (str kind)) :parse :type)
   def-name (:name diag)
   line (or (:error-line diag) (:line diag))
   expected (:expected diag)
   got (:actual diag)
   msg (str/replace (str (:message diag)) BEAGLE-MESSAGE-RE "")
   fix (:fix_plan diag)
   suggestion (cond
  (map? fix) (or (:suggestion fix) (:message fix) (:summary fix))
  (string? fix) fix
  (and expected got) (str "make it a " expected " (currently " got ")"))
   nearest (:nearest diag)]
  (let [at0 {:module module}
   at1 (if def-name (assoc at0 :def def-name) at0)
   at2 (if line (assoc at1 :line line) at1)
   e0 {:ok false :stage stage :at at2 :message msg}
   e1 (if expected (assoc e0 :expected expected) e0)
   e2 (if got (assoc e1 :got got) e1)
   e3 (if suggestion (assoc e2 :suggestion suggestion) e2)
   e4 (if (seq nearest) (assoc e3 :nearest (vec nearest)) e3)
   e5 (if kind (assoc e4 :kind kind) e4)]
  (if (:error-code diag) (assoc e5 :error-code (:error-code diag)) e5))))

(defn- pick-primary [name errs]
  (or (first (filter (fn [e] (= name (get-in e [:at :def]))) errs)) (first errs)))

(defn check-module-errors-with-state! [^DefcheckState state ^String module]
  (let [epath (refresh-sibling-with-state! state module)
   resp (sidecar-with-state state (str "check " epath " " (src-path-with-state state module)))]
  (if (:ok resp) (mapv (fn [e] (diag->error module e)) (:errors resp)) [{:ok false :stage :type :at {:module module} :message (str "def-check infra error: " (:error resp))}])))

(defn- ^Boolean beagle-source? [^String src]
  (boolean (re-find BEAGLE-SOURCE-RE (str src))))

(defn- ^Boolean untyped-mode? [^String src]
  (let [mode (or (System/getenv "BEAGLE_STORE_DEFCHECK_MODE") "auto")]
  (cond
  (= mode "typed") false
  (= mode "untyped") true
  :else (not (beagle-source? src)))))

(defn ^String module-src-text-with-state! [^DefcheckState state ^String module]
  (refresh-sibling-with-state! state module)
  (slurp (src-path-with-state state module)))

(defn- read-forms [^String src]
  (let [rdr (java.io.PushbackReader. (java.io.StringReader. (str src)))
   opts {:read-cond :allow :features #{:clj} :eof :store.defcheck/eof}]
  (binding [*read-eval* false
   *default-data-reader-fn* (fn [_tag v] v)]
  (loop [acc []]
  (let [f (try
  (clojure.core/read opts rdr)
  (catch Throwable t
    {:store.defcheck/read-error (or (.getMessage t) (str (class t)))}))]
  (cond
  (and (map? f) (:store.defcheck/read-error f)) {:forms acc :read-error (:store.defcheck/read-error f)}
  (= f :store.defcheck/eof) {:forms acc}
  :else (recur (conj acc f))))))))

(def special-forms (set (map symbol ["def" "if" "do" "let" "let*" "fn" "fn*" "loop" "loop*" "recur" "throw" "try" "catch" "finally" "quote" "var" "monitor-enter" "monitor-exit" "new" "set!" "." "&" "deftype*" "reify*" "case*" "letfn*" "import*" "clojure.core/import*" "unquote" "unquote-splicing"])))

(def core-names (delay (set (map (comp symbol name) (set (keys (clojure.core/ns-publics 'clojure.core)))))))

(def def-heads (set (map symbol ["def" "defn" "defn-" "defonce" "def-" "defmacro" "definline" "defmulti" "defmethod" "deftype" "defrecord" "defprotocol" "declare" "defstruct" "extend-type" "extend-protocol" "extend"])))

(def thread-heads (set (map symbol ["->" "->>" "some->" "some->>" "cond->" "cond->>" "as->" "doto"])))

(def binding-vec-heads (set (map symbol ["let" "let*" "loop" "loop*" "binding" "when-let" "if-let" "when-some" "if-some" "when-first" "with-open" "with-local-vars" "with-redefs" "dotimes"])))

(defn- pattern-locals [pat]
  (cond
  (symbol? pat) (if (= pat '&) #{} #{pat})
  (vector? pat) (set (mapcat pattern-locals pat))
  (map? pat) (reduce-kv (fn [acc k v] (cond
  (= k :keys) (into acc (map (comp symbol name) v))
  (= k :strs) (into acc (map (comp symbol name) v))
  (= k :syms) (into acc (map (comp symbol name) v))
  (= k :as) (conj acc v)
  (= k :or) acc
  (keyword? k) (into acc (pattern-locals k))
  :else (into acc (pattern-locals k)))) #{} pat)
  :else #{}))

(defn- arglist-locals [params]
  (set (mapcat pattern-locals (remove (fn [x] (= x '&)) params))))

(defn- fn-arities [tail]
  (let [tail (if (string? (first tail)) (drop 1 tail) tail)
   tail (if (map? (first tail)) (drop 1 tail) tail)
   bodies (cond
  (vector? (first tail)) [(first tail)]
  (and (seq? (first tail)) (vector? (ffirst tail))) (map first tail)
  :else nil)]
  (if (seq bodies) (do
  (reduce (fn [acc params] (let [amp (.indexOf (vec params) '&)
   fixed (if (neg? amp) (count params) amp)]
  (if (neg? amp) (update acc :fixed conj fixed) (update acc :variadic (fnil min fixed) fixed)))) {:fixed #{} :variadic nil} bodies)))))

(defn- collect-defs [forms]
  (reduce (fn [acc form] (if (and (seq? form) (symbol? (first form))) (let [h (first form)
   nm (if (>= (count form) 2) (do
  (first (rest form))))
   base (fn [a s] (if (symbol? s) (update a :names conj (symbol (name s))) a))]
  (cond
  (or (= h 'defn) (= h 'defn-) (= h 'defmacro) (= h 'definline)) (let [nm* (symbol (name nm))]
  (assoc-in (base acc nm) [:arities nm*] (fn-arities (drop 2 form))))
  (or (= h 'def) (= h 'defonce) (= h 'def-) (= h 'defstruct) (= h 'defmulti)) (base acc nm)
  (= 'declare h) (reduce base acc (rest form))
  (or (= h 'deftype) (= h 'defrecord)) (update (base acc nm) :names into (if (symbol? nm) (do
  [(symbol (str "->" (name nm))) (symbol (str "map->" (name nm))) (symbol (str (name nm) "."))])))
  (= 'defprotocol h) (reduce (fn [a sig] (if (and (seq? sig) (symbol? (first sig))) (base a (first sig)) a)) (base acc nm) (drop 2 form))
  :else acc)) acc)) {:names #{} :arities {}} forms))

(defn- parse-require-spec [acc spec]
  (cond
  (symbol? spec) (update acc :ns-names conj spec)
  (vector? spec) (let [nsym (first spec)
   opts (if (and (keyword? (second spec)) (even? (count (rest spec)))) (do
  (apply hash-map (rest spec))))]
  (let [a0 (update acc :ns-names conj nsym)
   a1 (if (:as opts) (update a0 :aliases conj (:as opts)) a0)
   a2 (if (:as-alias opts) (update a1 :aliases conj (:as-alias opts)) a1)
   a3 (if (= :all (:refer opts)) (assoc a2 :refer-all? true) a2)]
  (if (sequential? (:refer opts)) (update a3 :refers into (:refer opts)) a3)))
  :else acc))

(defn- parse-ns-env [forms]
  (let [empty' {:aliases #{} :refers #{} :ns-names #{} :imports #{} :refer-all? false}
   add-import (fn [acc spec] (cond
  (symbol? spec) (update acc :imports conj (symbol (peek (str/split (name spec) DOT-RE))))
  (sequential? spec) (update acc :imports into (map (fn [imported] (symbol (name imported))) (rest spec)))
  :else acc))
   handle-clause (fn [acc clause] (if (seq? clause) (let [k (first clause)]
  (cond
  (contains? #{:require :require-macros} k) (reduce parse-require-spec acc (rest clause))
  (= :use k) (assoc acc :refer-all? true)
  (= :import k) (reduce add-import acc (rest clause))
  :else acc)) acc))]
  (reduce (fn [acc form] (if (and (seq? form) (symbol? (first form))) (let [head (first form)]
  (cond
  (= head 'ns) (reduce handle-clause acc (drop 2 form))
  (= head 'require) (reduce parse-require-spec acc (map (fn [x] (if (and (seq? x) (= 'quote (first x))) (second x) x)) (rest form)))
  (= head 'use) (assoc acc :refer-all? true)
  (= head 'import) (reduce add-import acc (rest form))
  :else acc)) acc)) empty' forms)))

(defn- lev [a b]
  (let [a (str a)
   b (str b)
   m (count a)
   n (count b)]
  (if (or (zero? m) (zero? n)) (max m n) (loop [i 1
   prev (vec (range (inc n)))]
  (if (> i m) (peek prev) (recur (inc i) (reduce (fn [cur j] (conj cur (if (= (.charAt a (dec i)) (.charAt b (dec j))) (nth prev (dec j)) (inc (min (nth prev j) (peek cur) (nth prev (dec j))))))) [i] (vec (range 1 (inc n))))))))))

(defn- nearest [sym candidates]
  (let [s (name sym)
   thr (max 2 (quot (count s) 3))]
  (mapv (comp str first) (take 2 (sort-by second (filter (fn [pair] (<= (nth pair 1) thr)) (map (fn [c] [c (lev s (name c))]) candidates)))))))

(defn- ^Boolean anon-arg? [s]
  (boolean (re-matches ANON-ARG-RE (name s))))

(defn- ^Boolean interop-sym? [s]
  (let [n (name s)]
  (or (str/starts-with? n ".") (str/ends-with? n ".") (str/includes? n "/") (str/includes? n "."))))

(defn- ^Boolean class-like? [s]
  (boolean (re-matches CLASS-LIKE-RE (name s))))

(defn- ^Boolean qualifier-known? [env s]
  (let [q (namespace s)]
  (or (nil? q) (contains? (:aliases env) (symbol q)) (contains? (:ns-names env) (symbol q)) (contains? (:imports env) (symbol q)) (str/includes? q ".") (re-matches CLASS-LIKE-RE q))))

(defn- ^Boolean resolved-sym? [env defs locals s]
  (or (contains? locals s) (= s '&) (anon-arg? s) (if (namespace s) (qualifier-known? env s) (let [n (symbol (name s))]
  (or (contains? special-forms n) (contains? (:names defs) n) (contains? (:refers env) n) (contains? (clojure.core/deref core-names) n) (interop-sym? s) (class-like? s))))))

(defn- unresolved-error [^String module def-name env defs s]
  (let [cands (into (vec (:names defs)) (:refers env))]
  {:ok false :stage :type :at (if def-name {:module module :def def-name} {:module module}) :message (str "unresolved symbol `" s "` in " def-name " — not a local, an own def, a :require refer/alias, clojure.core, or interop") :got (str s) :suggestion "define it, require/refer it, or fix the name" :nearest (nearest s cands) :kind "unresolved-symbol"}))

(defn- arity-error [^String module def-name f n arities]
  (let [{:keys [fixed variadic]} arities]
  {:nearest [(str f)] :stage :type :suggestion (str "call `" f "` with " (str/join " or " (sort fixed)) " argument(s)") :got (str n) :ok false :kind "arity-mismatch" :at (if def-name {:module module :def def-name} {:module module}) :expected (str/join "/" (sort fixed)) :message (str "arity mismatch: `" f "` called with " n " arg(s), but is defined for " (str/join "/" (sort fixed)) (if variadic (do
  (str " (or " variadic "+)"))))}))

(defn- walk-fn-tail [rec ls0 tail]
  (let [tail (if (string? (first tail)) (rest tail) tail)
   tail (if (map? (first tail)) (rest tail) tail)]
  (cond
  (vector? (first tail)) (let [ls (into ls0 (arglist-locals (first tail)))]
  (doseq [b (rest tail)]
  (rec b ls)))
  :else (doseq [a tail
   :when (and (seq? a) (vector? (first a)))]
  (let [ls (into ls0 (arglist-locals (first a)))]
  (doseq [b (rest a)]
  (rec b ls)))))))

(defn walk-body-with-state! [^Boolean arity-check? ^String module def-name env defs errs form locals]
  (let [rec (fn [f ls] (walk-body-with-state! arity-check? module def-name env defs errs f ls))
   rec-no-arity (fn [f ls] (walk-body-with-state! false module def-name env defs errs f ls))
   emit (fn [e] (swap! errs conj e))
   classify (fn [s ls] (if (and (symbol? s) (not (:refer-all? env)) (not (resolved-sym? env defs ls s))) (do
  (emit (unresolved-error module def-name env defs s)))))]
  (cond
  (symbol? form) (classify form locals)
  (or (vector? form) (set? form)) (doseq [x form]
  (rec x locals))
  (map? form) (doseq [x (mapcat identity form)]
  (rec x locals))
  (seq? form) (let [h (first form)]
  (cond
  (empty? form) nil
  (= 'quote h) nil
  (= 'var h) nil
  (= 'as-> h) (do
  (rec-no-arity (second form) locals)
  (let [ls (into locals (if (symbol? (nth form 2 nil)) (do
  [(nth form 2)])))]
  (doseq [b (drop 3 form)]
  (rec-no-arity b ls))))
  (contains? thread-heads h) (doseq [x (rest form)]
  (rec-no-arity x locals))
  (or (= h 'defn) (= h 'defn-) (= h 'defmacro) (= h 'definline)) (walk-fn-tail rec locals (drop 2 form))
  (or (= h 'def) (= h 'defonce) (= h 'def-)) (doseq [b (drop 2 form)]
  (rec b locals))
  (or (= h 'defmulti) (= h 'defstruct) (= h 'declare)) nil
  (or (= h 'fn) (= h 'fn*)) (let [named? (symbol? (second form))
   ls0 (into locals (if named? (do
  [(second form)])))
   tail (if named? (drop 2 form) (drop 1 form))]
  (walk-fn-tail rec ls0 tail))
  (contains? binding-vec-heads h) (let [bvec (second form)
   [ls _] (reduce (fn [pair binding-pair] (let [ls (nth pair 0)
   pat (nth binding-pair 0)
   e (nth binding-pair 1)]
  (rec e ls)
  [(into ls (pattern-locals pat)) nil])) [locals nil] (partition 2 (if (vector? bvec) bvec [])))]
  (doseq [b (drop 2 form)]
  (rec b ls)))
  (or (= h 'for) (= h 'doseq)) (let [bvec (if (vector? (second form)) (second form) [])
   ls (loop [pairs (partition 2 bvec)
   ls locals]
  (let [bind__1 (first pairs)]
  (if bind__1 (let [[k v] bind__1]
  (cond
  (= k :let) (recur (rest pairs) (reduce (fn [l pair] (let [p (nth pair 0)
   e (nth pair 1)]
  (rec e l)
  (into l (pattern-locals p)))) ls (partition 2 (if (vector? v) v []))))
  (contains? #{:when :while} k) (do
  (rec v ls)
  (recur (rest pairs) ls))
  :else (do
  (rec v ls)
  (recur (rest pairs) (into ls (pattern-locals k)))))) ls)))]
  (doseq [b (drop 2 form)]
  (rec b ls)))
  (= 'letfn h) (let [fspecs (if (vector? (second form)) (second form) [])
   fnames (into #{} (keep (fn [x] (if (and (seq? x) (symbol? (first x))) (do
  (first x)))) fspecs))
   ls0 (into locals fnames)]
  (doseq [fs fspecs]
  (if (and (seq? fs) (vector? (second fs))) (do
  (let [ls (into ls0 (arglist-locals (second fs)))]
  (doseq [b (drop 2 fs)]
  (rec b ls))))))
  (doseq [b (drop 2 form)]
  (rec b ls0)))
  (= 'catch h) (let [ls (into locals (if (symbol? (nth form 2 nil)) (do
  [(nth form 2)])))]
  (doseq [b (drop 3 form)]
  (rec b ls)))
  (or (= h 'new) (= h '.) (= h '..) (= h 'set!) (= h 'monitor-enter) (= h 'monitor-exit)) (doseq [x (rest form)]
  (if (not (symbol? x)) (do
  (rec x locals))))
  (= 'defmethod h) (let [after (drop 2 form)]
  (rec (first after) locals)
  (let [pv (second after)]
  (if (vector? pv) (do
  (let [ls (into locals (arglist-locals pv))]
  (doseq [b (drop 2 after)]
  (rec b ls)))))))
  (or (= h 'deftype) (= h 'defrecord) (= h 'reify) (= h 'extend-type) (= h 'extend-protocol) (= h 'proxy) (= h 'definterface)) (let [fields (nth form 2 nil)
   base (into locals (if (and (or (= h 'deftype) (= h 'defrecord)) (vector? fields)) (do
  (arglist-locals fields))))]
  (doseq [x (rest form)]
  (cond
  (and (seq? x) (vector? (second x))) (let [ls (into base (arglist-locals (second x)))]
  (doseq [b (drop 2 x)]
  (rec b ls)))
  (vector? x) (doseq [e x]
  (if (coll? e) (do
  (rec e base))))
  :else nil)))
  :else (do
  (if (symbol? h) (do
  (classify h locals)
  (let [ar (and (not (contains? locals h)) (get-in defs [:arities (symbol (name h))]))]
  (if ar (do
  (let [n (count (rest form))
   {:keys [fixed variadic]} ar]
  (if (and arity-check? (seq fixed) (not (contains? fixed n)) (or (nil? variadic) (< n variadic))) (do
  (emit (arity-error module def-name h n ar))))))))))
  (let [child-locals (into locals (mapcat (fn [x] (if (vector? x) (do
  (arglist-locals x)))) (rest form)))]
  (doseq [x (rest form)]
  (rec x child-locals))))))
  :else nil)))

(defn- def-target-name [form]
  (if (and (seq? form) (>= (count form) 2)) (do
  (let [nm (first (rest form))]
  (cond
  (symbol? nm) (symbol (name nm))
  (and (seq? nm) (symbol? (second nm))) (symbol (name (second nm)))
  :else nil)))))

(defn analyze-untyped-module-with-state! [^Boolean arity-check? ^String module ^String src]
  (let [{:keys [forms read-error]} (read-forms src)]
  (if read-error [{:ok false :stage :parse :at {:module module} :message (str "module did not read as Clojure: " read-error) :kind "read-error" :suggestion "fix the malformed form so the module parses"}] (let [env (parse-ns-env forms)
   defs (collect-defs forms)
   errs (atom [])]
  (doseq [form forms
   :when (and (seq? form) (symbol? (first form)) (contains? def-heads (first form)))]
  (walk-body-with-state! arity-check? module (def-target-name form) env defs errs form #{}))
  (clojure.core/deref errs)))))

(defn check-module-errors-any-with-state! [^DefcheckState state ^String module]
  (let [src (module-src-text-with-state! state module)]
  (if (untyped-mode? src) (analyze-untyped-module-with-state! (:arity-check? state) module src) (check-module-errors-with-state! state module))))

(defn check-def-with-state! [^String module name ensure-sidecar-fn check-errors-fn]
  (try
  (ensure-sidecar-fn)
  (let [errs (check-errors-fn module)]
  (if (seq errs) (do
  (assoc (pick-primary name errs) :errors errs))))
  (catch Exception e
    {:ok false :stage :type :at {:module module :def name} :message (str "def-check unavailable: " (.getMessage e))})))

(defn whole-tree-check-with-state! [ensure-sidecar-fn prime-gwdir-fn live-modules-fn check-errors-fn]
  (try
  (ensure-sidecar-fn)
  (prime-gwdir-fn)
  (let [all (vec (mapcat check-errors-fn (live-modules-fn)))]
  (if (seq all) (do
  (assoc (first all) :stage :gate :errors (mapv (fn [e] (assoc e :stage :gate)) all)))))
  (catch Exception e
    {:ok false :stage :gate :message (str "whole-tree-check unavailable: " (.getMessage e))})))
