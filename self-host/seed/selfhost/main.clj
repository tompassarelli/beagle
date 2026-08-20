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

(def ^String IMPORTED-RECORD-CONTRACTS-KEY "$beagle$selfhost$imported-record-contracts")

(def ^String IMPORTED-CALLABLE-SYNCHRONIZATION-KEY "$beagle$selfhost$imported-callable-synchronization")

(def MODULE-SURFACE-CACHE (atom {}))

(def MODULE-LOAD-STACK (atom {}))

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
   acc ""]
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

(defn- ns-token-end [^String text start]
  (loop [i start]
  (if (>= i (count text)) i (let [c (subs text i (+ i 1))]
  (if (or (= c " ") (= c ")") (= c "\n") (= c "\r") (= c "\t")) i (recur (+ i 1)))))))

(defn- declared-ns-of-source [^String path]
  (let [text (selfhost.rt/slurp-file path)
   n (count text)]
  (loop [i 0
   bol true]
  (cond
  (>= i n) nil
  (and bol (<= (+ i 4) n) (= (subs text i (+ i 4)) "(ns ")) (let [start (+ i 4)
   end (ns-token-end text start)]
  (if (> end start) (subs text start end) nil))
  :else (recur (+ i 1) (= (subs text i (+ i 1)) "\n"))))))

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
  providers) (let [ns (declared-ns-of-source path)]
  (if (nil? ns) providers (let [absolute (selfhost.rt/abs-path path)
   existing (get providers ns [])
   already (filterv (fn [^String p] (= p absolute)) existing)]
  (if (> (count already) 0) providers (assoc providers ns (conj existing absolute))))))))

(defn- install-module-resolution! [root-specs source-paths]
  (reset! MODULE-RESOLUTION {"providers" (reduce register-bundle-source! {} source-paths) "roots" (mapv parse-module-root-spec! root-specs)})
  nil)

(defn- ^String join-comma [xs]
  (reduce (fn [^String acc ^String x] (if (= acc "") x (str acc ", " x))) "" xs))

(defn- root-candidate-paths [^String rn ^String importer-extension]
  (let [relative (ns-relative-source-path rn importer-extension)]
  (reduce (fn [hits root] (let [candidate (str (get root "dir") "/" relative)]
  (if (selfhost.rt/file-exists? candidate) (conj hits candidate) hits))) [] (get (deref MODULE-RESOLUTION) "roots"))))

(defn- resolve-required-source! [^String rn ^String source-path]
  (let [providers (get (get (deref MODULE-RESOLUTION) "providers") rn [])]
  (cond
  (> (count providers) 1) (do
  (selfhost.rt/eprint (str "beagle [module]: namespace " rn " required by " source-path " has multiple explicit providers: " (join-comma providers) "\n"))
  (selfhost.rt/exit 1)
  nil)
  (= (count providers) 1) (nth providers 0)
  :else (let [candidates (root-candidate-paths rn (source-extension source-path))]
  (cond
  (> (count candidates) 1) (do
  (selfhost.rt/eprint (str "beagle [module]: namespace " rn " required by " source-path " collides across module roots: " (join-comma candidates) "\n"))
  (selfhost.rt/exit 1)
  nil)
  (= (count candidates) 1) (nth candidates 0)
  :else nil)))))

(defn- ^Boolean contains-dot? [^String s]
  (loop [i 0]
  (cond
  (>= i (count s)) false
  (= (subs s i (+ i 1)) ".") true
  :else (recur (+ i 1)))))

(defn- ^Boolean host-required-ns? [^String rn ^String target]
  (or (str/starts-with? rn "clojure.") (str/starts-with? rn "babashka.") (and (= target "js") (not (contains-dot? rn)))))

