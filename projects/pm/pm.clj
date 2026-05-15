(ns pm.cli
  (:require [clojure.string :as str]))

(require '[babashka.pods :as pods])

(pods/load-pod 'replikativ/datahike "0.6.1613")

(require '[datahike.pod :as d])

(defrecord Task [id title status])

(defn task-id [r] (:id r))

(defn task-title [r] (:title r))

(defn task-status [r] (:status r))

(defn db-cfg []
  (hash-map :store (hash-map :backend :file :path (str (System/getProperty "user.home") "/.pm/datahike"))))

(def task-schema [(hash-map :db/ident :task/id :db/valueType :db.type/long :db/cardinality :db.cardinality/one :db/unique :db.unique/identity) (hash-map :db/ident :task/title :db/valueType :db.type/string :db/cardinality :db.cardinality/one) (hash-map :db/ident :task/status :db/valueType :db.type/string :db/cardinality :db.cardinality/one)])

(defn ensure-db []
  (when (not (d/database-exists? (db-cfg)))
  (d/create-database (db-cfg))
  (d/transact (d/connect (db-cfg)) task-schema)))

(defn get-conn []
  (ensure-db)
  (d/connect (db-cfg)))

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
  (d/q [:find '?e :where ['?e :task/id id]] (d/db conn)))

(defn cmd-add [title]
  (let [conn (get-conn)
   next-id (inc (query-max-id conn))]
  (d/transact conn [(hash-map :task/id next-id :task/title title :task/status "todo")])
  (println (str "added #" next-id ": " title))))

(defn cmd-list []
  (let [conn (get-conn)
   results (query-all conn)]
  (if (empty? results) (println "no tasks.") (let [sorted (sort-by first (mapv vec results))]
  (mapv (fn [row] (let [id (first row)
   title (second row)
   status (nth row 2)]
  (println (str (if (= status "done") "  [x] #" "  [ ] #") id " " title)))) sorted)))))

(defn cmd-done [id]
  (let [conn (get-conn)
   matches (query-by-id conn id)]
  (if (empty? matches) (println (str "no task #" id)) (let [eid (first (first matches))]
  (d/transact conn [(hash-map :db/id eid :task/status "done")])
  (println (str "done #" id))))))

(defn cmd-rm [id]
  (let [conn (get-conn)
   matches (query-by-id conn id)]
  (if (empty? matches) (println (str "no task #" id)) (let [eid (first (first matches))]
  (d/transact conn [[:db/retractEntity eid]])
  (println (str "removed #" id))))))

(defn cmd-help []
  (println "pm — task manager (datahike)")
  (println "")
  (println "  pm add <title>    add a task")
  (println "  pm list           list all tasks")
  (println "  pm done <id>      mark task done")
  (println "  pm rm <id>        remove a task")
  (println "  pm nuke           wipe database"))

(defn cmd-nuke []
  (when (d/database-exists? (db-cfg))
  (d/delete-database (db-cfg)))
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
