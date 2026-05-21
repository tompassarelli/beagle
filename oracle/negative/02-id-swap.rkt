#lang typed/racket

;; Negative fixture: task-id / worker-id swap.
;; This should be REJECTED by raco make.

(struct TaskId ([v : String]) #:transparent)
(struct WorkerId ([v : String]) #:transparent)

(struct Assignment ([task-id : TaskId]
                    [worker-id : WorkerId]) #:transparent)

;; Swapped: WorkerId in TaskId slot, TaskId in WorkerId slot
(define bad (Assignment (WorkerId "w1") (TaskId "t1")))
