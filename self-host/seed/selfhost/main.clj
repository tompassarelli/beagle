(ns selfhost.main
  (:gen-class)
  (:require [clojure.string :as str]
            [selfhost.rt :as rt]
            [selfhost.reader :as rd]
            [selfhost.ast :as syntax]
            [selfhost.parse :as p]
            [selfhost.check :as c]
            [selfhost.emit-clj :as e]
            [selfhost.emit-nix :as en]
            [selfhost.emit-js :as ejs]
            [selfhost.facts-roundtrip :as fr]))

(def CHECKED-PROGRAM-SCHEMA-VERSION 4)

(def HOSTED-NATIVE-NOT-APPLICABLE 200)

(def ^String IMPORTED-RECORD-CONTRACTS-KEY "$beagle$selfhost$imported-record-contracts")

(def ^String IMPORTED-CALLABLE-SYNCHRONIZATION-KEY "$beagle$selfhost$imported-callable-synchronization")

(def MODULE-SURFACE-CACHE (atom {}))

(def MODULE-LOAD-STACK (atom {}))

(def MODULE-SOURCE-UNIT-CACHE (atom {}))

(def MODULE-REQUIRE-CACHE (atom {}))

(def MODULE-RESOLUTION-EDGE-CACHE (atom {}))

(def FOREIGN-INTERFACE-CACHE (atom {}))

(def FOREIGN-PROJECT-ROOT (atom nil))

(def ^String FOREIGN-INTERFACES-KEY "$beagle$selfhost$foreign-interfaces")

(defn- read-source-unit! [^String path]
  (let [absolute-path (selfhost.rt/abs-path path)
   cached (get (deref MODULE-SOURCE-UNIT-CACHE) absolute-path)]
  (if (some? cached) cached (let [snapshot (selfhost.rt/read-source-snapshot absolute-path)
   source-text (get snapshot "text")
   source-id (selfhost.rt/source-id absolute-path)
   reader-output (rd/read-program-with-syntax! source-text source-id)
   reader-errors (get reader-output "errors")
   unit {"path" absolute-path "text" source-text "source-sha256" (get snapshot "sourceSha256") "source-id" source-id "datums" (get reader-output "datums") "syntaxes" (get reader-output "syntaxes")}]
  (if (> (count reader-errors) 0) (do
  (selfhost.rt/exit 1)
  unit) (do
  (swap! MODULE-SOURCE-UNIT-CACHE assoc absolute-path unit)
  unit))))))

(declare parse-file-target!)

(def MODULE-RESOLUTION (atom {"providers" {} "roots" []}))

(defn- split-dots [^String s]
  (loop [i 0
   start 0
   acc []]
  (cond
  (>= i (count s)) (conj acc (subs s start i))
  (= (subs s i (+ i 1)) ".") (recur (+ i 1) (+ i 1) (conj acc (subs s start i)))
  :else (recur (+ i 1) start acc))))

(defn- ^String ns-relative-source-path [^String ns ^String extension]
  (loop [i 0
   ^String acc ""]
  (if (>= i (count ns)) (str acc extension) (let [c (subs ns i (+ i 1))]
  (recur (+ i 1) (str acc (cond
  (= c ".") "/"
  (= c "-") "_"
  :else c)))))))

(defn- ^String source-extension [^String path]
  (loop [i (- (count path) 1)]
  (cond
  (< i 0) ""
  (= (subs path i (+ i 1)) "/") ""
  (= (subs path i (+ i 1)) ".") (subs path i (count path))
  :else (recur (- i 1)))))

(defn- module-declared-ns [datums]
  (loop [i 0]
  (if (>= i (count datums)) nil (let [d (nth datums i)]
  (if (and (vector? d) (>= (count d) 2) (= (nth d 0) "ns") (string? (nth d 1))) (nth d 1) (recur (+ i 1)))))))

(defn- declared-extern-names [datums]
  (reduce (fn [names d] (if (and (vector? d) (>= (count d) 2) (= (nth d 0) "declare-extern")) (let [head (nth d 1)]
  (cond
  (string? head) (conj names head)
  (and (vector? head) (> (count head) 1) (= (nth head 0) "#%brackets")) (into names (filterv string? (subvec head 1)))
  :else names)) names)) [] datums))

(defn- parse-module-root-spec! [^String spec]
  (let [eq (loop [i 0]
  (cond
  (>= i (count spec)) -1
  (= (subs spec i (+ i 1)) "=") i
  :else (recur (+ i 1))))]
  (if (or (< eq 1) (>= (+ eq 1) (count spec))) (do
  (selfhost.rt/eprint (str "beagle [module]: --module-root expects" " LOGICAL_PREFIX=PHYSICAL_DIRECTORY, got " spec "\n"))
  (selfhost.rt/exit 2)
  nil) {"logical" (subs spec 0 eq) "dir" (subs spec (+ eq 1) (count spec))})))

