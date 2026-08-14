#lang racket/base

;; Query-tool extraction tests (beagle-sig/-fields/-callers backbone).
;; These extractors rotted silently against the surface twice — bare-`:`
;; matching made every annotated fn report `-> Any`, and docstring-bearing
;; defns vanished entirely during compiler dogfooding.
;; No more silent: the canonical surface shapes are pinned here.

(require rackunit
         racket/file
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         racket/tcp
         beagle/private/query)

(define-runtime-path CANONICAL-FIXTURE "fixtures/query/canonical.bjs")
(define-runtime-path RETIRED-FLAT-FIXTURE
  "fixtures/query/invalid/retired-flat.bjs")
(define-runtime-path DAEMON-FILES "../../bin/_beagle-daemon-files")
(define-runtime-path DAEMON-CLI "../../bin/beagle-daemon")

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

(define (fixture-query-output fixture args)
  (with-output-to-string
    (lambda ()
      (run-query
       (append args (list (path->string fixture)))))))

(define (run-daemon-files-helper scratch command)
  (define out (open-output-string))
  (define err (open-output-string))
  (define script
    (string-append
     "export BEAGLE_DAEMON_PORTFILE=\"$1/daemon.port\"; "
     "export BEAGLE_DAEMON_PIDFILE=\"$1/daemon.pid\"; "
     "export BEAGLE_DAEMON_IDENTITYFILE=\"$1/daemon.identity\"; "
     "source \"$2\"; "
     command))
  (define status
    (parameterize ([current-output-port out]
                   [current-error-port err])
      (system*/exit-code
       (find-executable-path "bash")
       "-c"
       script
       "daemon-routing-test"
       (path->string scratch)
       (path->string DAEMON-FILES))))
  (values status (get-output-string out) (get-output-string err)))

