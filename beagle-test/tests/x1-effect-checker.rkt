#lang racket/base

(require rackunit
         beagle/private/ast
         beagle/private/check
         beagle/private/parse
         beagle/private/types)

(define (program . forms)
  (parse-program
   (map (lambda (form) (datum->syntax #f form)) forms)))

(define (check-at-profile-2 . forms)
  (parameterize ([current-check-profile 2])
    (type-check! (apply program forms))))

(test-case "catch bindings retain their declared type"
  (define inferred
    (parameterize ([current-check-profile 2])
      (infer-expr
       (try-form
        (list 0)
        (list (catch-clause 'ExceptionInfo 'caught (list 'caught)))
        #f)
       (make-hasheq))))
  (check-true (type-union? inferred))
  (check-true
   (type-compatible?
    inferred
    (type-union (list (type-prim 'Int) (type-prim 'ExceptionInfo))))))

(define throwable-declarations
  (list
   '(define-target js)
   '(defunion :throwable RequestError Missing Denied)
   '(defn request [] String :raises RequestError "ok")))

(define (check-with-throwable-declarations form)
  (apply check-at-profile-2
         (append throwable-declarations (list form))))

(test-case "try discharges every statically covered raised alternative"
  (check-not-exn
   (lambda ()
     (check-with-throwable-declarations
      '(defn recover [] String
         (try
          (request)
          (catch (missing Missing) "missing")
          (catch (denied Denied) "denied")))))))

(test-case "check propagates only the alternatives left uncovered by try"
  (check-not-exn
   (lambda ()
     (check-with-throwable-declarations
      '(defn relay [] String
         :raises RequestError
         (try
          (check (request))
          (catch (missing Missing) "missing"))))))
  (check-exn
   #rx"check propagates RequestError"
   (lambda ()
     (check-with-throwable-declarations
      '(defn broken [] String
         (try
          (check (request))
          (catch (missing Missing) "missing")))))))
