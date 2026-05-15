(def skill-text (str "1|Clojure|technical\n"
                     "2|React|technical\n"
                     "3|SQL|technical\n"
                     "4|Project Management|management\n"
                     "5|UX Design|design\n"
                     "6|DevOps|technical\n"
                     "7|Leadership|management\n"
                     "8|Figma|design"))

(def dept-text (str "1|Engineering|500000|1\n"
                    "2|Design|200000|5\n"
                    "3|Operations|300000|8"))

(def emp-text (str "1|Alice|1|95|1,3,6\n"
                   "2|Bob|1|85|1,2\n"
                   "3|Carol|2|75|5,8\n"
                   "4|Dave|1|90|1,3,4\n"
                   "5|Eve|2|80|5,7,8\n"
                   "6|Frank|3|70|4,6\n"
                   "7|Grace|1|100|1,2,3,6\n"
                   "8|Hank|3|65|4,7\n"
                   "9|Ivy|1|88|2,3\n"
                   "10|Jack|2|72|5,8"))

(def proj-text (str "1|Platform Rewrite|1|active|1|2024-06-30\n"
                    "2|Mobile App|1|active|2|2024-09-15\n"
                    "3|Brand Refresh|2|planning|3|2024-12-01\n"
                    "4|Infrastructure|3|active|1|2024-05-01\n"
                    "5|Data Pipeline|1|completed|2|2024-03-01\n"
                    "6|Design System|2|on-hold|4|2024-08-15\n"
                    "7|API Gateway|1|active|1|2024-07-15\n"
                    "8|Cost Optimization|3|planning|3|2025-01-01"))

(def task-text (str "1|1|1|Design database schema|done|16\n"
                    "2|1|2|Build API endpoints|in-progress|40\n"
                    "3|1|7|Code review framework|in-progress|24\n"
                    "4|1|4|Write migration scripts|todo|20\n"
                    "5|2|2|Setup React Native|done|12\n"
                    "6|2|9|Build login screen|in-progress|16\n"
                    "7|2|3|Design app mockups|done|24\n"
                    "8|3|5|Brand guidelines|todo|32\n"
                    "9|3|10|Logo concepts|todo|20\n"
                    "10|3|3|Color palette|todo|8\n"
                    "11|4|6|Kubernetes setup|in-progress|40\n"
                    "12|4|8|Monitoring dashboards|todo|16\n"
                    "13|5|1|ETL pipeline|done|30\n"
                    "14|5|4|Data validation|done|20\n"
                    "15|5|9|Query optimization|done|24\n"
                    "16|7|7|Gateway architecture|in-progress|20\n"
                    "17|7|1|Rate limiting|todo|12\n"
                    "18|7|4|Auth middleware|in-progress|16\n"
                    "19|6|5|Component library|todo|40\n"
                    "20|6|10|Icon set|todo|24\n"
                    "21|8|6|Cost analysis|todo|20\n"
                    "22|8|8|Vendor review|todo|16"))

(def time-text (str "1|1|1|14|2024-01-15\n"
                    "2|1|1|2|2024-01-16\n"
                    "3|2|2|20|2024-02-01\n"
                    "4|2|2|8|2024-02-15\n"
                    "5|3|7|10|2024-02-10\n"
                    "6|5|2|12|2024-01-20\n"
                    "7|6|9|8|2024-03-01\n"
                    "8|7|3|24|2024-01-10\n"
                    "9|11|6|20|2024-03-15\n"
                    "10|11|6|10|2024-03-20\n"
                    "11|13|1|28|2024-01-05\n"
                    "12|14|4|18|2024-01-20\n"
                    "13|15|9|22|2024-02-01\n"
                    "14|16|7|12|2024-03-01\n"
                    "15|17|1|4|2024-03-10\n"
                    "16|18|4|8|2024-03-15\n"
                    "17|9|10|6|2024-03-20\n"
                    "18|10|3|4|2024-03-22"))

(def skills (r/parse-skills skill-text))
(def departments (r/parse-departments dept-text))
(def employees (r/parse-employees emp-text))
(def projects (r/parse-projects proj-text))
(def tasks (r/parse-tasks task-text))
(def time-entries (r/parse-time-entries time-text))

;; --- parsing ---
(when-not (= (count skills) 8) (System/exit 1))
(when-not (= (nth (first skills) 0) 1) (System/exit 1))
(when-not (= (nth (first skills) 1) "Clojure") (System/exit 1))
(when-not (= (nth (first skills) 2) "technical") (System/exit 1))

