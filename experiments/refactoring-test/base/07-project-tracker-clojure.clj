(ns benchmark.project-tracker
  (:require [clojure.string :as str]))

;; === Parsing ===

(defn parse-skill [s]
  (let [parts (str/split s #"\|")]
    [(parse-long (nth parts 0)) (nth parts 1) (nth parts 2)]))

(defn parse-skills [text]
  (mapv parse-skill (filterv #(not (str/blank? %)) (str/split (str/trim text) #"\n"))))

(defn parse-department [s]
  (let [parts (str/split s #"\|")]
    [(parse-long (nth parts 0)) (nth parts 1) (parse-long (nth parts 2)) (parse-long (nth parts 3))]))

(defn parse-departments [text]
  (mapv parse-department (filterv #(not (str/blank? %)) (str/split (str/trim text) #"\n"))))

(defn parse-employee [s]
  (let [parts (str/split s #"\|")]
    [(parse-long (nth parts 0)) (nth parts 1) (parse-long (nth parts 2)) (parse-long (nth parts 3)) (nth parts 4)]))

(defn parse-employees [text]
  (mapv parse-employee (filterv #(not (str/blank? %)) (str/split (str/trim text) #"\n"))))

(defn parse-project [s]
  (let [parts (str/split s #"\|")]
    [(parse-long (nth parts 0)) (nth parts 1) (parse-long (nth parts 2)) (nth parts 3) (parse-long (nth parts 4)) (nth parts 5)]))

(defn parse-projects [text]
  (mapv parse-project (filterv #(not (str/blank? %)) (str/split (str/trim text) #"\n"))))

(defn parse-task [s]
  (let [parts (str/split s #"\|")]
    [(parse-long (nth parts 0)) (parse-long (nth parts 1)) (parse-long (nth parts 2)) (nth parts 3) (nth parts 4) (parse-long (nth parts 5))]))

(defn parse-tasks [text]
  (mapv parse-task (filterv #(not (str/blank? %)) (str/split (str/trim text) #"\n"))))

(defn parse-time-entry [s]
  (let [parts (str/split s #"\|")]
    [(parse-long (nth parts 0)) (parse-long (nth parts 1)) (parse-long (nth parts 2)) (parse-long (nth parts 3)) (nth parts 4)]))

(defn parse-time-entries [text]
  (mapv parse-time-entry (filterv #(not (str/blank? %)) (str/split (str/trim text) #"\n"))))

;; === Employee skill helpers ===

(defn parse-skill-ids [employee]
  (let [s (nth employee 4)]
    (if (= s "")
      []
      (mapv parse-long (str/split s #",")))))

(defn employee-has-skill? [employee skill-id]
  (some #(= % skill-id) (parse-skill-ids employee)))

(defn employees-with-skill [employees skill-id]
  (filterv #(employee-has-skill? % skill-id) employees))

(defn employee-skills [employee skills]
  (let [ids (parse-skill-ids employee)]
    (mapv (fn [sid] (first (filterv #(= (nth % 0) sid) skills))) ids)))

;; === Lookups ===

(defn find-employee [employees id]
  (first (filterv #(= (nth % 0) id) employees)))

(defn find-department [departments id]
  (first (filterv #(= (nth % 0) id) departments)))

(defn find-project [projects id]
  (first (filterv #(= (nth % 0) id) projects)))

(defn find-task [tasks id]
  (first (filterv #(= (nth % 0) id) tasks)))

(defn find-skill [skills id]
  (first (filterv #(= (nth % 0) id) skills)))

(defn department-for-employee [departments employee]
  (find-department departments (nth employee 2)))

;; === Filtering ===

(defn projects-by-status [projects status]
  (filterv #(= (nth % 3) status) projects))

(defn projects-by-department [projects dept-id]
  (filterv #(= (nth % 2) dept-id) projects))

(defn projects-by-priority [projects max-priority]
  (filterv #(<= (nth % 4) max-priority) projects))

(defn active-projects [projects]
  (projects-by-status projects "active"))

(defn tasks-for-project [tasks project-id]
  (filterv #(= (nth % 1) project-id) tasks))

(defn tasks-for-employee [tasks employee-id]
  (filterv #(= (nth % 2) employee-id) tasks))

(defn tasks-by-status [tasks status]
  (filterv #(= (nth % 4) status) tasks))

(defn employees-in-department [employees dept-id]
  (filterv #(= (nth % 2) dept-id) employees))

(defn time-entries-for-task [time-entries task-id]
  (filterv #(= (nth % 1) task-id) time-entries))

(defn time-entries-for-employee [time-entries employee-id]
  (filterv #(= (nth % 2) employee-id) time-entries))

;; === Cost calculations ===

(defn hours-logged-on-task [time-entries task-id]
  (reduce + 0 (mapv #(nth % 3) (time-entries-for-task time-entries task-id))))

(defn hours-logged-by-employee [time-entries employee-id]
  (reduce + 0 (mapv #(nth % 3) (time-entries-for-employee time-entries employee-id))))

(defn task-cost [task time-entries employees]
  (let [task-id (nth task 0)
        entries (time-entries-for-task time-entries task-id)]
    (reduce + 0 (mapv (fn [entry]
                         (let [emp (find-employee employees (nth entry 2))
                               rate (if emp (nth emp 3) 0)]
                           (* (nth entry 3) rate)))
                       entries))))

(defn project-cost [project tasks time-entries employees]
  (let [proj-tasks (tasks-for-project tasks (nth project 0))]
    (reduce + 0 (mapv #(task-cost % time-entries employees) proj-tasks))))

(defn department-total-cost [dept-id projects tasks time-entries employees]
  (let [dept-projects (projects-by-department projects dept-id)]
    (reduce + 0 (mapv #(project-cost % tasks time-entries employees) dept-projects))))

(defn employee-cost [employee time-entries]
  (* (hours-logged-by-employee time-entries (nth employee 0)) (nth employee 3)))

;; === Project analysis ===

(defn project-progress [tasks project-id]
  (let [proj-tasks (tasks-for-project tasks project-id)
        total (count proj-tasks)
        done (count (filterv #(= (nth % 4) "done") proj-tasks))]
    [done total]))

(defn project-estimated-hours [tasks project-id]
  (reduce + 0 (mapv #(nth % 5) (tasks-for-project tasks project-id))))

(defn project-actual-hours [tasks time-entries project-id]
  (let [proj-tasks (tasks-for-project tasks project-id)]
    (reduce + 0 (mapv #(hours-logged-on-task time-entries (nth % 0)) proj-tasks))))

(defn project-on-track? [tasks time-entries project-id]
  (<= (project-actual-hours tasks time-entries project-id)
      (project-estimated-hours tasks project-id)))

(defn overdue-tasks [tasks time-entries]
  (filterv (fn [task]
             (and (not= (nth task 4) "done")
                  (> (hours-logged-on-task time-entries (nth task 0)) (nth task 5))))
           tasks))

(defn blocked-tasks [tasks]
  (filterv #(= (nth % 4) "blocked") tasks))

(defn unassigned-estimate [tasks project-id]
  (reduce + 0 (mapv #(nth % 5) (filterv #(= (nth % 4) "todo") (tasks-for-project tasks project-id)))))

(defn completion-rate [tasks project-id]
  (let [[done total] (project-progress tasks project-id)]
    (if (> total 0)
      (quot (* done 100) total)
      0)))

;; === Department analysis ===

(defn department-headcount [employees dept-id]
  (count (employees-in-department employees dept-id)))

(defn department-avg-rate [employees dept-id]
  (let [emps (employees-in-department employees dept-id)]
    (if (empty? emps)
      0
      (quot (reduce + 0 (mapv #(nth % 3) emps)) (count emps)))))

(defn department-budget-remaining [dept departments projects tasks time-entries employees]
  (- (nth dept 2) (department-total-cost (nth dept 0) projects tasks time-entries employees)))

(defn department-budget-used-pct [dept departments projects tasks time-entries employees]
  (let [budget (nth dept 2)
        cost (department-total-cost (nth dept 0) projects tasks time-entries employees)]
    (if (= budget 0)
      0
      (quot (* cost 100) budget))))

(defn department-projects-summary [dept-id projects tasks]
  (let [dept-projs (projects-by-department projects dept-id)
        sorted (sort-by #(nth % 1) dept-projs)]
    (mapv (fn [p]
            (let [[done total] (project-progress tasks (nth p 0))]
              [(nth p 1) done total]))
          sorted)))

(defn department-skill-coverage [dept-id employees skills]
  (let [emps (employees-in-department employees dept-id)
        result (filterv #(> (nth % 1) 0)
                        (mapv (fn [skill]
                                [(nth skill 1)
                                 (count (filterv #(employee-has-skill? % (nth skill 0)) emps))])
                              skills))]
    (vec (sort-by #(nth % 0) result))))

;; === Cross-entity queries ===

(defn employee-workload [employee tasks time-entries]
  (let [emp-id (nth employee 0)
        emp-tasks (tasks-for-employee tasks emp-id)
        active-count (count (filterv #(= (nth % 4) "in-progress") emp-tasks))
        total-hours (hours-logged-by-employee time-entries emp-id)]
    [active-count total-hours]))

(defn busiest-employee [employees tasks time-entries]
  (first (sort-by (fn [e] [(- (hours-logged-by-employee time-entries (nth e 0))) (nth e 0)]) employees)))

(defn most-expensive-project [projects tasks time-entries employees]
  (first (sort-by (fn [p] [(- (project-cost p tasks time-entries employees)) (nth p 0)]) projects)))

(defn available-employees [employees tasks max-active]
  (filterv (fn [e]
             (let [active (count (filterv #(= (nth % 4) "in-progress") (tasks-for-employee tasks (nth e 0))))]
               (< active max-active)))
           employees))

(defn skill-gap [project-id tasks employees skills]
  (let [proj-tasks (tasks-for-project tasks project-id)
        assignee-ids (set (mapv #(nth % 2) proj-tasks))
        team-skill-ids (set (mapcat (fn [eid]
                                      (let [emp (find-employee employees eid)]
                                        (if emp (parse-skill-ids emp) [])))
                                    assignee-ids))
        missing (filterv #(not (contains? team-skill-ids (nth % 0))) skills)]
    (vec (sort-by #(nth % 1) missing))))

(defn team-for-project [project-id tasks employees]
  (let [proj-tasks (tasks-for-project tasks project-id)
        assignee-ids (distinct (mapv #(nth % 2) proj-tasks))
        team (filterv some? (mapv #(find-employee employees %) assignee-ids))]
    (vec (sort-by #(nth % 1) team))))

;; === Sorting ===

(defn sort-projects-by-priority [projects]
  (vec (sort-by (fn [p] [(nth p 4) (nth p 1)]) projects)))

(defn sort-employees-by-rate [employees]
  (vec (sort-by (fn [e] [(- (nth e 3)) (nth e 1)]) employees)))

(defn- status-order [status]
  (case status
    "blocked" 0
    "todo" 1
    "in-progress" 2
    "done" 3
    4))

(defn sort-tasks-by-status [tasks]
  (vec (sort-by (fn [t] [(status-order (nth t 4)) (nth t 0)]) tasks)))

(defn sort-projects-by-cost [projects tasks time-entries employees]
  (vec (sort-by (fn [p] [(- (project-cost p tasks time-entries employees)) (nth p 1)]) projects)))

;; === Formatting ===

(defn format-employee [employee]
  (str (nth employee 1) " ($" (nth employee 3) "/hr)"))

(defn format-project-short [project]
  (str (nth project 1) " [" (nth project 3) "] P" (nth project 4)))

(defn format-task [task]
  (str (nth task 3) " (" (nth task 4) ", Est: " (nth task 5) "h)"))

(defn format-project-progress [tasks project]
  (let [[done total] (project-progress tasks (nth project 0))
        pct (completion-rate tasks (nth project 0))]
    (str (nth project 1) ": " done "/" total " tasks complete (" pct "%)")))

(defn format-department-budget [dept departments projects tasks time-entries employees]
  (let [cost (department-total-cost (nth dept 0) projects tasks time-entries employees)
        budget (nth dept 2)
        pct (department-budget-used-pct dept departments projects tasks time-entries employees)]
    (str (nth dept 1) ": $" cost "/$" budget " (" pct "%)")))

(defn format-employee-workload [employee tasks time-entries]
  (let [[active hours] (employee-workload employee tasks time-entries)]
    (str (nth employee 1) ": " active " active, " hours "h logged")))

;; === Reports ===

(defn project-report [project tasks time-entries employees]
  (let [project-id (nth project 0)
        [done total] (project-progress tasks project-id)
        pct (completion-rate tasks project-id)
        actual (project-actual-hours tasks time-entries project-id)
        estimated (project-estimated-hours tasks project-id)
        cost (project-cost project tasks time-entries employees)
        team (team-for-project project-id tasks employees)
        proj-tasks (sort-tasks-by-status (tasks-for-project tasks project-id))]
    (vec (concat
          [(str "=== Project: " (nth project 1) " [" (nth project 3) "] ===")
           (str "Priority: " (nth project 4) " | Deadline: " (nth project 5))
           (str "Progress: " done "/" total " tasks (" pct "%)")
           (str "Hours: " actual "/" estimated)
           (str "Cost: $" cost)
           ""
           "--- Team ---"]
          (mapv #(str "  " (format-employee %)) team)
          ["" "--- Tasks ---"]
          (mapv (fn [t]
                  (str "  [" (nth t 4) "] " (nth t 3) " (Est: " (nth t 5) "h, Logged: " (hours-logged-on-task time-entries (nth t 0)) "h)"))
                proj-tasks)))))

(defn department-report [dept departments employees projects tasks time-entries skills]
  (let [dept-id (nth dept 0)
        hc (department-headcount employees dept-id)
        avg (department-avg-rate employees dept-id)
        cost (department-total-cost dept-id projects tasks time-entries employees)
        budget (nth dept 2)
        pct (department-budget-used-pct dept departments projects tasks time-entries employees)
        dept-projs (sort-projects-by-priority (projects-by-department projects dept-id))
        sc (department-skill-coverage dept-id employees skills)]
    (vec (concat
          [(str "=== Department: " (nth dept 1) " ===")
           (str "Headcount: " hc " | Avg Rate: $" avg "/hr")
           (str "Budget: $" cost "/$" budget " (" pct "%)")
           ""
           "--- Projects ---"]
          (mapv (fn [p]
                  (let [[done total] (project-progress tasks (nth p 0))]
                    (str "  " (nth p 1) " [" (nth p 3) "] - " done "/" total " tasks")))
                dept-projs)
          ["" "--- Skills ---"]
          (mapv (fn [s] (str "  " (nth s 0) ": " (nth s 1) " employees")) sc)))))

(defn executive-summary [departments employees projects tasks time-entries skills]
  (let [total-emps (count employees)
        total-projs (count projects)
        active-count (count (active-projects projects))
        total-budget (reduce + 0 (mapv #(nth % 2) departments))
        total-spent (reduce + 0 (mapv #(department-total-cost (nth % 0) projects tasks time-entries employees) departments))
        pct (if (= total-budget 0) 0 (quot (* total-spent 100) total-budget))
        overdue (sort-by #(nth % 0) (overdue-tasks tasks time-entries))]
    (vec (concat
          ["=== Executive Summary ==="
           (str "Total Employees: " total-emps)
           (str "Total Projects: " total-projs)
           (str "Active Projects: " active-count)
           (str "Total Budget: $" total-budget)
           (str "Total Spent: $" total-spent)
           (str "Overall Budget Used: " pct "%")
           ""
           "--- Overdue Tasks ---"]
          (if (empty? overdue)
            ["  None"]
            (mapv (fn [t]
                    (let [proj (find-project projects (nth t 1))]
                      (str "  [" (nth proj 1) "] " (nth t 3)
                           " (Est: " (nth t 5) "h, Actual: " (hours-logged-on-task time-entries (nth t 0)) "h)")))
                  overdue))))))

(defn availability-report [employees tasks max-active]
  (let [avail (vec (sort-by #(nth % 1) (available-employees employees tasks max-active)))]
    (vec (concat
          [(str "=== Availability Report (max " max-active " active) ===")
           (str "Available: " (count avail) " / Total: " (count employees))
           ""]
          (mapv (fn [e]
                  (let [active (count (filterv #(= (nth % 4) "in-progress") (tasks-for-employee tasks (nth e 0))))]
                    (str "  " (nth e 1) " (Rate: $" (nth e 3) "/hr) - " active " active tasks")))
                avail)))))
