# Program 8: University Course Scheduler (~1000 lines)

Build a university course scheduling and enrollment system with students, professors,
courses, rooms, time slots, enrollments, prerequisites, and grades. Heavy multi-step
validation, constraint checking, prerequisite chain traversal, GPA calculations,
schedule conflict detection, and waitlist processing.

## Data Model

**Student**: vector `[id name year gpa status]`
- id: Long, name: String, year: Long (1-4), gpa: Long (GPA * 100, e.g. 350 = 3.50), status: String ("active"/"probation"/"suspended")

**Professor**: vector `[id name department max-courses]`
- id: Long, name: String, department: String, max-courses: Long

**Course**: vector `[id code title department credits max-enrollment professor-id]`
- id: Long, code: String, title: String, department: String, credits: Long, max-enrollment: Long, professor-id: Long

**Room**: vector `[id name capacity building has-projector]`
- id: Long, name: String, capacity: Long, building: String, has-projector: String ("yes"/"no")

**TimeSlot**: vector `[id day start-hour end-hour]`
- id: Long, day: String ("Mon"/"Tue"/"Wed"/"Thu"/"Fri"), start-hour: Long (0-23), end-hour: Long (0-23)

**Schedule**: vector `[course-id room-id timeslot-id]`
- All Long. Links a course to a room and time.

**Enrollment**: vector `[student-id course-id status]`
- student-id: Long, course-id: Long, status: String ("enrolled"/"waitlisted"/"dropped")

**Prerequisite**: vector `[course-id prereq-course-id]`
- Both Long. course-id requires prereq-course-id to be completed first.

**Grade**: vector `[student-id course-id letter]`
- student-id: Long, course-id: Long, letter: String ("A"/"B"/"C"/"D"/"F"/"W")

## Test Data

```
;; Students
1|Alice|3|350|active
2|Bob|2|280|active
3|Carol|4|390|active
4|Dave|1|0|active
5|Eve|3|310|probation
6|Frank|2|190|suspended
7|Grace|4|370|active
8|Hank|1|0|active
9|Ivy|3|340|active
10|Jack|2|300|active
11|Kate|3|360|active
12|Leo|4|250|active

;; Professors
1|Dr. Smith|CS|3
2|Dr. Jones|Math|2
3|Dr. Lee|CS|3
4|Dr. Brown|Physics|2
5|Dr. Davis|Math|2

;; Courses
1|CS101|Intro to CS|CS|3|30|1
2|CS201|Data Structures|CS|3|25|1
3|CS301|Algorithms|CS|4|20|3
4|CS401|Compilers|CS|4|15|3
5|MATH101|Calculus I|Math|4|35|2
6|MATH201|Calculus II|Math|4|30|2
7|MATH301|Linear Algebra|Math|3|25|5
8|PHYS101|Physics I|Physics|4|30|4
9|PHYS201|Physics II|Physics|4|25|4
10|CS350|Databases|CS|3|20|1

;; Rooms
1|Room 101|40|Science|yes
2|Room 102|25|Science|yes
3|Room 201|35|Math|yes
4|Room 202|20|Math|no
5|Auditorium|100|Main|yes
6|Lab 301|15|Science|yes

;; TimeSlots
1|Mon|9|10
2|Mon|10|11
3|Mon|14|15
4|Tue|9|10
5|Tue|10|11
6|Tue|14|15
7|Wed|9|10
8|Wed|10|11
9|Thu|9|10
10|Thu|10|11
11|Thu|14|15
12|Fri|9|10

;; Schedule (course-id|room-id|timeslot-id)
1|1|1
1|1|7
2|2|2
2|2|8
3|6|3
4|4|4
5|3|1
5|3|7
6|3|2
6|3|8
7|4|5
8|1|4
8|1|9
9|2|5
9|2|10
10|2|6

;; Prerequisites (course-id|prereq-course-id)
2|1
3|2
4|3
6|5
7|5
9|8
10|2

;; Enrollments (student-id|course-id|status)
1|3|enrolled
1|4|enrolled
1|10|enrolled
2|2|enrolled
2|5|enrolled
3|4|enrolled
3|7|enrolled
4|1|enrolled
4|5|enrolled
4|8|enrolled
5|3|enrolled
5|10|enrolled
7|4|enrolled
7|3|enrolled
8|1|enrolled
8|8|enrolled
9|3|enrolled
9|10|enrolled
10|2|enrolled
10|6|enrolled
11|3|enrolled
11|4|waitlisted
12|4|enrolled
12|7|enrolled

;; Grades (student-id|course-id|letter) — past completed courses
1|1|A
1|2|A
1|5|B
1|6|A
2|1|B
2|8|C
3|1|A
3|2|A
3|3|A
3|5|B
3|6|B
5|1|B
5|2|C
5|5|D
7|1|A
7|2|A
7|3|A
7|5|A
7|6|A
9|1|A
9|2|B
9|5|B
10|1|B
10|5|C
11|1|A
11|2|A
11|5|A
12|1|B
12|2|C
12|3|D
12|5|C
12|6|D
```