(when-not (= (count departments) 3) (System/exit 1))
(when-not (= (nth (first departments) 1) "Engineering") (System/exit 1))
(when-not (= (nth (first departments) 2) 500000) (System/exit 1))

(when-not (= (count employees) 10) (System/exit 1))
(when-not (= (nth (first employees) 1) "Alice") (System/exit 1))
(when-not (= (nth (first employees) 3) 95) (System/exit 1))
(when-not (= (nth (first employees) 4) "1,3,6") (System/exit 1))

(when-not (= (count projects) 8) (System/exit 1))
(when-not (= (nth (first projects) 1) "Platform Rewrite") (System/exit 1))
(when-not (= (nth (first projects) 3) "active") (System/exit 1))

(when-not (= (count tasks) 22) (System/exit 1))
(when-not (= (nth (first tasks) 3) "Design database schema") (System/exit 1))
(when-not (= (nth (first tasks) 5) 16) (System/exit 1))

(when-not (= (count time-entries) 18) (System/exit 1))
(when-not (= (nth (first time-entries) 3) 14) (System/exit 1))

;; --- skill helpers ---
(when-not (= (r/parse-skill-ids (first employees)) [1 3 6]) (System/exit 1))
(when-not (= (r/parse-skill-ids (nth employees 2)) [5 8]) (System/exit 1))

;; employee 6 (Frank index 5) has skills "4,6"
(let [frank (nth employees 5)]
  (when-not (= (r/parse-skill-ids frank) [4 6]) (System/exit 1))
  (when-not (r/employee-has-skill? frank 4) (System/exit 1))
  (when (r/employee-has-skill? frank 1) (System/exit 1)))

(when-not (= (count (r/employees-with-skill employees 1)) 4) (System/exit 1))
(when-not (= (count (r/employees-with-skill employees 5)) 3) (System/exit 1))

(let [alice-skills (r/employee-skills (first employees) skills)]
  (when-not (= (count alice-skills) 3) (System/exit 1))
  (when-not (= (nth (first alice-skills) 1) "Clojure") (System/exit 1)))

;; --- lookups ---
(when-not (= (nth (r/find-employee employees 1) 1) "Alice") (System/exit 1))
(when-not (nil? (r/find-employee employees 99)) (System/exit 1))
(when-not (= (nth (r/find-department departments 2) 1) "Design") (System/exit 1))
(when-not (nil? (r/find-department departments 99)) (System/exit 1))
(when-not (= (nth (r/find-project projects 1) 1) "Platform Rewrite") (System/exit 1))
(when-not (nil? (r/find-project projects 99)) (System/exit 1))
(when-not (= (nth (r/find-task tasks 1) 3) "Design database schema") (System/exit 1))
(when-not (nil? (r/find-task tasks 99)) (System/exit 1))
(when-not (= (nth (r/find-skill skills 3) 1) "SQL") (System/exit 1))
(when-not (nil? (r/find-skill skills 99)) (System/exit 1))

;; department-for-employee: Alice is in dept 1 (Engineering)
(when-not (= (nth (r/department-for-employee departments (first employees)) 1) "Engineering") (System/exit 1))

;; --- filtering ---
(when-not (= (count (r/projects-by-status projects "active")) 4) (System/exit 1))
(when-not (= (count (r/projects-by-status projects "planning")) 2) (System/exit 1))
(when-not (= (count (r/projects-by-status projects "completed")) 1) (System/exit 1))
(when-not (= (count (r/projects-by-department projects 1)) 4) (System/exit 1))  ;; Plat Rewrite, Mobile, Data Pipeline, API Gateway
(when-not (= (count (r/projects-by-department projects 2)) 2) (System/exit 1))  ;; Brand Refresh, Design System
(when-not (= (count (r/projects-by-priority projects 1)) 3) (System/exit 1))  ;; priority <= 1: Plat Rewrite, Infrastructure, API Gateway
(when-not (= (count (r/projects-by-priority projects 2)) 5) (System/exit 1))  ;; + Mobile App, Data Pipeline
(when-not (= (count (r/active-projects projects)) 4) (System/exit 1))

(when-not (= (count (r/tasks-for-project tasks 1)) 4) (System/exit 1))
(when-not (= (count (r/tasks-for-project tasks 5)) 3) (System/exit 1))
(when-not (= (count (r/tasks-for-employee tasks 1)) 3) (System/exit 1))
(when-not (= (count (r/tasks-for-employee tasks 2)) 2) (System/exit 1))

