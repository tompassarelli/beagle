(def student-text (str "1|Alice|3|350|active\n"
                       "2|Bob|2|280|active\n"
                       "3|Carol|4|390|active\n"
                       "4|Dave|1|0|active\n"
                       "5|Eve|3|310|probation\n"
                       "6|Frank|2|190|suspended\n"
                       "7|Grace|4|370|active\n"
                       "8|Hank|1|0|active\n"
                       "9|Ivy|3|340|active\n"
                       "10|Jack|2|300|active\n"
                       "11|Kate|3|360|active\n"
                       "12|Leo|4|250|active"))

(def professor-text (str "1|Dr. Smith|CS|3\n"
                         "2|Dr. Jones|Math|2\n"
                         "3|Dr. Lee|CS|3\n"
                         "4|Dr. Brown|Physics|2\n"
                         "5|Dr. Davis|Math|2"))

(def course-text (str "1|CS101|Intro to CS|CS|3|30|1\n"
                      "2|CS201|Data Structures|CS|3|25|1\n"
                      "3|CS301|Algorithms|CS|4|20|3\n"
                      "4|CS401|Compilers|CS|4|15|3\n"
                      "5|MATH101|Calculus I|Math|4|35|2\n"
                      "6|MATH201|Calculus II|Math|4|30|2\n"
                      "7|MATH301|Linear Algebra|Math|3|25|5\n"
                      "8|PHYS101|Physics I|Physics|4|30|4\n"
                      "9|PHYS201|Physics II|Physics|4|25|4\n"
                      "10|CS350|Databases|CS|3|20|1"))

(def room-text (str "1|Room 101|40|Science|yes\n"
                    "2|Room 102|25|Science|yes\n"
                    "3|Room 201|35|Math|yes\n"
                    "4|Room 202|20|Math|no\n"
                    "5|Auditorium|100|Main|yes\n"
                    "6|Lab 301|15|Science|yes"))

(def timeslot-text (str "1|Mon|9|10\n"
                        "2|Mon|10|11\n"
                        "3|Mon|14|15\n"
                        "4|Tue|9|10\n"
                        "5|Tue|10|11\n"
                        "6|Tue|14|15\n"
                        "7|Wed|9|10\n"
                        "8|Wed|10|11\n"
                        "9|Thu|9|10\n"
                        "10|Thu|10|11\n"
                        "11|Thu|14|15\n"
                        "12|Fri|9|10"))

(def schedule-text (str "1|1|1\n1|1|7\n2|2|2\n2|2|8\n3|6|3\n4|4|4\n"
                        "5|3|1\n5|3|7\n6|3|2\n6|3|8\n7|4|5\n"
                        "8|1|4\n8|1|9\n9|2|5\n9|2|10\n10|2|6"))

(def enrollment-text (str "1|3|enrolled\n1|4|enrolled\n1|10|enrolled\n"
                          "2|2|enrolled\n2|5|enrolled\n"
                          "3|4|enrolled\n3|7|enrolled\n"
                          "4|1|enrolled\n4|5|enrolled\n4|8|enrolled\n"
                          "5|3|enrolled\n5|10|enrolled\n"
                          "7|4|enrolled\n7|3|enrolled\n"
                          "8|1|enrolled\n8|8|enrolled\n"
                          "9|3|enrolled\n9|10|enrolled\n"
                          "10|2|enrolled\n10|6|enrolled\n"
                          "11|3|enrolled\n11|4|waitlisted\n"
                          "12|4|enrolled\n12|7|enrolled"))

(def prerequisite-text (str "2|1\n3|2\n4|3\n6|5\n7|5\n9|8\n10|2"))

(def grade-text (str "1|1|A\n1|2|A\n1|5|B\n1|6|A\n"
                     "2|1|B\n2|8|C\n"
                     "3|1|A\n3|2|A\n3|3|A\n3|5|B\n3|6|B\n"
                     "5|1|B\n5|2|C\n5|5|D\n"
                     "7|1|A\n7|2|A\n7|3|A\n7|5|A\n7|6|A\n"
                     "9|1|A\n9|2|B\n9|5|B\n"
                     "10|1|B\n10|5|C\n"
                     "11|1|A\n11|2|A\n11|5|A\n"
                     "12|1|B\n12|2|C\n12|3|D\n12|5|C\n12|6|D"))

(def students (r/parse-students student-text))
(def professors (r/parse-professors professor-text))
(def courses (r/parse-courses course-text))
(def rooms (r/parse-rooms room-text))
(def timeslots (r/parse-timeslots timeslot-text))
(def schedules (r/parse-schedules schedule-text))
(def enrollments (r/parse-enrollments enrollment-text))
(def prerequisites (r/parse-prerequisites prerequisite-text))
(def grades (r/parse-grades grade-text))