(define (call-with-controlled-dead-endpoint proc)
  (define listener (tcp-listen 0 1 #t "127.0.0.1"))
  (define addresses (call-with-values (lambda () (tcp-addresses listener #t)) list))
  (define accepted (make-semaphore 0))
  (define endpoint-thread
    (thread
     (lambda ()
       (define-values (in out) (tcp-accept listener))
       (semaphore-post accepted)
       ;; The test owns this endpoint and makes it die during the request.
       ;; Keeping the listener bound until the connection is accepted removes
       ;; the close-then-reuse race of selecting an unowned ephemeral port.
       (close-output-port out)
       (close-input-port in))))
  (dynamic-wind
    void
    (lambda () (proc (cadr addresses) accepted))
    (lambda ()
      (kill-thread endpoint-thread)
      (tcp-close listener))))

(define (run-daemon-cli-against-dead-port scratch source-path port)
  (define out (open-output-string))
  (define err (open-output-string))
  (define script
    (string-append
     "export BEAGLE_ZO_GATE_QUIET=1; "
     "export BEAGLE_DAEMON_PORTFILE=\"$1/daemon.port\"; "
     "export BEAGLE_DAEMON_PIDFILE=\"$1/daemon.pid\"; "
     "export BEAGLE_DAEMON_IDENTITYFILE=\"$1/daemon.identity\"; "
     "source \"$2\"; "
     "beagle_compiler_identity > \"$1/daemon.identity\"; "
     "printf '%s\\n' \"$3\" > \"$1/daemon.port\"; "
     "exec \"$4\" query sig present \"$5\""))
  (define status
    (parameterize ([current-output-port out]
                   [current-error-port err])
      (system*/exit-code
       (find-executable-path "bash")
       "-c"
       script
       "daemon-dead-port-test"
       (path->string scratch)
       (path->string DAEMON-FILES)
       (number->string port)
       (path->string DAEMON-CLI)
       source-path)))
  (values status (get-output-string out) (get-output-string err)))

(define SRC
  (string-append
   "(ns q)\n"
   "(def plain Int 42)\n"
   "(def doced Int \"the answer\" 42)\n"
   "(defrecord R\n  [(a Int)\n   (b Bool)])\n"
   "(declare-extern host/get (Fn [Int] Int))\n"
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
  (check-regexp-match #rx"typed : \\(Fn \\[Int Bool\\] Int\\)" out))

(test-case "sig: docstring-bearing defn is visible"
  (define out (query-output SRC '("sig" "doced-fn")))
  (check-regexp-match #rx"doced-fn : \\(Fn \\[Int\\] Bool\\)" out))

(test-case "sig: defn- is visible"
  (define out (query-output SRC '("sig" "private-fn")))
  (check-regexp-match #rx"private-fn : \\(Fn \\[Int\\] Int\\)" out))

(test-case "sig: inferred scheme is the headline and its body drives detail"
  (define out (query-output SRC '("sig" "one")))
  (check-regexp-match #rx"one : \\(forall \\[A\\] \\(Fn \\[A\\] Int\\)\\)" out)
  (check-regexp-match #rx"  x : A" out)
  (check-regexp-match #rx"  -> Int" out)
  (check-false (regexp-match? #rx"\\?[0-9]+" out) out))

(test-case "sig: explicit Any remains authored Any"
  (define out (query-output SRC '("sig" "dynamic")))
  (check-regexp-match #rx"dynamic : \\(Fn \\[Any\\] Any\\)" out)
  (check-false (string-contains? out "forall") out)
  (check-false (regexp-match? #rx"\\?[0-9]+" out) out))

(test-case "sig: typed rest publishes the element type"
  (define out
    (query-output
     (string-append
      "(ns q.typed-rest)\n"
      "(defn collect [(first Int) & (more (Vec Int))] Int first)\n")
     '("sig" "collect")))
  (check-regexp-match #rx"collect : \\(Fn \\[Int & Int\\] Int\\)" out)
  (check-regexp-match #rx"& more : Int" out))

(test-case "sig: aggregate parameter detail preserves one binding operation"
  (define out (query-output SRC '("sig" "pair-head")))
  (check-regexp-match
   #rx"pair-head : \\(Fn \\[\\(HVec Int String\\)\\] Int\\)"
   out)
  (check-regexp-match #rx"  \\[x y\\] : \\(HVec Int String\\)" out))

(test-case "sig: associative destructuring comes from the checked AST"
  (define out
    (fixture-query-output CANONICAL-FIXTURE '("sig" "point-x")))
  (check-regexp-match #rx"point-x : \\(Fn \\[Point\\] Float\\)" out)
  (check-regexp-match #rx"  \\{:keys \\[x y\\]\\} : Point" out))

(test-case "sig: multi-arity headline and clause details use effective types"
  (define out (query-output SRC '("sig" "overloaded")))
  (check-regexp-match
   #rx"overloaded : \\(U \\(Fn \\[Int\\] Int\\) \\(Fn \\[String Int\\] String\\)\\)"
   out)
  (check-regexp-match #rx"arity 1:[\n ]+x : Int" out)
  (check-regexp-match #rx"arity 2:[\n ]+x : String[\n ]+n : Int" out))

(test-case "sig: declare-extern entries are found"
  (define out (query-output SRC '("sig" "host/get")))
  (check-regexp-match #rx"host/get : \\(Fn \\[Int\\] Int\\)  .extern." out))

(test-case "fields: record fields with types"
  (define out (query-output SRC '("fields" "R")))
  (check-regexp-match #rx"a : Int" out)
  (check-regexp-match #rx"b : Bool" out))

(test-case "fields: exported records use the checked canonical AST"
  (define out
    (fixture-query-output CANONICAL-FIXTURE '("fields" "World")))
  (check-regexp-match #rx"players : \\(Vec String\\)" out)
  (check-regexp-match #rx"elapsed : Float" out)
  (check-regexp-match #rx"constructor: ->World" out))

(test-case "fields: a qualified target selects its source namespace"
  (define out
    (fixture-query-output
     CANONICAL-FIXTURE
     '("fields" "query.fixture/TerrainInterest")))
  (check-regexp-match #rx"position : \\(Vec Float\\)" out)
  (define match
    (car (query-field-matches
          "query.fixture/TerrainInterest"
          (list (path->string CANONICAL-FIXTURE)))))
  (check-equal? (cadddr match) 'query.fixture)
  ;; An exported declaration reports its own line, not the `js/export`
  ;; wrapper's: the wrapper carries no declaration a reader can jump to.
  (check-equal? (list-ref match 4) 7))

(test-case "sig: generated record accessor and constructor are queryable"
  (define accessor-out
    (fixture-query-output
     CANONICAL-FIXTURE
     '("sig" "terraininterest-position")))
  (check-regexp-match
   #rx"terraininterest-position : \\(Fn \\[TerrainInterest\\] \\(Vec Float\\)\\)"
   accessor-out)
  (check-regexp-match #rx"  r : TerrainInterest" accessor-out)
  (define constructor-out
    (fixture-query-output CANONICAL-FIXTURE '("sig" "->World")))
  (check-regexp-match
   #rx"->World : \\(Fn \\[\\(Vec String\\) Float\\] World\\)"
   constructor-out))

(test-case "sig: qualified lookup is nonempty and preserves source metadata"
  (define matches
    (query-signature-matches
     "query.fixture/player-collision-radius"
     (list (path->string CANONICAL-FIXTURE))))
  (check-equal? (length matches) 1)
  (define match (car matches))
  (check-equal? (hash-ref match 'namespace) 'query.fixture)
  (check-equal? (hash-ref match 'line) 19)
  (check-regexp-match
   #rx"query.fixture/player-collision-radius : \\(Fn \\[\\] Float\\)"
   (fixture-query-output
    CANONICAL-FIXTURE
    '("sig" "query.fixture/player-collision-radius"))))

(test-case "sig: a missing callable fails instead of exiting successfully empty"
  (check-exn
   #rx"beagle-sig: callable missing not found in provided files"
   (lambda ()
     (fixture-query-output CANONICAL-FIXTURE '("sig" "missing")))))

(test-case "query routing rejects a daemon from another compiler closure"
  (define scratch (make-temporary-file "beagle-daemon-routing-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define-values (identity-status identity _identity-error)
        (run-daemon-files-helper scratch "beagle_compiler_identity"))
      (check-equal? identity-status 0)
      (call-with-output-file (build-path scratch "daemon.port")
        #:exists 'truncate/replace
        (lambda (out) (display "4242\n" out)))
      (call-with-output-file (build-path scratch "daemon.identity")
        #:exists 'truncate/replace
        (lambda (out) (display identity out)))
      (define-values (matching-status matching-port _matching-error)
        (run-daemon-files-helper scratch "beagle_daemon_compatible_port"))
      (check-equal? matching-status 0)
      (check-equal? matching-port "4242\n")
      (call-with-output-file (build-path scratch "daemon.identity")
        #:exists 'truncate/replace
        (lambda (out) (display "stale\n" out)))
      (define-values (stale-status stale-port _stale-error)
        (run-daemon-files-helper scratch "beagle_daemon_compatible_port"))
      (check-not-equal? stale-status 0)
      (check-equal? stale-port ""))
    (lambda () (delete-directory/files scratch))))

(test-case "daemon CLI falls back one-shot when a compatible endpoint dies"
  (define scratch (make-temporary-file "beagle-daemon-dead-port-~a" 'directory))
  (define source-path (build-path scratch "present.bclj"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file source-path
        #:exists 'truncate/replace
        (lambda (out)
          (display
           (string-append
            "#lang beagle/clj\n"
            "(ns daemon.dead-port)\n"
            "(defn present [] Int 1)\n")
           out)))
      (call-with-controlled-dead-endpoint
       (lambda (port accepted)
         (define-values (status out err)
           (run-daemon-cli-against-dead-port
            scratch
            (path->string source-path)
            port))
         (check-not-false
          (sync/timeout 0 accepted)
          "the CLI exercised the test-owned compatible endpoint")
         (check-equal? status 0)
         (check-true (string-contains? out "\"signature\":\"(Fn [] Int)\""))
         (check-equal? err ""))))
    (lambda () (delete-directory/files scratch))))

(test-case "fields: retired flat fields are refused by the canonical parser"
  (check-exn
   #rx"use \\[\\(name Type\\) \\(name2 Type2 validator\\) \\.\\.\\.\\]"
   (lambda ()
     (fixture-query-output
      RETIRED-FLAT-FIXTURE
      '("fields" "Retired")))))

(test-case "fields: empty source fails with the missing record"
  (check-exn
   #rx"beagle-fields: record Missing not found in provided files"
   (lambda ()
     (with-query-file
      (lambda (f) (run-query (list "fields" "Missing" f)))))))

(test-case "fields: checked-program failure reports its path"
  (check-exn
   #rx"beagle-fields: failed to check /unreadable[.]bgl: reader: denied"
   (lambda ()
     (query-field-matches
      "Missing"
      '("/unreadable.bgl")
      #:load-program (lambda (_f) (error 'reader "denied"))))))

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
