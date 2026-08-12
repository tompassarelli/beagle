#lang racket/base

;; Query-tool extraction tests (beagle-sig/-fields/-callers backbone).
;; These extractors rotted silently against the surface twice — bare-`:`
;; matching made every annotated fn report `-> Any`, and docstring-bearing
;; defns vanished entirely during compiler dogfooding.
;; No more silent: the canonical surface shapes are pinned here.

(require rackunit
         racket/file
         racket/port
         racket/string
         beagle/private/query)

(define (with-query-file source proc)
  (define f (make-temporary-file "query~a.bgl"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file f #:exists 'replace
        (lambda (p) (display source p)))
      (proc (path->string f)))
    (lambda () (delete-file f))))

(define (query-output source args)
  (with-query-file
   source
   (lambda (f)
     (with-output-to-string
       (lambda () (run-query (append args (list f))))))))

(define SRC
  (string-append
   "(ns q)\n"
   "(def plain Int 42)\n"
   "(def doced Int \"the answer\" 42)\n"
   "(defrecord R\n  [(a Int)\n   (b Bool)])\n"
   "(declare-extern host/get [Int -> Int])\n"
   "(defn typed\n  [(x Int)\n   (y Bool)]\n  Int\n  x)\n"
   "(defn doced-fn \"docs are surface\" [(x Int)] Bool (> x 0))\n"
   "(defn- private-fn [(x Int)] Int (typed x true))\n"
   "(defn one [x] Int 1)\n"
   "(defn dynamic [(x Any)] Any x)\n"
   "(defn pair-head [([x y] (HVec Int String))] Int x)\n"
   "(defn overloaded\n"
   "  ([(x Int)] Int x)\n"
   "  ([(x String) (n Int)] String x))\n"))

(test-case "sig: annotated defn reports real types (not Any)"
  (define out (query-output SRC '("sig" "typed")))
  (check-regexp-match #rx"typed : \\[Int Bool -> Int\\]" out))

(test-case "sig: docstring-bearing defn is visible"
  (define out (query-output SRC '("sig" "doced-fn")))
  (check-regexp-match #rx"doced-fn : \\[Int -> Bool\\]" out))

(test-case "sig: defn- is visible"
  (define out (query-output SRC '("sig" "private-fn")))
  (check-regexp-match #rx"private-fn : \\[Int -> Int\\]" out))

(test-case "sig: inferred scheme is the headline and its body drives detail"
  (define out (query-output SRC '("sig" "one")))
  (check-regexp-match #rx"one : \\(forall \\[A\\] \\[A -> Int\\]\\)" out)
  (check-regexp-match #rx"  x : A" out)
  (check-regexp-match #rx"  -> Int" out)
  (check-false (regexp-match? #rx"\\?[0-9]+" out) out))

(test-case "sig: explicit Any remains authored Any"
  (define out (query-output SRC '("sig" "dynamic")))
  (check-regexp-match #rx"dynamic : \\[Any -> Any\\]" out)
  (check-false (string-contains? out "forall") out)
  (check-false (regexp-match? #rx"\\?[0-9]+" out) out))

(test-case "sig: aggregate parameter detail preserves one binding operation"
  (define out (query-output SRC '("sig" "pair-head")))
  (check-regexp-match
   #rx"pair-head : \\[\\(HVec Int String\\) -> Int\\]"
   out)
  (check-regexp-match #rx"  \\[x y\\] : \\(HVec Int String\\)" out))

(test-case "sig: multi-arity headline and clause details use effective types"
  (define out (query-output SRC '("sig" "overloaded")))
  (check-regexp-match
   #rx"overloaded : \\(U \\[Int -> Int\\] \\[String Int -> String\\]\\)"
   out)
  (check-regexp-match #rx"arity 1:[\n ]+x : Int" out)
  (check-regexp-match #rx"arity 2:[\n ]+x : String[\n ]+n : Int" out))

(test-case "sig: declare-extern entries are found"
  (define out (query-output SRC '("sig" "host/get")))
  (check-regexp-match #rx"host/get : \\[Int -> Int\\]  .extern." out))

(test-case "fields: record fields with types"
  (define out (query-output SRC '("fields" "R")))
  (check-regexp-match #rx"a : Int" out)
  (check-regexp-match #rx"b : Bool" out))

(test-case "fields: empty source fails with the missing record"
  (check-exn
   #rx"beagle-fields: record Missing not found in provided files"
   (lambda ()
     (with-query-file
      ""
      (lambda (f) (run-query (list "fields" "Missing" f)))))))

(test-case "fields: reader failure reports its path"
  (check-exn
   #rx"beagle-fields: failed to read /unreadable[.]bgl: reader: denied"
   (lambda ()
     (query-field-matches
      "Missing"
      '("/unreadable.bgl")
      #:read-datums (lambda (_f) (error 'reader "denied"))))))

(test-case "fields: missing input path fails pointedly"
  (define missing (make-temporary-file "query-missing~a.bgl"))
  (delete-file missing)
  (check-exn
   #rx"beagle-fields: input path does not exist:"
   (lambda ()
     (run-query (list "fields" "Missing" (path->string missing))))))

(test-case "callers: finds call sites inside defn bodies"
  (define out (query-output SRC '("callers" "typed")))
  (check-regexp-match #rx"in private-fn" out))

(test-case "sig: checking rejects an invalid definition instead of publishing it"
  (check-exn
   #rx"expected return String, got Int"
   (lambda ()
     (query-output
      "(ns q)\n(defn broken [(x Int)] String x)\n"
      '("sig" "broken")))))