(defn- ^Boolean extern-authorized-require? [extern-names ^String rn ^String prefix refer-syms]
  (if (and (some? refer-syms) (> (count refer-syms) 0)) (every? (fn [^String name] (> (count (filterv (fn [^String e] (or (= e name) (= e (str prefix "/" name)) (= e (str rn "/" name)))) extern-names)) 0)) refer-syms) (> (count (filterv (fn [^String e] (or (str/starts-with? e (str prefix "/")) (str/starts-with? e (str rn "/")))) extern-names)) 0)))

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
  nil) (let [surface {"datums" (get snapshot "datums") "type-aliases" (p/module-type-aliases-with-imports! (get snapshot "datums") "" nil imported-aliases) "record-contracts" (c/export-checked-record-contracts! prog) "callable-synchronization" (c/export-checked-callable-synchronization! prog)}]
  (swap! MODULE-SURFACE-CACHE assoc cache-key surface)
  (swap! MODULE-LOAD-STACK dissoc cache-key)
  surface)))))))

(declare load-import-surfaces*!)

(defn- load-import-surfaces*! [requires ^String source-path ^String target extern-names seen-paths]
  (reduce (fn [surfaces r] (let [ns (get r "ns")
   alias (get r "alias")
   refer (get r "refer")
   prefix (if (and (some? alias) (not (= alias false))) alias (let [segs (split-dots ns)]
  (nth segs (- (count segs) 1))))
   refer-syms (if (and (some? refer) (not (= refer false))) refer nil)
   path (resolve-required-source! ns source-path)]
  (cond
  (some? path) (let [absolute-path (selfhost.rt/abs-path path)]
  (if (= true (get seen-paths absolute-path)) surfaces (let [datums (rd/read-program (selfhost.rt/slurp-file path))
   provider-ns (module-declared-ns datums)]
  (if (not (= provider-ns ns)) (do
  (selfhost.rt/eprint (str "beagle [module]: required namespace " ns " resolved to " path " which declares " (if (some? provider-ns) provider-ns "no namespace") "\n"))
  (selfhost.rt/exit 1)
  surfaces) (let [dependency-surfaces (load-import-surfaces*! (p/discover-requires! datums) path target (declared-extern-names datums) (assoc seen-paths absolute-path true))
   imported-aliases (surface-type-aliases dependency-surfaces)
   checked-surface (checked-module-surface! path target imported-aliases)
   type-aliases (p/module-type-aliases-with-imports! datums prefix refer-syms imported-aliases)]
  (conj surfaces (assoc checked-surface "path" path "prefix" prefix "refer" refer-syms "imported-aliases" imported-aliases "type-aliases" type-aliases)))))))
  (or (host-required-ns? ns target) (extern-authorized-require? extern-names ns prefix refer-syms)) surfaces
  :else (do
  (selfhost.rt/eprint (str "beagle [module]: required namespace " ns " could not be resolved (required by " source-path "); it is absent from the closed source bundle and no" " declared module root provides it\n"))
  (selfhost.rt/exit 1)
  surfaces)))) [] requires))

(defn- load-import-surfaces! [requires ^String source-path ^String target datums]
  (load-import-surfaces*! requires source-path target (declared-extern-names datums) {(selfhost.rt/abs-path source-path) true}))

(defn- import-parametric-arities! [surfaces]
  (reduce (fn [arities surface] (into arities (p/module-parametric-arities! (get surface "datums") (get surface "prefix") (get surface "refer")))) {} surfaces))

(defn- import-type-aliases [surfaces]
  (surface-type-aliases surfaces))

(defn- import-nominal-type-names! [surfaces]
  (reduce (fn [names surface] (into names (p/module-nominal-type-names! (get surface "datums") (get surface "prefix") (get surface "refer")))) {} surfaces))

(defn- resolve-imports! [prog surfaces]
  (let [own-externs (get prog "externs")
   imported (reduce (fn [acc surface] (into acc (mapv (fn [extern] (assoc extern "synchronous" false "returnsSynchronousCallable" false)) (p/import-module-surface-with-aliases! (get surface "datums") (get surface "prefix") (get surface "refer") (get surface "imported-aliases"))))) [] surfaces)
   record-contracts (reduce (fn [acc surface] (into acc (p/qualify-imported-record-contracts (get surface "record-contracts") (get surface "prefix") (get surface "refer")))) [] surfaces)
   callable-synchronization (reduce (fn [acc surface] (into acc (p/qualify-imported-callable-synchronization (get surface "callable-synchronization") (get surface "prefix") (get surface "refer")))) [] surfaces)]
  (assoc prog "externs" (dedup-externs (into own-externs imported)) IMPORTED-RECORD-CONTRACTS-KEY record-contracts IMPORTED-CALLABLE-SYNCHRONIZATION-KEY callable-synchronization)))

