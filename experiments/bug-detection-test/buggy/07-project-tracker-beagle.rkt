#lang beagle

(ns benchmark.project-tracker)

(require clojure.string :as str)

;; --- Parsing ---

(defn parse-skill [(s : String)]
  (let [parts (str/split s #"\|")]
    [(parse-long (nth parts 0))
     (nth parts 1)
     (nth parts 2)]))

(defn parse-skills [(text : String)]
  (let [lines (filterv (fn [line] (not (str/blank? line)))
                       (str/split (str/trim text) #"\n"))]
    (mapv parse-skill lines)))

(defn parse-department [(s : String)]
  (let [parts (str/split s #"\|")]
    [(parse-long (nth parts 0))
     (nth parts 1)
     (parse-long (nth parts 2))
     (parse-long (nth parts 3))]))

(defn parse-departments [(text : String)]
  (let [lines (filterv (fn [line] (not (str/blank? line)))
                       (str/split (str/trim text) #"\n"))]
    (mapv parse-department lines)))

(defn parse-employee [(s : String)]
  (let [parts (str/split s #"\|")]
    [(parse-long (nth parts 0))
     (nth parts 1)
     (parse-long (nth parts 2))
     (parse-long (nth parts 3))
     (nth parts 4)]))

(defn parse-employees [(text : String)]
  (let [lines (filterv (fn [line] (not (str/blank? line)))
                       (str/split (str/trim text) #"\n"))]
    (mapv parse-employee lines)))

(defn parse-project [(s : String)]
  (let [parts (str/split s #"\|")]
    [(parse-long (nth parts 0))
     (nth parts 1)
     (parse-long (nth parts 2))
     (nth parts 3)
     (parse-long (nth parts 4))
     (nth parts 5)]))

(defn parse-projects [(text : String)]
  (let [lines (filterv (fn [line] (not (str/blank? line)))
                       (str/split (str/trim text) #"\n"))]
    (mapv parse-project lines)))

(defn parse-task [(s : String)]
  (let [parts (str/split s #"\|")]
    [(parse-long (nth parts 0))
     (parse-long (nth parts 1))
     (parse-long (nth parts 2))
     (nth parts 3)
     (nth parts 4)
     (parse-long (nth parts 5))]))

(defn parse-tasks [(text : String)]
  (let [lines (filterv (fn [line] (not (str/blank? line)))
                       (str/split (str/trim text) #"\n"))]
    (mapv parse-task lines)))

(defn parse-time-entry [(s : String)]
  (let [parts (str/split s #"\|")]
    [(parse-long (nth parts 0))
     (parse-long (nth parts 1))
     (parse-long (nth parts 2))
     (parse-long (nth parts 3))
     (nth parts 4)]))

(defn parse-time-entries [(text : String)]
  (let [lines (filterv (fn [line] (not (str/blank? line)))
                       (str/split (str/trim text) #"\n"))]
    (mapv parse-time-entry lines)))

;; --- Employee skill helpers ---

(defn parse-skill-ids [employee]
  (let [s (nth employee 4)]
    (if (= s "")
      []
      (mapv parse-long (str/split s #",")))))

(defn employee-has-skill? [employee (skill-id : Long)]
  (some (fn [sid] (= sid skill-id)) (parse-skill-ids employee)))

(defn employees-with-skill [employees (skill-id : Long)]
  (filterv (fn [e] (employee-has-skill? e skill-id)) employees))

(defn employee-skills [employee skills]
  (let [sids (parse-skill-ids employee)]
    (filterv (fn [sk] (some (fn [sid] (= sid (nth sk 0))) sids)) skills)))

;; --- Lookups ---

(defn find-employee [employees (id : Long)]
  (first (filter (fn [e] (= (nth e 0) id)) employees)))

(defn find-department [departments (id : Long)]
  (first (filter (fn [d] (= (nth d 0) id)) departments)))

(defn find-project [projects (id : Long)]
  (first (filter (fn [p] (= (nth p 0) id)) projects)))

(defn find-task [tasks (id : Long)]
  (first (filter (fn [t] (= (nth t 0) id)) tasks)))

(defn find-skill [skills (id : Long)]
  (first (filter (fn [s] (= (nth s 0) id)) skills)))

(defn department-for-employee [departments employee]
  (find-department departments (nth employee 2)))

;; --- Filtering ---

(defn projects-by-status [projects (status : String)]
  (filterv (fn [p] (= (nth p 3) status)) projects))

(defn projects-by-department [projects (dept-id : Long)]
  (filterv (fn [p] (= (nth p 2) dept-id)) projects))

(defn projects-by-priority [projects (max-priority : Long)]
  (filterv (fn [p] (<= (nth p 4) max-priority)) projects))

(defn active-projects [projects]
  (projects-by-status projects "active"))

(defn tasks-for-project [tasks (project-id : Long)]
  (filterv (fn [t] (= (nth t 1) project-id)) tasks))

(defn tasks-for-employee [tasks (employee-id : Long)]
  (filterv (fn [t] (= (nth t 2) employee-id)) tasks))

(defn tasks-by-status [tasks (status : String)]
  (filterv (fn [t] (= (nth t 4) status)) tasks))

(defn employees-in-department [employees (dept-id : Long)]
  (filterv (fn [e] (= (nth e 2) dept-id)) employees))

(defn time-entries-for-task [time-entries (task-id : Long)]
  (filterv (fn [te] (= (nth te 1) task-id)) time-entries))

(defn time-entries-for-employee [time-entries (employee-id : Long)]
  (filterv (fn [te] (= (nth te 2) employee-id)) time-entries))

;; --- Cost calculations ---

(defn hours-logged-on-task [time-entries (task-id : Long)]
  (reduce (fn [acc te] (+ acc (nth te 3)))
          0
          (time-entries-for-task time-entries task-id)))

(defn hours-logged-by-employee [time-entries (employee-id : Long)]
  (reduce (fn [acc te] (+ acc (nth te 3)))
          0
          (time-entries-for-employee time-entries employee-id)))

(defn task-cost [task time-entries employees]
  (let [tid (nth task 0)
        entries (time-entries-for-task time-entries tid)]
    (reduce (fn [acc te]
              (let [emp (find-employee employees (nth te 2))
                    rate (if (nil? emp) 0 (nth emp 3))]
                (+ acc (* (nth te 3) rate))))
            0
            entries)))

(defn project-cost [project tasks time-entries employees]
  (let [pid (nth project 0)
        ptasks (tasks-for-project tasks pid)]
    (reduce (fn [acc t] (+ acc (task-cost t time-entries employees)))
            0
            ptasks)))

(defn department-total-cost [dept-id projects tasks time-entries employees]
  (let [dprojects (projects-by-department projects dept-id)]
    (reduce (fn [acc p] (+ acc (project-cost p tasks time-entries employees)))
            0
            dprojects)))

(defn employee-cost [employee time-entries]
  (let [hours (hours-logged-by-employee time-entries (nth employee 0))]
    (* hours (nth employee 2))))

;; --- Project analysis ---

(defn project-progress [tasks (project-id : Long)]
  (let [ptasks (tasks-for-project tasks project-id)
        total (count ptasks)
        done (count (filterv (fn [t] (= (nth t 4) "done")) ptasks))]
    [done total]))

(defn project-estimated-hours [tasks (project-id : Long)]
  (reduce (fn [acc t] (+ acc (nth t 5)))
          0
          (tasks-for-project tasks project-id)))

(defn project-actual-hours [tasks time-entries (project-id : Long)]
  (let [ptasks (tasks-for-project tasks project-id)]
    (reduce (fn [acc t] (+ acc (hours-logged-on-task time-entries (nth t 0))))
            0
            ptasks)))

(defn project-on-track? [tasks time-entries (project-id : Long)]
  (<= (project-actual-hours tasks time-entries project-id)
      (project-estimated-hours tasks project-id)))

(defn overdue-tasks [tasks time-entries]
  (filterv (fn [t]
             (if (= (nth t 4) "done")
               false
               (> (hours-logged-on-task time-entries (nth t 0)) (nth t 5))))
           tasks))

(defn blocked-tasks [tasks]
  (tasks-by-status tasks "blocked"))

(defn unassigned-estimate [tasks (project-id : Long)]
  (reduce (fn [acc t] (+ acc (nth t 5)))
          0
          (filterv (fn [t] (= (nth t 4) "todo"))
                   (tasks-for-project tasks project-id))))

(defn completion-rate [tasks (project-id : Long)]
  (let [prog (project-progress tasks project-id)
        done (nth prog 0)
        total (nth prog 1)]
    (if (> total 0)
      (quot (* done 100) total)
      0)))

;; --- Department analysis ---

(defn department-headcount [employees (dept-id : Long)]
  (count (employees-in-department employees dept-id)))

(defn department-avg-rate [employees (dept-id : Long)]
  (let [emps (employees-in-department employees dept-id)
        n (count emps)]
    (if (= n 0)
      0
      (quot (reduce (fn [acc e] (+ acc (nth e 3))) 0 emps) n))))

(defn department-budget-remaining [dept departments projects tasks time-entries employees]
  (let [budget (nth dept 2)
        cost (department-total-cost (nth dept 0) projects tasks time-entries employees)]
    (- budget cost)))

(defn department-budget-used-pct [dept departments projects tasks time-entries employees]
  (let [budget (nth dept 2)
        cost (department-total-cost (nth dept 0) projects tasks time-entries employees)]
    (if (= budget 0)
      0
      (quot (* cost 100) budget))))

(defn department-projects-summary [(dept-id : Long) projects tasks]
  (let [dprojects (projects-by-department projects dept-id)
        summaries (mapv (fn [p]
                          (let [prog (project-progress tasks (nth p 0))]
                            [(nth p 1) (nth prog 0) (nth prog 1)]))
                        dprojects)]
    (vec (sort-by first summaries))))

(defn department-skill-coverage [(dept-id : Long) employees skills]
  (let [emps (employees-in-department employees dept-id)
        pairs (filterv
                (fn [pair] (> (nth pair 1) 0))
                (mapv (fn [sk]
                        (let [sid (nth sk 0)
                              cnt (count (filterv (fn [e] (employee-has-skill? e sid)) emps))]
                          [(nth sk 1) cnt]))
                      skills))]
    (vec (sort-by first pairs))))

;; --- Cross-entity queries ---

(defn employee-workload [employee tasks time-entries]
  (let [eid (nth employee 0)
        etasks (tasks-for-employee tasks eid)
        active (count (filterv (fn [t] (= (nth t 4) "in-progress")) etasks))
        hours (hours-logged-by-employee time-entries eid)]
    [active hours]))

(defn busiest-employee [employees tasks time-entries]
  (first (sort-by (fn [e] (- 0 (hours-logged-employee time-entries (nth e 0)))) employees)))

(defn most-expensive-project [projects tasks time-entries employees]
  (first (sort-by (fn [p] (- 0 (project-cost p tasks time-entries))) projects)))

(defn available-employees [employees tasks (max-active : Long)]
  (filterv (fn [e]
             (let [etasks (tasks-for-employee tasks (nth e 0))
                   active (count (filterv (fn [t] (= (nth t 4) "in-progress")) etasks))]
               (< active max-active)))
           employees))

(defn skill-gap [(project-id : Long) tasks employees skills]
  (let [ptasks (tasks-for-project tasks project-id)
        assignee-ids (distinct (mapv (fn [t] (nth t 2)) ptasks))
        team-emps (filterv (fn [e] (some (fn [aid] (= aid (nth e 0))) assignee-ids)) employees)
        team-skill-ids (distinct (reduce (fn [acc e] (into acc (parse-skill-ids e))) [] team-emps))
        missing (filterv (fn [sk] (not (some (fn [sid] (= sid (nth sk 0))) team-skill-ids))) skills)]
    (vec (sort-by (fn [sk] (nth sk 1)) missing))))

(defn team-for-project [(project-id : Long) tasks employees]
  (let [ptasks (tasks-for-project tasks project-id)
        assignee-ids (distinct (mapv (fn [t] (nth t 2)) ptasks))
        team (filterv (fn [e] (some (fn [aid] (= aid (nth e 0))) assignee-ids)) employees)]
    (vec (sort-by (fn [e] (nth e 1)) team))))

;; --- Sorting ---

(defn status-order [(status : String)]
  (cond
    (= status "blocked") 0
    (= status "todo") 1
    (= status "in-progress") 2
    (= status "done") 3
    true 4))

(defn sort-projects-by-priority [projects]
  (vec (sort-by (fn [p] [(nth p 4) (nth p 1)]) projects)))

(defn sort-employees-by-rate [employees]
  (vec (sort-by (fn [e] [(- 0 (nth e 3)) (nth e 1)]) employees)))

(defn sort-tasks-by-status [tasks]
  (vec (sort-by (fn [t] [(status-order (nth t 4)) (nth t 0)]) tasks)))

(defn sort-projects-by-cost [projects tasks time-entries employees]
  (vec (sort-by (fn [p] [(project-cost p tasks time-entries employees) (nth p 1)]) projects)))

;; --- Formatting ---

(defn format-employee [employee]
  (str (nth employee 1) " ($" (nth employee 3) "/hr)"))

(defn format-project-short [project]
  (str (nth project 1) " [" (nth project 3) "] P" (nth project 4)))

(defn format-task [task]
  (str (nth task 3) " (" (nth task 4) ", Est: " (nth task 5) "h)"))

(defn format-project-progress [tasks project]
  (let [prog (project-progress tasks (nth project 0))
        done (nth prog 0)
        total (nth prog 1)
        pct (completion-rate tasks (nth project 0))]
    (str (nth project 1) ": " done "/" total " tasks complete (" pct "%)")))

(defn format-department-budget [dept departments projects tasks time-entries employees]
  (let [cost (department-total-cost (nth dept 0) projects tasks time-entries employees)
        budget (nth dept 2)
        pct (department-budget-used-pct dept departments projects tasks time-entries)]
    (str (nth dept 1) ": $" cost "/$" budget " (" pct "%)")))

(defn format-employee-workload [employee tasks time-entries]
  (let [wl (employee-workload employee tasks time-entries)
        active (nth wl 0)
        hours (nth wl 1)]
    (str (nth employee 1) ": " active " active, " hours "h logged")))

;; --- Reports ---

(defn project-report [project tasks time-entries employees]
  (let [pid (nth project 0)
        prog (project-progress tasks pid)
        done (nth prog 0)
        total (nth prog 1)
        pct (completion-rate tasks pid)
        actual (project-actual-hours tasks time-entries pid)
        estimated (project-estimated-hours tasks pid)
        cost (project-cost project tasks time-entries employees)
        team (team-for-project pid tasks employees)
        ptasks (sort-tasks-by-status (tasks-for-project tasks pid))
        header [(str "=== Project: " (nth project 1) " [" (nth project 3) "] ===")
                (str "Priority: " (nth project 4) " | Deadline: " (nth project 5))
                (str "Progress: " done "/" total " tasks (" pct "%)")
                (str "Hours: " actual "/" estimated)
                (str "Cost: $" cost)
                ""
                "--- Team ---"]
        team-lines (mapv (fn [e] (str "  " (nth e 1) " ($" (nth e 3) "/hr)")) team)
        mid ["" "--- Tasks ---"]
        task-lines (mapv (fn [t]
                           (str "  [" (nth t 4) "] " (nth t 3)
                                " (Est: " (nth t 5) "h, Logged: "
                                (hours-logged-on-task time-entries (nth t 0)) "h)"))
                         ptasks)]
    (vec (concat header team-lines mid task-lines))))

(defn department-report [dept departments employees projects tasks time-entries skills]
  (let [did (nth dept 0)
        hc (department-headcount employees did)
        avg (department-avg-rate employees did)
        cost (department-total-cost did projects tasks time-entries employees)
        budget (nth dept 2)
        pct (department-budget-used-pct dept departments projects tasks time-entries employees)
        dprojects (sort-projects-by-priority (projects-by-department projects did))
        sc (department-skill-coverage did employees skills)
        header [(str "=== Department: " (nth dept 1) " ===")
                (str "Headcount: " hc " | Avg Rate: $" avg "/hr")
                (str "Budget: $" cost "/$" budget " (" pct "%)")
                ""
                "--- Projects ---"]
        proj-lines (mapv (fn [p]
                           (let [prog (project-progress tasks (nth p 0))]
                             (str "  " (nth p 1) " [" (nth p 3) "] - "
                                  (nth prog 0) "/" (nth prog 1) " tasks")))
                         dprojects)
        mid ["" "--- Skills ---"]
        skill-lines (mapv (fn [pair]
                            (str "  " (nth pair 0) ": " (nth pair 1) " employees"))
                          sc)]
    (vec (concat header proj-lines mid skill-lines))))

(defn executive-summary [departments employees projects tasks time-entries skills]
  (let [total-emps (count employees)
        total-projs (count projects)
        active-projs (count (active-projects projects))
        total-budget (reduce (fn [acc d] (+ acc (nth d 2))) 0 departments)
        total-spent (reduce (fn [acc d] (+ acc (department-total-cost (nth d 0) projects tasks time-entries employees)))
                            0 departments)
        pct (if (= total-budget 0) 0 (quot (* total-spent 100) total-budget))
        od (overdue-tasks tasks time-entries)
        od-sorted (vec (sort-by (fn [t] (nth t 0)) od))
        header [(str "=== Executive Summary ===")
                (str "Total Employees: " total-emps)
                (str "Total Projects: " total-projs)
                (str "Active Projects: " active-projs)
                (str "Total Budget: $" total-budget)
                (str "Total Spent: $" total-spent)
                (str "Overall Budget Used: " pct "%")
                ""
                "--- Overdue Tasks ---"]
        od-lines (if (= (count od-sorted) 0)
                   ["  None"]
                   (mapv (fn [t]
                           (let [proj (find-project projects (nth t 1))]
                             (str "  [" (nth proj 1) "] " (nth t 3)
                                  " (Est: " (nth t 5) "h, Actual: "
                                  (hours-logged-on-task time-entries (nth t 0)) "h)")))
                         od-sorted))]
    (vec (concat header od-lines))))

(defn availability-report [employees tasks (max-active : Long)]
  (let [avail (available-employees employees tasks max-active)
        avail-sorted (vec (sort-by (fn [e] (nth e 1)) avail))
        header [(str "=== Availability Report (max " max-active " active) ===")
                (str "Available: " (count avail) " / Total: " (count employees))
                ""]
        lines (mapv (fn [e]
                      (let [etasks (tasks-for-employee tasks (nth e 0))
                            active (count (filterv (fn [t] (= (nth t 4) "in-progress")) etasks))]
                        (str "  " (nth e 1) " (Rate: $" (nth e 3) "/hr) - " active " active tasks")))
                    avail-sorted)]
    (vec (concat header lines))))
