(ns selfhost.main
  (:gen-class)
  (:require [selfhost.rt :as rt]
            [selfhost.reader :as rd]
            [selfhost.parse :as p]
            [selfhost.check :as c]
            [selfhost.emit-clj :as e]
            [selfhost.emit-nix :as en]))

(defn- parse-file! [^String path]
  (let [prog (p/parse-program! (rd/read-program (selfhost.rt/slurp-file path)))
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

(defn- cmd-ast! [^String path]
  (println (selfhost.rt/to-json (parse-file! path))))

(defn- cmd-check! [^String path]
  (check-or-die! (parse-file! path))
  (selfhost.rt/eprint "ok\n"))

(defn- emit-for-target! [^String target prog]
  (cond
  (= target "nix") (print (en/emit-program! prog))
  :else (print (e/emit-program! prog))))

(defn- cmd-emit! [^String target ^String path]
  (emit-for-target! target (check-or-die! (parse-file! path))))

(defn- cmd-emit-from-ast! [^String target]
  (emit-for-target! target (selfhost.rt/parse-json (selfhost.rt/read-stdin))))

(defn- ^String parse-target [argv]
  (loop [i 0]
  (cond
  (>= i (count argv)) "clj"
  (= (nth argv i) "--target") (if (< (+ i 1) (count argv)) (nth argv (+ i 1)) "clj")
  :else (recur (+ i 1)))))

(defn- positional-args [argv]
  (loop [i 0
   acc []]
  (cond
  (>= i (count argv)) acc
  (= (nth argv i) "--target") (recur (+ i 2) acc)
  :else (recur (+ i 1) (conj acc (nth argv i))))))

(defn -main [& args]
  (let [argv (vec args)
   target (parse-target argv)
   pos (positional-args argv)
   cmd (if (> (count pos) 0) (nth pos 0) "")
   path (if (> (count pos) 1) (nth pos 1) "")]
  (cond
  (= cmd "ast") (cmd-ast! path)
  (= cmd "check") (cmd-check! path)
  (= cmd "emit") (cmd-emit! target path)
  (= cmd "emit-from-ast") (cmd-emit-from-ast! target)
  :else (do
  (selfhost.rt/eprint "usage: selfhost.main [--target clj|nix] ast|check|emit FILE, or emit-from-ast < ast.json\n")
  (selfhost.rt/exit 2)))
  (flush)))