(when-not (= (count (r/tasks-by-status tasks "done")) 6) (System/exit 1))  ;; tasks 1,5,7,13,14,15
(when-not (= (count (r/tasks-by-status tasks "in-progress")) 6) (System/exit 1))  ;; tasks 2,3,6,11,16,18
(when-not (= (count (r/tasks-by-status tasks "todo")) 10) (System/exit 1))  ;; tasks 4,8,9,10,12,17,19,20,21,22
(when-not (= (count (r/tasks-by-status tasks "blocked")) 0) (System/exit 1))

(when-not (= (count (r/employees-in-department employees 1)) 5) (System/exit 1))  ;; Alice,Bob,Dave,Grace,Ivy
(when-not (= (count (r/employees-in-department employees 2)) 3) (System/exit 1))  ;; Carol,Eve,Jack
(when-not (= (count (r/employees-in-department employees 3)) 2) (System/exit 1))  ;; Frank,Hank

(when-not (= (count (r/time-entries-for-task time-entries 1)) 2) (System/exit 1))  ;; entries 1,2
(when-not (= (count (r/time-entries-for-task time-entries 2)) 2) (System/exit 1))  ;; entries 3,4
(when-not (= (count (r/time-entries-for-employee time-entries 1)) 4) (System/exit 1))  ;; entries 1,2,11,15 (Alice)
(when-not (= (count (r/time-entries-for-employee time-entries 2)) 3) (System/exit 1))  ;; entries 3,4,6 (Bob)

;; --- cost calculations ---
;; hours-logged-on-task: task 1 = 14+2 = 16, task 2 = 20+8 = 28
(when-not (= (r/hours-logged-on-task time-entries 1) 16) (System/exit 1))
(when-not (= (r/hours-logged-on-task time-entries 2) 28) (System/exit 1))
(when-not (= (r/hours-logged-on-task time-entries 11) 30) (System/exit 1))  ;; 20+10
(when-not (= (r/hours-logged-on-task time-entries 99) 0) (System/exit 1))

;; hours-logged-by-employee: Alice(id=1) = 14+2+28+4 = 48
(when-not (= (r/hours-logged-by-employee time-entries 1) 48) (System/exit 1))
;; Bob(id=2) = 20+8+12 = 40
(when-not (= (r/hours-logged-by-employee time-entries 2) 40) (System/exit 1))

;; task-cost: task 1 has entries by Alice(id=1,rate=95): 16hrs * 95 = 1520
(when-not (= (r/task-cost (first tasks) time-entries employees) 1520) (System/exit 1))

;; task 2 (Build API endpoints): entries 3,4 by Bob(id=2,rate=85): 28hrs * 85 = 2380
(when-not (= (r/task-cost (nth tasks 1) time-entries employees) 2380) (System/exit 1))

;; project-cost: project 1 (Platform Rewrite) has tasks 1,2,3,4
;; task 1: Alice 16hrs * 95 = 1520
;; task 2: Bob 28hrs * 85 = 2380
;; task 3: Grace(id=7,rate=100) 10hrs * 100 = 1000
;; task 4: no time entries = 0
;; total = 4900
(when-not (= (r/project-cost (first projects) tasks time-entries employees) 4900) (System/exit 1))

;; project 5 (Data Pipeline) has tasks 13,14,15
;; task 13: Alice 28hrs * 95 = 2660
;; task 14: Dave(id=4,rate=90) 18hrs * 90 = 1620
;; task 15: Ivy(id=9,rate=88) 22hrs * 88 = 1936
;; total = 6216
(when-not (= (r/project-cost (nth projects 4) tasks time-entries employees) 6216) (System/exit 1))

;; department-total-cost: dept 1 (Engineering) has projects 1,2,5,7
;; project 1: 4900 (calculated above)
;; project 2 (Mobile App): tasks 5,6,7
;;   task 5: Bob 12hrs * 85 = 1020
;;   task 6: Ivy 8hrs * 88 = 704
;;   task 7: Carol(id=3,rate=75) 24hrs * 75 = 1800
;;   total = 3524
;; project 5: 6216 (calculated above)
;; project 7 (API Gateway): tasks 16,17,18
;;   task 16: Grace 12hrs * 100 = 1200
;;   task 17: Alice 4hrs * 95 = 380
;;   task 18: Dave 8hrs * 90 = 720
;;   total = 2300
;; dept 1 total = 4900 + 3524 + 6216 + 2300 = 16940
(when-not (= (r/department-total-cost 1 projects tasks time-entries employees) 16940) (System/exit 1))