;; --- parsing ---
(when-not (= (count students) 12) (System/exit 1))
(when-not (= (nth (first students) 1) "Alice") (System/exit 1))
(when-not (= (nth (first students) 2) 3) (System/exit 1))
(when-not (= (nth (first students) 3) 350) (System/exit 1))
(when-not (= (nth (first students) 4) "active") (System/exit 1))

(when-not (= (count professors) 5) (System/exit 1))
(when-not (= (nth (first professors) 1) "Dr. Smith") (System/exit 1))
(when-not (= (nth (first professors) 3) 3) (System/exit 1))

(when-not (= (count courses) 10) (System/exit 1))
(when-not (= (nth (first courses) 1) "CS101") (System/exit 1))
(when-not (= (nth (first courses) 2) "Intro to CS") (System/exit 1))
(when-not (= (nth (first courses) 4) 3) (System/exit 1))
(when-not (= (nth (first courses) 5) 30) (System/exit 1))
(when-not (= (nth (first courses) 6) 1) (System/exit 1))

(when-not (= (count rooms) 6) (System/exit 1))
(when-not (= (nth (first rooms) 1) "Room 101") (System/exit 1))
(when-not (= (nth (first rooms) 2) 40) (System/exit 1))
(when-not (= (nth (first rooms) 4) "yes") (System/exit 1))

(when-not (= (count timeslots) 12) (System/exit 1))
(when-not (= (nth (first timeslots) 1) "Mon") (System/exit 1))
(when-not (= (nth (first timeslots) 2) 9) (System/exit 1))
(when-not (= (nth (first timeslots) 3) 10) (System/exit 1))

(when-not (= (count schedules) 16) (System/exit 1))
(when-not (= (count enrollments) 24) (System/exit 1))
(when-not (= (count prerequisites) 7) (System/exit 1))
(when-not (= (count grades) 32) (System/exit 1))

;; --- lookups ---
(when-not (= (nth (r/find-student students 1) 1) "Alice") (System/exit 1))
(when-not (nil? (r/find-student students 99)) (System/exit 1))
(when-not (= (nth (r/find-professor professors 3) 1) "Dr. Lee") (System/exit 1))
(when-not (nil? (r/find-professor professors 99)) (System/exit 1))
(when-not (= (nth (r/find-course courses 4) 1) "CS401") (System/exit 1))
(when-not (nil? (r/find-course courses 99)) (System/exit 1))
(when-not (= (nth (r/find-room rooms 5) 1) "Auditorium") (System/exit 1))
(when-not (nil? (r/find-room rooms 99)) (System/exit 1))
(when-not (= (nth (r/find-timeslot timeslots 3) 1) "Mon") (System/exit 1))
(when-not (nil? (r/find-timeslot timeslots 99)) (System/exit 1))

;; --- grade helpers ---
(when-not (= (r/letter-to-points "A") 400) (System/exit 1))
(when-not (= (r/letter-to-points "B") 300) (System/exit 1))
(when-not (= (r/letter-to-points "C") 200) (System/exit 1))
(when-not (= (r/letter-to-points "D") 100) (System/exit 1))
(when-not (= (r/letter-to-points "F") 0) (System/exit 1))
(when-not (nil? (r/letter-to-points "W")) (System/exit 1))

(when-not (= (count (r/student-grades 1 grades)) 4) (System/exit 1))
(when-not (= (count (r/student-grades 4 grades)) 0) (System/exit 1))
(when-not (= (count (r/student-grades 7 grades)) 5) (System/exit 1))

;; calculate-gpa:
;; Alice: CS101-A(400*3=1200) CS201-A(400*3=1200) MATH101-B(300*4=1200) MATH201-A(400*4=1600) = 5200/14 = 371
(when-not (= (r/calculate-gpa 1 grades courses) 371) (System/exit 1))
;; Bob: CS101-B(300*3=900) PHYS101-C(200*4=800) = 1700/7 = 242
(when-not (= (r/calculate-gpa 2 grades courses) 242) (System/exit 1))
;; Grace: CS101-A(1200) CS201-A(1200) CS301-A(1600) MATH101-A(1600) MATH201-A(1600) = 7200/18 = 400
(when-not (= (r/calculate-gpa 7 grades courses) 400) (System/exit 1))
;; Dave: no grades = 0
(when-not (= (r/calculate-gpa 4 grades courses) 0) (System/exit 1))
;; Eve: CS101-B(900) CS201-C(600) MATH101-D(400) = 1900/10 = 190
(when-not (= (r/calculate-gpa 5 grades courses) 190) (System/exit 1))
;; Kate: CS101-A(1200) CS201-A(1200) MATH101-A(1600) = 4000/10 = 400
(when-not (= (r/calculate-gpa 11 grades courses) 400) (System/exit 1))
;; Leo: CS101-B(900) CS201-C(600) CS301-D(400) MATH101-C(800) MATH201-D(400) = 3100/18 = 172
(when-not (= (r/calculate-gpa 12 grades courses) 172) (System/exit 1))

