# Program 7: Project Tracker (~1000 lines)

Build a project management system with employees, departments, projects,
tasks, time entries, and skills. Heavy cross-entity lookups, nil-returning
searches, multi-step aggregation, and error propagation.

## Data Model

**Employee**: vector `[id name department-id hourly-rate skill-ids]`
- id: Long, name: String, department-id: Long, hourly-rate: Long, skill-ids: String (comma-separated ids, e.g. "1,3,5" — empty string "" if none)

**Department**: vector `[id name budget manager-id]`
- id: Long, name: String, budget: Long, manager-id: Long

**Project**: vector `[id name department-id status priority deadline]`
- id: Long, name: String, department-id: Long, status: String ("planning"/"active"/"completed"/"on-hold"), priority: Long (1=highest), deadline: String (date)

**Task**: vector `[id project-id assignee-id title status estimated-hours]`
- id: Long, project-id: Long, assignee-id: Long, title: String, status: String ("todo"/"in-progress"/"done"/"blocked"), estimated-hours: Long

**TimeEntry**: vector `[id task-id employee-id hours date]`
- id: Long, task-id: Long, employee-id: Long, hours: Long, date: String

**Skill**: vector `[id name category]`
- id: Long, name: String, category: String ("technical"/"management"/"design")

## Test Data

```
;; Skills
1|Clojure|technical
2|React|technical
3|SQL|technical
4|Project Management|management
5|UX Design|design
6|DevOps|technical
7|Leadership|management
8|Figma|design

;; Departments
1|Engineering|500000|1
2|Design|200000|5
3|Operations|300000|8

;; Employees
1|Alice|1|95|1,3,6
2|Bob|1|85|1,2
3|Carol|2|75|5,8
4|Dave|1|90|1,3,4
5|Eve|2|80|5,7,8
6|Frank|3|70|4,6
7|Grace|1|100|1,2,3,6
8|Hank|3|65|4,7
9|Ivy|1|88|2,3
10|Jack|2|72|5,8

;; Projects
1|Platform Rewrite|1|active|1|2024-06-30
2|Mobile App|1|active|2|2024-09-15
3|Brand Refresh|2|planning|3|2024-12-01
4|Infrastructure|3|active|1|2024-05-01
5|Data Pipeline|1|completed|2|2024-03-01
6|Design System|2|on-hold|4|2024-08-15
7|API Gateway|1|active|1|2024-07-15
8|Cost Optimization|3|planning|3|2025-01-01

;; Tasks
1|1|1|Design database schema|done|16
2|1|2|Build API endpoints|in-progress|40
3|1|7|Code review framework|in-progress|24
4|1|4|Write migration scripts|todo|20
5|2|2|Setup React Native|done|12
6|2|9|Build login screen|in-progress|16
7|2|3|Design app mockups|done|24
8|3|5|Brand guidelines|todo|32
9|3|10|Logo concepts|todo|20
10|3|3|Color palette|todo|8
11|4|6|Kubernetes setup|in-progress|40
12|4|8|Monitoring dashboards|todo|16
13|5|1|ETL pipeline|done|30
14|5|4|Data validation|done|20
15|5|9|Query optimization|done|24
16|7|7|Gateway architecture|in-progress|20
17|7|1|Rate limiting|todo|12
18|7|4|Auth middleware|in-progress|16
19|6|5|Component library|todo|40
20|6|10|Icon set|todo|24
21|8|6|Cost analysis|todo|20
22|8|8|Vendor review|todo|16

;; TimeEntries
1|1|1|14|2024-01-15
2|1|1|2|2024-01-16
3|2|2|20|2024-02-01
4|2|2|8|2024-02-15
5|3|7|10|2024-02-10
6|5|2|12|2024-01-20
7|6|9|8|2024-03-01
8|7|3|24|2024-01-10
9|11|6|20|2024-03-15
10|11|6|10|2024-03-20
11|13|1|28|2024-01-05
12|14|4|18|2024-01-20
13|15|9|22|2024-02-01
14|16|7|12|2024-03-01
15|17|1|4|2024-03-10
16|18|4|8|2024-03-15
17|9|10|6|2024-03-20
18|10|3|4|2024-03-22
```

## Functions to Implement

### Parsing (6 functions)

Use `clojure.string/split` with `#"\|"` for pipe-delimited fields.
Use `clojure.string/trim` on input text. Use `parse-long` for numbers.

1. `parse-skill [s]` — split by "|", return `[id name category]` with id as Long
2. `parse-skills [text]` — trim, split by newline, filter non-empty, parse each, return vector
3. `parse-department [s]` — return `[id name budget manager-id]` with id/budget/manager-id as Long
4. `parse-departments [text]` — same pattern
5. `parse-employee [s]` — return `[id name department-id hourly-rate skill-ids]` with id/dept-id/rate as Long, skill-ids stays as String
6. `parse-employees [text]` — same pattern
7. `parse-project [s]` — return `[id name department-id status priority deadline]` with id/dept-id/priority as Long
8. `parse-projects [text]` — same pattern
9. `parse-task [s]` — return `[id project-id assignee-id title status estimated-hours]` with id/project-id/assignee-id/estimated-hours as Long
10. `parse-tasks [text]` — same pattern
11. `parse-time-entry [s]` — return `[id task-id employee-id hours date]` with id/task-id/employee-id/hours as Long
12. `parse-time-entries [text]` — same pattern