;; dept 3 (Operations): projects 4,8
;; project 4 (Infrastructure): tasks 11,12
;;   task 11: Frank(id=6,rate=70) 30hrs * 70 = 2100
;;   task 12: no entries = 0
;;   total = 2100
;; project 8 (Cost Optimization): tasks 21,22 — no time entries = 0
;; dept 3 total = 2100
(when-not (= (r/department-total-cost 3 projects tasks time-entries employees) 2100) (System/exit 1))

;; employee-cost: Alice = 48hrs * 95 = 4560
(when-not (= (r/employee-cost (first employees) time-entries) 4560) (System/exit 1))

;; --- project analysis ---
;; project-progress: project 1 has 4 tasks, 1 done
(when-not (= (r/project-progress tasks 1) [1 4]) (System/exit 1))
;; project 5 has 3 tasks, 3 done
(when-not (= (r/project-progress tasks 5) [3 3]) (System/exit 1))
;; project 8 has 2 tasks, 0 done
(when-not (= (r/project-progress tasks 8) [0 2]) (System/exit 1))

;; project-estimated-hours: project 1 = 16+40+24+20 = 100
(when-not (= (r/project-estimated-hours tasks 1) 100) (System/exit 1))
;; project 5 = 30+20+24 = 74
(when-not (= (r/project-estimated-hours tasks 5) 74) (System/exit 1))

;; project-actual-hours: project 1 = 16+28+10+0 = 54
(when-not (= (r/project-actual-hours tasks time-entries 1) 54) (System/exit 1))
;; project 5 = 28+18+22 = 68
(when-not (= (r/project-actual-hours tasks time-entries 5) 68) (System/exit 1))

;; project-on-track?: project 1: 54 <= 100 -> true
(when-not (r/project-on-track? tasks time-entries 1) (System/exit 1))
;; project 5: 68 <= 74 -> true
(when-not (r/project-on-track? tasks time-entries 5) (System/exit 1))

;; overdue-tasks: tasks where NOT done AND hours-logged > estimated-hours
;; Check each non-done task:
;; task 2 (in-progress, est=40): logged=28 -> not overdue
;; task 3 (in-progress, est=24): logged=10 -> not overdue
;; task 4 (todo, est=20): logged=0 -> not overdue
;; task 6 (in-progress, est=16): logged=8 -> not overdue
;; task 8 (todo, est=32): logged=0 -> not overdue
;; task 9 (todo, est=20): logged=6 -> not overdue
;; task 10 (todo, est=8): logged=4 -> not overdue
;; task 11 (in-progress, est=40): logged=30 -> not overdue
;; task 12 (todo, est=16): logged=0 -> not overdue
;; task 16 (in-progress, est=20): logged=12 -> not overdue
;; task 17 (todo, est=12): logged=4 -> not overdue
;; task 18 (in-progress, est=16): logged=8 -> not overdue
;; task 19 (todo, est=40): logged=0 -> not overdue
;; task 20 (todo, est=24): logged=0 -> not overdue
;; task 21 (todo, est=20): logged=0 -> not overdue
;; task 22 (todo, est=16): logged=0 -> not overdue
;; None are overdue!
(when-not (= (count (r/overdue-tasks tasks time-entries)) 0) (System/exit 1))

(when-not (= (count (r/blocked-tasks tasks)) 0) (System/exit 1))

;; unassigned-estimate: project 1 todo tasks: task 4 (est=20) -> 20
(when-not (= (r/unassigned-estimate tasks 1) 20) (System/exit 1))
;; project 3: tasks 8(32),9(20),10(8) all todo -> 60
(when-not (= (r/unassigned-estimate tasks 3) 60) (System/exit 1))

;; completion-rate: project 1 = 1/4 = quot(100,4) = 25
(when-not (= (r/completion-rate tasks 1) 25) (System/exit 1))
;; project 5 = 3/3 = 100
(when-not (= (r/completion-rate tasks 5) 100) (System/exit 1))
;; project 8 = 0/2 = 0
(when-not (= (r/completion-rate tasks 8) 0) (System/exit 1))

;; --- department analysis ---
(when-not (= (r/department-headcount employees 1) 5) (System/exit 1))
(when-not (= (r/department-headcount employees 2) 3) (System/exit 1))
(when-not (= (r/department-headcount employees 3) 2) (System/exit 1))

;; department-avg-rate: dept 1 = (95+85+90+100+88)/5 = 458/5 = quot(458,5) = 91
(when-not (= (r/department-avg-rate employees 1) 91) (System/exit 1))
;; dept 2 = (75+80+72)/3 = 227/3 = quot(227,3) = 75
(when-not (= (r/department-avg-rate employees 2) 75) (System/exit 1))
;; dept 3 = (70+65)/2 = 135/2 = quot(135,2) = 67
(when-not (= (r/department-avg-rate employees 3) 67) (System/exit 1))

