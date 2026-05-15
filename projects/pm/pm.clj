(ns pm.cli
  (:require [clojure.string :as str]))

(require '[babashka.pods :as pods])

(pods/load-pod 'huahaiy/datalevin "0.9.12")

(require '[pod.huahaiy.datalevin :as d])

(defrecord Task [id title status])

(defn task-id [r] (:id r))

(defn task-title [r] (:title r))

(defn task-status [r] (:status r))

(defn db-path []
  (str (System/getProperty "user.home") "/.pm/datalevin"))

(def schema (hash-map :task/id (hash-map :db/valueType :db.type/long :db/unique :db.unique/identity) :task/title (hash-map :db/valueType :db.type/string) :task/status (hash-map :db/valueType :db.type/string)))

(defn get-conn []
  (d/get-conn (db-path) schema))

(defn query-all [conn]
  (d/q '[:find ?id ?title ?status
                  :where [?e :task/id ?id]
                         [?e :task/title ?title]
                         [?e :task/status ?status]]
                (d/db conn)))

(defn query-max-id [conn]
  (let [r (d/q '[:find (max ?id) :where [_ :task/id ?id]] (d/db conn))]
             (if (seq r) (ffirst r) 0)))

(defn query-by-id [conn id]
  (d/q '[:find ?e :in $ ?id :where [?e :task/id ?id]] (d/db conn) id))

(defn cmd-add [title]
  (let [conn (get-conn)
   next-id (inc (query-max-id conn))]
  (d/transact! conn [(hash-map :task/id next-id :task/title title :task/status "todo")])
  (println (str "added #" next-id ": " title))
  (d/close conn)))

(defn cmd-list []
  (let [conn (get-conn)
   results (query-all conn)]
  (if (empty? results) (println "no tasks.") (let [sorted (sort-by first (mapv vec results))]
  (mapv (fn [row] (let [id (first row)
   title (second row)
   status (nth row 2)]
  (println (str (if (= status "done") "  [x] #" "  [ ] #") id " " title)))) sorted)))
  (d/close conn)))

(defn cmd-done [id]
  (let [conn (get-conn)
   matches (query-by-id conn id)]
  (if (empty? matches) (println (str "no task #" id)) (let [eid (first (first matches))]
  (d/transact! conn [(hash-map :db/id eid :task/status "done")])
  (println (str "done #" id))))
  (d/close conn)))

(defn cmd-rm [id]
  (let [conn (get-conn)
   matches (query-by-id conn id)]
  (if (empty? matches) (println (str "no task #" id)) (let [eid (first (first matches))]
  (d/transact! conn [[:db/retractEntity eid]])
  (println (str "removed #" id))))
  (d/close conn)))

(defn cmd-help []
  (println "pm — task manager (datalevin)")
  (println "")
  (println "  pm add <title>    add a task")
  (println "  pm list           list all tasks")
  (println "  pm done <id>      mark task done")
  (println "  pm rm <id>        remove a task")
  (println "  pm nuke           wipe database"))

(defn cmd-nuke []
  (d/clear (db-path))
  (println "database cleared."))

(defn main []
  (let [args *command-line-args*
   cmd (first args)]
  (cond
  (= cmd "add") (if (empty? (rest args)) (println "usage: pm add <title>") (cmd-add (str/join " " (rest args))))
  (= cmd "list") (cmd-list)
  (= cmd "done") (if (nil? (second args)) (println "usage: pm done <id>") (cmd-done (parse-long (second args))))
  (= cmd "rm") (if (nil? (second args)) (println "usage: pm rm <id>") (cmd-rm (parse-long (second args))))
  (= cmd "nuke") (cmd-nuke)
  :else (cmd-help))))

(main)