(defn- register-bundle-source! [providers ^String path]
  (if (not (selfhost.rt/file-exists? path)) (do
  (selfhost.rt/eprint (str "beagle [module]: bundle source does not exist: " path "\n"))
  (selfhost.rt/exit 1)
  providers) (let [unit (read-source-unit! path)
   ns (module-declared-ns (get unit "datums"))]
  (if (nil? ns) providers (let [absolute (get unit "path")
   existing (get providers ns [])
   already (filterv (fn [^String p] (= p absolute)) existing)]
  (if (> (count already) 0) providers (assoc providers ns (conj existing absolute))))))))

(defn- install-module-resolution! [root-specs source-paths project-root]
  (reset! MODULE-SOURCE-UNIT-CACHE {})
  (reset! MODULE-REQUIRE-CACHE {})
  (reset! MODULE-RESOLUTION-EDGE-CACHE {})
  (reset! MODULE-SURFACE-CACHE {})
  (reset! MODULE-LOAD-STACK {})
  (reset! FOREIGN-INTERFACE-CACHE {})
  (reset! FOREIGN-PROJECT-ROOT project-root)
  (reset! MODULE-RESOLUTION {"providers" (reduce register-bundle-source! {} source-paths) "roots" (mapv parse-module-root-spec! root-specs)})
  nil)

(defn- ^String join-comma [xs]
  (reduce (fn [^String acc ^String x] (if (= acc "") x (str acc ", " x))) "" xs))

(defn- root-candidate-paths [^String rn ^String importer-extension]
  (let [relative (ns-relative-source-path rn importer-extension)]
  (reduce (fn [hits root] (let [candidate (str (get root "dir") "/" relative)]
  (if (selfhost.rt/file-exists? candidate) (conj hits (selfhost.rt/abs-path candidate)) hits))) [] (get (deref MODULE-RESOLUTION) "roots"))))

(defn- resolve-required-source! [^String rn ^String source-path]
  (let [absolute-source (selfhost.rt/abs-path source-path)
   edge-key (str absolute-source "\n" rn)
   cached (get (deref MODULE-RESOLUTION-EDGE-CACHE) edge-key)]
  (if (some? cached) (get cached "path") (let [providers (get (get (deref MODULE-RESOLUTION) "providers") rn [])
   path (cond
  (> (count providers) 1) (do
  (selfhost.rt/eprint (str "beagle [module]: namespace " rn " required by " absolute-source " has multiple explicit providers: " (join-comma providers) "\n"))
  (selfhost.rt/exit 1)
  nil)
  (= (count providers) 1) (nth providers 0)
  :else (let [candidates (root-candidate-paths rn (source-extension absolute-source))]
  (cond
  (> (count candidates) 1) (do
  (selfhost.rt/eprint (str "beagle [module]: namespace " rn " required by " absolute-source " collides across module roots: " (join-comma candidates) "\n"))
  (selfhost.rt/exit 1)
  nil)
  (= (count candidates) 1) (nth candidates 0)
  :else nil)))]
  (swap! MODULE-RESOLUTION-EDGE-CACHE assoc edge-key {"path" path})
  path))))

(defn- ^Boolean host-required-ns? [^String rn ^String _target]
  (or (str/starts-with? rn "clojure.") (str/starts-with? rn "babashka.")))

(defn- ^Boolean extern-authorized-require? [extern-names ^String rn ^String prefix refer-syms]
  (if (and (some? refer-syms) (> (count refer-syms) 0)) (every? (fn [^String name] (> (count (filterv (fn [^String e] (or (= e name) (= e (str prefix "/" name)) (= e (str rn "/" name)))) extern-names)) 0)) refer-syms) (> (count (filterv (fn [^String e] (or (str/starts-with? e (str prefix "/")) (str/starts-with? e (str rn "/")))) extern-names)) 0)))

(defn- ^String require-prefix [require]
  (let [alias (get require "alias")
   ns (get require "ns")]
  (if (and (some? alias) (not (= alias false))) alias (let [segs (split-dots ns)]
  (nth segs (- (count segs) 1))))))

(defn- require-refer-syms [require]
  (let [refer (get require "refer")]
  (if (and (some? refer) (not (= refer false))) refer nil)))

(defn- member-demand-name [^String value]
  (cond
  (and (str/starts-with? value ".-") (> (count value) 2)) (subs value 2)
  (and (str/starts-with? value ".") (> (count value) 1)) (subs value 1)
  :else nil))