## Functions to Implement

### Parsing (18 functions)

1. `parse-student [s]` — split by "|", return vector with id/year/gpa as Long
2. `parse-students [text]` — standard trim/split/filter/parse pattern
3. `parse-professor [s]` — return vector with id/max-courses as Long
4. `parse-professors [text]`
5. `parse-course [s]` — return vector with id/credits/max-enrollment/professor-id as Long
6. `parse-courses [text]`
7. `parse-room [s]` — return vector with id/capacity as Long, has-projector as String
8. `parse-rooms [text]`
9. `parse-timeslot [s]` — return vector with id/start-hour/end-hour as Long
10. `parse-timeslots [text]`
11. `parse-schedule [s]` — return vector with all three as Long
12. `parse-schedules [text]`
13. `parse-enrollment [s]` — return vector with student-id/course-id as Long, status as String
14. `parse-enrollments [text]`
15. `parse-prerequisite [s]` — return vector with both as Long
16. `parse-prerequisites [text]`
17. `parse-grade [s]` — return vector with student-id/course-id as Long, letter as String
18. `parse-grades [text]`

### Lookups (5 functions)

19. `find-student [students id]` — first match or nil
20. `find-professor [professors id]` — first match or nil
21. `find-course [courses id]` — first match or nil
22. `find-room [rooms id]` — first match or nil
23. `find-timeslot [timeslots id]` — first match or nil

### Grade helpers (6 functions)

24. `letter-to-points [letter]` — "A"→400, "B"→300, "C"→200, "D"→100, "F"→0, "W"→nil. Return nil for "W".
25. `student-grades [student-id grades]` — filter grades for this student
26. `calculate-gpa [student-id grades courses]` — For each grade (excluding "W"), find the course, multiply letter-to-points by credits. Sum weighted points, sum total credits. If total credits = 0, return 0. Otherwise `quot(sum-points, total-credits)`. Returns Long (GPA*100).
27. `course-grade-distribution [course-id grades]` — return vector of `[letter count]` pairs for all grades of this course, sorted alphabetically by letter. Only include letters with count > 0.
28. `course-avg-grade [course-id grades courses]` — average grade points (letter-to-points, ignoring W) for this course. quot division. Return 0 if no non-W grades.
29. `honor-roll [students grades courses]` — return students with calculated GPA >= 350, sorted by GPA descending, name alphabetically for ties. Only include students with at least 1 graded course (non-W).

### Filtering (10 functions)

