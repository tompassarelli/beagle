#!/usr/bin/env bb
;; rename-in-store: a SCOPE-CORRECT rename as a CLAIM EDIT on the canonical Fram
;; store. Loads each file's lossless claims into ONE store, then renames a symbol
;; in the target module(s) by SUPERSEDING its `v` claims (claim-native: the old
;; claims stay, marked not-live, fully recoverable — nothing is overwritten). The
;; SAME-named symbol in other modules is untouched by construction, because scope
;; is structural (which file's entities), not lexical text. A text `sed` would
;; corrupt both files. Re-extracts each file's LIVE claims to <outdir>/<base>.edn.
;;
;; Ports chartroom's Turtle #4 (rename.clj), self-contained so beagle's repair
;; toolchain owns it. Refuses (exit 3) if `new` already binds in a target module
;; (the rename-doesn't-collide invariant) — no claims mutated on refusal.
;;
;;   bb -cp <fram>/out rename-in-store.clj <old> <new> <target-substr> <outdir> <edn>...
(ns rename-in-store
  (:require [clojure.edn :as edn]
            [clojure.string :as str]
            [clojure.java.io :as io]
            [fram.cnf :as c]))

(def argv *command-line-args*)
(def old-name (nth argv 0))
(def new-name (nth argv 1))
(def target-substr (nth argv 2))
(def outdir (nth argv 3))
(def edn-files (drop 4 argv))

(def ctx (c/new-store))
(def tx  (c/begin-tx! ctx "author"))
(def SUP (c/value! ctx "supersedes"))
(c/set-supersedes-pred! ctx SUP)
(def file->ents (atom {}))

(defn load-edn [path]
  (let [lines (str/split-lines (slurp path))
        src   (-> (first (filter #(str/starts-with? % "@file") lines)) (subs 6))
        local (atom {})
        ent   (fn [lid] (or (@local lid)
                            (let [e (c/entity! ctx)]
                              (swap! local assoc lid e)
                              (swap! file->ents update src (fnil conj []) e)
                              e)))]
    (doseq [line lines :when (str/starts-with? line "[")]
      (let [[s p o] (edn/read-string line)
            L (ent s) P (c/value! ctx p)
            R (if (number? o) (ent o) (c/value! ctx o))]   ; bare number = node-ref (incl floats)
        (c/claim! ctx L P R tx)))
    src))

(def srcs (mapv load-edn edn-files))

(def Vp   (c/value! ctx "v"))
(def KIND (c/value! ctx "kind"))
(def SYM  (c/value! ctx "symbol"))
(def OLDv (c/value-id ctx old-name))
(def NEWv (c/value! ctx new-name))

(defn symbol-leaf? [e]
  (some #(= SYM (:r (c/claim-of ctx %))) (c/by-lp ctx e KIND)))

(def target-modules (filter #(str/includes? % target-substr) (keys @file->ents)))
(def target-ents (set (mapcat @file->ents target-modules)))

;; invariant: refuse a rename onto an existing binding in a target module.
(def DEFHEADS #{"def" "defn" "defn-" "def-" "defonce" "definline"})
(defn field-child [e fname]
  (let [P (c/value-id ctx fname)]
    (when P (let [cids (c/by-lp ctx e P)] (when (seq cids) (:r (c/claim-of ctx (first cids))))))))
(defn sym-val [e]
  (when (and e (symbol-leaf? e))
    (let [vc (filter #(= Vp (:p (c/claim-of ctx %))) (c/by-l ctx e))]
      (when (seq vc) (c/literal ctx (:r (c/claim-of ctx (first vc))))))))
(defn binding-name [e]
  (let [h (sym-val (field-child e "f0"))]
    (when (and h (DEFHEADS h)) (sym-val (field-child e "f1")))))
(defn module-bindings [src] (set (keep binding-name (@file->ents src))))

(doseq [m target-modules]
  (when (contains? (module-bindings m) new-name)
    (binding [*out* *err*]
      (println (str "REJECTED — `" new-name "` already binds in " m
                    "; a rename onto an existing binding would collide. No claims mutated.")))
    (System/exit 3)))

(def renamed (atom 0))
(when OLDv
  (doseq [cid (vec (c/by-pr ctx Vp OLDv))]            ; every [e v old] claim
    (let [e (:l (c/claim-of ctx cid))]
      (when (and (target-ents e) (symbol-leaf? e))
        (let [ncid (c/claim! ctx e Vp NEWv tx)]       ; assert new value
          (c/claim! ctx ncid SUP cid tx))             ; supersede the old value-claim
        (swap! renamed inc)))))

(def preserved
  (if OLDv
    (count (filter (fn [cid] (let [e (:l (c/claim-of ctx cid))]
                               (and (not (target-ents e)) (symbol-leaf? e))))
                   (c/by-pr ctx Vp OLDv)))
    0))

(defn base [src] (-> src (str/split #"/") last))
(defn extract-file! [src out-path]
  (with-open [w (io/writer out-path)]
    (binding [*out* w]
      (println (str "@file " src))
      (doseq [e (@file->ents src)
              cid (c/by-l ctx e)]                      ; LIVE claims only (superseded excluded)
        (let [cl (c/claim-of ctx cid) p (:p cl) r (:r cl) ps (c/literal ctx p)]
          (when (not= ps "supersedes")
            (if (c/value-object? ctx r)
              (println (str "[" e " " (pr-str ps) " " (pr-str (c/literal ctx r)) "]"))
              (println (str "[" e " " (pr-str ps) " " r "]")))))))))

(.mkdirs (io/file outdir))
(doseq [src srcs] (extract-file! src (str outdir "/" (base src) ".edn")))

(binding [*out* *err*]
  (println (str "rename `" old-name "` -> `" new-name "` in \"" target-substr "\": "
                @renamed " renamed (target), " preserved " preserved (other modules, untouched)")))