;; department-budget-remaining: dept 1 budget=500000, cost=16940, remaining=483060
(when-not (= (r/department-budget-remaining (first departments) departments projects tasks time-entries employees) 483060) (System/exit 1))

;; department-budget-used-pct: dept 1 = quot(16940*100, 500000) = quot(1694000, 500000) = 3
(when-not (= (r/department-budget-used-pct (first departments) departments projects tasks time-entries employees) 3) (System/exit 1))

;; department-projects-summary: dept 1 projects sorted by name:
;; API Gateway, Data Pipeline, Mobile App, Platform Rewrite
;; API Gateway: tasks 16,17,18 -> 0 done / 3 total. Wait: task 16 in-progress, 17 todo, 18 in-progress -> 0 done
;; Data Pipeline: tasks 13,14,15 -> 3 done / 3 total
;; Mobile App: tasks 5,6,7 -> task 5 done, 7 done, 6 in-progress -> 2 done / 3 total
;; Platform Rewrite: tasks 1,2,3,4 -> task 1 done -> 1 done / 4 total
(let [summary (r/department-projects-summary 1 projects tasks)]
  (when-not (= (count summary) 4) (System/exit 1))
  (when-not (= (nth (nth summary 0) 0) "API Gateway") (System/exit 1))
  (when-not (= (nth (nth summary 0) 1) 0) (System/exit 1))
  (when-not (= (nth (nth summary 0) 2) 3) (System/exit 1))
  (when-not (= (nth (nth summary 1) 0) "Data Pipeline") (System/exit 1))
  (when-not (= (nth (nth summary 1) 1) 3) (System/exit 1))
  (when-not (= (nth (nth summary 2) 0) "Mobile App") (System/exit 1))
  (when-not (= (nth (nth summary 2) 1) 2) (System/exit 1))
  (when-not (= (nth (nth summary 3) 0) "Platform Rewrite") (System/exit 1))
  (when-not (= (nth (nth summary 3) 1) 1) (System/exit 1)))

;; department-skill-coverage: dept 1 employees: Alice(1,3,6) Bob(1,2) Dave(1,3,4) Grace(1,2,3,6) Ivy(2,3)
;; skill 1 (Clojure): Alice,Bob,Dave,Grace = 4
;; skill 2 (React): Bob,Grace,Ivy = 3
;; skill 3 (SQL): Alice,Dave,Grace,Ivy = 4
;; skill 4 (PM): Dave = 1
;; skill 6 (DevOps): Alice,Grace = 2
;; sorted alpha: Clojure(4), DevOps(2), Project Management(1), React(3), SQL(4)
(let [sc (r/department-skill-coverage 1 employees skills)]
  (when-not (= (count sc) 5) (System/exit 1))
  (when-not (= (nth (nth sc 0) 0) "Clojure") (System/exit 1))
  (when-not (= (nth (nth sc 0) 1) 4) (System/exit 1))
  (when-not (= (nth (nth sc 1) 0) "DevOps") (System/exit 1))
  (when-not (= (nth (nth sc 1) 1) 2) (System/exit 1))
  (when-not (= (nth (nth sc 2) 0) "Project Management") (System/exit 1))
  (when-not (= (nth (nth sc 2) 1) 1) (System/exit 1))
  (when-not (= (nth (nth sc 3) 0) "React") (System/exit 1))
  (when-not (= (nth (nth sc 3) 1) 3) (System/exit 1))
  (when-not (= (nth (nth sc 4) 0) "SQL") (System/exit 1))
  (when-not (= (nth (nth sc 4) 1) 4) (System/exit 1)))

;; --- cross-entity queries ---
;; employee-workload: Alice has in-progress tasks: none (task 1 done, task 13 done, task 17 todo)
;; Alice's tasks: 1(done), 13(done), 17(todo) -> 0 active
;; Alice's hours: 48
(when-not (= (r/employee-workload (first employees) tasks time-entries) [0 48]) (System/exit 1))

;; Bob: tasks 2(in-progress), 5(done) -> 1 active, hours=40
(when-not (= (r/employee-workload (nth employees 1) tasks time-entries) [1 40]) (System/exit 1))

;; busiest-employee: by total hours logged
;; Alice=48, Bob=40, Carol=24+4=28, Dave=18+8=26, Eve=0, Frank=20+10=30, Grace=10+12=22, Hank=0, Ivy=8+22=30, Jack=6
;; Alice has most at 48
(when-not (= (nth (r/busiest-employee employees tasks time-entries) 1) "Alice") (System/exit 1))

