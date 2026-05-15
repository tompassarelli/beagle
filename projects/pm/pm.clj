(ns pm.cli
  (:require [clojure.edn :as edn]
            [clojure.java.io :as io]
            [clojure.string :as str]))

(defrecord Task [id title status])

(defn task-id [r] (:id r))

(defn task-title [r] (:title r))

(defn task-status [r] (:status r))

(defn store-path []
  (str (System/getProperty "user.home") "/.pm/tasks.edn"))

(defn load-raw []
  (let [path (store-path)]
  (if (.exists (io/file path)) (edn/read-string (slurp path)) [])))

(defn map->task [m]
  (->Task (get m :id) (get m :title) (get m :status)))

(defn task->map [t]
  (hash-map :id (task-id t) :title (task-title t) :status (task-status t)))

(defn load-tasks []
  (mapv map->task (load-raw)))

(defn save-tasks [tasks]
  (let [path (store-path)]
  (.mkdirs (.getParentFile (io/file path)))
  (spit path (pr-str (mapv task->map tasks)))))

(defn next-id [tasks]
  (if (empty? tasks) 1 (inc (reduce (fn [mx t] (if (> (task-id t) mx) (task-id t) mx)) 0 tasks))))

(defn cmd-add [title]
  (let [tasks (load-tasks)
   id (next-id tasks)
   task (->Task id title "todo")]
  (save-tasks (conj tasks task))
  (println (str "added #" id ": " title))))

(defn cmd-list []
  (let [tasks (load-tasks)]
  (if (empty? tasks) (println "no tasks.") (mapv (fn [t] (println (str (if (= (task-status t) "done") "  [x] #" "  [ ] #") (task-id t) " " (task-title t)))) tasks))))

(defn cmd-done [id]
  (let [tasks (load-tasks)
   updated (mapv (fn [t] (if (= (task-id t) id) (->Task id (task-title t) "done") t)) tasks)]
  (if (= tasks updated) (println (str "no task #" id)) (do
  (save-tasks updated)
  (println (str "done #" id))))))

(defn cmd-rm [id]
  (let [tasks (load-tasks)
   remaining (filterv (fn [t] (not (= (task-id t) id))) tasks)]
  (if (= (count tasks) (count remaining)) (println (str "no task #" id)) (do
  (save-tasks remaining)
  (println (str "removed #" id))))))

(defn cmd-help []
  (println "pm — task manager")
  (println "")
  (println "  pm add <title>    add a task")
  (println "  pm list           list all tasks")
  (println "  pm done <id>      mark task done")
  (println "  pm rm <id>        remove a task"))

(defn main []
  (let [args *command-line-args*
   cmd (first args)]
  (cond
  (= cmd "add") (if (empty? (rest args)) (println "usage: pm add <title>") (cmd-add (str/join " " (rest args))))
  (= cmd "list") (cmd-list)
  (= cmd "done") (if (nil? (second args)) (println "usage: pm done <id>") (cmd-done (parse-long (second args))))
  (= cmd "rm") (if (nil? (second args)) (println "usage: pm rm <id>") (cmd-rm (parse-long (second args))))
  :else (cmd-help))))

(main)
