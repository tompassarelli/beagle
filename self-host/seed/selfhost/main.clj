(ns selfhost.main
  (:gen-class)
  (:require [clojure.string :as str]
            [selfhost.rt :as rt]
            [selfhost.reader :as rd]
            [selfhost.parse :as p]
            [selfhost.check :as c]
            [selfhost.emit-clj :as e]
            [selfhost.emit-nix :as en]
            [selfhost.emit-js :as ejs]))

(def BEAGLE-EXTENSIONS [".bclj" ".bjs" ".bnix" ".bodin" ".bgl" ".rkt"])

(defn- split-dots [^String s]
  (loop [i 0
   start 0
   acc []]
  (cond
  (>= i (count s)) (conj acc (subs s start i))
  (= (subs s i (+ i 1)) ".") (recur (+ i 1) (+ i 1) (conj acc (subs s start i)))
  :else (recur (+ i 1) start acc))))

(defn- last-slash [^String s]
  (loop [i (- (count s) 1)]
  (cond
  (< i 0) -1
  (= (subs s i (+ i 1)) "/") i
  :else (recur (- i 1)))))

(defn- ^String dir-of [^String path]
  (let [i (last-slash path)]
  (if (< i 0) "" (subs path 0 i))))

(defn- ^String join-slash [segs]
  (if (= (count segs) 0) "" (reduce (fn [a s] (str a "/" s)) (nth segs 0) (subvec segs 1))))

(defn- try-ext [^String dir ^String rel]
  (loop [i 0]
  (if (>= i (count BEAGLE-EXTENSIONS)) nil (let [p (str dir "/" rel (nth BEAGLE-EXTENSIONS i))]
  (if (selfhost.rt/file-exists? p) p (recur (+ i 1)))))))

(defn- try-at-dir [^String dir dir-segs ^String base ^String abs-source]
  (let [nested-rel (if (> (count dir-segs) 0) (str (join-slash dir-segs) "/" base) base)
   nested (try-ext dir nested-rel)]
  (if (some? nested) nested (if (> (count dir-segs) 0) (let [flat (try-ext dir base)]
  (if (and (some? flat) (not (= flat abs-source))) flat nil)) nil))))

(defn- resolve-ns-path [^String ns ^String source-path]
  (let [segs (split-dots ns)
   base (nth segs (- (count segs) 1))
   dir-segs (subvec segs 0 (- (count segs) 1))
   abs-source (selfhost.rt/abs-path source-path)
   src-dir (dir-of abs-source)]
  (loop [cur src-dir]
  (let [hit (try-at-dir cur dir-segs base abs-source)]
  (if (some? hit) hit (let [parent (dir-of cur)]
  (if (or (= parent "") (= parent cur)) nil (recur parent))))))))

(defn- dedup-externs [xs]
  (loop [i 0
   seen {}
   acc []]
  (if (>= i (count xs)) acc (let [e (nth xs i)
   nm (get e "name")]
  (if (= true (get seen nm)) (recur (+ i 1) seen acc) (recur (+ i 1) (assoc seen nm true) (conj acc e)))))))

(defn- resolve-imports! [prog ^String source-path]
  (let [requires (get prog "requires")
   own-externs (get prog "externs")
   imported (reduce (fn [acc r] (let [ns (get r "ns")
   alias (get r "alias")
   refer (get r "refer")
   prefix (if (and (some? alias) (not (= alias false))) alias (let [segs (split-dots ns)]
  (nth segs (- (count segs) 1))))
   refer-syms (if (and (some? refer) (not (= refer false))) refer nil)
   path (resolve-ns-path ns source-path)]
  (if (some? path) (into acc (p/import-module-surface (rd/read-program (selfhost.rt/slurp-file path)) prefix refer-syms)) acc))) [] requires)]
  (assoc prog "externs" (dedup-externs (into own-externs imported)))))

(defn- ^Boolean has-define-target? [datums]
  (> (count (filterv (fn [d] (and (vector? d) (>= (count d) 2) (= (nth d 0) "define-target"))) datums)) 0))

(defn- parse-file-target! [^String path ^String target]
  (let [datums0 (rd/read-program (selfhost.rt/slurp-file path))
   datums (if (has-define-target? datums0) datums0 (into [["define-target" target]] datums0))
   prog (resolve-imports! (p/parse-program! datums) path)
   perrs (p/parse-errors)]
  (if (> (count perrs) 0) (do
  (selfhost.rt/exit 1)
  prog) prog)))

(defn- check-or-die! [prog]
  (let [errors (c/check-program! prog)]
  (if (> (count errors) 0) (do
  (doseq [err errors]
  (selfhost.rt/eprint (str "beagle [check]: " err "\n")))
  (selfhost.rt/exit 1)
  prog) prog)))

(defn- ^String emit-for-target [^String target prog]
  (cond
  (= target "js") (ejs/emit-program! prog)
  (= target "nix") (en/emit-program! prog)
  :else (e/emit-program! prog)))

(defn- cmd-ast! [^String path ^String target]
  (println (selfhost.rt/to-json (parse-file-target! path target))))

(defn- cmd-check! [^String path ^String target]
  (check-or-die! (parse-file-target! path target))
  (selfhost.rt/eprint "ok\n"))

(defn- cmd-emit! [^String path ^String target]
  (print (emit-for-target target (check-or-die! (parse-file-target! path target)))))

(defn- cmd-emit-from-ast! [^String target]
  (print (emit-for-target target (selfhost.rt/parse-json (selfhost.rt/read-stdin)))))

(defn- ^String flag-value [args ^String flag ^String default]
  (loop [i 0]
  (if (>= i (count args)) default (if (and (= (nth args i) flag) (< (+ i 1) (count args))) (nth args (+ i 1)) (recur (+ i 1))))))

(defn- ^String first-positional [args]
  (loop [i 1]
  (if (>= i (count args)) "" (let [a (nth args i)]
  (cond
  (= a "--target") (recur (+ i 2))
  (str/starts-with? a "--") (recur (+ i 1))
  :else a)))))

(defn -main [& args]
  (let [cmd (if (> (count args) 0) (nth args 0) "")
   target (flag-value args "--target" "clj")
   path (first-positional args)]
  (cond
  (= cmd "ast") (cmd-ast! path target)
  (= cmd "check") (cmd-check! path target)
  (= cmd "emit") (cmd-emit! path target)
  (= cmd "emit-from-ast") (cmd-emit-from-ast! target)
  :else (do
  (selfhost.rt/eprint "usage: selfhost.main [--target clj|js|nix] ast|check|emit FILE, or emit-from-ast < ast.json\n")
  (selfhost.rt/exit 2)))
  (flush)))
