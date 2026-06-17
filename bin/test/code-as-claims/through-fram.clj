#!/usr/bin/env bb
;; through-fram: load reader-level claims into a REAL Fram store, then re-extract
;; them FROM the store. This is the "through the engine" leg of the code-as-claims
;; loop: source -> claims -> Fram -> claims -> source. Proves the program persists
;; through the claim engine (the canonical store), not just an in-memory map.
;;
;;   racket .../claims-roundtrip.rkt --emit-edn FILE > a.edn
;;   bb -cp <fram>/out through-fram.clj a.edn > b.edn
;;   racket .../claims-roundtrip.rkt --render b.edn   # byte-stable source
;;
;; (Mirrors chartroom's roundtrip_fram.clj; inlined here so the move-3 gate is
;; self-contained — beagle CI already checks out fram for the classpath.)
(ns through-fram
  (:require [clojure.edn :as edn]
            [clojure.string :as str]
            [fram.cnf :as c]))

(def edn-path (first *command-line-args*))

(def ctx (c/new-store))
(def tx  (c/begin-tx! ctx "code"))
(def lid->ent (atom {}))
(defn ent [lid] (or (@lid->ent lid)
                    (let [e (c/entity! ctx)] (swap! lid->ent assoc lid e) e)))

;; load: an integer object is a node-ref (-> entity); a string is a leaf value.
(doseq [line (str/split-lines (slurp edn-path))
        :when (str/starts-with? line "[")]
  (let [[s p o] (edn/read-string line)
        L (ent s)
        P (c/value! ctx p)
        R (if (integer? o) (ent o) (c/value! ctx o))]
    (c/claim! ctx L P R tx)))

(binding [*out* *err*]
  (println "loaded" (count (c/current-claims ctx)) "claims into a Fram store"))

;; re-extract every live claim straight from the store, back to EDN triples.
(doseq [cid (c/current-claims ctx)]
  (let [cl (c/claim-of ctx cid)
        l (:l cl) p (:p cl) r (:r cl)
        ps (c/literal ctx p)]
    (if (c/value-object? ctx r)
      (println (str "[" l " " (pr-str ps) " " (pr-str (c/literal ctx r)) "]"))
      (println (str "[" l " " (pr-str ps) " " r "]")))))