(defn- ^Boolean has-define-target? [datums]
  (> (count (filterv (fn [d] (and (vector? d) (>= (count d) 2) (= (nth d 0) "define-target"))) datums)) 0))

(defn- parse-file-target! [^String path ^String target]
  (let [source-snapshot (selfhost.rt/read-source-snapshot path)
   source-text (get source-snapshot "text")
   source-id (selfhost.rt/source-id path)
   reader-output (rd/read-program-with-syntax! source-text source-id)
   datums0 (get reader-output "datums")
   syntaxes0 (get reader-output "syntaxes")
   datums (if (has-define-target? datums0) datums0 (into [["define-target" target]] datums0))
   syntaxes (if (has-define-target? datums0) syntaxes0 (into [(syntax/datum->beagle-syntax! ["define-target" target] nil syntax/EMPTY-SCOPE-SET nil {"reader" (syntax/make-reader-metadata "" "synthetic")})] syntaxes0))
   surfaces (load-import-surfaces! (p/discover-requires! datums) path target datums)
   imported-arities (import-parametric-arities! surfaces)
   imported-aliases (import-type-aliases surfaces)
   imported-nominal-type-names (import-nominal-type-names! surfaces)
   prog (resolve-imports! (p/parse-program-with-syntax-and-imports! datums syntaxes imported-arities imported-aliases imported-nominal-type-names) surfaces)
   perrs (p/parse-errors)]
  (if (> (count perrs) 0) (do
  (selfhost.rt/exit 1)
  prog) {"program" prog "datums" datums "source-text" source-text "source-sha256" (get source-snapshot "sourceSha256") "source-id" source-id})))

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

(defn- cmd-emit-from-ast! [^String target]
  (print (emit-for-target! target (validate-checked-projection! target (selfhost.rt/parse-json (selfhost.rt/read-stdin))))))

(defn- ^String flag-value [args ^String flag ^String default]
  (loop [i 0]
  (if (>= i (count args)) default (if (and (= (nth args i) flag) (< (+ i 1) (count args))) (nth args (+ i 1)) (recur (+ i 1))))))

(defn- flag-values [args ^String flag]
  (loop [i 0
   acc []]
  (if (>= i (count args)) acc (if (and (= (nth args i) flag) (< (+ i 1) (count args))) (recur (+ i 2) (conj acc (nth args (+ i 1)))) (recur (+ i 1) acc)))))

(defn- ^String first-positional [args]
  (loop [i 1]
  (if (>= i (count args)) "" (let [a (nth args i)]
  (cond
  (= a "--target") (recur (+ i 2))
  (= a "--module-root") (recur (+ i 2))
  (= a "--source") (recur (+ i 2))
  (str/starts-with? a "--") (recur (+ i 1))
  :else a)))))

(defn -main [& $beagle$rest$host]
  (let [args (vec $beagle$rest$host)]
  (reset! MODULE-SURFACE-CACHE {})
  (reset! MODULE-LOAD-STACK {})
  (let [cmd (if (> (count args) 0) (nth args 0) "")
   target (flag-value args "--target" "clj")
   path (first-positional args)
   roots (flag-values args "--module-root")
   bundle (flag-values args "--source")]
  (cond
  (= cmd "ast") (do
  (install-module-resolution! roots (conj bundle path))
  (cmd-ast! path target))
  (= cmd "check") (do
  (install-module-resolution! roots (conj bundle path))
  (cmd-check! path target))
  (= cmd "emit") (do
  (install-module-resolution! roots (conj bundle path))
  (cmd-emit! path target))
  (= cmd "emit-from-ast") (cmd-emit-from-ast! target)
  (= cmd "facts-roundtrip") (fr/run! (rest args))
  :else (do
  (selfhost.rt/eprint "usage: selfhost.main [--target clj|js|nix] [--module-root LOGICAL=PHYSICAL]... [--source FILE]... ast|check|emit FILE, emit-from-ast < ast.json, or facts-roundtrip MODE FILE\n")
  (selfhost.rt/exit 2)))
  (flush))))
