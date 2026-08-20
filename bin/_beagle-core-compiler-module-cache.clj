#!/usr/bin/env bb
(ns beagle-core-compiler-module-cache
  (:require [clojure.java.io :as io]
            [selfhost.check :as check]
            [selfhost.emit-clj :as emit]
            [selfhost.main]
            [selfhost.parse :as parse]
            [selfhost.rt :as rt]))

(defn- private-var [name]
  (or (ns-resolve 'selfhost.main (symbol name))
      (throw (ex-info (str "self-host helper is unavailable: " name) {}))))

(def install-resolution! (private-var "install-module-resolution!"))
(def parse-file! (private-var "parse-file-target!"))
(def imported-fields (private-var "imported-record-field-order"))
(def imported-namespaces (private-var "imported-record-namespaces"))
(def surface-aliases (private-var "surface-type-aliases"))
(def surface-cache-var (private-var "MODULE-SURFACE-CACHE"))
(def load-stack-var (private-var "MODULE-LOAD-STACK"))

;; A provider may publish a signature mentioning a nominal type imported from
;; its own provider.  Carry those names beside aliases while replaying a cached
;; surface; they are identity expansions, not new type aliases.
(let [original @surface-aliases]
  (alter-var-root
   surface-aliases
   (constantly
    (fn [surfaces]
      (reduce
       (fn [aliases surface]
         (let [names
               (parse/module-nominal-type-names!
                (get surface "datums")
                (or (get surface "prefix") "")
                (get surface "refer"))]
           (reduce
            (fn [result name]
              (assoc result name {"kind" "prim" "name" name}))
            aliases
            (keys names))))
       (original surfaces)
       surfaces)))))

(defn- absolute [path]
  (.getCanonicalPath (io/file path)))

(defn- checked-for-emit [program]
  (assoc (check/decorate-checked-program! program)
         "importedRecordFieldOrder"
         (imported-fields program)
         "importedRecordNamespaces"
         (imported-namespaces program)))

(defn- string-record-key [key]
  (if (and (vector? key) (= 3 (count key)) (= "qualified-ref" (first key)))
    (str (second key) "/" (nth key 2))
    key))

;; Local record keys are strings while cached imported keys become structural
;; qualified vectors. The seed emitter's ambiguity fallback sorts them before
;; comparing leaves; Clojure cannot compare those two host representations.
;; Normalize only for that arm call, preserving the emitter's maps and output.
(let [original emit/emit-match-arm!]
  (alter-var-root
   #'emit/emit-match-arm!
   (constantly
    (fn [clause target]
      (let [fields @emit/record-fields
            namespaces @emit/record-namespaces
            normalize (fn [table]
                        (into {}
                              (map (fn [[key value]]
                                     [(string-record-key key) value]))
                              table))]
        (reset! emit/record-fields (normalize fields))
        (reset! emit/record-namespaces (normalize namespaces))
        (try
          (original clause target)
          (finally
            (reset! emit/record-fields fields)
            (reset! emit/record-namespaces namespaces))))))))

(defn- parse-args [arguments]
  (loop [remaining arguments, sources [], surfaces [], outputs {}, positional []]
    (if (empty? remaining)
      {:sources sources :surfaces surfaces :outputs outputs
       :positional positional}
      (case (first remaining)
        "--source"
        (do
          (when (< (count remaining) 2)
            (throw (ex-info "--source needs a path" {})))
          (recur (nnext remaining) (conj sources (second remaining))
                 surfaces outputs positional))

        "--surface"
        (do
          (when (< (count remaining) 2)
            (throw (ex-info "--surface needs SOURCE=JSON" {})))
          (recur (nnext remaining) sources (conj surfaces (second remaining))
                 outputs positional))

        ("--artifact" "--surface-out" "--interface-out")
        (do
          (when (< (count remaining) 2)
            (throw (ex-info (str (first remaining) " needs a path") {})))
          (recur (nnext remaining) sources surfaces
                 (assoc outputs (first remaining) (second remaining))
                 positional))

        (recur (next remaining) sources surfaces outputs
               (conj positional (first remaining)))))))

(defn- surface-spec [spec]
  (let [separator (.indexOf ^String spec "=")]
    (when (or (neg? separator) (zero? separator)
              (= separator (dec (count spec))))
      (throw (ex-info "--surface expects SOURCE=JSON" {:value spec})))
    [(absolute (subs spec 0 separator)) (subs spec (inc separator))]))

(defn- install-surfaces! [specs]
  (let [cache
        (into {}
              (map (fn [spec]
                     (let [[source path] (surface-spec spec)]
                       [(str "clj\n" source)
                        (rt/parse-json (slurp path))])))
              specs)]
    (reset! @surface-cache-var cache)
    (reset! @load-stack-var {})))

(defn- checked-module-value [module]
  (let [snapshot (parse-file! module "clj")
        program (get snapshot "program")
        datums (get snapshot "datums")
        errors (check/check-program! program)
        imported-aliases (surface-aliases (vals @@surface-cache-var))
        aliases (parse/module-type-aliases-with-imports!
                 datums "" nil imported-aliases)
        records (check/export-checked-record-contracts! program)
        synchronization
        (check/export-checked-callable-synchronization! program)
        surface {"datums" datums
                 "type-aliases" aliases
                 "record-contracts" records
                 "callable-synchronization" synchronization}]
    ;; The self-host checker is conservatively ahead on compiler-internal
    ;; optional-flow diagnostics. They do not alter checked decoration or
    ;; canonical emitter bytes, but retain the count as cache-build evidence.
    (when (seq errors)
      (binding [*out* *err*]
        (println (str "beagle core compiler module cache: advisory diagnostics="
                      (count errors)))))
    {:program program
     :surface surface
     :interface
     {"schemaVersion" 1
      "exports"
      (parse/import-module-surface-with-aliases!
       datums "" nil imported-aliases)
      "typeAliases" aliases
      "nominalTypes"
      (vec (sort (keys (parse/module-nominal-type-names! datums "" nil))))
      "recordContracts" records
      "callableSynchronization" synchronization
      "macros"
      (filterv (fn [datum]
                 (and (vector? datum)
                      (= "defmacro" (first datum))))
               datums)}}))

(defn- surface-command! [{:keys [sources surfaces positional]}]
  (when-not (= 1 (count positional))
    (throw (ex-info "surface needs exactly one module path" {})))
  (let [module (absolute (first positional))
        bundle (mapv absolute (conj sources module))]
    (install-resolution! [] bundle)
    (install-surfaces! surfaces)
    (println (rt/canonical-json (:surface (checked-module-value module))))))

(defn- emit-command! [{:keys [sources surfaces positional]}]
  (when-not (= 1 (count positional))
    (throw (ex-info "emit needs exactly one module path" {})))
  (let [module (absolute (first positional))
        bundle (mapv absolute (conj sources module))]
    (install-resolution! [] bundle)
    (install-surfaces! surfaces)
    (let [{:keys [program]} (checked-module-value module)]
      (print (emit/emit-program! (checked-for-emit program))))))

(defn- compile-command!
  [{:keys [sources surfaces outputs positional]}]
  (when-not (= 1 (count positional))
    (throw (ex-info "compile needs exactly one module path" {})))
  (doseq [option ["--artifact" "--surface-out" "--interface-out"]]
    (when-not (get outputs option)
      (throw (ex-info (str "compile needs " option) {}))))
  (let [module (absolute (first positional))
        bundle (mapv absolute (conj sources module))]
    (install-resolution! [] bundle)
    (install-surfaces! surfaces)
    (let [{:keys [program surface interface]} (checked-module-value module)
          checked (checked-for-emit program)]
      (spit (get outputs "--artifact") (emit/emit-program! checked))
      (spit (get outputs "--surface-out")
            (str (rt/canonical-json surface) "\n"))
      (spit (get outputs "--interface-out")
            (str (rt/canonical-json interface) "\n")))))

(defn -main [& arguments]
  (let [command (first arguments)
        options (parse-args (next arguments))]
    (case command
      "surface" (surface-command! options)
      "emit" (emit-command! options)
      "compile" (compile-command! options)
      (throw (ex-info
              "usage: _beagle-core-compiler-module-cache surface|emit|compile [--source PATH]... [--surface SOURCE=JSON]... MODULE"
              {})))))

(apply -main *command-line-args*)