;; most-expensive-project: compare all project costs
;; project 1: 4900
;; project 2: 3524
;; project 3: tasks 8,9,10. task 8: no entries. task 9: entry 17 (Jack, 6hrs*72=432). task 10: entry 18 (Carol, 4hrs*75=300). total=732
;; project 4: 2100
;; project 5: 6216
;; project 6: tasks 19,20 — no entries = 0
;; project 7: 2300
;; project 8: tasks 21,22 — no entries = 0
;; Most expensive: project 5 (Data Pipeline) at 6216
(when-not (= (nth (r/most-expensive-project projects tasks time-entries employees) 1) "Data Pipeline") (System/exit 1))

;; available-employees with max-active=2: employees with <2 in-progress tasks
;; in-progress tasks per employee:
;; Alice: 0, Bob: 1(task2), Carol: 0, Dave: 1(task18), Eve: 0, Frank: 1(task11), Grace: 1(task3)+1(task16)=2, Hank: 0, Ivy: 1(task6), Jack: 0
;; Grace has 2, everyone else < 2 -> 9 available
(when-not (= (count (r/available-employees employees tasks 2)) 9) (System/exit 1))
;; with max-active=1: employees with 0 in-progress: Alice, Carol, Eve, Hank, Jack = 5
(when-not (= (count (r/available-employees employees tasks 1)) 5) (System/exit 1))

;; skill-gap for project 1: assignees are Alice(1,3,6), Bob(1,2), Grace(1,2,3,6), Dave(1,3,4)
;; team skills: 1,2,3,4,6
;; all skills: 1,2,3,4,5,6,7,8
;; missing: 5(UX Design), 7(Leadership), 8(Figma)
;; sorted: Figma, Leadership, UX Design
(let [gaps (r/skill-gap 1 tasks employees skills)]
  (when-not (= (count gaps) 3) (System/exit 1))
  (when-not (= (nth (first gaps) 1) "Figma") (System/exit 1))
  (when-not (= (nth (nth gaps 1) 1) "Leadership") (System/exit 1))
  (when-not (= (nth (nth gaps 2) 1) "UX Design") (System/exit 1)))

;; team-for-project: project 1 assignees: Alice(1), Bob(2), Grace(7), Dave(4)
;; sorted by name: Alice, Bob, Dave, Grace
(let [team (r/team-for-project 1 tasks employees)]
  (when-not (= (count team) 4) (System/exit 1))
  (when-not (= (nth (first team) 1) "Alice") (System/exit 1))
  (when-not (= (nth (nth team 1) 1) "Bob") (System/exit 1))
  (when-not (= (nth (nth team 2) 1) "Dave") (System/exit 1))
  (when-not (= (nth (nth team 3) 1) "Grace") (System/exit 1)))

;; --- sorting ---
;; sort-projects-by-priority: priority 1: Platform Rewrite, Infrastructure, API Gateway (alpha: API Gateway, Infrastructure, Platform Rewrite)
;; priority 2: Mobile App, Data Pipeline (alpha: Data Pipeline, Mobile App)
;; priority 3: Brand Refresh, Cost Optimization
;; priority 4: Design System
(let [sp (r/sort-projects-by-priority projects)]
  (when-not (= (nth (first sp) 1) "API Gateway") (System/exit 1))
  (when-not (= (nth (nth sp 1) 1) "Infrastructure") (System/exit 1))
  (when-not (= (nth (nth sp 2) 1) "Platform Rewrite") (System/exit 1))
  (when-not (= (nth (nth sp 3) 1) "Data Pipeline") (System/exit 1))
  (when-not (= (nth (last sp) 1) "Design System") (System/exit 1)))

;; sort-employees-by-rate: Grace(100), Alice(95), Dave(90), Ivy(88), Bob(85), Eve(80), Carol(75), Jack(72), Frank(70), Hank(65)
(let [se (r/sort-employees-by-rate employees)]
  (when-not (= (nth (first se) 1) "Grace") (System/exit 1))
  (when-not (= (nth (nth se 1) 1) "Alice") (System/exit 1))
  (when-not (= (nth (last se) 1) "Hank") (System/exit 1)))