### Employee skill helpers (4 functions)

13. `parse-skill-ids [employee]` — given an employee, parse skill-ids string (index 4) into a vector of Longs. If the string is empty (""), return []. Split by "," and parse-long each.
14. `employee-has-skill? [employee skill-id]` — true if skill-id is in parse-skill-ids result. Use `some` with a predicate checking `=`.
15. `employees-with-skill [employees skill-id]` — filter employees who have the given skill
16. `employee-skills [employee skills]` — return vector of skill vectors that match the employee's skill-ids. For each id in parse-skill-ids, find the skill with that id.

### Lookups (6 functions)

17. `find-employee [employees id]` — first with matching id, or nil
18. `find-department [departments id]` — first with matching id, or nil
19. `find-project [projects id]` — first with matching id, or nil
20. `find-task [tasks id]` — first with matching id, or nil
21. `find-skill [skills id]` — first with matching id, or nil
22. `department-for-employee [departments employee]` — find-department using employee's department-id (index 2)

### Filtering (10 functions)

23. `projects-by-status [projects status]` — filter by status (index 3)
24. `projects-by-department [projects dept-id]` — filter by department-id (index 2)
25. `projects-by-priority [projects max-priority]` — filter where priority (index 4) <= max-priority
26. `active-projects [projects]` — shorthand for projects-by-status "active"
27. `tasks-for-project [tasks project-id]` — filter by project-id (index 1)
28. `tasks-for-employee [tasks employee-id]` — filter by assignee-id (index 2)
29. `tasks-by-status [tasks status]` — filter by status (index 4)
30. `employees-in-department [employees dept-id]` — filter by department-id (index 2)
31. `time-entries-for-task [time-entries task-id]` — filter by task-id (index 1)
32. `time-entries-for-employee [time-entries employee-id]` — filter by employee-id (index 2)

### Cost calculations (6 functions)