(defn- foreign-member-demand*! [value names]
  (cond
  (string? value) (let [name (member-demand-name value)]
  (if (some? name) (do
  (swap! names assoc name true))))
  (vector? value) (do
  (if (and (> (count value) 1) (= (nth value 0) "#%map")) (do
  (doseq [index (range 1 (count value) 2)]
  (let [key (nth value index)]
  (if (and (string? key) (str/starts-with? key ":") (> (count key) 1)) (do
  (swap! names assoc (subs key 1) true)))))))
  (doseq [child value]
  (foreign-member-demand*! child names)))
  (map? value) (doseq [key (keys value)]
  (foreign-member-demand*! (get value key) names))
  :else nil)
  nil)

(defn- foreign-member-demand! [datums]
  (let [names (atom {})]
  (foreign-member-demand*! datums names)
  (vec (sort (keys (deref names))))))

(defn- checked-foreign-interface! [require source-unit]
  (let [module-specifier (get require "ns")
   requested-exports (require-refer-syms require)
   requested-members (foreign-member-demand! (get source-unit "datums"))
   project-root (deref FOREIGN-PROJECT-ROOT)
   source-path (get source-unit "path")]
  (cond
  (or (nil? requested-exports) (= (count requested-exports) 0)) (do
  (selfhost.rt/eprint (str "beagle [foreign]: native ESM module " module-specifier " requires an explicit non-empty :refer root set\n"))
  (selfhost.rt/exit 1)
  nil)
  (not (string? project-root)) (do
  (selfhost.rt/eprint (str "beagle [foreign]: --project-root is required for native ESM module " module-specifier "\n"))
  (selfhost.rt/exit 2)
  nil)
  :else (let [cache-key (str project-root "\n" source-path "\n" module-specifier "\n" requested-exports "\n" requested-members)
   cached (get (deref FOREIGN-INTERFACE-CACHE) cache-key)]
  (if (some? cached) cached (let [interface (selfhost.rt/foreign-interface-v1 project-root source-path module-specifier requested-exports requested-members)
   stats (get interface "stats")]
  (if (not (and (= (get interface "kind") "ForeignInterfaceV1") (= (get interface "schemaVersion") 1) (= (get interface "frontend") "typescript") (= (get interface "moduleSpecifier") module-specifier) (= (get stats "anyCount") 0) (= (get stats "obligationCount") 0))) (do
  (selfhost.rt/eprint (str "beagle [foreign]: native interface for " module-specifier " is not a closed no-Any ForeignInterfaceV1 graph\n"))
  (selfhost.rt/exit 1)
  nil) (let [entry {"graph" interface "prefix" (require-prefix require) "refer" requested-exports}]
  (swap! FOREIGN-INTERFACE-CACHE assoc cache-key entry)
  entry))))))))

(defn- read-required-source-unit! [^String required-ns ^String path]
  (let [unit (read-source-unit! path)
   provider-ns (module-declared-ns (get unit "datums"))]
  (if (= provider-ns required-ns) unit (do
  (selfhost.rt/eprint (str "beagle [module]: required namespace " required-ns " resolved to " (get unit "path") " which declares " (if (some? provider-ns) provider-ns "no namespace") "\n"))
  (selfhost.rt/exit 1)
  unit))))

(defn- unresolved-required-source! [^String rn ^String source-path]
  (selfhost.rt/eprint (str "beagle [module]: required namespace " rn " could not be resolved (required by " source-path "); it is absent from the closed source bundle and no" " declared module root provides it\n"))
  (selfhost.rt/exit 1)
  nil)

(defn- discover-source-requires! [unit]
  (let [path (get unit "path")
   cached (get (deref MODULE-REQUIRE-CACHE) path)]
  (if (some? cached) (get cached "requires") (do
  (p/reset-errors!)
  (let [requires (p/discover-requires-reporting! (get unit "datums"))
   errors (p/parse-errors)]
  (if (> (count errors) 0) (do
  (selfhost.rt/exit 1)
  []) (do
  (swap! MODULE-REQUIRE-CACHE assoc path {"requires" requires})
  requires)))))))

