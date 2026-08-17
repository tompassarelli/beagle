;; Structured typed bindings survive graph authoring, EDN projection, and the
;; canonical Beagle renderer. This is a scratch-only, no-socket regression.
(require '[fram.store :as c]
         '[fram.schema :as s]
         '[clojure.string :as str]
         '[clojure.java.io :as io]
         '[babashka.process :as proc]
         '[resolve-binds :as rb])

(def root (System/getProperty "user.dir"))
(def beagle-home
  (or (System/getenv "BEAGLE_HOME")
      (str (System/getProperty "user.home") "/code/beagle/main")))
(def beagle-bin
  (or (System/getenv "FRAM_BEAGLE") (str beagle-home "/bin/beagle")))

(doseq [[path label] [[(str root "/out/resolve.clj") "resolve entrypoint"]
                      [beagle-bin "Beagle CLI"]]]
  (when-not (.exists (io/file path))
    (println "SKIP — missing prerequisite:" label "(" path ")")
    (System/exit 0)))

(load-file (str root "/out/resolve.clj"))

(def checks (atom []))
(defn check! [label value]
  (swap! checks conj [label (boolean value)]))

(def work
  (str (System/getProperty "java.io.tmpdir")
       "/structured-binding-roundtrip-"
       (System/nanoTime)))
(.mkdirs (io/file work))

;; The graph representation must retain one typed binding as one structured
;; list. Aggregate destructuring is likewise one parameter entry, even though
;; it introduces multiple local names. A constraint remains the third child of
;; that same binding rather than becoming an adjacent parameter.
(resolve/resolve-edn! []
  (fn []
    (let [named (resolve/mint-datum! "demo" '(who String))
          named-kids (resolve/ordered-children named)
          constrained (resolve/mint-datum!
                       "demo"
                       '(who String validator?))
          constrained-kids (resolve/ordered-children constrained)
          aggregate (resolve/mint-datum!
                     "demo"
                     '([left right] (HVec Int Int)))
          aggregate-kids (resolve/ordered-children aggregate)
          config (resolve/mint-datum!
                  "demo"
                  '({:keys [host port]} Config))
          config-kids (resolve/ordered-children config)]
      (check! "named typed binding is a two-child list"
              (and (= "list" (resolve/kind-of named))
                   (= ["who" "String"]
                      (mapv resolve/sym-val named-kids))))
      (check! "constrained binding is one three-child list"
              (and (= "list" (resolve/kind-of constrained))
                   (= ["who" "String" "validator?"]
                      (mapv resolve/sym-val constrained-kids))))
      (check! "typed destructuring remains one binding plus one type"
              (and (= 2 (count aggregate-kids))
                   (= "#%brackets"
                      (resolve/head-sym (first aggregate-kids)))
                   (= "HVec"
                      (resolve/head-sym (second aggregate-kids)))))
      (check! "nominal Config types one map destructuring parameter"
              (and (= 2 (count config-kids))
                   (= "#%map" (resolve/head-sym (first config-kids)))
                   (= "Config" (resolve/sym-val (second config-kids))))))))

(def seed (str work "/demo.bclj"))
(spit seed
      (str "#lang beagle/clj\n"
           "(ns demo)\n"
           "(defrecord Point [(value String)])\n"
           "(defn validator? [(value Point)] Bool true)\n"
           "(defn canonical [(who Point validator?)] Point who)\n"
           "(defn shifted junk [(ghost Point validator?)] Point ghost)\n"
           "(defn malformed [(broken Point validator?)] Point)\n"))
(def seed-edn (str work "/demo.edn"))
(def emit-result
  (proc/sh {:out :string :err :string}
           beagle-bin "facts-roundtrip" "--emit-edn" seed))

(if-not (zero? (:exit emit-result))
  (check! "seed module emits as facts" false)
  (do
    (spit seed-edn (:out emit-result))
    (def rendered-edn (str work "/rendered.edn"))
    (resolve/resolve-edn! [seed-edn]
      (fn []
        (let [src (first resolve/srcs)
              forms (resolve/forms-of src)
              named-form (fn [expected]
                           (some (fn [form]
                                   (let [children
                                         (resolve/ordered-children form)]
                                     (when (= expected
                                              (resolve/sym-val
                                               (nth children 1 nil)))
                                       form)))
                                 forms))
              signatures (fn [form]
                           (let [children
                                 (resolve/ordered-children form)]
                             (rb/executable-signatures
                              resolve/rctx
                              resolve/*view*
                              (resolve/head-sym form)
                              (vec (drop 2 children)))))
              direct-binding (fn [form]
                               (let [params
                                     (some #(when (= "#%brackets"
                                                     (resolve/head-sym %))
                                              %)
                                           (resolve/ordered-children form))]
                                 (second
                                  (resolve/ordered-children params))))
              canonical (named-form "canonical")
              shifted (named-form "shifted")
              malformed (named-form "malformed")
              canonical-signatures (signatures canonical)
              canonical-parts
              (rb/typed-binding-parts
               resolve/rctx resolve/*view* (direct-binding canonical))
              shifted-parts
              (rb/typed-binding-parts
               resolve/rctx resolve/*view* (direct-binding shifted))
              malformed-parts
              (rb/typed-binding-parts
               resolve/rctx resolve/*view* (direct-binding malformed))
              canonical-body
              (last (resolve/ordered-children canonical))
              shifted-body (last (resolve/ordered-children shifted))
              module-defs (resolve/module-defs src)
              module-types (resolve/module-types src)]
          (check! "parser facts preserve one three-child constrained binding"
                  (= ["who" "Point" "validator?"]
                     (mapv resolve/sym-val
                           (resolve/ordered-children
                            (direct-binding canonical)))))
          (check! "canonical executable slots produce one resolver signature"
                  (= 1 (count canonical-signatures)))
          (check! "shifted and incomplete executable slots produce no signature"
                  (and (empty? (signatures shifted))
                       (empty? (signatures malformed))))
          (check! "canonical type, constraint, and body references resolve"
                  (and (= (get module-types "Point")
                          (resolve/refers-target (:type canonical-parts)))
                       (= (get module-defs "validator?")
                          (resolve/refers-target
                           (:constraint canonical-parts)))
                       (= (:binding canonical-parts)
                          (resolve/refers-target canonical-body))))
          (check! "shifted executable children gain no resolver semantics"
                  (every? nil?
                          [(resolve/refers-target (:type shifted-parts))
                           (resolve/refers-target
                            (:constraint shifted-parts))
                           (resolve/refers-target shifted-body)]))
          (check! "incomplete executable children gain no resolver semantics"
                  (every? nil?
                          [(resolve/refers-target (:type malformed-parts))
                           (resolve/refers-target
                            (:constraint malformed-parts))])))
        (binding [resolve/*reject!*
                  (fn [code]
                    (throw (ex-info (str "verb rejected " code) {})))]
          (resolve/verb-upsert-form! "demo" '(def base String "Howdy"))
          (resolve/verb-upsert-form!
           "demo"
           '(defn greet [(who String)] String (str base ", " who "!"))))
        (resolve/extract-file! (first resolve/srcs) rendered-edn)))
    (let [facts (slurp rendered-edn)
          render-result (proc/sh {:out :string :err :string}
                                 beagle-bin "facts-roundtrip" "--render"
                                 rendered-edn)
          rendered (:out render-result)
          rendered-source (str work "/rendered.bclj")]
      (spit rendered-source rendered)
      (check! "rendered facts contain no retired annotation marker leaves"
              (and (not (str/includes? facts "\"v\" \":-\""))
                   (not (str/includes? facts "\"v\" \"->\""))))
      (check! "certified renderer accepts the authored graph"
              (zero? (:exit render-result)))
      (check! "rendered source preserves the structured typed binding"
              (str/includes? rendered "(who String)"))
      (check! "rendered source preserves the constrained binding"
              (str/includes? rendered "(who Point validator?)"))
      (check! "rendered source preserves shifted and incomplete slots as data"
              (and (str/includes? rendered "(defn shifted junk")
                   (str/includes? rendered
                                  "(defn malformed [(broken Point validator?)] Point)")))
      (check! "rendered source preserves the positional return type"
              (str/includes? rendered "] String"))
      (let [syntax-result (proc/sh {:out :string :err :string}
                                   beagle-bin "syntax" rendered-source)]
        (check! "rendered source passes Beagle syntax"
                (zero? (:exit syntax-result)))))))

(println "\n=== structured binding graph round-trip ===")
(let [failures (remove second @checks)]
  (doseq [[label ok?] @checks]
    (println (if ok? "  [PASS] " "  [FAIL] ") label))
  (if (empty? failures)
    (do
      (println "\nPASS —" (count @checks) "/" (count @checks))
      (System/exit 0))
    (do
      (println "\nFAIL —" (count failures) "of" (count @checks))
      (System/exit 1))))
