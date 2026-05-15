#lang beagle

(ns pm.cli)

(require clojure.edn :as edn)
(require clojure.java.io :as io)
(require clojure.string :as str)

;; -- externs for IO --
(declare-extern slurp [String -> String])
(declare-extern spit [String String -> Nil])
(declare-extern parse-long [String -> Long])
(declare-extern edn/read-string [String -> Any])
(declare-extern io/file [String -> Any])

;; -- record --
(defrecord Task [(id : Long) (title : String) (status : String)])

;; -- persistence --
(defn store-path [] : String
  (str (System/getProperty "user.home") "/.pm/tasks.edn"))

(defn load-raw []
  (let [path (store-path)]
    (if (.exists (io/file path))
      (edn/read-string (slurp path))
      [])))

(defn map->task [m] : Task
  (->Task (get m :id) (get m :title) (get m :status)))

(defn task->map [(t : Task)]
  (hash-map :id (task-id t) :title (task-title t) :status (task-status t)))

(defn load-tasks []
  (mapv map->task (load-raw)))

(defn save-tasks [tasks]
  (let [path (store-path)]
    (.mkdirs (.getParentFile (io/file path)))
    (spit path (pr-str (mapv task->map tasks)))))

;; -- id generation --
(defn next-id [tasks] : Long
  (if (empty? tasks)
    1
    (inc (reduce (fn [mx t] (if (> (task-id t) mx) (task-id t) mx)) 0 tasks))))

;; -- commands --
(defn cmd-add [(title : String)]
  (let [tasks (load-tasks)
        id (next-id tasks)
        task (->Task id title "todo")]
    (save-tasks (conj tasks task))
    (println (str "added #" id ": " title))))

(defn cmd-list []
  (let [tasks (load-tasks)]
    (if (empty? tasks)
      (println "no tasks.")
      (mapv (fn [t]
              (println (str (if (= (task-status t) "done") "  [x] #" "  [ ] #")
                            (task-id t) " " (task-title t))))
            tasks))))

(defn cmd-done [(id : Long)]
  (let [tasks (load-tasks)
        updated (mapv (fn [t]
                        (if (= (task-id t) id)
                          (->Task id (task-title t) "done")
                          t))
                      tasks)]
    (if (= tasks updated)
      (println (str "no task #" id))
      (do (save-tasks updated)
          (println (str "done #" id))))))

(defn cmd-rm [(id : Long)]
  (let [tasks (load-tasks)
        remaining (filterv (fn [t] (not (= (task-id t) id))) tasks)]
    (if (= (count tasks) (count remaining))
      (println (str "no task #" id))
      (do (save-tasks remaining)
          (println (str "removed #" id))))))

(defn cmd-help []
  (println "pm — task manager")
  (println "")
  (println "  pm add <title>    add a task")
  (println "  pm list           list all tasks")
  (println "  pm done <id>      mark task done")
  (println "  pm rm <id>        remove a task"))

;; -- dispatch --
(defn main []
  (let [args *command-line-args*
        cmd (first args)]
    (cond
      (= cmd "add") (if (empty? (rest args))
                      (println "usage: pm add <title>")
                      (cmd-add (str/join " " (rest args))))
      (= cmd "list") (cmd-list)
      (= cmd "done") (if (nil? (second args))
                       (println "usage: pm done <id>")
                       (cmd-done (parse-long (second args))))
      (= cmd "rm") (if (nil? (second args))
                     (println "usage: pm rm <id>")
                     (cmd-rm (parse-long (second args))))
      :else (cmd-help))))

(main)