(defn- require-route! [require source-unit ^String target]
  (if (p/native-esm-require? require) (if (and (= target "js") (not (p/renamed-require? require))) {"kind" "foreign" "applicable" true "require" require} {"kind" "unsupported" "applicable" false}) (let [ns (get require "ns")
   prefix (require-prefix require)
   refer-syms (require-refer-syms require)
   applicable (not (p/renamed-require? require))
   source-path (get source-unit "path")
   path (resolve-required-source! ns source-path)]
  (cond
  (some? path) {"kind" "source" "applicable" applicable "unit" (read-required-source-unit! ns path) "prefix" prefix "refer" refer-syms}
  (or (host-required-ns? ns target) (extern-authorized-require? (declared-extern-names (get source-unit "datums")) ns prefix refer-syms)) {"kind" "host" "applicable" applicable}
  :else (do
  (unresolved-required-source! ns source-path)
  {"kind" "unresolved"})))))

(declare admit-source-unit*!)

(defn- admit-source-unit*! [unit ^String target state]
  (let [path (get unit "path")]
  (if (= true (get (get state "seen") path)) state (reduce (fn [current require] (let [route (require-route! require unit target)
   kind (get route "kind")
   next (if (= true (get route "applicable")) current (assoc current "admitted" false))]
  (cond
  (= kind "source") (admit-source-unit*! (get route "unit") target next)
  :else next))) (assoc state "seen" (assoc (get state "seen") path true)) (discover-source-requires! unit)))))

(defn- ^Boolean admit-source-graph! [^String path ^String target]
  (= true (get (admit-source-unit*! (read-source-unit! path) target {"admitted" true "seen" {}}) "admitted")))

(defn- dedup-externs [xs]
  (loop [i 0
   seen {}
   acc []]
  (if (>= i (count xs)) acc (let [e (nth xs i)
   nm (get e "name")]
  (if (= true (get seen nm)) (recur (+ i 1) seen acc) (recur (+ i 1) (assoc seen nm true) (conj acc e)))))))

(defn- surface-type-aliases [surfaces]
  (reduce (fn [aliases surface] (into aliases (get surface "type-aliases" {}))) {} surfaces))

(defn- checked-module-surface! [^String path ^String target imported-aliases]
  (let [absolute-path (selfhost.rt/abs-path path)
   cache-key (str target "\n" absolute-path)
   cached (get (deref MODULE-SURFACE-CACHE) cache-key)]
  (cond
  (some? cached) cached
  (= true (get (deref MODULE-LOAD-STACK) cache-key)) (do
  (selfhost.rt/eprint (str "beagle [module]: cyclic checked module dependency at " absolute-path "\n"))
  (selfhost.rt/exit 1)
  nil)
  :else (do
  (swap! MODULE-LOAD-STACK assoc cache-key true)
  (let [snapshot (parse-file-target! absolute-path target)
   prog (get snapshot "program")
   errors (c/check-program! prog)]
  (if (> (count errors) 0) (do
  (doseq [err errors]
  (selfhost.rt/eprint (str "beagle [check]: " err "\n")))
  (selfhost.rt/exit 1)
  nil) (let [surface {"datums" (get snapshot "datums") "imported-nominal-type-names" (get snapshot "imported-nominal-type-names") "type-aliases" (p/module-type-aliases-with-imports! (get snapshot "datums") "" nil imported-aliases) "record-contracts" (c/export-checked-record-contracts! prog) "callable-synchronization" (c/export-checked-callable-synchronization! prog)}]
  (swap! MODULE-SURFACE-CACHE assoc cache-key surface)
  (swap! MODULE-LOAD-STACK dissoc cache-key)
  surface)))))))

(declare load-import-surfaces*!)

(defn- unsupported-route-invariant! [^String source-path]
  (selfhost.rt/eprint (str "beagle [internal]: unsupported require reached final loading for " source-path " after native graph admission\n"))
  (selfhost.rt/exit 2)
  nil)

(defn- load-import-surfaces*! [source-unit ^String target seen-paths]
  (reduce (fn [surfaces require] (let [route (require-route! require source-unit target)
   kind (get route "kind")]
  (cond
  (not (= true (get route "applicable"))) (do
  (unsupported-route-invariant! (get source-unit "path"))
  surfaces)
  (= kind "source") (let [unit (get route "unit")
   path (get unit "path")
   prefix (get route "prefix")
   refer-syms (get route "refer")]
  (if (= true (get seen-paths path)) surfaces (let [datums (get unit "datums")
   dependency-surfaces (load-import-surfaces*! unit target (assoc seen-paths path true))
   imported-aliases (surface-type-aliases dependency-surfaces)
   checked-surface (checked-module-surface! path target imported-aliases)
   type-aliases (p/module-type-aliases-with-imports! datums prefix refer-syms imported-aliases)]
  (conj surfaces (assoc checked-surface "path" path "prefix" prefix "refer" refer-syms "imported-aliases" imported-aliases "type-aliases" type-aliases)))))
  (= kind "foreign") (conj surfaces (assoc (checked-foreign-interface! (get route "require") source-unit) "foreign" true))
  :else surfaces))) [] (discover-source-requires! source-unit)))