33. `hours-logged-on-task [time-entries task-id]` — sum hours (index 3) for entries matching task-id
34. `hours-logged-by-employee [time-entries employee-id]` — sum hours for entries matching employee-id
35. `task-cost [task time-entries employees]` — for each time entry on this task (by task id, index 0), find the employee (by entry's employee-id), multiply hours * hourly-rate, sum. If employee not found for an entry, treat rate as 0.
36. `project-cost [project tasks time-entries employees]` — sum task-cost for all tasks in the project (by project id, index 0)
37. `department-total-cost [dept-id projects tasks time-entries employees]` — sum project-cost for all projects in that department
38. `employee-cost [employee time-entries]` — total hours logged * hourly-rate (index 3)

### Project analysis (8 functions)

39. `project-progress [tasks project-id]` — count of "done" tasks / total tasks for that project. Return as vector `[done-count total-count]`. If no tasks, return `[0 0]`.
40. `project-estimated-hours [tasks project-id]` — sum estimated-hours (index 5) for tasks in project
41. `project-actual-hours [tasks time-entries project-id]` — sum hours from all time entries for all tasks in the project
42. `project-on-track? [tasks time-entries project-id]` — true if actual-hours <= estimated-hours for the project
43. `overdue-tasks [tasks time-entries]` — tasks where status is NOT "done" AND hours-logged > estimated-hours. For each task, sum time entries by task id (index 0) and compare to estimated-hours (index 5).
44. `blocked-tasks [tasks]` — filter tasks with status "blocked"
45. `unassigned-estimate [tasks project-id]` — sum estimated-hours for tasks in project that are "todo" status
46. `completion-rate [tasks project-id]` — if total tasks > 0, `(quot (* done-count 100) total-count)`, else 0. Use project-progress.

### Department analysis (6 functions)

47. `department-headcount [employees dept-id]` — count employees in department
48. `department-avg-rate [employees dept-id]` — average hourly-rate (integer division) of employees in department. Return 0 if no employees.
49. `department-budget-remaining [dept departments projects tasks time-entries employees]` — dept budget (index 2) minus department-total-cost. dept is the department vector itself.
50. `department-budget-used-pct [dept departments projects tasks time-entries employees]` — `(quot (* cost 100) budget)` where cost is department-total-cost and budget is dept's budget (index 2). Return 0 if budget is 0.
51. `department-projects-summary [dept-id projects tasks]` — return vector of `[project-name done-count total-count]` for each project in department, sorted by project name alphabetically.
52. `department-skill-coverage [dept-id employees skills]` — return vector of `[skill-name count]` pairs — for each skill, how many employees in the department have it. Only include skills where count > 0. Sort alphabetically by skill name.

### Cross-entity queries (6 functions)

53. `employee-workload [employee tasks time-entries]` — return `[active-task-count total-hours-logged]` where active-task-count is tasks assigned to this employee with status "in-progress", and total-hours-logged is sum of all time entries for this employee.
54. `busiest-employee [employees tasks time-entries]` — employee with most total hours logged. On tie, first by id.
55. `most-expensive-project [projects tasks time-entries employees]` — project with highest project-cost. On tie, first by id.
56. `available-employees [employees tasks max-active]` — employees whose count of "in-progress" assigned tasks < max-active
57. `skill-gap [project-id tasks employees skills]` — return skills that are NOT held by ANY assignee on the project. Collect all assignee-ids from tasks for the project, collect all their skill-ids, find skills not in that set. Return vector of skill vectors sorted by skill name.
58. `team-for-project [project-id tasks employees]` — return distinct employees assigned to tasks in the project, sorted by employee name.

### Sorting (4 functions)

59. `sort-projects-by-priority [projects]` — sort by priority ascending (index 4), then by name alphabetically for ties
60. `sort-employees-by-rate [employees]` — sort by hourly-rate descending (index 3), name alphabetically for ties
61. `sort-tasks-by-status [tasks]` — sort by status order: "blocked" < "todo" < "in-progress" < "done" (use a helper to map status to number). Within same status, sort by id ascending.
62. `sort-projects-by-cost [projects tasks time-entries employees]` — sort by project-cost descending, name alphabetically for ties

### Formatting (6 functions)

63. `format-employee [employee]` — `"Name ($Rate/hr)"`
64. `format-project-short [project]` — `"Name [Status] P{Priority}"`
65. `format-task [task]` — `"Title (Status, Est: Nh)"`
66. `format-project-progress [tasks project]` — `"Name: D/T tasks complete (P%)"` where D=done, T=total, P=completion-rate
67. `format-department-budget [dept departments projects tasks time-entries employees]` — `"Name: $Used/$Budget (P%)"` where Used=department-total-cost, Budget=dept budget, P=budget-used-pct
68. `format-employee-workload [employee tasks time-entries]` — `"Name: A active, Hh logged"` where A=active-task-count, H=total-hours-logged

### Reports (4 functions)

69. `project-report [project tasks time-entries employees]` — return vector of strings:
    - `"=== Project: Name [Status] ==="`
    - `"Priority: N | Deadline: D"`
    - `"Progress: D/T tasks (P%)"`
    - `"Hours: Actual/Estimated"`
    - `"Cost: $C"`
    - `""` (blank)
    - `"--- Team ---"` 
    - One line per team member (from team-for-project): `"  Name ($Rate/hr)"`
    - `""` (blank)
    - `"--- Tasks ---"`
    - One line per task (sorted by sort-tasks-by-status): `"  [Status] Title (Est: Nh, Logged: Mh)"`
      where N=estimated-hours, M=hours-logged-on-task for that task

70. `department-report [dept departments employees projects tasks time-entries skills]` — return vector of strings:
    - `"=== Department: Name ==="`
    - `"Headcount: N | Avg Rate: $R/hr"`
    - `"Budget: $Used/$Total (P%)"`
    - `""` (blank)
    - `"--- Projects ---"`
    - One line per project in department (sorted by priority then name): `"  Name [Status] - D/T tasks"`
    - `""` (blank)
    - `"--- Skills ---"`
    - One line per skill coverage (from department-skill-coverage): `"  SkillName: N employees"`

71. `executive-summary [departments employees projects tasks time-entries skills]` — return vector of strings:
    - `"=== Executive Summary ==="`
    - `"Total Employees: N"`
    - `"Total Projects: P"`
    - `"Active Projects: A"`
    - `"Total Budget: $B"`
    - `"Total Spent: $S"` (sum of department-total-cost for all departments)
    - `"Overall Budget Used: P%"` (quot (* total-spent 100) total-budget, 0 if budget=0)
    - `""` (blank)
    - `"--- Overdue Tasks ---"`
    - One line per overdue task (from overdue-tasks): `"  [ProjectName] TaskTitle (Est: Nh, Actual: Mh)"`
      where ProjectName is looked up via the task's project-id. Sort by task id ascending.
    - If no overdue tasks: `"  None"`

72. `availability-report [employees tasks max-active]` — return vector of strings:
    - `"=== Availability Report (max N active) ==="`
    - `"Available: A / Total: T"`
    - `""` (blank)
    - One line per available employee (sorted by name): `"  Name - K active tasks, Hh capacity"`
      where K=count of in-progress tasks, and H is not logged hours but rather `(* 40 1)` minus total-hours-logged — NO, simpler: just show active task count. Format: `"  Name (Rate: $R/hr) - K active tasks"`

## Notes

- All "sort" and "group" operations should return vectors
- Use `clojure.string` functions for string operations
- `parse-long` for string→Long conversion
- Integer division uses `quot`
- When a lookup returns nil and you need a value, use 0 for numeric defaults
- skill-ids field is a comma-separated string — parse it each time with parse-skill-ids
- For status ordering in sort-tasks-by-status: "blocked"→0, "todo"→1, "in-progress"→2, "done"→3
- sort-projects-by-priority tiebreak is alphabetical by name
