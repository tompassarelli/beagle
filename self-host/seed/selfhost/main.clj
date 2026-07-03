(ns selfhost.main
  (:gen-class)
  (:require [clojure.string :as str]
            [selfhost.rt :as rt]
            [selfhost.reader :as rd]
            [selfhost.parse :as p]
            [selfhost.check :as c]
            [selfhost.emit-clj :as e]
            [selfhost.emit-js :as ejs]))

(defn- ^Boolean has-define-target? [datums]
  (> (count (filterv (fn [d] (and (vector? d) (>= (count d) 2) (= (nth d 0) "define-target"))) datums)) 0))

(defn- parse-file-target! [^String path ^String target]
  (let [datums0 (rd/read-program (selfhost.rt/slurp-file path))
   datums (if (has-define-target? datums0) datums0 (into [["define-target" target]] datums0))
   prog (p/parse-program! datums)
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
  (selfhost.rt/eprint "usage: selfhost.main [--target clj|js] ast|check|emit FILE, or emit-from-ast < ast.json\n")
  (selfhost.rt/exit 2)))
  (flush)))