(defn- load-import-surfaces! [source-unit ^String target]
  (load-import-surfaces*! source-unit target {(get source-unit "path") true}))

(defn- import-parametric-arities! [surfaces]
  (reduce (fn [arities surface] (if (= true (get surface "foreign")) (reduce (fn [out export] (let [node-id (get export "node")
   node (first (filterv (fn [candidate] (= (get candidate "id") node-id)) (get (get surface "graph") "nodes")))
   signatures (get node "constructSignatures" [])
   arity (if (= (count signatures) 0) (count (get node "typeParameters" [])) (count (get (nth signatures 0) "capturedTypeParameters" [])))]
  (if (> arity 0) (assoc out (get export "name") arity) out))) arities (get (get surface "graph") "exports")) (into arities (p/module-parametric-arities! (get surface "datums") (get surface "prefix") (get surface "refer"))))) {} surfaces))

(defn- import-type-aliases [surfaces]
  (surface-type-aliases surfaces))

(defn- import-nominal-type-names! [surfaces]
  (reduce (fn [names surface] (if (= true (get surface "foreign")) (reduce (fn [out export] (assoc out (get export "name") true)) names (get (get surface "graph") "exports")) (into names (p/module-nominal-type-names-with-imports! (get surface "datums") (get surface "prefix") (get surface "refer") (get surface "imported-nominal-type-names" {}))))) {} surfaces))

(defn- resolve-imports! [prog surfaces]
  (let [own-externs (get prog "externs")
   imported (reduce (fn [acc surface] (if (= true (get surface "foreign")) acc (into acc (mapv (fn [extern] (assoc extern "synchronous" false "returnsSynchronousCallable" false)) (p/import-module-surface-with-aliases! (get surface "datums") (get surface "prefix") (get surface "refer") (get surface "imported-aliases")))))) [] surfaces)
   record-contracts (reduce (fn [acc surface] (if (= true (get surface "foreign")) acc (into acc (p/qualify-imported-record-contracts (get surface "record-contracts") (get surface "prefix") (get surface "refer"))))) [] surfaces)
   callable-synchronization (reduce (fn [acc surface] (if (= true (get surface "foreign")) acc (into acc (p/qualify-imported-callable-synchronization (get surface "callable-synchronization") (get surface "prefix") (get surface "refer"))))) [] surfaces)]
  (assoc prog "externs" (dedup-externs (into own-externs imported)) IMPORTED-RECORD-CONTRACTS-KEY record-contracts IMPORTED-CALLABLE-SYNCHRONIZATION-KEY callable-synchronization FOREIGN-INTERFACES-KEY (filterv (fn [surface] (= true (get surface "foreign"))) surfaces))))

(defn- ^Boolean has-define-target? [datums]
  (> (count (filterv (fn [d] (and (vector? d) (>= (count d) 2) (= (nth d 0) "define-target"))) datums)) 0))

(defn- parse-file-target! [^String path ^String target]
  (let [source-unit (read-source-unit! path)
   ^String source-text (get source-unit "text")
   ^String source-id (get source-unit "source-id")
   datums0 (get source-unit "datums")
   syntaxes0 (get source-unit "syntaxes")
   datums (if (has-define-target? datums0) datums0 (into [["define-target" target]] datums0))
   syntaxes (if (has-define-target? datums0) syntaxes0 (into [(syntax/datum->beagle-syntax! ["define-target" target] nil syntax/EMPTY-SCOPE-SET nil {"reader" (syntax/make-reader-metadata "" "synthetic")})] syntaxes0))
   targeted-unit (assoc (assoc source-unit "datums" datums) "syntaxes" syntaxes)
   surfaces (load-import-surfaces! targeted-unit target)
   imported-arities (import-parametric-arities! surfaces)
   imported-aliases (import-type-aliases surfaces)
   imported-nominal-type-names (import-nominal-type-names! surfaces)
   prog (resolve-imports! (p/parse-program-with-syntax-and-imports! datums syntaxes imported-arities imported-aliases imported-nominal-type-names) surfaces)
   perrs (p/parse-errors)]
  (if (> (count perrs) 0) (do
  (selfhost.rt/exit 1)
  prog) {"program" prog "datums" datums "imported-nominal-type-names" imported-nominal-type-names "source-text" source-text "source-sha256" (get source-unit "source-sha256") "source-id" source-id})))