;; sort-tasks-by-status: blocked(0) < todo(1) < in-progress(2) < done(3)
;; No blocked tasks. Todo tasks (by id): 4,8,9,10,12,17,19,20,21,22
;; In-progress (by id): 2,3,6,11,16,18
;; Done (by id): 1,5,7,13,14,15
(let [st (r/sort-tasks-by-status tasks)]
  (when-not (= (nth (first st) 0) 4) (System/exit 1))   ;; first todo
  (when-not (= (nth (nth st 9) 0) 22) (System/exit 1))  ;; last todo
  (when-not (= (nth (nth st 10) 0) 2) (System/exit 1))  ;; first in-progress
  (when-not (= (nth (nth st 15) 0) 18) (System/exit 1)) ;; last in-progress
  (when-not (= (nth (nth st 16) 0) 1) (System/exit 1))  ;; first done
  (when-not (= (nth (last st) 0) 15) (System/exit 1)))   ;; last done

;; sort-projects-by-cost: Data Pipeline(6216), Platform Rewrite(4900), Mobile App(3524), API Gateway(2300), Infrastructure(2100), Brand Refresh(732), Cost Optimization(0), Design System(0)
;; ties at 0: Cost Optimization vs Design System -> alpha: Cost Optimization first
(let [sc (r/sort-projects-by-cost projects tasks time-entries employees)]
  (when-not (= (nth (first sc) 1) "Data Pipeline") (System/exit 1))
  (when-not (= (nth (nth sc 1) 1) "Platform Rewrite") (System/exit 1))
  (when-not (= (nth (nth sc 2) 1) "Mobile App") (System/exit 1))
  (when-not (= (nth (last sc) 1) "Design System") (System/exit 1)))

;; --- formatting ---
(when-not (= (r/format-employee (first employees)) "Alice ($95/hr)") (System/exit 1))
(when-not (= (r/format-employee (nth employees 6)) "Grace ($100/hr)") (System/exit 1))

(when-not (= (r/format-project-short (first projects)) "Platform Rewrite [active] P1") (System/exit 1))
(when-not (= (r/format-project-short (nth projects 5)) "Design System [on-hold] P4") (System/exit 1))

(when-not (= (r/format-task (first tasks)) "Design database schema (done, Est: 16h)") (System/exit 1))

(when-not (= (r/format-project-progress tasks (first projects)) "Platform Rewrite: 1/4 tasks complete (25%)") (System/exit 1))
(when-not (= (r/format-project-progress tasks (nth projects 4)) "Data Pipeline: 3/3 tasks complete (100%)") (System/exit 1))

(when-not (= (r/format-department-budget (first departments) departments projects tasks time-entries employees)
             "Engineering: $16940/$500000 (3%)") (System/exit 1))

(when-not (= (r/format-employee-workload (first employees) tasks time-entries)
             "Alice: 0 active, 48h logged") (System/exit 1))
(when-not (= (r/format-employee-workload (nth employees 1) tasks time-entries)
             "Bob: 1 active, 40h logged") (System/exit 1))

;; --- reports ---
;; project-report for project 1
(let [pr (r/project-report (first projects) tasks time-entries employees)]
  (when-not (= (first pr) "=== Project: Platform Rewrite [active] ===") (System/exit 1))
  (when-not (= (nth pr 1) "Priority: 1 | Deadline: 2024-06-30") (System/exit 1))
  (when-not (= (nth pr 2) "Progress: 1/4 tasks (25%)") (System/exit 1))
  (when-not (= (nth pr 3) "Hours: 54/100") (System/exit 1))
  (when-not (= (nth pr 4) "Cost: $4900") (System/exit 1))
  (when-not (= (nth pr 5) "") (System/exit 1))
  (when-not (= (nth pr 6) "--- Team ---") (System/exit 1))
  ;; team sorted by name: Alice, Bob, Dave, Grace
  (when-not (= (nth pr 7) "  Alice ($95/hr)") (System/exit 1))
  (when-not (= (nth pr 8) "  Bob ($85/hr)") (System/exit 1))
  (when-not (= (nth pr 9) "  Dave ($90/hr)") (System/exit 1))
  (when-not (= (nth pr 10) "  Grace ($100/hr)") (System/exit 1))
  (when-not (= (nth pr 11) "") (System/exit 1))
  (when-not (= (nth pr 12) "--- Tasks ---") (System/exit 1))
  ;; tasks sorted by status: todo(4), in-progress(2,3), done(1)
  (when-not (= (nth pr 13) "  [todo] Write migration scripts (Est: 20h, Logged: 0h)") (System/exit 1))
  (when-not (= (nth pr 14) "  [in-progress] Build API endpoints (Est: 40h, Logged: 28h)") (System/exit 1))
  (when-not (= (nth pr 15) "  [in-progress] Code review framework (Est: 24h, Logged: 10h)") (System/exit 1))
  (when-not (= (nth pr 16) "  [done] Design database schema (Est: 16h, Logged: 16h)") (System/exit 1))
  (when-not (= (count pr) 17) (System/exit 1)))