30. `courses-by-department [courses dept]` — filter by department (index 3)
31. `courses-by-professor [courses prof-id]` — filter by professor-id (index 6)
32. `active-students [students]` — filter by status "active"
33. `students-by-year [students year]` — filter by year (index 2)
34. `enrolled-students [enrollments course-id]` — filter enrollments where course-id matches AND status is "enrolled", return student-ids (index 0). Return a vector of Longs.
35. `waitlisted-students [enrollments course-id]` — same but status "waitlisted", return student-ids
36. `student-enrollments [enrollments student-id]` — filter where student-id matches AND status is "enrolled", return course-ids (index 1). Return vector of Longs.
37. `rooms-with-projector [rooms]` — filter where has-projector (index 4) is "yes"
38. `rooms-by-capacity [rooms min-cap]` — filter where capacity (index 2) >= min-cap
39. `courses-for-timeslot [schedules timeslot-id]` — filter schedules where timeslot-id (index 2) matches, return course-ids (index 0)

### Schedule helpers (8 functions)

40. `course-timeslots [schedules timeslots course-id]` — for each schedule entry matching course-id, find the timeslot. Return vector of timeslot vectors.
41. `course-room [schedules rooms course-id]` — find first schedule entry for course-id, find the room. Return room vector or nil if no schedule.
42. `timeslots-overlap? [ts1 ts2]` — two timeslots overlap if same day AND time ranges overlap. Overlap means: ts1-start < ts2-end AND ts2-start < ts1-end.
43. `student-schedule-conflicts [student-id enrollments schedules timeslots]` — get enrolled course-ids for student. For each pair of courses, check if any of their timeslots overlap. Return vector of `[course-id-1 course-id-2]` pairs (smaller id first) that conflict. No duplicates.
44. `professor-schedule [prof-id courses schedules timeslots]` — get courses taught by prof, collect all their timeslots. Return sorted by day-order then start-hour. Day order: Mon=0 Tue=1 Wed=2 Thu=3 Fri=4.
45. `room-schedule [room-id schedules timeslots courses]` — find all schedule entries for this room, collect `[timeslot course]` pairs. Sort by day-order then start-hour. Return vector of `[timeslot-vector course-vector]` pairs.
46. `room-utilization [room-id schedules]` — count of schedule entries for this room. (How many course-timeslot slots use this room.)
47. `busiest-room [rooms schedules]` — room with highest utilization. Tie: first by id.

### Enrollment operations (8 functions)

48. `enrollment-count [enrollments course-id]` — count enrollments with status "enrolled" for this course
49. `course-is-full? [enrollments courses course-id]` — enrollment-count >= max-enrollment (index 5 of course)
50. `has-completed [student-id course-id grades]` — true if there exists a grade for this student+course with letter NOT "W" and NOT "F"
51. `has-prerequisites? [student-id course-id prerequisites grades]` — for each prerequisite of course-id, check has-completed. True only if ALL prerequisites are satisfied. If no prerequisites, return true.
52. `can-enroll? [student-id course-id students courses enrollments prerequisites grades schedules timeslots]` — return `[boolean reason-or-nil]`. Check in order:
    1. Student not found → `[false "student not found"]`
    2. Student status is "suspended" → `[false "student suspended"]`
    3. Course not found → `[false "course not found"]`
    4. Already enrolled in this course → `[false "already enrolled"]`
    5. Course is full → `[false "course full"]`
    6. Prerequisites not met → `[false "prerequisites not met"]`
    7. Schedule conflict: get student's current enrolled courses + this new course-id. Check if adding this course creates any timeslot overlap with existing courses. → `[false "schedule conflict"]`
    8. All checks pass → `[true nil]`
53. `process-waitlist [course-id enrollments students courses prerequisites grades schedules timeslots]` — for each waitlisted student for this course (in order), check can-enroll? (ignoring the "course full" check — assume a spot opened). Return `[promoted-ids rejected-pairs]` where promoted-ids is a vector of student-ids that can be promoted, and rejected-pairs is vector of `[student-id reason]` for those who can't. Stop promoting when enrollment-count + promoted so far >= max-enrollment.
54. `total-credits [student-id enrollments courses]` — sum credits of courses the student is enrolled in
55. `max-credits-check [student-id enrollments courses max-credits]` — true if total-credits <= max-credits

### Prerequisite analysis (4 functions)