(defn- imported-record-field-order [prog]
  (reduce (fn [out contract] (assoc out (get contract "name") (mapv (fn [^String field] (if (str/starts-with? field ":") (subs field 1) field)) (get contract "field-order")))) {} (get prog IMPORTED-RECORD-CONTRACTS-KEY [])))

(defn- imported-record-namespaces [prog]
  (reduce (fn [out contract] (let [namespace (get contract "namespace")]
  (if (string? namespace) (assoc out (get contract "name") namespace) out))) {} (get prog IMPORTED-RECORD-CONTRACTS-KEY [])))

(defn- check-or-die! [prog]
  (let [errors (c/check-program! prog)]
  (if (> (count errors) 0) (do
  (doseq [err errors]
  (selfhost.rt/eprint (str "beagle [check]: " err "\n")))
  (selfhost.rt/exit 1)
  prog) (assoc (c/decorate-checked-program! prog) "importedRecordFieldOrder" (imported-record-field-order prog) "importedRecordNamespaces" (imported-record-namespaces prog)))))

(defn- ^String emit-for-target! [^String target prog]
  (cond
  (= target "js") (ejs/emit-program! prog)
  (= target "nix") (en/emit-program! prog)
  :else (e/emit-program! prog)))

(def CHECKED-PROGRAM-KEYS ["kind" "schemaVersion" "phase" "target" "namespace" "sourceId" "sourceSha256" "projectionSha256" "gen-class" "requires" "imports" "importedRecordFieldOrder" "importedRecordNamespaces" "externs" "forms"])

(defn- ^Boolean exact-checked-program-keys? [projection]
  (and (= (count (keys projection)) (count CHECKED-PROGRAM-KEYS)) (every? (fn [^String key] (contains? projection key)) CHECKED-PROGRAM-KEYS)))

(defn- ^Boolean contains-renamed-require? [requires]
  (boolean (some (fn [require] (p/renamed-require? require)) requires)))

(defn- ^Boolean complete-binding? [binding]
  (and (map? binding) (contains? binding "name") (contains? binding "constraint") (contains? binding "constraintSynchronous") (boolean? (get binding "constraintSynchronous")) (= (get binding "constraintSynchronous") (and (not (nil? (get binding "constraint"))) (not (false? (get binding "constraint")))))))

(defn- ^Boolean exact-object-keys? [value expected]
  (and (map? value) (= (count (keys value)) (count expected)) (every? (fn [^String key] (contains? value key)) expected)))

(defn- ^Boolean valid-record-update-contract? [contract]
  (and (exact-object-keys? contract ["recordName" "fieldOrder" "validator"]) (string? (get contract "recordName")) (vector? (get contract "fieldOrder")) (every? string? (get contract "fieldOrder")) (or (nil? (get contract "validator")) (string? (get contract "validator")))))

(defn- ^Boolean valid-record-field-access-contract? [contract]
  (and (exact-object-keys? contract ["recordName"]) (string? (get contract "recordName"))))

(defn- ^Boolean params-complete? [params]
  (and (vector? params) (every? (fn [param] (if (= (get param "type") "param") (complete-binding? param) true)) params)))

(defn- ^Boolean callable-shape-complete? [callable]
  (and (contains? callable "rest") (params-complete? (get callable "params")) (let [rest-param (get callable "rest")]
  (or (nil? rest-param) (false? rest-param) (and (= (get rest-param "type") "param") (complete-binding? rest-param))))))

(defn- ^Boolean bindings-complete? [bindings]
  (and (vector? bindings) (every? complete-binding? bindings)))

(declare constraint-schema-complete?)

(defn- ^Boolean map-children-complete? [value]
  (every? (fn [key] (constraint-schema-complete? (get value key))) (keys value)))

(defn- ^Boolean constraint-schema-complete? [value]
  (cond
  (vector? value) (every? constraint-schema-complete? value)
  (map? value) (let [node (get value "node")
   type (get value "type")
   local-ok (cond
  (= type "param") (complete-binding? value)
  (= type "binding") (complete-binding? value)
  (or (= node "defn") (= node "fn")) (callable-shape-complete? value)
  (= node "defn-multi") (every? callable-shape-complete? (get value "arities"))
  (= node "letfn") (every? callable-shape-complete? (get value "fns"))
  (or (= node "let") (= node "loop") (= node "binding") (= node "with-open")) (bindings-complete? (get value "bindings"))
  (or (= node "for") (= node "doseq")) (every? (fn [clause] (cond
  (= (get clause "type") "binding") (complete-binding? clause)
  (= (get clause "type") "let") (bindings-complete? (get clause "bindings"))
  :else true)) (get value "clauses"))
  (= node "record") (params-complete? (get value "fields"))
  (or (= node "defunion") (= node "deferror")) (let [member-fields (get value "member-fields")]
  (or (nil? member-fields) (false? member-fields) (every? (fn [name] (params-complete? (get member-fields name))) (keys member-fields))))
  (= node "defprotocol") (every? callable-shape-complete? (get value "methods"))
  (= node "extend-type") (every? (fn [impl] (every? callable-shape-complete? (get impl "methods"))) (get value "impls"))
  (= node "defscalar") (and (contains? value "predicates") (vector? (get value "predicates")))
  (= node "with") (and (contains? value "recordUpdate") (not (contains? value "validator")) (or (nil? (get value "recordUpdate")) (valid-record-update-contract? (get value "recordUpdate"))))
  (= node "kw-access") (and (contains? value "recordFieldAccess") (or (nil? (get value "recordFieldAccess")) (valid-record-field-access-contract? (get value "recordFieldAccess"))))
  :else true)]
  (and local-ok (map-children-complete? value)))
  :else true))