;; course-grade-distribution for CS101: A=5, B=4 (sorted alpha)
(let [dist (r/course-grade-distribution 1 grades)]
  (when-not (= (count dist) 2) (System/exit 1))
  (when-not (= (nth (first dist) 0) "A") (System/exit 1))
  (when-not (= (nth (first dist) 1) 5) (System/exit 1))
  (when-not (= (nth (nth dist 1) 0) "B") (System/exit 1))
  (when-not (= (nth (nth dist 1) 1) 4) (System/exit 1)))

;; course-avg-grade for CS101: (400*5+300*4)/9 = (2000+1200)/9 = 3200/9 = 355
(when-not (= (r/course-avg-grade 1 grades courses) 355) (System/exit 1))

;; honor-roll: GPA >= 350, sorted desc by GPA, alpha for ties
;; Grace(400), Kate(400), Alice(371), Carol(355)
;; Ivy: 330, not qualified. Bob: 242. etc.
;; Carol: quot(6400,18)=355 >= 350 ✓
(let [hr (r/honor-roll students grades courses)]
  (when-not (= (count hr) 4) (System/exit 1))
  (when-not (= (nth (first hr) 1) "Grace") (System/exit 1))
  (when-not (= (nth (nth hr 1) 1) "Kate") (System/exit 1))
  (when-not (= (nth (nth hr 2) 1) "Alice") (System/exit 1))
  (when-not (= (nth (nth hr 3) 1) "Carol") (System/exit 1)))

;; --- filtering ---
(when-not (= (count (r/courses-by-department courses "CS")) 5) (System/exit 1))
(when-not (= (count (r/courses-by-department courses "Math")) 3) (System/exit 1))
(when-not (= (count (r/courses-by-department courses "Physics")) 2) (System/exit 1))

(when-not (= (count (r/courses-by-professor courses 1)) 3) (System/exit 1))
(when-not (= (count (r/courses-by-professor courses 3)) 2) (System/exit 1))

(when-not (= (count (r/active-students students)) 10) (System/exit 1))
(when-not (= (count (r/students-by-year students 1)) 2) (System/exit 1))
(when-not (= (count (r/students-by-year students 3)) 4) (System/exit 1))
(when-not (= (count (r/students-by-year students 4)) 3) (System/exit 1))

;; enrolled-students returns student-ids
;; CS301(3): Alice(1),Eve(5),Grace(7),Ivy(9),Kate(11) = 5
(when-not (= (count (r/enrolled-students enrollments 3)) 5) (System/exit 1))
;; CS401(4): Alice(1),Carol(3),Grace(7),Leo(12) = 4
(when-not (= (count (r/enrolled-students enrollments 4)) 4) (System/exit 1))
;; PHYS201(9): nobody = 0
(when-not (= (count (r/enrolled-students enrollments 9)) 0) (System/exit 1))

;; waitlisted-students: CS401 has Kate
(when-not (= (count (r/waitlisted-students enrollments 4)) 1) (System/exit 1))
(when-not (= (first (r/waitlisted-students enrollments 4)) 11) (System/exit 1))
(when-not (= (count (r/waitlisted-students enrollments 3)) 0) (System/exit 1))

;; student-enrollments returns course-ids
;; Alice(1): CS301(3), CS401(4), CS350(10) = 3
(when-not (= (count (r/student-enrollments enrollments 1)) 3) (System/exit 1))
;; Dave(4): CS101(1), MATH101(5), PHYS101(8) = 3
(when-not (= (count (r/student-enrollments enrollments 4)) 3) (System/exit 1))
;; Kate(11): CS301(3) = 1 (CS401 is waitlisted)
(when-not (= (count (r/student-enrollments enrollments 11)) 1) (System/exit 1))

(when-not (= (count (r/rooms-with-projector rooms)) 5) (System/exit 1))
(when-not (= (count (r/rooms-by-capacity rooms 30)) 3) (System/exit 1))
(when-not (= (count (r/rooms-by-capacity rooms 100)) 1) (System/exit 1))

;; courses-for-timeslot: slot 1 (Mon 9-10) has CS101(1) and MATH101(5)
(let [cft (r/courses-for-timeslot schedules 1)]
  (when-not (= (count cft) 2) (System/exit 1)))
;; slot 6 (Tue 14-15) has CS350(10) only
(when-not (= (count (r/courses-for-timeslot schedules 6)) 1) (System/exit 1))
;; slot 11 (Thu 14-15) has nothing
(when-not (= (count (r/courses-for-timeslot schedules 11)) 0) (System/exit 1))

;; --- schedule helpers ---
;; course-timeslots: CS101 has slots 1(Mon 9-10) and 7(Wed 9-10)
(when-not (= (count (r/course-timeslots schedules timeslots 1)) 2) (System/exit 1))
;; CS301 has slot 3 only
(when-not (= (count (r/course-timeslots schedules timeslots 3)) 1) (System/exit 1))