;; department-report for dept 1
(let [dr (r/department-report (first departments) departments employees projects tasks time-entries skills)]
  (when-not (= (first dr) "=== Department: Engineering ===") (System/exit 1))
  (when-not (= (nth dr 1) "Headcount: 5 | Avg Rate: $91/hr") (System/exit 1))
  (when-not (= (nth dr 2) "Budget: $16940/$500000 (3%)") (System/exit 1))
  (when-not (= (nth dr 3) "") (System/exit 1))
  (when-not (= (nth dr 4) "--- Projects ---") (System/exit 1))
  ;; projects sorted by priority then name:
  ;; priority 1: API Gateway, Platform Rewrite
  ;; priority 2: Data Pipeline, Mobile App
  (when-not (= (nth dr 5) "  API Gateway [active] - 0/3 tasks") (System/exit 1))
  (when-not (= (nth dr 6) "  Platform Rewrite [active] - 1/4 tasks") (System/exit 1))
  (when-not (= (nth dr 7) "  Data Pipeline [completed] - 3/3 tasks") (System/exit 1))
  (when-not (= (nth dr 8) "  Mobile App [active] - 2/3 tasks") (System/exit 1))
  (when-not (= (nth dr 9) "") (System/exit 1))
  (when-not (= (nth dr 10) "--- Skills ---") (System/exit 1))
  (when-not (= (nth dr 11) "  Clojure: 4 employees") (System/exit 1))
  (when-not (= (nth dr 12) "  DevOps: 2 employees") (System/exit 1))
  (when-not (= (nth dr 13) "  Project Management: 1 employees") (System/exit 1))
  (when-not (= (nth dr 14) "  React: 3 employees") (System/exit 1))
  (when-not (= (nth dr 15) "  SQL: 4 employees") (System/exit 1))
  (when-not (= (count dr) 16) (System/exit 1)))

;; executive-summary
(let [es (r/executive-summary departments employees projects tasks time-entries skills)]
  (when-not (= (first es) "=== Executive Summary ===") (System/exit 1))
  (when-not (= (nth es 1) "Total Employees: 10") (System/exit 1))
  (when-not (= (nth es 2) "Total Projects: 8") (System/exit 1))
  (when-not (= (nth es 3) "Active Projects: 4") (System/exit 1))
  ;; total budget = 500000 + 200000 + 300000 = 1000000
  (when-not (= (nth es 4) "Total Budget: $1000000") (System/exit 1))
  ;; total spent: dept1=16940 + dept2=? + dept3=2100
  ;; dept 2 (Design): projects 3,6
  ;; project 3 (Brand Refresh): tasks 8,9,10 -> task 9 entry17(Jack 6*72=432), task 10 entry18(Carol 4*75=300) -> 732
  ;; project 6 (Design System): tasks 19,20 -> no entries -> 0
  ;; dept 2 total = 732
  ;; grand total = 16940 + 732 + 2100 = 19772
  (when-not (= (nth es 5) "Total Spent: $19772") (System/exit 1))
  ;; pct = quot(19772*100, 1000000) = quot(1977200, 1000000) = 1
  (when-not (= (nth es 6) "Overall Budget Used: 1%") (System/exit 1))
  (when-not (= (nth es 7) "") (System/exit 1))
  (when-not (= (nth es 8) "--- Overdue Tasks ---") (System/exit 1))
  (when-not (= (nth es 9) "  None") (System/exit 1))
  (when-not (= (count es) 10) (System/exit 1)))

;; availability-report with max=2
(let [ar (r/availability-report employees tasks 2)]
  (when-not (= (first ar) "=== Availability Report (max 2 active) ===") (System/exit 1))
  ;; 9 available out of 10 (Grace excluded with 2 in-progress)
  (when-not (= (nth ar 1) "Available: 9 / Total: 10") (System/exit 1))
  (when-not (= (nth ar 2) "") (System/exit 1))
  ;; sorted by name: Alice, Bob, Carol, Dave, Eve, Frank, Hank, Ivy, Jack
  (when-not (= (nth ar 3) "  Alice (Rate: $95/hr) - 0 active tasks") (System/exit 1))
  (when-not (= (nth ar 4) "  Bob (Rate: $85/hr) - 1 active tasks") (System/exit 1))
  (when-not (= (nth ar 11) "  Jack (Rate: $72/hr) - 0 active tasks") (System/exit 1))
  (when-not (= (count ar) 12) (System/exit 1)))

(System/exit 0)