(defn- checked-projection [snapshot]
  (let [prog (get snapshot "program")
   externs (mapv (fn [extern] {"name" (get extern "name") "type" (get extern "type")}) (get prog "externs"))
   base {"kind" "beagle.checked-program" "schemaVersion" CHECKED-PROGRAM-SCHEMA-VERSION "phase" "checked" "target" (get prog "target") "namespace" (get prog "namespace") "sourceId" (get snapshot "source-id") "sourceSha256" (get snapshot "source-sha256") "gen-class" (get prog "gen-class") "requires" (get prog "requires") "imports" (get prog "imports") "importedRecordFieldOrder" (get prog "importedRecordFieldOrder") "importedRecordNamespaces" (get prog "importedRecordNamespaces") "externs" externs "forms" (get prog "forms")}]
  (assoc base "projectionSha256" (selfhost.rt/projection-sha256 base))))

(defn- invalid-projection! [^String message]
  (selfhost.rt/eprint (str "beagle [emit-from-ast]: " message "\n"))
  (selfhost.rt/exit 1)
  nil)

(defn- validate-checked-projection! [^String target projection]
  (cond
  (not (map? projection)) (invalid-projection! "input must be a checked-program JSON object")
  (not (exact-checked-program-keys? projection)) (invalid-projection! "checked-program keys do not match the v4 contract")
  (not (= (get projection "kind") "beagle.checked-program")) (invalid-projection! "kind must be beagle.checked-program")
  (not (= (get projection "schemaVersion") CHECKED-PROGRAM-SCHEMA-VERSION)) (invalid-projection! "schemaVersion must be 4")
  (not (= (get projection "phase") "checked")) (invalid-projection! "phase must be checked")
  (not (= (get projection "target") target)) (invalid-projection! (str "target mismatch: projection is " (get projection "target") ", command requested " target))
  (not (string? (get projection "namespace"))) (invalid-projection! "namespace must be a string")
  (not (or (nil? (get projection "sourceId")) (string? (get projection "sourceId")))) (invalid-projection! "sourceId must be a string or null")
  (not (selfhost.rt/valid-sha256? (get projection "sourceSha256"))) (invalid-projection! "sourceSha256 must be a lowercase sha256 digest")
  (not (vector? (get projection "requires"))) (invalid-projection! "requires must be an array")
  (contains-renamed-require? (get projection "requires")) (invalid-projection! "a checked program with :rename must enter through source graph admission")
  (not (and (vector? (get projection "imports")) (every? string? (get projection "imports")))) (invalid-projection! "imports must be an array of class names")
  (not (vector? (get projection "externs"))) (invalid-projection! "externs must be an array")
  (not (vector? (get projection "forms"))) (invalid-projection! "forms must be an array")
  (not (constraint-schema-complete? (get projection "forms"))) (invalid-projection! "checked-program binding constraint schema is incomplete")
  (not (selfhost.rt/valid-projection-sha256? projection)) (invalid-projection! "projectionSha256 does not match the canonical checked program")
  :else projection))

(defn- cmd-ast! [^String path ^String target]
  (let [snapshot (parse-file-target! path target)
   prog (check-or-die! (get snapshot "program"))]
  (println (selfhost.rt/canonical-json (checked-projection (assoc snapshot "program" prog))))))

(defn- cmd-check! [^String path ^String target]
  (let [prog (get (parse-file-target! path target) "program")]
  (check-or-die! prog)
  (if (= (c/purity-severity) "warn") (do
  (c/check-purity! prog))))
  (selfhost.rt/eprint "ok\n"))

(defn- cmd-emit! [^String path ^String target]
  (print (emit-for-target! target (check-or-die! (get (parse-file-target! path target) "program")))))