56. `direct-prerequisites [course-id prerequisites]` — return vector of prerequisite course-ids for this course
57. `all-prerequisites [course-id prerequisites]` — return ALL prerequisites transitively (recursive). If CS401 requires CS301, and CS301 requires CS201, and CS201 requires CS101, then all-prerequisites of CS401 = [CS301 CS201 CS101] (the set of all, order doesn't matter but return as sorted vector ascending). Use a loop/accumulator approach.
58. `prerequisite-chain-length [course-id prerequisites]` — length of the longest prerequisite chain. CS101 has 0. CS201 has 1. CS301 has 2. CS401 has 3.
59. `courses-unlocked-by [course-id prerequisites]` — which courses have this course-id as a direct prerequisite? Return vector of course-ids sorted ascending.

### Statistics (10 functions)

60. `department-enrollment-count [dept courses enrollments]` — total enrolled students across all courses in department
61. `department-avg-class-size [dept courses enrollments]` — average enrollment per course in department. Integer division. 0 if no courses.
62. `professor-course-count [prof-id courses]` — count courses taught by this professor
63. `professor-total-students [prof-id courses enrollments]` — total enrolled students across professor's courses
64. `course-fill-rate [course-id enrollments courses]` — `quot(enrollment-count * 100, max-enrollment)`. 0 if max=0.
65. `avg-fill-rate [courses enrollments]` — average fill rate across all courses. Sum fill-rates, quot by count. 0 if no courses.
66. `credits-by-year [students enrollments courses]` — for each year 1-4, sum total-credits for all students in that year. Return vector of `[year total-credits]` for years 1-4.
67. `popular-courses [courses enrollments n]` — top n courses by enrollment-count, sorted desc. Ties: by course code alphabetically. Return vector of course vectors.
68. `underutilized-courses [courses enrollments threshold]` — courses where fill-rate < threshold (a percentage). Return sorted by fill-rate ascending, code alphabetically for ties.
69. `professor-workload [professors courses enrollments]` — for each professor, `[prof-name course-count total-students]`. Sorted by total-students descending, name alphabetically for ties.

### Formatting (8 functions)

70. `format-student [student]` — `"Name (Year Y, GPA G.GG)"` where G.GG is gpa/100 formatted as "X.XX". Use: `(str (quot gpa 100) "." (let [r (mod gpa 100)] (if (< r 10) (str "0" r) (str r))))` to get two decimal places.
71. `format-course [course]` — `"CODE: Title (N credits)"`
72. `format-enrollment-status [course-id enrollments courses]` — `"CODE: E/M enrolled (F% full)"` where E=enrolled count, M=max, F=fill-rate
73. `format-timeslot [timeslot]` — `"Day HH:00-HH:00"` where HH is zero-padded. Use `(if (< h 10) (str "0" h) (str h))` for padding.
74. `format-schedule-entry [course timeslot room]` — `"CODE Day HH:00-HH:00 in RoomName"`
75. `format-grade [letter gpa]` — `"Grade: L (GPA: G.GG)"` using same decimal format
76. `format-professor [professor]` — `"Name (Dept, max N courses)"`
77. `format-room [room]` — `"Name (cap: C, Building) [projector: yes/no]"`

### Reports (8 functions)

78. `student-transcript [student-id students grades courses]` — return vector of strings:
    - `"=== Transcript: Name (Year Y) ==="`
    - `"GPA: G.GG"`
    - `""` (blank)
    - `"--- Courses ---"`
    - For each grade sorted by course code: `"  CODE: Title - L"` where L is letter
    - If no grades: `"  No courses completed"`

79. `course-roster [course-id courses students enrollments grades]` — return vector of strings:
    - `"=== CODE: Title ==="`
    - `"Enrolled: E/M | Waitlisted: W"`
    - `""` (blank)
    - `"--- Students ---"`
    - For each enrolled student (sorted by name): `"  Name (Year Y, GPA G.GG)"`
    - If waitlisted students exist:
      - `""` (blank)
      - `"--- Waitlist ---"`
      - For each waitlisted student (sorted by name): `"  Name (Year Y, GPA G.GG)"`

80. `professor-report [prof-id professors courses enrollments schedules timeslots rooms]` — return vector of strings:
    - `"=== Professor: Name ==="`
    - `"Department: D | Courses: N/M"` where N=current course count, M=max-courses
    - `""` (blank)
    - `"--- Schedule ---"`
    - For each timeslot in professor-schedule: `"  CODE Day HH:00-HH:00 in RoomName"` (need to look up course and room from schedule)
    - If no schedule entries: `"  No scheduled courses"`

81. `room-report [room-id rooms schedules timeslots courses]` — return vector of strings:
    - `"=== Room: Name (Building, cap: C) ==="`
    - `"Utilization: U slots"`
    - `""` (blank)
    - `"--- Schedule ---"`
    - For each entry in room-schedule: `"  CODE Day HH:00-HH:00"`
    - If no entries: `"  Empty"`

82. `department-report [dept courses enrollments professors students grades]` — return vector of strings:
    - `"=== Department: D ==="`
    - `"Courses: N | Total Enrollment: E | Avg Class Size: A"`
    - `""` (blank)
    - `"--- Courses ---"`
    - For each course in dept sorted by code: `"  CODE: Title (E/M enrolled)"`
    - `""` (blank)
    - `"--- Faculty ---"`
    - For each professor in dept sorted by name: `"  Name (N courses, S students)"`

83. `enrollment-summary [courses enrollments students]` — return vector of strings:
    - `"=== Enrollment Summary ==="`
    - `"Total Courses: C"`
    - `"Total Enrollments: E"` (count of "enrolled" status)
    - `"Total Waitlisted: W"` (count of "waitlisted" status)
    - `"Avg Fill Rate: F%"`
    - `""` (blank)
    - `"--- Most Popular ---"` 
    - Top 3 courses (from popular-courses): `"  CODE: Title (E enrolled)"`
    - `""` (blank)
    - `"--- Underutilized (<50%) ---"`
    - Courses with fill rate < 50: `"  CODE: Title (F% full)"`
    - If none: `"  None"`

84. `prerequisite-report [course-id courses prerequisites]` — return vector of strings:
    - `"=== Prerequisites for CODE: Title ==="`
    - `"Direct: N | Chain length: L"`
    - `""` (blank)
    - `"--- Prerequisite Chain ---"`
    - For each prerequisite in all-prerequisites (sorted by code): `"  CODE: Title"`
    - If none: `"  No prerequisites"`
    - `""` (blank)
    - `"--- Unlocks ---"`
    - For each course unlocked by this one (sorted by code): `"  CODE: Title"`
    - If none: `"  Nothing"`

85. `schedule-grid [timeslots schedules courses rooms]` — return vector of strings. For each timeslot sorted by day-order then start-hour:
    - `"Day HH:00-HH:00: CODE in RoomName"` for each course scheduled at that time (from courses-for-timeslot, sorted by code). If no courses: `"Day HH:00-HH:00: ---"`.

## Notes

- All "sort" and "group" operations should return vectors
- Use `clojure.string` functions for string operations
- `parse-long` for string→Long conversion
- Integer division uses `quot`
- GPA is stored as Long * 100 (e.g., 350 = 3.50)
- For GPA display: `(str (quot gpa 100) "." ...)` with zero-padded remainder
- For hour display: zero-pad to 2 digits
- Day ordering: Mon=0, Tue=1, Wed=2, Thu=3, Fri=4
- Timeslot overlap: same day AND start1 < end2 AND start2 < end1
- `all-prerequisites` must be transitive/recursive
- `can-enroll?` checks must be in the specified order (first failing check wins)
- For `process-waitlist`: check can-enroll? but skip the "course full" check. Use a modified version or pass adjusted data.
- `letter-to-points` returns nil for "W" — exclude "W" grades from GPA and average calculations
