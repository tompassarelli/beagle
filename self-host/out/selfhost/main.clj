(ns selfhost.main
  (:require [selfhost.rt :as rt]
            [selfhost.reader :as rd]
            [selfhost.parse :as p]
            [selfhost.check :as c]
            [selfhost.emit-clj :as e]))

(defn- parse-file [^String path]
  (p/parse-program (rd/read-program (selfhost.rt/slurp-file path))))

(defn- check-or-die! [prog]
  (let [errors (c/check-program prog)]
  (if (> (count errors) 0) (do
  (doseq [err errors]
  (selfhost.rt/eprint (str "beagle [check]: " err "\n")))
  (selfhost.rt/exit 1)
  prog) prog)))

(defn- cmd-ast! [^String path]
  (println (selfhost.rt/to-json (parse-file path))))

(defn- cmd-check! [^String path]
  (check-or-die! (parse-file path))
  (selfhost.rt/eprint "ok\n"))

(defn- cmd-emit! [^String path]
  (print (e/emit-program (check-or-die! (parse-file path)))))

(defn- cmd-emit-from-ast! []
  (print (e/emit-program (selfhost.rt/parse-json (selfhost.rt/read-stdin)))))

(defn -main [& args]
  (let [cmd (if (> (count args) 0) (nth args 0) "")
   path (if (> (count args) 1) (nth args 1) "")]
  (cond
  (= cmd "ast") (cmd-ast! path)
  (= cmd "check") (cmd-check! path)
  (= cmd "emit") (cmd-emit! path)
  (= cmd "emit-from-ast") (cmd-emit-from-ast!)
  :else (do
  (selfhost.rt/eprint "usage: selfhost.main ast|check|emit FILE, or emit-from-ast < ast.json\n")
  (selfhost.rt/exit 2)))))