(defn- run-admitted-source-command! [^String command root-specs source-paths project-root ^String path ^String target]
  (install-module-resolution! root-specs (conj source-paths path) project-root)
  (if (admit-source-graph! path target) (cond
  (= command "ast") (cmd-ast! path target)
  (= command "check") (cmd-check! path target)
  :else (cmd-emit! path target)) (selfhost.rt/exit HOSTED-NATIVE-NOT-APPLICABLE))
  nil)

(defn- cmd-emit-from-ast! [^String target]
  (print (emit-for-target! target (validate-checked-projection! target (selfhost.rt/parse-json (selfhost.rt/read-stdin))))))

(defn- ^String flag-value [args ^String flag ^String default]
  (loop [i 0]
  (if (>= i (count args)) default (cond
  (= (nth args i) "--") default
  (and (= (nth args i) flag) (< (+ i 1) (count args))) (nth args (+ i 1))
  :else (recur (+ i 1))))))

(defn- source-command-argument-error! [^String message]
  (selfhost.rt/eprint (str "beagle: " message "\n"))
  (selfhost.rt/exit 2)
  {})

(defn- ^Boolean source-command-target? [^String target]
  (or (= target "clj") (= target "js") (= target "nix")))

(defn- parse-source-command-args! [args]
  (loop [i 1
   after-double-dash? false
   ^String target "clj"
   target-seen? false
   project-root nil
   project-root-seen? false
   roots []
   sources []
   positionals []]
  (if (>= i (count args)) (cond
  (not (= (count positionals) 1)) (source-command-argument-error! (str "source command expects exactly one source path, got " (count positionals)))
  (not (source-command-target? target)) (source-command-argument-error! (str "unsupported source command target " target))
  :else {"target" target "roots" roots "sources" sources "project-root" project-root "path" (nth positionals 0)}) (let [arg (nth args i)]
  (cond
  after-double-dash? (recur (+ i 1) true target target-seen? project-root project-root-seen? roots sources (conj positionals arg))
  (= arg "--") (recur (+ i 1) true target target-seen? project-root project-root-seen? roots sources positionals)
  (= arg "--target") (cond
  target-seen? (source-command-argument-error! "source command accepts --target only once")
  (or (>= (+ i 1) (count args)) (= (nth args (+ i 1)) "--")) (source-command-argument-error! "source command --target requires a value")
  :else (recur (+ i 2) false (nth args (+ i 1)) true project-root project-root-seen? roots sources positionals))
  (= arg "--project-root") (cond
  project-root-seen? (source-command-argument-error! "source command accepts --project-root only once")
  (or (>= (+ i 1) (count args)) (= (nth args (+ i 1)) "--")) (source-command-argument-error! "source command --project-root requires a value")
  :else (recur (+ i 2) false target target-seen? (nth args (+ i 1)) true roots sources positionals))
  (= arg "--module-root") (if (or (>= (+ i 1) (count args)) (= (nth args (+ i 1)) "--")) (source-command-argument-error! "source command --module-root requires a value") (recur (+ i 2) false target target-seen? project-root project-root-seen? (conj roots (nth args (+ i 1))) sources positionals))
  (= arg "--source") (if (or (>= (+ i 1) (count args)) (= (nth args (+ i 1)) "--")) (source-command-argument-error! "source command --source requires a value") (recur (+ i 2) false target target-seen? project-root project-root-seen? roots (conj sources (nth args (+ i 1))) positionals))
  (str/starts-with? arg "--") (source-command-argument-error! (str "unsupported source command option " arg))
  :else (recur (+ i 1) false target target-seen? project-root project-root-seen? roots sources (conj positionals arg)))))))

(defn -main [& $beagle$rest$host]
  (let [args (vec $beagle$rest$host)]
  (let [cmd (if (> (count args) 0) (nth args 0) "")]
  (cond
  (or (= cmd "ast") (= cmd "check") (= cmd "emit")) (let [options (parse-source-command-args! args)]
  (run-admitted-source-command! cmd (get options "roots") (get options "sources") (get options "project-root") (get options "path") (get options "target")))
  (= cmd "emit-from-ast") (cmd-emit-from-ast! (flag-value args "--target" "clj"))
  (= cmd "facts-roundtrip") (fr/run! (rest args))
  :else (do
  (selfhost.rt/eprint "usage: selfhost.main [--target clj|js|nix] [--module-root LOGICAL=PHYSICAL]... [--source FILE]... ast|check|emit FILE, emit-from-ast < ast.json, or facts-roundtrip MODE FILE\n")
  (selfhost.rt/exit 2)))
  (flush))))