;; course-room: CS101 → Room 101 (room id 1)
(when-not (= (nth (r/course-room schedules rooms 1) 1) "Room 101") (System/exit 1))
;; CS301 → Lab 301 (room id 6)
(when-not (= (nth (r/course-room schedules rooms 3) 1) "Lab 301") (System/exit 1))
;; nonexistent course
(when-not (nil? (r/course-room schedules rooms 99)) (System/exit 1))

;; timeslots-overlap?
;; same day, overlapping times
(when-not (r/timeslots-overlap? [1 "Mon" 9 10] [2 "Mon" 9 10]) (System/exit 1))
(when-not (r/timeslots-overlap? [1 "Mon" 9 11] [2 "Mon" 10 12]) (System/exit 1))
;; same day, non-overlapping (adjacent: 9-10 and 10-11 don't overlap since 10 < 10 is false)
(when (r/timeslots-overlap? [1 "Mon" 9 10] [2 "Mon" 10 11]) (System/exit 1))
;; different days
(when (r/timeslots-overlap? [1 "Mon" 9 10] [2 "Tue" 9 10]) (System/exit 1))

;; student-schedule-conflicts: Dave(4) enrolled in CS101(1), MATH101(5), PHYS101(8)
;; CS101 and MATH101 share timeslots 1(Mon9) and 7(Wed9) → conflict
(let [conflicts (r/student-schedule-conflicts 4 enrollments schedules timeslots)]
  (when-not (= (count conflicts) 1) (System/exit 1))
  (when-not (= (first conflicts) [1 5]) (System/exit 1)))

;; Alice(1) enrolled in CS301(3), CS401(4), CS350(10) — no overlaps
(when-not (= (count (r/student-schedule-conflicts 1 enrollments schedules timeslots)) 0) (System/exit 1))

;; room-utilization: Room 2 has 5 schedule entries
(when-not (= (r/room-utilization 2 schedules) 5) (System/exit 1))
;; Room 1 has 4
(when-not (= (r/room-utilization 1 schedules) 4) (System/exit 1))
;; Room 5 (Auditorium) has 0
(when-not (= (r/room-utilization 5 schedules) 0) (System/exit 1))

;; busiest-room: Room 2 with 5 slots
(when-not (= (nth (r/busiest-room rooms schedules) 1) "Room 102") (System/exit 1))

;; --- enrollment operations ---
;; enrollment-count: CS301 = 5
(when-not (= (r/enrollment-count enrollments 3) 5) (System/exit 1))
;; CS401 = 4 (Kate waitlisted doesn't count)
(when-not (= (r/enrollment-count enrollments 4) 4) (System/exit 1))
;; PHYS201 = 0
(when-not (= (r/enrollment-count enrollments 9) 0) (System/exit 1))

;; course-is-full? CS401 max=15, enrolled=4 → not full
(when (r/course-is-full? enrollments courses 4) (System/exit 1))

;; has-completed: Alice completed CS101 with A (not W, not F) → true
(when-not (r/has-completed 1 1 grades) (System/exit 1))
;; Dave has no grades at all → false
(when (r/has-completed 4 1 grades) (System/exit 1))
;; Leo completed CS301 with D (D is passing, not F) → true
(when-not (r/has-completed 12 3 grades) (System/exit 1))

;; has-prerequisites?
;; Alice for CS401: needs CS301. Alice completed CS301? Grades: CS101-A, CS201-A, MATH101-B, MATH201-A. No CS301.
;; Wait — Alice IS enrolled in CS301 this semester but hasn't graded yet. So prereq NOT met.
;; But the test data shows Alice enrolled in CS401... let me re-check.
;; Actually, has-completed checks grades, not enrollments. Alice's grades don't include CS301.
;; This means Alice shouldn't actually have been able to enroll in CS401 (prereq violation).
;; But we don't validate existing enrollments — we just test the function.
;; has-prerequisites?(1, 4, prereqs, grades): CS401 needs CS301. has-completed(1, 3, grades)? No CS301 grade. → false
(when (r/has-prerequisites? 1 4 prerequisites grades) (System/exit 1))

;; Carol for CS401: needs CS301. Carol has CS301-A → true
(when-not (r/has-prerequisites? 3 4 prerequisites grades) (System/exit 1))

;; CS101 has no prerequisites → true for anyone
(when-not (r/has-prerequisites? 4 1 prerequisites grades) (System/exit 1))

;; Bob for CS201: needs CS101. Bob has CS101-B → true
(when-not (r/has-prerequisites? 2 2 prerequisites grades) (System/exit 1))

;; can-enroll? tests
;; nonexistent student
(let [[ok reason] (r/can-enroll? 99 1 students courses enrollments prerequisites grades schedules timeslots)]
  (when ok (System/exit 1))
  (when-not (= reason "student not found") (System/exit 1)))

;; Frank (suspended)
(let [[ok reason] (r/can-enroll? 6 1 students courses enrollments prerequisites grades schedules timeslots)]
  (when ok (System/exit 1))
  (when-not (= reason "student suspended") (System/exit 1)))

;; nonexistent course
(let [[ok reason] (r/can-enroll? 2 99 students courses enrollments prerequisites grades schedules timeslots)]
  (when ok (System/exit 1))
  (when-not (= reason "course not found") (System/exit 1)))

;; already enrolled: Alice in CS301
(let [[ok reason] (r/can-enroll? 1 3 students courses enrollments prerequisites grades schedules timeslots)]
  (when ok (System/exit 1))
  (when-not (= reason "already enrolled") (System/exit 1)))

;; prerequisites not met: Dave for CS201 (no CS101 grade)
(let [[ok reason] (r/can-enroll? 4 2 students courses enrollments prerequisites grades schedules timeslots)]
  (when ok (System/exit 1))
  (when-not (= reason "prerequisites not met") (System/exit 1)))

;; Bob for PHYS201: has PHYS101-C (passing), no conflicts → should pass
(let [[ok reason] (r/can-enroll? 2 9 students courses enrollments prerequisites grades schedules timeslots)]
  (when-not ok (System/exit 1))
  (when-not (nil? reason) (System/exit 1)))

;; total-credits: Alice = CS301(4)+CS401(4)+CS350(3) = 11
(when-not (= (r/total-credits 1 enrollments courses) 11) (System/exit 1))
;; Dave = CS101(3)+MATH101(4)+PHYS101(4) = 11
(when-not (= (r/total-credits 4 enrollments courses) 11) (System/exit 1))
;; Kate = CS301(4) = 4
(when-not (= (r/total-credits 11 enrollments courses) 4) (System/exit 1))

;; max-credits-check
(when-not (r/max-credits-check 1 enrollments courses 18) (System/exit 1))
(when (r/max-credits-check 1 enrollments courses 10) (System/exit 1))

;; process-waitlist for CS401: Kate waitlisted, but Kate lacks CS301 prereq
(let [[promoted rejected] (r/process-waitlist 4 enrollments students courses prerequisites grades schedules timeslots)]
  (when-not (= (count promoted) 0) (System/exit 1))
  (when-not (= (count rejected) 1) (System/exit 1))
  (when-not (= (nth (first rejected) 0) 11) (System/exit 1))
  (when-not (= (nth (first rejected) 1) "prerequisites not met") (System/exit 1)))

;; --- prerequisite analysis ---
;; direct-prerequisites
(when-not (= (r/direct-prerequisites 4 prerequisites) [3]) (System/exit 1))
(when-not (= (count (r/direct-prerequisites 1 prerequisites)) 0) (System/exit 1))
(when-not (= (r/direct-prerequisites 10 prerequisites) [2]) (System/exit 1))

;; all-prerequisites: CS401(4) → CS301(3) → CS201(2) → CS101(1), sorted ascending
(when-not (= (r/all-prerequisites 4 prerequisites) [1 2 3]) (System/exit 1))
;; CS201(2) → CS101(1)
(when-not (= (r/all-prerequisites 2 prerequisites) [1]) (System/exit 1))
;; CS350(10) → CS201(2) → CS101(1)
(when-not (= (r/all-prerequisites 10 prerequisites) [1 2]) (System/exit 1))
;; CS101(1) → none
(when-not (= (r/all-prerequisites 1 prerequisites) []) (System/exit 1))

;; prerequisite-chain-length
(when-not (= (r/prerequisite-chain-length 4 prerequisites) 3) (System/exit 1))
(when-not (= (r/prerequisite-chain-length 3 prerequisites) 2) (System/exit 1))
(when-not (= (r/prerequisite-chain-length 2 prerequisites) 1) (System/exit 1))
(when-not (= (r/prerequisite-chain-length 1 prerequisites) 0) (System/exit 1))
(when-not (= (r/prerequisite-chain-length 10 prerequisites) 2) (System/exit 1))

;; courses-unlocked-by
(when-not (= (r/courses-unlocked-by 1 prerequisites) [2]) (System/exit 1))
(when-not (= (r/courses-unlocked-by 2 prerequisites) [3 10]) (System/exit 1))
(when-not (= (r/courses-unlocked-by 5 prerequisites) [6 7]) (System/exit 1))
(when-not (= (r/courses-unlocked-by 4 prerequisites) []) (System/exit 1))

;; --- statistics ---
;; department-enrollment-count: CS = 2+2+5+4+3 = 16
(when-not (= (r/department-enrollment-count "CS" courses enrollments) 16) (System/exit 1))
;; Math = 2+1+2 = 5
(when-not (= (r/department-enrollment-count "Math" courses enrollments) 5) (System/exit 1))
;; Physics = 2+0 = 2
(when-not (= (r/department-enrollment-count "Physics" courses enrollments) 2) (System/exit 1))

;; department-avg-class-size: CS = quot(16,5) = 3
(when-not (= (r/department-avg-class-size "CS" courses enrollments) 3) (System/exit 1))
;; Math = quot(5,3) = 1
(when-not (= (r/department-avg-class-size "Math" courses enrollments) 1) (System/exit 1))

;; professor-course-count
(when-not (= (r/professor-course-count 1 courses) 3) (System/exit 1))
(when-not (= (r/professor-course-count 3 courses) 2) (System/exit 1))
(when-not (= (r/professor-course-count 5 courses) 1) (System/exit 1))

;; professor-total-students: Dr. Smith(1) = CS101(2)+CS201(2)+CS350(3) = 7
(when-not (= (r/professor-total-students 1 courses enrollments) 7) (System/exit 1))
;; Dr. Lee(3) = CS301(5)+CS401(4) = 9
(when-not (= (r/professor-total-students 3 courses enrollments) 9) (System/exit 1))

;; course-fill-rate: CS301 = quot(5*100,20) = 25
(when-not (= (r/course-fill-rate 3 enrollments courses) 25) (System/exit 1))
;; CS401 = quot(4*100,15) = 26
(when-not (= (r/course-fill-rate 4 enrollments courses) 26) (System/exit 1))
;; PHYS201 = 0
(when-not (= (r/course-fill-rate 9 enrollments courses) 0) (System/exit 1))

;; avg-fill-rate: (6+8+25+26+5+3+8+6+0+15)/10 = 102/10 = 10
(when-not (= (r/avg-fill-rate courses enrollments) 10) (System/exit 1))

;; credits-by-year:
;; Year 1: Dave(11)+Hank(7)=18, Year 2: Bob(7)+Jack(7)=14, Year 3: Alice(11)+Eve(7)+Ivy(7)+Kate(4)=29, Year 4: Carol(7)+Grace(8)+Leo(7)=22
(let [cby (r/credits-by-year students enrollments courses)]
  (when-not (= (count cby) 4) (System/exit 1))
  (when-not (= (nth (first cby) 0) 1) (System/exit 1))
  (when-not (= (nth (first cby) 1) 18) (System/exit 1))
  (when-not (= (nth (nth cby 1) 1) 14) (System/exit 1))
  (when-not (= (nth (nth cby 2) 1) 29) (System/exit 1))
  (when-not (= (nth (nth cby 3) 1) 22) (System/exit 1)))

;; popular-courses top 3: CS301(5), CS401(4), CS350(3)
(let [pop (r/popular-courses courses enrollments 3)]
  (when-not (= (count pop) 3) (System/exit 1))
  (when-not (= (nth (first pop) 1) "CS301") (System/exit 1))
  (when-not (= (nth (nth pop 1) 1) "CS401") (System/exit 1))
  (when-not (= (nth (nth pop 2) 1) "CS350") (System/exit 1)))

;; underutilized (<50%): all 10 courses are under 50%
;; sorted by fill-rate asc, code alpha for ties
;; PHYS201(0), MATH201(3), MATH101(5), CS101(6), PHYS101(6), CS201(8), MATH301(8), CS350(15), CS301(25), CS401(26)
(let [uu (r/underutilized-courses courses enrollments 50)]
  (when-not (= (count uu) 10) (System/exit 1))
  (when-not (= (nth (first uu) 1) "PHYS201") (System/exit 1))
  (when-not (= (nth (nth uu 1) 1) "MATH201") (System/exit 1))
  (when-not (= (nth (last uu) 1) "CS401") (System/exit 1)))

;; professor-workload: sorted by total-students desc, name alpha for ties
;; Dr. Lee(9), Dr. Smith(7), Dr. Jones(3), Dr. Brown(2), Dr. Davis(2)
(let [pw (r/professor-workload professors courses enrollments)]
  (when-not (= (count pw) 5) (System/exit 1))
  (when-not (= (nth (first pw) 0) "Dr. Lee") (System/exit 1))
  (when-not (= (nth (first pw) 1) 2) (System/exit 1))
  (when-not (= (nth (first pw) 2) 9) (System/exit 1))
  (when-not (= (nth (nth pw 1) 0) "Dr. Smith") (System/exit 1))
  (when-not (= (nth (nth pw 1) 2) 7) (System/exit 1))
  ;; Dr. Brown and Dr. Davis both have 2 students, alpha: Brown first
  (when-not (= (nth (nth pw 3) 0) "Dr. Brown") (System/exit 1))
  (when-not (= (nth (nth pw 4) 0) "Dr. Davis") (System/exit 1)))

;; --- formatting ---
;; format-student: "Name (Year Y, GPA G.GG)"
(when-not (= (r/format-student (first students)) "Alice (Year 3, GPA 3.50)") (System/exit 1))
(when-not (= (r/format-student (nth students 3)) "Dave (Year 1, GPA 0.00)") (System/exit 1))
(when-not (= (r/format-student (nth students 6)) "Grace (Year 4, GPA 3.70)") (System/exit 1))

;; format-course: "CODE: Title (N credits)"
(when-not (= (r/format-course (first courses)) "CS101: Intro to CS (3 credits)") (System/exit 1))
(when-not (= (r/format-course (nth courses 2)) "CS301: Algorithms (4 credits)") (System/exit 1))

;; format-enrollment-status: "CODE: E/M enrolled (F% full)"
(when-not (= (r/format-enrollment-status 3 enrollments courses) "CS301: 5/20 enrolled (25% full)") (System/exit 1))
(when-not (= (r/format-enrollment-status 9 enrollments courses) "PHYS201: 0/25 enrolled (0% full)") (System/exit 1))

;; format-timeslot: "Day HH:00-HH:00"
(when-not (= (r/format-timeslot (first timeslots)) "Mon 09:00-10:00") (System/exit 1))
(when-not (= (r/format-timeslot (nth timeslots 2)) "Mon 14:00-15:00") (System/exit 1))
(when-not (= (r/format-timeslot (nth timeslots 3)) "Tue 09:00-10:00") (System/exit 1))

;; format-professor: "Name (Dept, max N courses)"
(when-not (= (r/format-professor (first professors)) "Dr. Smith (CS, max 3 courses)") (System/exit 1))

;; format-room: "Name (cap: C, Building) [projector: yes/no]"
(when-not (= (r/format-room (first rooms)) "Room 101 (cap: 40, Science) [projector: yes]") (System/exit 1))
(when-not (= (r/format-room (nth rooms 3)) "Room 202 (cap: 20, Math) [projector: no]") (System/exit 1))

;; format-grade: "Grade: L (GPA: G.GG)"
(when-not (= (r/format-grade "A" 371) "Grade: A (GPA: 3.71)") (System/exit 1))
(when-not (= (r/format-grade "B" 300) "Grade: B (GPA: 3.00)") (System/exit 1))

;; --- reports ---
;; student-transcript for Alice
(let [tr (r/student-transcript 1 students grades courses)]
  (when-not (= (first tr) "=== Transcript: Alice (Year 3) ===") (System/exit 1))
  (when-not (= (nth tr 1) "GPA: 3.71") (System/exit 1))
  (when-not (= (nth tr 2) "") (System/exit 1))
  (when-not (= (nth tr 3) "--- Courses ---") (System/exit 1))
  ;; sorted by code: CS101, CS201, MATH101, MATH201
  (when-not (= (nth tr 4) "  CS101: Intro to CS - A") (System/exit 1))
  (when-not (= (nth tr 5) "  CS201: Data Structures - A") (System/exit 1))
  (when-not (= (nth tr 6) "  MATH101: Calculus I - B") (System/exit 1))
  (when-not (= (nth tr 7) "  MATH201: Calculus II - A") (System/exit 1))
  (when-not (= (count tr) 8) (System/exit 1)))

;; student-transcript for Dave (no grades)
(let [tr (r/student-transcript 4 students grades courses)]
  (when-not (= (first tr) "=== Transcript: Dave (Year 1) ===") (System/exit 1))
  (when-not (= (nth tr 1) "GPA: 0.00") (System/exit 1))
  (when-not (= (nth tr 4) "  No courses completed") (System/exit 1))
  (when-not (= (count tr) 5) (System/exit 1)))

;; course-roster for CS401
(let [cr (r/course-roster 4 courses students enrollments grades)]
  (when-not (= (first cr) "=== CS401: Compilers ===") (System/exit 1))
  (when-not (= (nth cr 1) "Enrolled: 4/15 | Waitlisted: 1") (System/exit 1))
  (when-not (= (nth cr 2) "") (System/exit 1))
  (when-not (= (nth cr 3) "--- Students ---") (System/exit 1))
  ;; enrolled sorted by name: Alice, Carol, Grace, Leo
  (when-not (= (nth cr 4) "  Alice (Year 3, GPA 3.50)") (System/exit 1))
  (when-not (= (nth cr 5) "  Carol (Year 4, GPA 3.90)") (System/exit 1))
  (when-not (= (nth cr 6) "  Grace (Year 4, GPA 3.70)") (System/exit 1))
  (when-not (= (nth cr 7) "  Leo (Year 4, GPA 2.50)") (System/exit 1))
  (when-not (= (nth cr 8) "") (System/exit 1))
  (when-not (= (nth cr 9) "--- Waitlist ---") (System/exit 1))
  (when-not (= (nth cr 10) "  Kate (Year 3, GPA 3.60)") (System/exit 1))
  (when-not (= (count cr) 11) (System/exit 1)))

;; course-roster for CS301 (no waitlist)
(let [cr (r/course-roster 3 courses students enrollments grades)]
  (when-not (= (first cr) "=== CS301: Algorithms ===") (System/exit 1))
  (when-not (= (nth cr 1) "Enrolled: 5/20 | Waitlisted: 0") (System/exit 1))
  ;; no waitlist section
  (when-not (= (count cr) 9) (System/exit 1)))

;; department-report for CS
(let [dr (r/department-report "CS" courses enrollments professors students grades)]
  (when-not (= (first dr) "=== Department: CS ===") (System/exit 1))
  (when-not (= (nth dr 1) "Courses: 5 | Total Enrollment: 16 | Avg Class Size: 3") (System/exit 1))
  (when-not (= (nth dr 2) "") (System/exit 1))
  (when-not (= (nth dr 3) "--- Courses ---") (System/exit 1))
  (when-not (= (nth dr 4) "  CS101: Intro to CS (2/30 enrolled)") (System/exit 1))
  (when-not (= (nth dr 8) "  CS401: Compilers (4/15 enrolled)") (System/exit 1))
  (when-not (= (nth dr 9) "") (System/exit 1))
  (when-not (= (nth dr 10) "--- Faculty ---") (System/exit 1))
  (when-not (= (nth dr 11) "  Dr. Lee (2 courses, 9 students)") (System/exit 1))
  (when-not (= (nth dr 12) "  Dr. Smith (3 courses, 7 students)") (System/exit 1))
  (when-not (= (count dr) 13) (System/exit 1)))

;; enrollment-summary
(let [es (r/enrollment-summary courses enrollments students)]
  (when-not (= (first es) "=== Enrollment Summary ===") (System/exit 1))
  (when-not (= (nth es 1) "Total Courses: 10") (System/exit 1))
  (when-not (= (nth es 2) "Total Enrollments: 23") (System/exit 1))
  (when-not (= (nth es 3) "Total Waitlisted: 1") (System/exit 1))
  (when-not (= (nth es 4) "Avg Fill Rate: 10%") (System/exit 1))
  (when-not (= (nth es 5) "") (System/exit 1))
  (when-not (= (nth es 6) "--- Most Popular ---") (System/exit 1))
  (when-not (= (nth es 7) "  CS301: Algorithms (5 enrolled)") (System/exit 1))
  (when-not (= (nth es 8) "  CS401: Compilers (4 enrolled)") (System/exit 1))
  (when-not (= (nth es 9) "  CS350: Databases (3 enrolled)") (System/exit 1))
  (when-not (= (nth es 10) "") (System/exit 1))
  (when-not (= (nth es 11) "--- Underutilized (<50%) ---") (System/exit 1))
  ;; all 10 courses under 50%, first is PHYS201(0%)
  (when-not (= (nth es 12) "  PHYS201: Physics II (0% full)") (System/exit 1))
  (when-not (= (count es) 22) (System/exit 1)))

;; prerequisite-report for CS401
(let [pr (r/prerequisite-report 4 courses prerequisites)]
  (when-not (= (first pr) "=== Prerequisites for CS401: Compilers ===") (System/exit 1))
  (when-not (= (nth pr 1) "Direct: 1 | Chain length: 3") (System/exit 1))
  (when-not (= (nth pr 2) "") (System/exit 1))
  (when-not (= (nth pr 3) "--- Prerequisite Chain ---") (System/exit 1))
  (when-not (= (nth pr 4) "  CS101: Intro to CS") (System/exit 1))
  (when-not (= (nth pr 5) "  CS201: Data Structures") (System/exit 1))
  (when-not (= (nth pr 6) "  CS301: Algorithms") (System/exit 1))
  (when-not (= (nth pr 7) "") (System/exit 1))
  (when-not (= (nth pr 8) "--- Unlocks ---") (System/exit 1))
  (when-not (= (nth pr 9) "  Nothing") (System/exit 1))
  (when-not (= (count pr) 10) (System/exit 1)))

;; prerequisite-report for CS101 (no prereqs, unlocks CS201)
(let [pr (r/prerequisite-report 1 courses prerequisites)]
  (when-not (= (first pr) "=== Prerequisites for CS101: Intro to CS ===") (System/exit 1))
  (when-not (= (nth pr 1) "Direct: 0 | Chain length: 0") (System/exit 1))
  (when-not (= (nth pr 4) "  No prerequisites") (System/exit 1))
  (when-not (= (nth pr 8) "  CS201: Data Structures") (System/exit 1))
  (when-not (= (count pr) 9) (System/exit 1)))

;; schedule-grid: check first few and last entries
(let [sg (r/schedule-grid timeslots schedules courses rooms)]
  ;; Mon 09:00-10:00: CS101 and MATH101
  (when-not (= (first sg) "Mon 09:00-10:00: CS101 in Room 101") (System/exit 1))
  (when-not (= (nth sg 1) "Mon 09:00-10:00: MATH101 in Room 201") (System/exit 1))
  ;; last two entries: Thu 14:00-15:00 (empty) and Fri 09:00-10:00 (empty)
  (when-not (= (nth sg (- (count sg) 2)) "Thu 14:00-15:00: ---") (System/exit 1))
  (when-not (= (last sg) "Fri 09:00-10:00: ---") (System/exit 1))
  ;; total: 2+2+1+2+2+1+2+2+1+1+1+1 = 18
  (when-not (= (count sg) 18) (System/exit 1)))

(System/exit 0)
