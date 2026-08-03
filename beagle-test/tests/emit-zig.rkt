#lang racket/base

;; Zig backend golden snapshots (thread 20260612232001, brief §7.1).
;;
;; Each fixtures/zig-golden/NN-name.bgl compiles (target injected) and
;; must match its committed NN-name.zig snapshot byte-for-byte — any
;; diff is a deliberate, reviewed change. Re-bless after a reviewed
;; emitter change with:
;;
;;   BEAGLE_ZIG_BLESS=1 raco test beagle-test/tests/emit-zig.rkt
;;
;; Additionally every snapshot must COMPILE: when `zig` is on PATH the
;; suite runs `zig build-obj -fno-emit-bin` over each snapshot (with the
;; kernel prelude copied alongside), so snapshots can't rot into
;; non-Zig. Without zig the compile check is skipped (snapshot
;; comparison still runs).
;;
;; Also here: pointed-rejection cases — out-of-table IR must error with
;; "not yet supported by zig backend", never silently approximate.

(require rackunit
         racket/file
         racket/path
         racket/port
         racket/string
         racket/system
         beagle/private/ast
         beagle/private/parse
         beagle/private/check
         beagle/private/tags
         beagle/private/types
         beagle/private/emit)

(define fixtures-dir
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (build-path dir "fixtures" "zig-golden")))

(define semantic-contract-dir
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (build-path dir "fixtures" "semantic-contract")))

(define zig-stdlib-dir
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (build-path dir "fixtures" "zig-stdlib")))

(define imported-record-types-dir
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (build-path dir "fixtures" "zig-imported-record-types")))

(define beagle-cli
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (simplify-path (build-path dir 'up 'up "bin" "beagle"))))

(define kernel-rt
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (simplify-path (build-path dir 'up 'up "beagle-lib" "zig" "beagle_rt.zig"))))

(define js-runtime-dir
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (simplify-path
     (build-path dir 'up 'up "beagle-lib" "lib" "beagle"))))

;; Non-core runtime modules (los_rt, los_yaml, ...) lower to their OWN
;; `@import("X.zig")` (Phase 1). The golden compile check copies a
;; self-contained stand-in for each from fixtures/zig-support/ so it stays
;; independent of the los-bb application repo.
(define support-dir (simplify-path (build-path fixtures-dir 'up "zig-support")))

;; modules referenced by the emitted source via @import("X.zig"), minus
;; std and the core prelude (which are copied/builtin separately).
(define (emitted-support-modules zig-src)
  (for/list ([m (in-list (regexp-match* #rx"@import\\(\"([a-z0-9_]+)\\.zig\"\\)" zig-src
                                        #:match-select cadr))]
             #:unless (member m '("beagle_rt")))
    m))

(define bless? (and (getenv "BEAGLE_ZIG_BLESS") #t))

(define (parse-target-src target src-path)
  (define stxs (read-beagle-syntax src-path))
  (define has-target?
    (for/or ([stx (in-list stxs)])
      (define d (syntax->datum stx))
      (and (pair? d) (eq? (car d) 'define-target))))
  (define forms
    (if has-target?
        stxs
        (cons (datum->syntax #f `(define-target ,target)) stxs)))
  (parse-program forms #:source-path src-path))

(define (compile-target-src target src-path)
  (define prog (parse-target-src target src-path))
  (type-check! prog)
  (emit-program prog))

(define (compile-zig-src src-path)
  (compile-target-src 'zig src-path))

(define (compile-zig-forms . datums)
  (define forms (map (lambda (d) (datum->syntax #f d))
                     (cons '(define-target zig) datums)))
  (define prog (parse-program forms))
  (type-check! prog)
  (emit-program prog))

(define (compile-target-forms target . datums)
  (define forms
    (map (lambda (d) (datum->syntax #f d))
         (cons `(define-target ,target) datums)))
  (define prog (parse-program forms))
  (type-check! prog)
  (emit-program prog))

(define (check-zig-forms . datums)
  (define forms (map (lambda (d) (datum->syntax #f d))
                     (cons '(define-target zig) datums)))
  (type-check! (parse-program forms)))

(define (br . xs) (cons BRACKET-TAG xs))
(define (mp . xs) (cons MAP-TAG xs))
(define (st . xs) (cons SET-TAG xs))

(define (compile-zig-string src)
  ;; through the REAL beagle reader (brackets/braces), via a temp file.
  (define f (make-temporary-file "zigsrc~a.bgl"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file f #:exists 'replace (lambda (p) (display src p)))
      (compile-zig-src f))
    (lambda () (delete-file f))))

(define ZIG (find-executable-path "zig"))
(define NODE (find-executable-path "node"))
(define CLOJURE (find-executable-path "clojure"))
(unless ZIG
  (displayln "note: zig not on PATH — snapshot compile checks skipped"))

(define (zig-env dir)
  (define ev (environment-variables-copy (current-environment-variables)))
  (define global-cache (build-path dir "zig-global-cache"))
  (define local-cache (build-path dir "zig-local-cache"))
  (make-directory* global-cache)
  (make-directory* local-cache)
  (environment-variables-set! ev #"ZIG_GLOBAL_CACHE_DIR" (path->bytes global-cache))
  (environment-variables-set! ev #"ZIG_LOCAL_CACHE_DIR" (path->bytes local-cache))
  ev)

(define (zig-compiles? zig-src name)
  (define dir (make-temporary-file "zigck~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (copy-file kernel-rt (build-path dir "beagle_rt.zig"))
      (for ([mod (in-list (emitted-support-modules zig-src))])
        (define support (build-path support-dir (format "~a.zig" mod)))
        (when (file-exists? support)
          (copy-file support (build-path dir (format "~a.zig" mod)))))
      (define f (build-path dir (format "~a.zig" name)))
      (call-with-output-file f (lambda (p) (display zig-src p)))
      (define out (open-output-string))
      (define ok
        (parameterize ([current-output-port out]
                       [current-error-port out]
                       [current-environment-variables (zig-env dir)]
                       [current-directory dir])
          (system* ZIG "build-obj" "-fno-emit-bin" (path->string f))))
      (unless ok
        (eprintf "zig compile check failed for ~a:\n~a\n" name
                 (get-output-string out)))
      ok)
    (lambda () (delete-directory/files dir))))

(define (zig-tests? zig-src tests name)
  (define dir (make-temporary-file "zigtest~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (copy-file kernel-rt (build-path dir "beagle_rt.zig"))
      (define f (build-path dir (format "~a.zig" name)))
      (call-with-output-file f
        (lambda (p)
          (display zig-src p)
          (newline p)
          (display tests p)))
      (define out (open-output-string))
      (define ok
        (parameterize ([current-output-port out]
                       [current-error-port out]
                       [current-environment-variables (zig-env dir)]
                       [current-directory dir])
          (system* ZIG "test" (path->string f))))
      (unless ok
        (eprintf "zig behavior check failed for ~a:\n~a\n" name
                 (get-output-string out)))
      ok)
    (lambda () (delete-directory/files dir))))

(define (run-command-output executable . args)
  (define out (open-output-string))
  (define err (open-output-string))
  (define ok?
    (parameterize ([current-output-port out]
                   [current-error-port err])
      (apply system* executable args)))
  (values ok? (get-output-string out) (get-output-string err)))

(define (zig-build-exe-and-run zig-src
                               #:args [args '()]
                               #:env [environment '()]
                               #:exit-code [expected-exit 0])
  (define dir (make-temporary-file "zigsmoke~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (copy-file kernel-rt (build-path dir "beagle_rt.zig"))
      (define src (build-path dir "main.zig"))
      (define exe (build-path dir "zig-smoke"))
      (call-with-output-file src (lambda (p) (display zig-src p)))
      (define build-log (open-output-string))
      (define built?
        (parameterize ([current-output-port build-log]
                       [current-error-port build-log]
                       [current-environment-variables (zig-env dir)]
                       [current-directory dir])
          (system* ZIG "build-exe" (path->string src)
                   (format "-femit-bin=~a" (path->string exe)))))
      (unless built?
        (error 'zig-smoke "zig build-exe failed:\n~a" (get-output-string build-log)))
      (define run-out (open-output-string))
      (define run-env
        (environment-variables-copy (current-environment-variables)))
      (environment-variables-set! run-env #"TMPDIR" (path->bytes dir))
      (for ([entry (in-list environment)])
        (environment-variables-set!
         run-env
         (string->bytes/utf-8 (car entry))
         (string->bytes/utf-8 (cdr entry))))
      (define actual-exit
        (parameterize ([current-output-port run-out]
                       [current-error-port run-out]
                       [current-environment-variables run-env]
                       [current-directory dir])
          (apply system*/exit-code exe args)))
      (unless (= actual-exit expected-exit)
        (error 'zig-smoke
               "emitted binary exited ~a, expected ~a:\n~a"
               actual-exit expected-exit (get-output-string run-out)))
      (get-output-string run-out))
    (lambda () (delete-directory/files dir))))

(define fixture-files
  (sort (for/list ([f (in-list (directory-list fixtures-dir))]
                   #:when (regexp-match? #rx"\\.bgl$" (path->string f)))
          (path->string f))
        string<?))

(for ([bgl (in-list fixture-files)])
  (define name (regexp-replace #rx"\\.bgl$" bgl ""))
  (define snap-path (build-path fixtures-dir (string-append name ".zig")))
  (define emitted (compile-zig-src (build-path fixtures-dir bgl)))
  (when bless?
    (call-with-output-file snap-path #:exists 'replace
      (lambda (p) (display emitted p))))
  (test-case (format "golden: ~a matches snapshot" name)
    (check-true (file-exists? snap-path)
                (format "missing snapshot ~a (run with BEAGLE_ZIG_BLESS=1)" name))
    (check-equal? emitted (file->string snap-path)))
  (when ZIG
    (test-case (format "golden: ~a compiles as zig" name)
      (check-true (zig-compiles? emitted name)))))

(when ZIG
  (test-case "typed beagle smoke emits, build-exe compiles, and binary runs"
    (define smoke
      (build-path fixtures-dir 'up "zig-smoke" "main.bzig"))
    (check-equal? (zig-build-exe-and-run (compile-zig-src smoke))
                  "zig revival alive\n")))

(when ZIG
  (test-case "zig CLI runtime exposes argv, environment, and JSON escaping"
    (define cli-runtime
      (build-path fixtures-dir "35-cli-runtime.bgl"))
    (check-equal?
     (zig-build-exe-and-run
      (compile-zig-src cli-runtime)
      #:args '("arg-value")
      #:env '(("BEAGLE_CLI_TEST_VALUE" . "env-value")))
     (string-append
      "arg-value:env-value:a\\\"b\\nc:9:captured-out:captured-err:7"
      ":alphabeta:true:true:true:true:true\n"))))

(when ZIG
  (test-case "zig process children inherit the emitted program environment"
    (define emitted
      (compile-zig-string
       (string-append
        "(ns zig.process-env)\n"
        "(defn main [] -> Nil\n"
        "  (let [run-exit (zig/process-run [\"sh\" \"-c\" \"test x$BEAGLE_CHILD_ENV = xinherited\"] nil)\n"
        "        captured (zig/process-capture [\"sh\" \"-c\" \"printf %s $BEAGLE_CHILD_ENV\"] nil)]\n"
        "    (println (str run-exit \":\" (zig/process-result-stdout captured) \":\" (zig/process-result-exit captured)))))\n")))
    (check-equal?
     (zig-build-exe-and-run
      emitted
      #:env '(("BEAGLE_CHILD_ENV" . "inherited")))
     "0:inherited:0\n")))

(when ZIG
  (test-case "zig equality compares process exit codes with Int literals"
    (define emitted
      (compile-zig-string
       (string-append
        "(ns zig.process-exit-equality)\n"
        "(defn main [] -> Nil\n"
        "  (let [result (zig/process-capture [\"sh\" \"-c\" \"exit 0\"] nil)]\n"
        "    (println (= (zig/process-result-exit result) 0))))\n")))
    (check-equal? (zig-build-exe-and-run emitted) "true\n")))

(when ZIG
  (test-case "zig/exit propagates the exact native status"
    (define emitted
      (compile-zig-forms
       '(defn main [] -> Nil (zig/exit 23))))
    (check-equal?
     (zig-build-exe-and-run emitted #:exit-code 23)
     "")))

(when ZIG
  (test-case "zig/temp-dir installs process context independently"
    (define emitted
      (compile-zig-forms
       '(defn main [] -> Nil
          (let [temporary (zig/temp-dir)]
            (zig/remove-tree temporary)))))
    (check-equal? (zig-build-exe-and-run emitted) "")))

(when ZIG
  (test-case "imported record types and constructors lower through canonical Zig modules"
    (define dir (make-temporary-file "zig-imported-records~a" 'directory))
    (dynamic-wind
      void
      (lambda ()
        (define executable (build-path dir "imported-records"))
        (define build-output (open-output-string))
        (define built?
          (parameterize ([current-output-port build-output]
                         [current-error-port build-output]
                         [current-environment-variables (zig-env dir)]
                         [current-directory dir])
            (system*
             beagle-cli
             "build"
             "--target"
             "zig"
             "--exe"
             (path->string executable)
             (path->string (build-path imported-record-types-dir "types.bclj"))
             (path->string (build-path imported-record-types-dir "main.bclj")))))
        (check-true built? (get-output-string build-output))
        (define run-output (open-output-string))
        (define ran?
          (parameterize ([current-output-port run-output]
                         [current-error-port run-output]
                         [current-directory dir])
            (system* executable)))
        (check-true ran? (get-output-string run-output))
        (check-equal? (get-output-string run-output) "84\n"))
      (lambda () (delete-directory/files dir)))))

;; --- Fram rt_core stdlib conformance ----------------------------------------

(define zig-stdlib-cases
  '(("string-seq" "zig-stdlib.string-seq" "2:a:b\n2\nxoxoxo\n")
    ("predicates" "zig-stdlib.predicates" "true:true:true:true:true:true\n")
    ("pr-str" "zig-stdlib.pr-str" "{:name \"fram\", :version 7}\n")))

(for ([entry (in-list zig-stdlib-cases)])
  (define name (car entry))
  (define namespace (cadr entry))
  (define expected (caddr entry))
  (define src (build-path zig-stdlib-dir (string-append name ".bgl")))
  (define snapshot (build-path zig-stdlib-dir (string-append name ".zig")))
  (define zig-src (compile-zig-src src))
  (when bless?
    (call-with-output-file snapshot #:exists 'replace
      (lambda (out) (display zig-src out))))
  (test-case (format "rt_core stdlib: ~a Zig snapshot" name)
    (check-true (file-exists? snapshot)
                (format "missing snapshot ~a (run with BEAGLE_ZIG_BLESS=1)"
                        snapshot))
    (check-equal? zig-src (file->string snapshot)))
  (when CLOJURE
    (test-case (format "rt_core stdlib: ~a CLJ behavior" name)
      (define clj-src (compile-target-src 'clj src))
      (define clj-file (make-temporary-file "zig-stdlib~a.clj"))
      (dynamic-wind
        void
        (lambda ()
          (call-with-output-file clj-file #:exists 'replace
            (lambda (out) (display clj-src out)))
          (define-values (ok? stdout stderr)
            (run-command-output
             CLOJURE
             "-i" (path->string clj-file)
             "-e" (format "(~a/main)" namespace)))
          (check-true ok? stderr)
          (check-equal? stdout expected))
        (lambda () (delete-file clj-file)))))
  (when ZIG
    (test-case (format "rt_core stdlib: ~a Zig behavior agrees with CLJ" name)
      (check-equal? (zig-build-exe-and-run zig-src) expected))))

(define atom-runtime-src
  (build-path zig-stdlib-dir "atom-runtime.bclj"))

(define (compile-retarget-fixture target src)
  (define datums
    (for/list ([stx (in-list (read-beagle-syntax src))]
               #:unless
               (let ([datum (syntax->datum stx)])
                 (and (pair? datum) (eq? (car datum) 'define-target))))
      (datum->syntax #f (syntax->datum stx))))
  (define prog
    (parse-program
     (cons (datum->syntax #f `(define-target ,target)) datums)))
  (type-check! prog)
  (emit-program prog))

(test-case "Zig Atom preserves aliases, mutation results, and arena ownership"
  (define zig-src (compile-retarget-fixture 'zig atom-runtime-src))
  (check-true (string-contains? zig-src "*rt.Atom(Counter)"))
  (check-true (string-contains? zig-src "rt.makeAtom(Counter, __ctx.tick"))
  (when ZIG
    (check-true
     (zig-tests?
      zig-src
      #<<ZIG
test "Atom aliases observe reset and swap in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rng = rt.Splitmix64.init(1);
    var ctx = rt.Ctx{ .tick = arena.allocator(), .rng = &rng };

    try std.testing.expectEqual(@as(i64, 26), exercise(&ctx));
}
ZIG
      "atom-runtime"))))

(test-case "ordinary portable conj allocates through the hidden Zig context"
  (define zig-src
    (compile-zig-string
     "(ns g)\n(defn append-value\n  [xs: (Vec Int)\n   x: Int] -> (Vec Int)\n  (conj xs x))"))
  (check-true (string-contains? zig-src "rt.conj(__ctx, xs, x)"))
  (when ZIG
    (check-true
     (zig-tests?
      zig-src
      #<<ZIG
test "ordinary conj preserves input and appends one value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rng = rt.Splitmix64.init(1);
    var ctx = rt.Ctx{ .tick = arena.allocator(), .rng = &rng };

    const out = appendValue(&ctx, &.{ 1, 2 }, 3);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, out);
}
ZIG
      "ordinary-conj"))))

(test-case "ordinary portable vector assoc is persistent and can grow at count"
  (define zig-src
    (compile-zig-string
     "(ns g)\n(defn replace-value\n  [xs: (Vec Int)\n   i: Int\n   x: Int] -> (Vec Int)\n  (assoc xs i x))"))
  (check-true (string-contains? zig-src "rt.assoc(__ctx, xs, i, x)"))
  (when ZIG
    (check-true
     (zig-tests?
      zig-src
      #<<ZIG
test "vector assoc preserves input, replaces, and grows at count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rng = rt.Splitmix64.init(1);
    var ctx = rt.Ctx{ .tick = arena.allocator(), .rng = &rng };

    const input: []const i64 = &.{ 1, 2 };
    const replaced = replaceValue(&ctx, input, 0, 9);
    const grown = replaceValue(&ctx, input, 2, 3);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, input);
    try std.testing.expectEqualSlices(i64, &.{ 9, 2 }, replaced);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, grown);
}
ZIG
      "ordinary-vector-assoc"))))

(when ZIG
  (test-case "vector assoc rejects an index beyond count"
    (define zig-src
      (compile-zig-string
       (string-append
        "(ns g)\n"
        "(def INPUT: (Vec Int) [1 2])\n"
        "(defn invalid-assoc [xs: (Vec Int)] -> (Vec Int) (assoc xs 3 9))\n"
        "(defn main [] -> Nil (println (count (invalid-assoc INPUT))))\n")))
    (define failure (zig-build-exe-and-run zig-src #:exit-code 134))
    (check-true (string-contains? failure "vector assoc index out of bounds"))))

;; --- semantic contract 1: concrete native boundaries -------------------------

(define semantic-bless? (and (getenv "BEAGLE_SEMANTIC_BLESS") #t))
(define any-boundary-src (build-path semantic-contract-dir "any-boundary.bgl"))
(define concrete-boundary-src (build-path semantic-contract-dir "concrete-boundary.bgl"))
(define regex-src (build-path semantic-contract-dir "regex.bgl"))
(define closed-dynamic-src (build-path semantic-contract-dir "closed-dynamic.bgl"))
(define collections-layout-src
  (build-path semantic-contract-dir "collections-layout.bgl"))
(define collection-order-killed-src
  (build-path semantic-contract-dir "collection-order-killed.bgl"))
(define collection-order-observed-src
  (build-path semantic-contract-dir "collection-order-observed.bgl"))
(define allocation-failure-src
  (build-path semantic-contract-dir "allocation-failure.bgl"))
(define ownership-lifetime-src
  (build-path semantic-contract-dir "ownership-lifetime.bgl"))
(define typed-errors-src
  (build-path semantic-contract-dir "typed-errors.bgl"))
(define composite-raises-src
  (build-path semantic-contract-dir "composite-raises.bgl"))

(define (parse-semantic-target-src target src)
  ;; Source locations contain an absolute checkout path. Strip only that
  ;; incidental metadata so these cross-worktree byte goldens stay portable.
  (define datums
    (for/list ([stx (in-list (read-beagle-syntax src))])
      (datum->syntax #f (syntax->datum stx))))
  (parse-program (cons (datum->syntax #f `(define-target ,target)) datums)))

(define (compile-semantic-target-src target src)
  (define prog (parse-semantic-target-src target src))
  (type-check! prog)
  (emit-program prog))

(define (semantic-golden target src name)
  (define ext (if (eq? target 'clj) ".clj" ".zig"))
  (define path (build-path semantic-contract-dir (string-append name ext)))
  (define emitted (compile-semantic-target-src target src))
  (when semantic-bless?
    (call-with-output-file path #:exists 'replace
      (lambda (p) (display emitted p))))
  (check-true (file-exists? path)
              (format "missing semantic-contract golden ~a (run with BEAGLE_SEMANTIC_BLESS=1)"
                      path))
  (check-equal? emitted (file->string path))
  emitted)

(test-case "Any boundary remains byte-identical on CLJ"
  (semantic-golden 'clj any-boundary-src "any-boundary"))

(test-case "Zig rejects Any at the checker boundary"
  (check-exn
   (lambda (e)
     (and (beagle-diagnostic? e)
          (eq? (beagle-diagnostic-kind e) 'type-mismatch)
          (regexp-match? #rx"native boundary" (exn-message e))))
   (lambda () (type-check! (parse-semantic-target-src 'zig any-boundary-src)))))

(define (native-boundary-rejection? e)
  (and (beagle-diagnostic? e)
       (eq? (beagle-diagnostic-kind e) 'type-mismatch)
       (regexp-match? #rx"zig native boundary" (exn-message e))
       (regexp-match? #rx"concrete :- type" (exn-message e))))

(for ([case (in-list
             (list
              (cons "def" '((def value #%: Any 1)))
              (cons "parameter" '((defn f [value #%: Any] -> Int 1)))
              (cons "return" '((defn f [] -> Any 1)))
              (cons "record field" '((defrecord Box [value #%: Any])))
              (cons "nested extern"
                    (list `(declare-extern app.rt/read
                             ,(br 'String '-> '(Map Keyword Any)))))))])
  (test-case (format "Zig checker rejects Any in ~a boundary" (car case))
    (check-exn native-boundary-rejection?
               (lambda () (apply check-zig-forms (cdr case))))))

(test-case "concrete boundary remains byte-identical on CLJ and emits Zig"
  (semantic-golden 'clj concrete-boundary-src "concrete-boundary")
  (define zig-src (semantic-golden 'zig concrete-boundary-src "concrete-boundary"))
  (when ZIG
    (check-true (zig-compiles? zig-src "semantic-concrete-boundary"))))

;; --- semantic contract 2: regex value and match shape -----------------------

(test-case "regex contract pins CLJ bytes and emits compiling Zig"
  (define clj-src (semantic-golden 'clj regex-src "regex"))
  (define zig-src (semantic-golden 'zig regex-src "regex"))
  (when CLOJURE
    (define clj-file (make-temporary-file "semantic-regex~a.clj"))
    (dynamic-wind
      void
      (lambda ()
        (call-with-output-file clj-file
          #:exists 'replace
          (lambda (p)
            (display clj-src p)
            (display
             "\n(prn [(find-no-capture \"cat\") (find-no-capture \"dog\") (match-optional-capture \"ab\") (match-optional-capture \"b\") (match-optional-capture \"ba\") (match-multiple-captures \"abc-42\") (match-escaped-group \"(x)\") (replace-runs \"A--b c\") (split-runs \"a,b;;c\")])\n"
             p)))
        (define-values (ok? out err)
          (run-command-output CLOJURE (path->string clj-file)))
        (check-true ok? err)
        (check-equal?
         out
         "[\"cat\" nil [\"ab\" \"a\"] [\"b\" nil] nil [\"abc-42\" \"abc\" \"42\"] \"(x)\" \"_b_c\" [\"a\" \"b\" \"c\"]]\n"))
      (lambda () (delete-file clj-file))))
  (when NODE
    (define js-src (compile-semantic-target-src 'js regex-src))
    (define runnable
      (regexp-replace* #px"(?m:^import [^\n]*\n)" js-src ""))
    (define-values (ok? out err)
      (run-command-output
       NODE "--input-type=module" "-e"
       (string-append
        runnable
        "\nconsole.log(JSON.stringify([find_no_capture(\"cat\"), find_no_capture(\"dog\"), match_optional_capture(\"ab\"), match_optional_capture(\"b\"), match_optional_capture(\"ba\"), match_multiple_captures(\"abc-42\"), match_escaped_group(\"(x)\"), replace_runs(\"A--b c\"), split_runs(\"a,b;;c\")]));\n")))
    (check-true ok? err)
    (check-equal?
     out
     "[\"cat\",null,[\"ab\",\"a\"],[\"b\",null],null,[\"abc-42\",\"abc\",\"42\"],\"(x)\",\"_b_c\",[\"a\",\"b\",\"c\"]]\n"))
  (when ZIG
    (check-true (zig-compiles? zig-src "semantic-regex"))
    (check-true
     (zig-tests?
      zig-src
      #<<ZIG
test "regex semantic contract behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rng = rt.Splitmix64.init(1);
    var ctx = rt.Ctx{ .tick = arena.allocator(), .rng = &rng };

    try std.testing.expectEqualStrings("cat", findNoCapture("cat").?);
    try std.testing.expect(findNoCapture("dog") == null);

    const optional_present = matchOptionalCapture("ab").?;
    try std.testing.expectEqualStrings("ab", optional_present[0].?);
    try std.testing.expectEqualStrings("a", optional_present[1].?);
    const optional_absent = matchOptionalCapture("b").?;
    try std.testing.expectEqualStrings("b", optional_absent[0].?);
    try std.testing.expect(optional_absent[1] == null);
    try std.testing.expect(matchOptionalCapture("ba") == null);

    const multiple = matchMultipleCaptures("abc-42").?;
    try std.testing.expectEqualStrings("abc-42", multiple[0].?);
    try std.testing.expectEqualStrings("abc", multiple[1].?);
    try std.testing.expectEqualStrings("42", multiple[2].?);
    try std.testing.expectEqualStrings("(x)", matchEscapedGroup("(x)").?);
    try std.testing.expectEqualStrings("_b_c", replaceRuns(&ctx, "A--b c"));

    const pieces = splitRuns(&ctx, "a,b;;c");
    try std.testing.expectEqual(@as(usize, 3), pieces.len);
    try std.testing.expectEqualStrings("a", pieces[0]);
    try std.testing.expectEqualStrings("b", pieces[1]);
    try std.testing.expectEqualStrings("c", pieces[2]);
}
ZIG
      "semantic-regex-behavior"))))

(test-case "regex checker records static construction and normalized match shape"
  (define prog
    (parse-program
     (map (lambda (datum) (datum->syntax #f datum))
          '((define-target zig)
            (ns regex-contract-shape)
            (def optional #%: Regex (re-pattern "^(a)?b$"))
            (defn match-it [s #%: String] -> (U (HVec String String?) Nil)
              (re-matches optional s))))))
  (type-check! prog)
  (define optional-def
    (for/first ([form (in-list (program-forms prog))]
                #:when (and (def-form? form) (eq? (def-form-name form) 'optional)))
      form))
  (define contract
    (hash-ref (program-semantic-contracts prog) (def-form-value optional-def)))
  (check-equal? (regex-contract-pattern-source contract) "^(a)?b$")
  (check-equal? (type->string (regex-contract-match-type contract))
                "(HVec String String?)")
  (check-equal? (regex-contract-unit contract) 'utf8-codepoint))

(test-case "regex checker retains a static contract through an Any annotation"
  (define prog
    (parse-program
     (map (lambda (datum) (datum->syntax #f datum))
          '((define-target clj)
            (ns regex-contract-any)
            (def legacy-pattern #%: Any (re-pattern "^[a-z]+$"))
            (defn match-it [s #%: String] -> Any
              (re-matches legacy-pattern s))))))
  (check-not-exn (lambda () (type-check! prog))))

(test-case "zig regex checker admits a dynamic pattern with explicit match shape"
  (check-zig-forms
   '(ns regex-contract-dynamic)
   '(defn make-it [s #%: String] -> (Regex String) (re-pattern s))))

(test-case "zig regex checker rejects unsupported pattern features"
  (check-exn
   #rx"not lookaround, inline flags, or named groups"
   (lambda ()
     (check-zig-forms
      '(ns regex-contract-feature)
      '(def value #%: Regex (re-pattern "(?=a)a"))))))

;; --- semantic contract 3: closed dynamic values -----------------------------

(test-case "closed dynamic contract pins CLJ bytes and emits compiling Zig"
  (define clj-src (semantic-golden 'clj closed-dynamic-src "closed-dynamic"))
  (define zig-src (semantic-golden 'zig closed-dynamic-src "closed-dynamic"))
  (when CLOJURE
    (define clj-file (make-temporary-file "semantic-closed-dynamic~a.clj"))
    (dynamic-wind
      void
      (lambda ()
        (call-with-output-file clj-file
          #:exists 'replace
          (lambda (p)
            (display clj-src p)
            (display
             "\n(prn [(observe (round-trip (dyn-string \"ok\"))) (observe (round-trip (dyn-int 7))) (observe (round-trip (dyn-bool true))) (observe (round-trip (dyn-vector [\"a\" \"b\"]))) (observe (round-trip (dyn-map {\"k\" 1})))])\n"
             p)))
        (define-values (ok? out err)
          (run-command-output CLOJURE (path->string clj-file)))
        (check-true ok? err)
        (check-equal?
         out
         "[\"string:ok\" \"int:7\" \"bool:true\" \"vec:2\" \"map\"]\n"))
      (lambda () (delete-file clj-file))))
  (when NODE
    (define js-src (compile-semantic-target-src 'js closed-dynamic-src))
    (define runnable
      (regexp-replace* #px"(?m:^import [^\n]*\n)" js-src ""))
    (define-values (ok? out err)
      (run-command-output
       NODE "--input-type=module" "-e"
       (string-append
        runnable
        "\nconsole.log(JSON.stringify([observe(round_trip(dyn_string(\"ok\"))), observe(round_trip(dyn_int(7))), observe(round_trip(dyn_bool(true))), observe(round_trip(dyn_vector([\"a\", \"b\"]))), observe(round_trip(dyn_map({\"k\": 1})))]));\n")))
    (check-true ok? err)
    (check-equal?
     out
     "[\"string:ok\",\"int:7\",\"bool:true\",\"vec:2\",\"map\"]\n"))
  (when ZIG
    (check-true (zig-compiles? zig-src "semantic-closed-dynamic"))
    (check-true
     (zig-tests?
      zig-src
      #<<ZIG
test "closed dynamic semantic contract behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rng = rt.Splitmix64.init(1);
    var ctx = rt.Ctx{ .tick = arena.allocator(), .rng = &rng };

    try std.testing.expectEqualStrings("string:ok", observe(&ctx, roundTrip(dynString("ok"))));
    try std.testing.expectEqualStrings("int:7", observe(&ctx, roundTrip(dynInt(7))));
    try std.testing.expectEqualStrings("bool:true", observe(&ctx, roundTrip(dynBool(true))));
    try std.testing.expectEqualStrings("vec:2", observe(&ctx, roundTrip(dynVector(&.{ "a", "b" }))));
    const value_map = rt.Map(i64).empty(ctx.tick).assoc(ctx.tick, "k", 1);
    try std.testing.expectEqualStrings("map", observe(&ctx, roundTrip(dynMap(value_map))));

    try std.testing.expectEqual(@as(u16, 0), @intFromEnum(std.meta.activeTag(dynString("ok"))));
    try std.testing.expectEqual(@as(u16, 1), @intFromEnum(std.meta.activeTag(dynInt(7))));
    try std.testing.expectEqual(@as(u16, 2), @intFromEnum(std.meta.activeTag(dynBool(true))));
    try std.testing.expectEqual(@as(u16, 3), @intFromEnum(std.meta.activeTag(dynVector(&.{ "a" }))));
    try std.testing.expectEqual(@as(u16, 4), @intFromEnum(std.meta.activeTag(dynMap(value_map))));
}
ZIG
      "semantic-closed-dynamic-behavior"))))

(define (dynamic-contract-rejection? e)
  (and (beagle-diagnostic? e)
       (eq? (beagle-diagnostic-kind e) 'dynamic-contract)))

(for ([case (in-list
             (list
              (cons "empty"
                    '((defn bad [value #%: (Dyn)] -> Int 0)))
              (cons "nested Any"
                    '((defn bad [value #%: (Dyn String (Vec Any))] -> Int 0)))
              (cons "duplicate alternative"
                    '((defn bad [value #%: (Dyn String String)] -> Int 0)))
              (cons "use without narrowing"
                    '((defn bad [value #%: (Dyn String Int)] -> Int
                        (count value))))))])
  (test-case (format "closed dynamic checker rejects ~a" (car case))
    (check-exn dynamic-contract-rejection?
               (lambda () (apply check-zig-forms (cdr case))))))

(test-case "closed dynamic checker rejects an unlisted runtime value"
  (check-exn
   #rx"expected return \\(Dyn String Int\\), got Bool"
   (lambda ()
     (check-zig-forms
      '(defn bad [value #%: Bool] -> (Dyn String Int) value)))))

(test-case "closed dynamic checker validates local annotations"
  (check-exn
   dynamic-contract-rejection?
   (lambda ()
     (check-zig-forms
      '(defn bad [] -> Int
         (let [value #%: (Dyn String Any) "x"] 0))))))

(test-case "closed dynamic lowering discovers local-only contracts"
  (define out
    (compile-zig-forms
     '(defn local-dynamic [value #%: String] -> String
        (let [closed #%: (Dyn String Int) value]
          (if (string? closed) closed "")))))
  (check-true (regexp-match? #rx"pub const Dyn0 = union" out))
  (check-true (regexp-match? #rx"const closed = Dyn0\\{ \\.string = value \\}" out))
  (when ZIG
    (check-true (zig-compiles? out "semantic-local-closed-dynamic"))))

(test-case "closed dynamic lowering discovers extern-only contracts"
  (define out
    (compile-zig-string
     (string-append
      "(ns dynamic-extern)\n"
      "(declare-extern app.rt/tag [(Dyn String Int) -> Int])\n"
      "(defn call-tag [value: String] -> Int (app.rt/tag value))")))
  (check-true (regexp-match? #rx"pub const Dyn0 = union" out))
  (check-true
   (regexp-match?
    #rx"beagle_module_app_rt\\.tag\\(Dyn0\\{ \\.string = value \\}\\)"
    out)))

(test-case "closed dynamic contract records declared-order integer tags"
  (define prog
    (parse-program
     (map (lambda (datum) (datum->syntax #f datum))
          '((define-target zig)
            (ns dynamic-contract-shape)
            (defn identity [value #%: (Dyn String Int Bool)]
              -> (Dyn String Int Bool)
              value)))))
  (type-check! prog)
  (define identity-form
    (for/first ([form (in-list (program-forms prog))]
                #:when (and (defn-form? form)
                            (eq? (defn-form-name form) 'identity)))
      form))
  (define contract
    (hash-ref (program-semantic-contracts prog)
              (car (defn-form-params identity-form))))
  (check-equal? (map type->string (dynamic-contract-alternatives contract))
                '("String" "Int" "Bool"))
  (check-equal? (map cdr (dynamic-contract-tag-abi contract)) '(0 1 2)))

;; --- semantic contract 4: collections, equality, and native layout ----------

(test-case "collection contract pins CLJ bytes and emits compiling Zig"
  (define clj-src
    (semantic-golden 'clj collections-layout-src "collections-layout"))
  (define zig-src
    (semantic-golden 'zig collections-layout-src "collections-layout"))
  (when CLOJURE
    (define clj-file (make-temporary-file "semantic-collections-layout~a.clj"))
    (dynamic-wind
      void
      (lambda ()
        (call-with-output-file clj-file
          #:exists 'replace
          (lambda (p)
            (display clj-src p)
            (display
             "\n(prn [(keyword-map-count) (keyword-map-absent) (compound-map-present) (set-dedup-count) (set-present) (compound-equal) (compound-hash-consistent) (keyword-distinct-from-string)])\n"
             p)))
        (define-values (ok? out err)
          (run-command-output CLOJURE (path->string clj-file)))
        (check-true ok? err)
        (check-equal? out "[2 true true 2 true true true true]\n"))
      (lambda () (delete-file clj-file))))
  (when NODE
    (define js-src (compile-semantic-target-src 'js collections-layout-src))
    (define runnable
      (for/fold ([source js-src])
                ([name (in-list '("core.js" "hamt.js"))])
        (regexp-replace*
         (regexp
          (format "['\"]beagle/~a['\"]" (regexp-quote name)))
         source
         (format "\"file://~a\""
                 (path->string (build-path js-runtime-dir name))))))
    (define-values (ok? out err)
      (run-command-output
       NODE "--input-type=module" "-e"
       (string-append
        runnable
        "\nconsole.log(JSON.stringify([keyword_map_count(), keyword_map_absent(), compound_map_present(), set_dedup_count(), set_present(), compound_equal(), compound_hash_consistent(), keyword_distinct_from_string()]));\n")))
    (check-true ok? err)
    (check-equal? out "[2,true,true,2,true,true,true,true]\n"))
  (when ZIG
    (check-true (zig-compiles? zig-src "semantic-collections-layout"))
    (check-true
     (zig-tests?
      zig-src
      #<<ZIG
test "collection semantic contract behavior and keyword ABI metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rng = rt.Splitmix64.init(1);
    var ctx = rt.Ctx{ .tick = arena.allocator(), .rng = &rng };

    try std.testing.expectEqual(@as(i64, 2), keywordMapCount(&ctx));
    try std.testing.expect(keywordMapAbsent(&ctx));
    try std.testing.expect(compoundMapPresent(&ctx));
    try std.testing.expectEqual(@as(i64, 2), setDedupCount(&ctx));
    try std.testing.expect(setPresent(&ctx));
    try std.testing.expect(compoundEqual(&ctx));
    try std.testing.expect(compoundHashConsistent(&ctx));
    try std.testing.expect(keywordDistinctFromString());

    try std.testing.expectEqual(@as(u16, 1), rt.Keyword.abi_version);
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(rt.Keyword, "namespace"));
    try std.testing.expectEqual(
        @sizeOf([]const u8) * 2,
        @sizeOf(rt.Keyword),
    );
}
ZIG
      "semantic-collections-layout-behavior"))))

(define (collection-contract-rejection? e)
  (and (beagle-diagnostic? e)
       (eq? (beagle-diagnostic-kind e) 'collection-contract)))

(test-case "collection checker rejects observable unspecified map order"
  (check-exn
   collection-contract-rejection?
   (lambda ()
     (check-zig-forms
      '(defn bad [values #%: (Map Keyword Int)] -> Keyword
         (first (keys values)))))))

(test-case "collection checker accepts order-killing consumers and pins target bytes"
  (define clj-src
    (semantic-golden 'clj collection-order-killed-src
                     "collection-order-killed"))
  (define zig-src
    (semantic-golden 'zig collection-order-killed-src
                     "collection-order-killed"))
  (when ZIG
    (check-true (zig-compiles? zig-src "semantic-collection-order-killed"))
    (check-true
     (zig-tests?
      zig-src
      #<<ZIG
test "order-killed keys and vals remain order-free" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rng = rt.Splitmix64.init(1);
    var ctx = rt.Ctx{ .tick = arena.allocator(), .rng = &rng };

    const populated = rt.ValueMap(rt.Keyword, i64).empty(ctx.tick)
        .assoc(ctx.tick, rt.keyword("", "beta"), 2)
        .assoc(ctx.tick, rt.keyword("", "alpha"), 1);
    const empty = rt.ValueMap(rt.Keyword, i64).empty(ctx.tick);
    try std.testing.expect(keySetMatches(&ctx, populated));
    try std.testing.expectEqual(@as(i64, 2), keyCount(&ctx, populated));
    try std.testing.expect(valuesEmpty(&ctx, empty));
    try std.testing.expect(keyPresent(&ctx, populated));
}
ZIG
      "semantic-collection-order-killed-behavior"))))

(test-case "collection checker pins E023 for order-observing consumer"
  (define expected-path
    (build-path semantic-contract-dir
                "collection-order-observed.checker-error"))
  (define actual
    (with-handlers
      ([beagle-diagnostic?
        (lambda (e)
          (format "~a\n~a\n"
                  (hash-ref (beagle-diagnostic-details e) 'error-code)
                  (exn-message e)))])
      (type-check!
       (parse-semantic-target-src 'zig collection-order-observed-src))
      "NO ERROR\n"))
  (check-equal? actual (file->string expected-path)))

(test-case "collection checker rejects target-private map extern layout"
  (check-exn
   collection-contract-rejection?
   (lambda ()
     (check-zig-forms
      `(declare-extern app.rt/send
         ,(br '(Map Keyword Int) '-> 'Int))))))

(test-case "collection checker rejects an annotation-widened literal element"
  (check-exn
   collection-contract-rejection?
   (lambda ()
     (check-zig-forms
      `(defn bad [] -> Int
         (let ,(br 'values ANN-MARKER '(Vec Int) (br 1 "wrong"))
           (count values)))))))

(test-case "collection checker records value semantics, order, and layout"
  (define prog
    (parse-program
     (map (lambda (datum) (datum->syntax #f datum))
          `((define-target zig)
            (ns collection-contract-shape)
            (defn lookup ,(br 'values ANN-MARKER '(Map (Vec Int) String))
              -> Bool
              (let ,(br 'needle ANN-MARKER '(Vec Int) (br 1))
                (contains? values needle)))))))
  (type-check! prog)
  (define lookup-form
    (for/first ([form (in-list (program-forms prog))]
                #:when (and (defn-form? form)
                            (eq? (defn-form-name form) 'lookup)))
      form))
  (define contract
    (hash-ref (program-semantic-contracts prog)
              (car (defn-form-params lookup-form))))
  (check-equal? (collection-contract-kind contract) 'Map)
  (check-equal? (type->string (collection-contract-key-type contract))
                "(Vec Int)")
  (check-equal? (type->string (collection-contract-value-type contract))
                "String")
  (check-equal? (collection-contract-equality contract) 'clojure-value)
  (check-equal? (collection-contract-hashing contract) 'clojure-hash)
  (check-equal? (collection-contract-order contract) 'unspecified)
  (check-equal? (collection-contract-layout contract) 'target-private))

(test-case "collection checker names the built-in Vec extern ABI"
  (define prog
    (parse-program
     (map (lambda (datum) (datum->syntax #f datum))
          `((define-target zig)
            (ns collection-contract-extern)
            (declare-extern app.rt/size
              ,(br '(Vec String) '-> 'Int))))))
  (type-check! prog)
  (define extern-type (hash-ref (program-externs prog) 'app.rt/size))
  (define vec-type (car (type-fn-params extern-type)))
  (define contract
    (hash-ref (program-semantic-contracts prog) vec-type))
  (check-equal? (collection-contract-layout contract)
                '(abi-record beagle.vec 1)))

;; --- semantic contract 5: allocation region and allocation failure ----------

(test-case "allocation contract pins CLJ bytes and emits compiling Zig"
  (define clj-src
    (semantic-golden 'clj allocation-failure-src "allocation-failure"))
  (define zig-src
    (semantic-golden 'zig allocation-failure-src "allocation-failure"))
  (when CLOJURE
    (define clj-file (make-temporary-file "semantic-allocation-failure~a.clj"))
    (dynamic-wind
      void
      (lambda ()
        (call-with-output-file clj-file
          #:exists 'replace
          (lambda (p)
            (display clj-src p)
            (display
             "\n(prn [(map-abort [1 2 3]) (map-fallible nil [4 5]) (string-abort \"beagle-\" \"zig\")])\n"
             p)))
        (define-values (ok? out err)
          (run-command-output CLOJURE (path->string clj-file)))
        (check-true ok? err)
        (check-equal? out "[[2 3 4] [5 6] \"beagle-zig\"]\n"))
      (lambda () (delete-file clj-file))))
  (when NODE
    (define js-src (compile-semantic-target-src 'js allocation-failure-src))
    (define runnable
      (regexp-replace* #px"(?m:^import [^\n]*\n)" js-src ""))
    (define-values (ok? out err)
      (run-command-output
       NODE "--input-type=module" "-e"
       (string-append
        runnable
        "\nconsole.log(JSON.stringify([map_abort([1, 2, 3]), map_fallible(null, [4, 5]), string_abort(\"beagle-\", \"zig\")]));\n")))
    (check-true ok? err)
    (check-equal? out "[[2,3,4],[5,6],\"beagle-zig\"]\n"))
  (when ZIG
    (check-true (zig-compiles? zig-src "semantic-allocation-failure"))
    (check-true
     (zig-tests?
      zig-src
      #<<ZIG
test "allocation semantic contract success and injected failure" {
    var success_storage: [256]u8 = undefined;
    var success_fba = std.heap.FixedBufferAllocator.init(&success_storage);
    var success_rng = rt.Splitmix64.init(1);
    var success_ctx = rt.Ctx{
        .tick = success_fba.allocator(),
        .rng = &success_rng,
    };
    const mapped = mapAbort(&success_ctx, &.{ 1, 2, 3 });
    try std.testing.expectEqualSlices(i64, &.{ 2, 3, 4 }, mapped);
    try std.testing.expectEqualStrings(
        "beagle-zig",
        stringAbort(&success_ctx, "beagle-", "zig"),
    );
    const fallible = try mapFallible(&success_ctx, &.{ 4, 5 });
    try std.testing.expectEqualSlices(i64, &.{ 5, 6 }, fallible);

    var failed_storage: [1]u8 = undefined;
    var failed_fba = std.heap.FixedBufferAllocator.init(&failed_storage);
    var failed_rng = rt.Splitmix64.init(2);
    var failed_ctx = rt.Ctx{
        .tick = failed_fba.allocator(),
        .rng = &failed_rng,
    };
    try std.testing.expectError(
        error.OutOfMemory,
        mapFallible(&failed_ctx, &.{ 7, 8 }),
    );
}
ZIG
      "semantic-allocation-failure-behavior"))))

(define (allocation-contract-rejection? e)
  (and (beagle-diagnostic? e)
       (eq? (beagle-diagnostic-kind e) 'allocation-contract)))

(test-case "allocation checker rejects a typed failure without AllocationError"
  (check-exn
   allocation-contract-rejection?
   (lambda ()
     (check-zig-forms
      '(defn bad [ctx #%: Ctx xs #%: (Vec Int)] -> (Vec Int)
         :raises IOError
         (mapv (fn [x #%: Int] -> Int x) xs))))))

(test-case "allocation checker records region and failure on boundaries and expressions"
  (define prog
    (parse-semantic-target-src 'zig allocation-failure-src))
  (type-check! prog)
  (define (named-defn name)
    (for/first ([form (in-list (program-forms prog))]
                #:when (and (defn-form? form)
                            (eq? (defn-form-name form) name)))
      form))
  (define abort-form (named-defn 'map-abort))
  (define fallible-form (named-defn 'map-fallible))
  (define string-form (named-defn 'string-abort))
  (define contracts (program-semantic-contracts prog))
  (define abort-contract (hash-ref contracts abort-form))
  (define fallible-contract (hash-ref contracts fallible-form))
  (define fallible-call (car (defn-form-body fallible-form)))
  (define string-call (car (defn-form-body string-form)))
  (check-equal? (allocation-contract-region abort-contract) 'caller)
  (check-equal? (allocation-contract-failure abort-contract) 'abort)
  (check-equal? (allocation-contract-region fallible-contract) 'tick)
  (define fallible-failure (allocation-contract-failure fallible-contract))
  (check-equal? (car fallible-failure) 'raises)
  (check-equal? (type->string (cadr fallible-failure)) "AllocationError")
  (check-equal? (hash-ref contracts fallible-call) fallible-contract)
  (check-equal? (allocation-contract-region (hash-ref contracts string-call))
                'caller))

(test-case "zig allocator ABI propagates through local calls and leaves pure siblings alone"
  (define xs-param (br 'xs ANN-MARKER '(Vec Int)))
  (define mapper
    `(fn ,(br 'x ANN-MARKER 'Int) -> Int (inc x)))
  (define out
    (compile-zig-forms
     `(defn leaf ,xs-param -> (Vec Int) (mapv ,mapper xs))
     `(defn middle ,xs-param -> (Vec Int) (leaf xs))
     `(defn top ,xs-param -> (Vec Int) (middle xs))
     `(defn pure ,(br 'x ANN-MARKER 'Int) -> Int (inc x))))
  (for ([name (in-list '("leaf" "middle" "top"))])
    (check-regexp-match
     (regexp (format "pub fn ~a\\(__ctx: \\*rt\\.Ctx" name))
     out))
  (check-regexp-match #rx"return leaf\\(__ctx, xs\\);" out)
  (check-regexp-match #rx"return middle\\(__ctx, xs\\);" out)
  (check-regexp-match #rx"pub fn pure\\(x: i64\\) i64" out)
  (check-false (regexp-match? #rx"pub fn pure\\(__ctx" out)))

(test-case "zig runtime-valued Vec uses caller storage and propagates fixed-buffer OOM"
  (define out
    (compile-zig-forms
     `(defn pair ,(br 'left ANN-MARKER 'String 'right ANN-MARKER 'String)
        -> (Vec String)
        :raises AllocationError
        ,(br 'left 'right))))
  (check-regexp-match
   #rx"pub fn pair\\(__ctx: \\*rt\\.Ctx.*Allocator\\.Error!"
   out)
  (check-false (regexp-match? #rx"cliAlloc|cli_arena_state" out))
  (when ZIG
    (check-true
     (zig-tests?
      out
      #<<ZIG
test "caller-owned Vec storage and OOM" {
    var success_storage: [64]u8 = undefined;
    var success_fba = std.heap.FixedBufferAllocator.init(&success_storage);
    var success_rng = rt.Splitmix64.init(1);
    var success_ctx = rt.Ctx{
        .tick = success_fba.allocator(),
        .rng = &success_rng,
    };
    const values = try pair(&success_ctx, "left", "right");
    try std.testing.expectEqualStrings("left", values[0]);
    try std.testing.expectEqualStrings("right", values[1]);

    var failed_storage: [1]u8 = undefined;
    var failed_fba = std.heap.FixedBufferAllocator.init(&failed_storage);
    var failed_rng = rt.Splitmix64.init(2);
    var failed_ctx = rt.Ctx{
        .tick = failed_fba.allocator(),
        .rng = &failed_rng,
    };
    try std.testing.expectError(
        error.OutOfMemory,
        pair(&failed_ctx, "left", "right"),
    );
}
ZIG
      "caller-owned-vec-oom"))))

(test-case "zig static top-level Set borrows storage without an allocator"
  (define out
    (compile-zig-forms
     `(def names #%: (Set Keyword) ,(st ':alpha ':beta))
     '(defn size [] -> Int (count names))))
  (check-regexp-match
   #rx"ValueSet\\(rt\\.Keyword\\)\\.fromStatic"
   out)
  (check-false (regexp-match? #rx"cliAlloc|cli_arena_state|__ctx" out)))

(test-case "zig fallible Map and Set literals fail closed"
  (for ([return-type (in-list '((Map Keyword Int) (Set Keyword)))]
        [literal (in-list (list (mp ':alpha 1) (st ':alpha)))])
    (check-exn
     (lambda (e)
       (and (allocation-contract-rejection? e)
            (regexp-match? #rx"Map/Set literals" (exn-message e))))
     (lambda ()
       (check-zig-forms
        `(defn bad ,(br) -> ,return-type
           :raises AllocationError
           ,literal))))))

(test-case "zig allocation aliases receive the hidden caller context"
  (define out
    (compile-zig-string
     (string-append
      "(ns allocator.aliases (:require [clojure.string :as str] [babashka.fs :as fs]))\n"
      "(defn lower [s: String] -> String (str/lower-case s))\n"
      "(defn fix [s: String] -> String (str/replace s \"a\" \"b\"))\n"
      "(defn lines [s: String] -> (Vec String) (str/split-lines s))\n"
      "(defn under\n  [a: String\n   b: String] -> String\n  (fs/path a b))\n")))
  (for ([name (in-list '("lower" "fix" "lines" "under"))])
    (check-regexp-match
     (regexp (format "pub fn ~a\\(__ctx: \\*rt\\.Ctx" name))
     out))
  (check-regexp-match #rx"rt\\.lower_case\\(__ctx\\.tick, s\\)" out)
  (check-regexp-match #rx"rt\\.replace\\(__ctx\\.tick, s" out)
  (check-regexp-match #rx"rt\\.split_lines\\(__ctx\\.tick, s\\)" out)
  (check-regexp-match #rx"rt\\.path\\(__ctx\\.tick, a, b\\)" out))

(test-case "zig function names containing = use collision-free escaped identifiers"
  (define out
    (compile-zig-string
     (string-append
      "(ns zig.function-names)\n"
      "(defn store-value=?\n  [a: Int\n   b: Int] -> Bool\n  (= a b))\n"
      "(defn store-value=\n  [a: Int\n   b: Int] -> Bool\n  false)\n"
      "(defn main [] -> Nil\n"
      "  (do (println (store-value=? 1 1))\n"
      "      (println (store-value= 1 1))))\n")))
  (check-regexp-match #rx"pub fn @\"store-value=\\?\"" out)
  (check-regexp-match #rx"pub fn @\"store-value=\"" out)
  (check-regexp-match #rx"@\"store-value=\\?\"\\(1, 1\\)" out)
  (check-regexp-match #rx"@\"store-value=\"\\(1, 1\\)" out)
  (check-equal? (zig-build-exe-and-run out) "true\nfalse\n"))

(test-case "zig string literals use Zig control escapes without changing printable Unicode"
  (define controls
    (list->string
     (map integer->char '(0 1 7 8 11 12 27 31 127))))
  (define stable "printable λ🙂 \"quoted\" \\ slash\n\t\r")
  (define out
    (compile-zig-forms
     `(def controls #%: String ,controls)
     `(def stable #%: String ,stable)))
  (check-true
   (string-contains?
    out
    "pub const controls: []const u8 = \"\\x00\\x01\\x07\\x08\\x0b\\x0c\\x1b\\x1f\\x7f\";"))
  (check-true
   (string-contains?
    out
    (format "pub const stable: []const u8 = ~v;" stable)))
  (when ZIG
    (check-true (zig-compiles? out "string-control-escapes"))))

(test-case "zig allocating main owns one local arena while pure main stays direct"
  (define pure
    (compile-zig-forms '(defn main [] -> Nil nil)))
  (check-regexp-match #rx"pub fn main\\(\\) void" pure)
  (check-false (regexp-match? #rx"__beagle_main|ArenaAllocator" pure))
  (define allocating
    (compile-zig-forms
     '(define-mode strict)
     '(defn store-roundtrip?! [] -> Nil (println "ok"))
     '(defn main [] -> Nil (store-roundtrip?!))))
  (check-regexp-match
   #rx"pub fn __beagle_main\\(__ctx: \\*rt\\.Ctx\\) void"
   allocating)
  (check-regexp-match #rx"pub fn main\\(\\) void" allocating)
  (check-regexp-match #rx"ArenaAllocator\\.init\\(std\\.heap\\.page_allocator\\)"
                      allocating)
  (check-regexp-match #rx"defer __arena\\.deinit\\(\\);" allocating)
  (check-regexp-match #rx"__beagle_main\\(&__ctx\\);" allocating))

(test-case "zig core runtime owns no global value allocator"
  (define runtime (file->string kernel-rt))
  (check-false (regexp-match? #rx"cliAlloc|cli_arena_state" runtime)))

(test-case "zig non-optional unions use deterministic tagged storage"
  (define value-param (br 'value ANN-MARKER '(U String Int)))
  (define nullable-param (br 'value ANN-MARKER '(U String Int Nil)))
  (define out
    (compile-zig-forms
     `(defn number-or-zero ,value-param -> Int
        (if (integer? value) value 0))
     `(defn is-missing? ,nullable-param -> Bool
        (nil? value))
     `(defn widen ,value-param -> (U String Int Bool)
        value)
     `(defn wrap ,value-param -> (Map Keyword (U String Int))
        ,(mp ':value 'value))))
  (check-regexp-match #rx"pub const Union0 = union\\(enum\\)" out)
  (check-regexp-match #rx"rt\\.widen_union\\(Union2, value\\)" out)
  (check-regexp-match #rx"rt\\.is_nil\\(value\\)" out)
  (when ZIG
    (check-true
     (zig-tests?
      out
      #<<ZIG
test "tagged unions narrow, widen, and survive map storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rng = rt.Splitmix64.init(1);
    var ctx = rt.Ctx{ .tick = arena.allocator(), .rng = &rng };

    try std.testing.expectEqual(
        @as(i64, 7),
        numberOrZero(Union0{ .int = 7 }),
    );
    try std.testing.expectEqual(
        @as(i64, 0),
        numberOrZero(Union0{ .string = "ok" }),
    );
    try std.testing.expect(isMissing(Union1{ .nil = {} }));
    try std.testing.expect(!isMissing(Union1{ .string = "present" }));

    const widened = widen(Union0{ .int = 11 });
    switch (widened) {
        .int => |value| try std.testing.expectEqual(@as(i64, 11), value),
        else => return error.TestUnexpectedResult,
    }

    const wrapped = wrap(&ctx, Union0{ .int = 13 });
    const stored = wrapped.get(rt.keyword("", "value")).?;
    switch (stored) {
        .int => |value| try std.testing.expectEqual(@as(i64, 13), value),
        else => return error.TestUnexpectedResult,
    }
}
ZIG
      "tagged-union-storage"))))

;; --- match on a closed union ------------------------------------------------

(define union-match-src
  (string-append
   "(ns zig.union-match)\n"
   "(defrecord Circle [(radius: Int)])\n"
   "(defrecord Square [(side: Int)])\n"
   "(defn describe [shape: (U Circle Square Int)] -> String\n"
   "  (match shape\n"
   "    [(Circle r) (str \"circle:\" r)]\n"
   "    [(Square s) (str \"square:\" s)]\n"
   "    [_ \"scalar\"]))\n"
   "(defn tag-of [shape: (U Circle Square Int)] -> String\n"
   "  (match shape\n"
   "    [(Circle ignored) \"circle\"]\n"
   "    [other (describe other)]))\n"
   "(defn measure [shape: (U Circle Square)] -> Int\n"
   "  (match shape\n"
   "    [(Circle r) (* r 2)]\n"
   "    [(Square s) (* s s)]))\n"
   "(defn main [] -> Nil\n"
   "  (println (str (describe (->Circle 3)) \":\"\n"
   "                (describe (->Square 4)) \":\"\n"
   "                (describe 7) \":\"\n"
   "                (tag-of (->Circle 9)) \":\"\n"
   "                (tag-of (->Square 4)) \":\"\n"
   "                (measure (->Circle 5)) \":\"\n"
   "                (measure (->Square 6)))))\n"))

(test-case "zig match on a closed union switches on the tag"
  (define out (compile-zig-string union-match-src))
  ;; two RECORD alternatives of one union — no type predicate can tell them
  ;; apart, so the lowering must go through the tag.
  (check-regexp-match
   #rx"switch \\(__blk1_value\\) \\{ \\.circle => \\|__blk1_payload\\| blk2: \\{ const r = __blk1_payload\\.radius;"
   out)
  (check-regexp-match #rx"\\.square => \\|__blk1_payload\\| blk3: \\{ const s = __blk1_payload\\.side;" out)
  (check-regexp-match #rx"else => \"scalar\"," out)
  ;; a binder the arm never mentions is dropped (Zig rejects an unused local)
  (check-false (regexp-match? #rx"const ignored" out))
  ;; the default arm rebinds the whole union value — else has no payload
  (check-regexp-match #rx"else => blk[0-9]+: \\{ const other = __blk[0-9]+_value; " out)
  ;; measure covers every alternative: Zig rejects an else prong that covers
  ;; nothing, so none is emitted.
  (define measure-body
    (cadr (regexp-match #px"pub fn measure\\(shape: Union1\\) i64 \\{\n([^\n]*)\n" out)))
  (check-false (regexp-match? #rx"else =>" measure-body)))

(when ZIG
  (test-case "zig closed-union match compiles, runs, and extracts payloads"
    (check-equal?
     (zig-build-exe-and-run (compile-zig-string union-match-src))
     "circle:3:square:4:scalar:circle:square:4:10:36\n")))

;; --- semantic contract 6: ownership and lifetime ----------------------------

(test-case "ownership contract pins CLJ bytes and emits compiling Zig"
  (define clj-src
    (semantic-golden 'clj ownership-lifetime-src "ownership-lifetime"))
  (define zig-src
    (semantic-golden 'zig ownership-lifetime-src "ownership-lifetime"))
  (when CLOJURE
    (define clj-file (make-temporary-file "semantic-ownership-lifetime~a.clj"))
    (dynamic-wind
      void
      (lambda ()
        (call-with-output-file clj-file
          #:exists 'replace
          (lambda (p)
            (display clj-src p)
            (display "\n(prn (observe nil))\n" p)))
        (define-values (ok? out err)
          (run-command-output CLOJURE (path->string clj-file)))
        (check-true ok? err)
        (check-equal? out "16\n"))
      (lambda () (delete-file clj-file))))
  (when NODE
    (define js-src (compile-semantic-target-src 'js ownership-lifetime-src))
    (define runnable
      (regexp-replace*
       #rx"['\"]beagle/core.js['\"]"
       js-src
       (format "\"file://~a\""
               (path->string (build-path js-runtime-dir "core.js")))))
    (define-values (ok? out err)
      (run-command-output
       NODE "--input-type=module" "-e"
       (string-append runnable "\nconsole.log(observe(null));\n")))
    (check-true ok? err)
    (check-equal? out "16\n"))
  (when ZIG
    (check-true (zig-compiles? zig-src "semantic-ownership-lifetime"))
    (check-true
     (zig-tests?
      zig-src
      #<<ZIG
test "ownership semantic contract behavior and explicit promotion" {
    var storage: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var rng = rt.Splitmix64.init(1);
    var ctx = rt.Ctx{
        .tick = fba.allocator(),
        .rng = &rng,
    };
    try std.testing.expectEqual(@as(i64, 16), observe(&ctx));

    const copied = promote(World{
        .cell = Cell{ .value = 5 },
        .score = 11,
    });
    try std.testing.expectEqual(@as(i64, 5), copied.cell.value);
    try std.testing.expectEqual(@as(i64, 11), copied.score);
}
ZIG
      "semantic-ownership-lifetime-behavior"))))

(define (ownership-contract-rejection? e)
  (and (beagle-diagnostic? e)
       (eq? (beagle-diagnostic-kind e) 'ownership-contract)))

(test-case "ownership checker records storage, lifetime, and transfer"
  (define prog
    (parse-semantic-target-src 'zig ownership-lifetime-src))
  (type-check! prog)
  (define contracts (program-semantic-contracts prog))
  (define world-tick-form
    (for/first ([form (in-list (program-forms prog))]
                #:when (and (defn-form? form)
                            (eq? (defn-form-name form) 'world-tick)))
      form))
  (define records
    (for/hash ([form (in-list (program-forms prog))]
               #:when (record-form? form))
      (values (record-form-name form) form)))
  (define return-contract (hash-ref contracts world-tick-form))
  (check-equal? (ownership-contract-storage return-contract) 'owned)
  (check-equal? (ownership-contract-lifetime return-contract) 'process)
  (check-equal? (ownership-contract-transfer return-contract) 'copy)
  (for ([parameter (in-list (defn-form-params world-tick-form))])
    (define contract (hash-ref contracts parameter))
    (check-equal? (ownership-contract-storage contract) 'borrowed)
    (check-equal? (ownership-contract-lifetime contract) 'tick)
    (check-equal? (ownership-contract-transfer contract) 'retain))
  (for* ([record-name (in-list '(World Cell))]
         [field (in-list
                 (record-form-fields (hash-ref records record-name)))])
    (define contract (hash-ref contracts field))
    (check-equal? (ownership-contract-storage contract) 'owned)
    (check-equal? (ownership-contract-lifetime contract) 'process)
    (check-equal? (ownership-contract-transfer contract) 'copy)))

(test-case "ownership checker rejects returned borrowed storage on GC targets"
  (define datums
    (list
     '(define-target clj)
     '(ns ownership-contract-rejection)
     `(defrecord World ,(br 'name ANN-MARKER 'String))
     `(defn world-tick
        ,(br 'ctx ANN-MARKER 'Ctx 'world ANN-MARKER 'World)
        -> World
        world)))
  (check-exn
   ownership-contract-rejection?
   (lambda ()
     (type-check!
      (parse-program
       (map (lambda (datum) (datum->syntax #f datum)) datums))))))

(test-case "ownership lowering fails closed without the checked side-table fact"
  (define prog
    (parse-semantic-target-src 'zig ownership-lifetime-src))
  (type-check! prog)
  (define world-tick-form
    (for/first ([form (in-list (program-forms prog))]
                #:when (and (defn-form? form)
                            (eq? (defn-form-name form) 'world-tick)))
      form))
  (hash-remove! (program-semantic-contracts prog) world-tick-form)
  (check-exn
   #rx"ownership contract for world-tick"
   (lambda () (emit-program prog))))

;; --- semantic contract 7: typed errors and payloads --------------------------

(test-case "typed error CLJ diff is exactly the carrier declaration"
  (define (compile-clj-forms . datums)
    (define forms
      (map (lambda (d) (datum->syntax #f d))
           (cons '(define-target clj) datums)))
    (define prog (parse-program forms))
    (type-check! prog)
    (emit-program prog))
  (define params
    (br 'missing ANN-MARKER 'Bool
        'mismatch ANN-MARKER 'Bool
        'path ANN-MARKER 'String))
  (define body
    `(cond
       missing
       (throw (ex-info "missing" ,(mp ':path 'path ':refusal 'true)))
       mismatch
       (throw (ex-info "mismatch" ,(mp ':path 'path ':refusal 'true)))
       :else
       "roll-back"))
  (define baseline
    (compile-clj-forms
     '(ns semantic-contract.carrier-diff)
     `(defn classify ,params -> String ,body)))
  (define carried
    (compile-clj-forms
     '(ns semantic-contract.carrier-diff)
     `(defunion :throwable RewriteError
        (RewriteFailure
         ,(br 'message ANN-MARKER 'String
              'path ANN-MARKER 'String
              'refusal ANN-MARKER 'Bool)))
     `(defn classify ,params -> String :raises RewriteError ,body)))
  (check-equal?
   carried
   (string-replace
    baseline
    "(defn ^String classify"
    (string-append
     ";; error RewriteError = RewriteFailure\n"
     "(defrecord RewriteFailure [message path refusal])\n\n"
     "(defn rewritefailure-message [r] (:message r))\n\n"
     "(defn rewritefailure-path [r] (:path r))\n\n"
     "(defn rewritefailure-refusal [r] (:refusal r))\n\n"
     "(defn ^String classify"))))

(test-case "typed error contract pins CLJ bytes and emits compiling Zig"
  (define clj-src
    (semantic-golden 'clj typed-errors-src "typed-errors"))
  (define zig-src
    (semantic-golden 'zig typed-errors-src "typed-errors"))
  (define composite-clj-src
    (semantic-golden 'clj composite-raises-src "composite-raises"))
  (define composite-zig-src
    (semantic-golden 'zig composite-raises-src "composite-raises"))
  (when CLOJURE
    (define clj-file (make-temporary-file "semantic-typed-errors~a.clj"))
    (dynamic-wind
      void
      (lambda ()
        (call-with-output-file clj-file
          #:exists 'replace
          (lambda (p)
            (display clj-src p)
            (display
             #<<CLJ

(defn legacy-classify [missing mismatch path]
  (cond
    missing (throw (ex-info "missing" {:path path :refusal true}))
    mismatch (throw (ex-info "mismatch" {:path path :refusal true}))
    :else "roll-back"))
(defn observe [f missing mismatch path]
  (try
    {:ok (f missing mismatch path)}
    (catch clojure.lang.ExceptionInfo e
      {:class (class e) :message (ex-message e) :data (ex-data e)})))
(prn [(= (observe classify false false "/tmp/coord")
         (observe legacy-classify false false "/tmp/coord"))
      (= (observe classify true false "/tmp/coord")
         (observe legacy-classify true false "/tmp/coord"))
      (= (observe classify false true "/tmp/coord")
         (observe legacy-classify false true "/tmp/coord"))])
(prn [(classify false false "/tmp/coord")
      (propagate false false "/tmp/coord")
      (render true false "/tmp/coord")
      (render false true "/tmp/coord")])
CLJ
             p)))
        (define-values (ok? out err)
          (run-command-output CLOJURE (path->string clj-file)))
        (check-true ok? err)
        (check-equal?
         out
         "[true true true]\n[\"roll-back\" \"roll-back\" \"missing\" \"mismatch\"]\n"))
      (lambda () (delete-file clj-file))))
  (when NODE
    (define js-src (compile-semantic-target-src 'js typed-errors-src))
    (define runnable
      (regexp-replace* #px"(?m:^import [^\n]*\n)" js-src ""))
    (define-values (ok? out err)
      (run-command-output
       NODE "--input-type=module" "-e"
       (string-append
        runnable
        #<<JS

console.log(JSON.stringify([
  classify(false, false, "/tmp/coord"),
  propagate(false, false, "/tmp/coord"),
  render(true, false, "/tmp/coord"),
  render(false, true, "/tmp/coord"),
]));
try {
  classify(true, false, "/tmp/coord");
} catch (e) {
  console.log(JSON.stringify([e.message, e.data.path, e.data.refusal]));
}
try {
  classify(false, true, "/tmp/coord");
} catch (e) {
  console.log(JSON.stringify([e.message, e.data.path, e.data.refusal]));
}
JS
        )))
    (check-true ok? err)
    (check-equal?
     out
     (string-append
      "[\"roll-back\",\"roll-back\",\"missing\",\"mismatch\"]\n"
      "[\"missing\",\"/tmp/coord\",true]\n"
      "[\"mismatch\",\"/tmp/coord\",true]\n")))
  (when ZIG
    (check-true (zig-compiles? zig-src "semantic-typed-errors"))
    (check-true
     (zig-compiles? composite-zig-src "semantic-composite-raises"))
    (check-true
     (zig-tests?
      composite-zig-src
      #<<ZIG
test "allocation and domain errors compose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rng = rt.Splitmix64.init(1);
    var ctx = rt.Ctx{ .tick = arena.allocator(), .rng = &rng };

    var success_errors = RewriteCrashErrorCarrier{};
    const result = try classifyRewriteCrash(
        &ctx,
        &success_errors,
        "/tmp/coord",
        7,
        7,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    try std.testing.expect(rt.eq(result, rt.keyword("", "roll-back")));
    try std.testing.expect(success_errors.payload == null);

    var crash_errors = RewriteCrashErrorCarrier{};
    try std.testing.expectError(
        error.RewriteCrash,
        classifyRewriteCrash(
            &ctx,
            &crash_errors,
            "/tmp/coord",
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
        ),
    );
    switch (crash_errors.payload.?) {
        .rewrite_crash => |payload| {
            try std.testing.expectEqualStrings(
                "rewrite intent present but /tmp/coord does not exist — refusing to classify",
                payload.message,
            );
            try std.testing.expectEqualStrings("/tmp/coord", payload.path);
            try std.testing.expect(payload.refusal);
        },
    }
}
ZIG
      "semantic-composite-raises-behavior"))
    (check-true
     (zig-tests?
      zig-src
      #<<ZIG
test "typed error success, payload, rescue, and propagation" {
    var errors = RewriteErrorCarrier{};
    try std.testing.expectEqualStrings(
        "roll-back",
        try classify(&errors, false, false, "/tmp/coord"),
    );
    try std.testing.expect(errors.payload == null);

    try std.testing.expectError(
        error.RewriteFailure,
        classify(&errors, true, false, "/tmp/coord"),
    );
    switch (errors.payload.?) {
        .rewrite_failure => |payload| {
            try std.testing.expectEqualStrings("missing", payload.message);
            try std.testing.expectEqualStrings("/tmp/coord", payload.path);
            try std.testing.expect(payload.refusal);
        },
    }

    var mismatch_errors = RewriteErrorCarrier{};
    try std.testing.expectError(
        error.RewriteFailure,
        classify(&mismatch_errors, false, true, "/tmp/coord"),
    );
    switch (mismatch_errors.payload.?) {
        .rewrite_failure => |payload| {
            try std.testing.expectEqualStrings("mismatch", payload.message);
            try std.testing.expectEqualStrings("/tmp/coord", payload.path);
            try std.testing.expect(payload.refusal);
        },
    }

    var propagated = RewriteErrorCarrier{};
    try std.testing.expectError(
        error.RewriteFailure,
        propagate(&propagated, true, false, "/tmp/coord"),
    );
    try std.testing.expect(propagated.payload != null);
    try std.testing.expectEqualStrings(
        "missing",
        render(true, false, "/tmp/coord"),
    );
    try std.testing.expectEqualStrings(
        "mismatch",
        render(false, true, "/tmp/coord"),
    );
}
ZIG
      "semantic-typed-errors-behavior"))))

(define (error-contract-rejection? e)
  (and (beagle-diagnostic? e)
       (eq? (beagle-diagnostic-kind e) 'error-contract)))

(test-case "typed error checker records type, payload layout, and mode"
  (define prog (parse-semantic-target-src 'zig typed-errors-src))
  (type-check! prog)
  (define contracts (program-semantic-contracts prog))
  (define classify-form
    (for/first ([form (in-list (program-forms prog))]
                #:when (and (defn-form? form)
                            (eq? (defn-form-name form) 'classify)))
      form))
  (define contract (hash-ref contracts classify-form))
  (check-equal? (type->string (error-contract-error-type contract))
                "RewriteError")
  (check-equal? (error-contract-mode contract) 'native-error-union)
  (check-equal?
   (for/list ([variant (in-list (error-contract-payload-layout contract))])
     (cons (car variant)
           (for/list ([field (in-list (cdr variant))])
             (cons (param-name field)
                   (type->string (param-type field))))))
   '((RewriteFailure
      (message . "String")
      (path . "String")
      (refusal . "Bool"))))
  (define allocation-prog
    (parse-semantic-target-src 'zig allocation-failure-src))
  (type-check! allocation-prog)
  (define single-raise-summary
    (string-append
     "map-fallible :raises "
     (type->string
      (defn-form-raises
       (for/first ([form (in-list (program-forms allocation-prog))]
                   #:when (and (defn-form? form)
                               (eq? (defn-form-name form) 'map-fallible)))
         form)))
     "\nclassify :raises "
     (type->string (defn-form-raises classify-form))
     "\n"))
  (check-equal?
   single-raise-summary
   (file->string
    (build-path semantic-contract-dir "single-raises.checker-golden"))))

(test-case "typed errors preserve namespaced host payload keys"
  (define forms
    (list
     '(ns semantic-contract.namespaced-error)
     '(defunion :throwable RewriteCrashError
        (RewriteCrash
         [message #%: String
          path #%: String
          doctor-refusal #%: Bool]))
     `(defn classify-ns [path #%: String] -> String
        :raises RewriteCrashError
        (throw
         (ex-info
          "refusal"
          ,(mp ':path 'path ':fram/doctor-refusal 'true))))
     '(defn render-ns [path #%: String] -> String
        (rescue
         (classify-ns path)
         err
         (if (:doctor-refusal err) "refused" "allowed")))))
  (define clj-src (apply compile-target-forms 'clj forms))
  (check-true
   (string-contains?
    clj-src
    "(:fram/doctor-refusal (ex-data err__exception))"))
  (check-true
   (string-contains?
    clj-src
    "(defrecord RewriteCrash [message path doctor-refusal])"))
  (when CLOJURE
    (define clj-file
      (make-temporary-file "semantic-namespaced-error~a.clj"))
    (dynamic-wind
      void
      (lambda ()
        (call-with-output-file clj-file
          #:exists 'replace
          (lambda (p)
            (display clj-src p)
            (display
             #<<CLJ

(prn
 [(render-ns "/tmp/coord")
  (try
    (classify-ns "/tmp/coord")
    (catch clojure.lang.ExceptionInfo e
      [(:path (ex-data e))
       (:fram/doctor-refusal (ex-data e))
       (contains? (ex-data e) :doctor-refusal)]))])
CLJ
             p)))
        (define-values (ok? out err)
          (run-command-output CLOJURE (path->string clj-file)))
        (check-true ok? err)
        (check-equal? out "[\"refused\" [\"/tmp/coord\" true false]]\n"))
      (lambda () (delete-file clj-file))))
  (when NODE
    (define js-src (apply compile-target-forms 'js forms))
    (check-true
     (string-contains?
      js-src
      "err__exception.data[\"fram/doctor_refusal\"]"))
    (define runnable
      (regexp-replace* #px"(?m:^import [^\n]*\n)" js-src ""))
    (define-values (ok? out err)
      (run-command-output
       NODE "--input-type=module" "-e"
       (string-append
        runnable
        #<<JS

console.log(JSON.stringify([
  render_ns("/tmp/coord"),
  (() => {
    try {
      classify_ns("/tmp/coord");
    } catch (e) {
      return [
        e.data.path,
        e.data["fram/doctor_refusal"],
        Object.hasOwn(e.data, "doctor_refusal"),
      ];
    }
  })(),
]));
JS
        )))
    (check-true ok? err)
    (check-equal? out "[\"refused\",[\"/tmp/coord\",true,false]]\n"))
  (when ZIG
    (define zig-src (apply compile-target-forms 'zig forms))
    (check-true
     (zig-tests?
      zig-src
      #<<ZIG
test "namespaced host key maps to the declared payload field" {
    try std.testing.expectEqualStrings("refused", renderNs("/tmp/coord"));

    var errors = RewriteCrashErrorCarrier{};
    try std.testing.expectError(
        error.RewriteCrash,
        classifyNs(&errors, "/tmp/coord"),
    );
    switch (errors.payload.?) {
        .rewrite_crash => |payload| {
            try std.testing.expectEqualStrings("/tmp/coord", payload.path);
            try std.testing.expect(payload.doctor_refusal);
        },
    }
}
ZIG
      "semantic-namespaced-error"))))

(test-case "typed errors reject ambiguous host-key mappings"
  (check-exn
   #rx"mapped to both"
   (lambda ()
     (check-zig-forms
      '(defunion :throwable RewriteCrashError
         (RewriteCrash
          [message #%: String
           path #%: String
           doctor-refusal #%: Bool]))
      `(defn inconsistent
         [namespaced #%: Bool path #%: String]
         -> String
         :raises RewriteCrashError
         (if namespaced
             (throw
              (ex-info
               "namespaced"
               ,(mp ':path 'path ':fram/doctor-refusal 'true)))
             (throw
              (ex-info
               "unqualified"
               ,(mp ':path 'path ':doctor-refusal 'true)))))))))

(test-case "typed error checker rejects throw without :raises"
  (check-exn
   error-contract-rejection?
   (lambda ()
     (check-zig-forms
      '(defunion :throwable RewriteError
         (RewriteFailure [message #%: String path #%: String refusal #%: Bool]))
      `(defn bad [path #%: String] -> String
         (throw (ex-info "missing" ,(mp ':path 'path ':refusal 'true))))))))

(test-case "typed error checker rejects a wrong payload type"
  (check-exn
   error-contract-rejection?
   (lambda ()
     (check-zig-forms
      '(defunion :throwable RewriteError
         (RewriteFailure [message #%: String path #%: String refusal #%: Bool]))
      `(defn bad [path #%: String] -> String
         :raises RewriteError
         (throw (ex-info "missing" ,(mp ':path 'path ':refusal "yes"))))))))

(test-case "typed error checker rejects an unhandled throwing call"
  (check-exn
   error-contract-rejection?
   (lambda ()
     (check-zig-forms
      '(defunion :throwable RewriteError
         (RewriteFailure [message #%: String path #%: String refusal #%: Bool]))
      `(defn fail [path #%: String] -> String
         :raises RewriteError
         (throw (ex-info "missing" ,(mp ':path 'path ':refusal 'true))))
      '(defn main [path #%: String] -> String
         (fail path))))))

;; --- determinism: same input → byte-identical output --------------------------

(define extern-union-fixture
  (build-path fixtures-dir 'up "zig-determinism" "extern-union-order.bgl"))

;; "Union0: int string" — positional name plus alternatives in emission order.
(define (emitted-union-decls zig-src)
  (for/list ([m (in-list (regexp-match*
                          #px"pub const (Union[0-9]+) = union\\(enum\\) \\{([^}]*)\\}"
                          zig-src
                          #:match-select values))])
    (format "~a: ~a"
            (cadr m)
            (string-join
             (regexp-match* #px"([a-z_][a-z0-9_]*):" (caddr m) #:match-select cadr)
             " "))))

;; Emit in a FRESH racket process: same pinned racket, but the compiler is
;; required by ABSOLUTE path so a worktree never resolves beagle/* through the
;; global pkg links to the canonical checkout.
(define (emit-zig-in-fresh-process src-path)
  (define private-dir
    (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
      (simplify-path (build-path dir 'up 'up "beagle-lib" "private"))))
  (define (lib name) (path->string (build-path private-dir name)))
  (define eval-str
    (format
     (string-append
      "(require (file ~s) (file ~s) (file ~s))"
      "(define src (string->path (vector-ref (current-command-line-arguments) 0)))"
      "(define prog (parse-program (read-beagle-syntax src) #:source-path src))"
      "(type-check! prog)"
      "(display (emit-program prog))")
     (lib "parse.rkt") (lib "check.rkt") (lib "emit.rkt")))
  (define out (open-output-string))
  (define err (open-output-string))
  (define-values (proc pout pin perr)
    (subprocess #f #f #f (find-system-path 'exec-file)
                "-e" eval-str "--" (path->string src-path)))
  (close-output-port pin)
  (define drain-out (thread (lambda () (copy-port pout out))))
  (define drain-err (thread (lambda () (copy-port perr err))))
  (subprocess-wait proc)
  (thread-wait drain-out)
  (thread-wait drain-err)
  (unless (zero? (subprocess-status proc))
    (error 'emit-zig-in-fresh-process "child racket exited ~a:\n~a"
           (subprocess-status proc) (get-output-string err)))
  (get-output-string out))

(test-case "emission is deterministic"
  (define f (build-path fixtures-dir "07-loop-recur.bgl"))
  (check-equal? (compile-zig-src f) (compile-zig-src f)))

(test-case "extern-only boxed unions emit identically in two fresh processes"
  (define a (emit-zig-in-fresh-process extern-union-fixture))
  (define b (emit-zig-in-fresh-process extern-union-fixture))
  ;; guard the guard: the fixture must actually reach the union-numbering path
  (check-equal? (length (emitted-union-decls a)) 3)
  (check-equal? a b)
  (check-equal? a (compile-zig-src extern-union-fixture)))

(test-case "extern-only boxed unions are numbered in canonical type order"
  ;; Sorted by extern type->string ([Bool -> …] < [Int -> …] < [String -> …]),
  ;; NOT by declaration order and not by extern-name hash order.
  (check-equal? (emitted-union-decls (compile-zig-src extern-union-fixture))
                '("Union0: int string"
                  "Union1: boolean float"
                  "Union2: int float boolean")))

;; --- pointed rejections (out-of-table IR) --------------------------------------

(define-syntax-rule (check-unsupported name rx form ...)
  (test-case name
    (check-exn (lambda (e)
                 (and (exn:fail? e)
                      (regexp-match? #rx"not yet supported by zig backend" (exn-message e))
                      (regexp-match? rx (exn-message e))))
               (lambda () (compile-zig-forms form ...)))))

(check-unsupported "zig rejects untyped def pointedly"
  #rx"untyped def"
  '(def x 42))

(check-unsupported "zig rejects defn without return annotation"
  #rx"return annotation"
  '(defn f [x #%: Int] x))

(define-syntax-rule (check-unsupported/src name rx src)
  (test-case name
    (check-exn (lambda (e)
                 (and (exn:fail? e)
                      (regexp-match? #rx"not yet supported by zig backend" (exn-message e))
                      (regexp-match? rx (exn-message e))))
               (lambda () (compile-zig-string src)))))

(check-unsupported/src "zig rejects map literals pointedly"
  #rx"map literal"
  "(ns g)\n(defn f [x: Int] -> Int (do {:a x} x))")

(check-unsupported/src "zig rejects multi-arity defn"
  #rx"multi-arity"
  "(ns g)\n(defn f\n  ([a: Int] -> Int a)\n  ([a: Int\n    b: Int] -> Int (+ a b)))")

(check-unsupported "zig rejects variable shift amounts"
  #rx"shift"
  '(defn f [x #%: Int n #%: Int] -> Int (bit-shift-left x n)))

(check-unsupported "zig rejects / pointing at quot"
  #rx"quot"
  '(defn f [a #%: Int b #%: Int] -> Int (/ a b)))

(check-unsupported/src "zig rejects a non-exhaustive closed-union match"
  #rx"non-exhaustive match on closed union"
  (string-append
   "(ns zig.union-match-partial)\n"
   "(defrecord Circle [(radius: Int)])\n"
   "(defrecord Square [(side: Int)])\n"
   "(defn f [shape: (U Circle Square)] -> Int\n"
   "  (match shape [(Circle r) r]))\n"))

(check-unsupported/src "zig rejects a match clause outside the target union"
  #rx"is not an alternative of"
  (string-append
   "(ns zig.union-match-foreign)\n"
   "(defrecord Circle [(radius: Int)])\n"
   "(defrecord Square [(side: Int)])\n"
   "(defrecord Blob [(size: Int)])\n"
   "(defn f [shape: (U Circle Square)] -> Int\n"
   "  (match shape [(Circle r) r] [(Square s) s] [(Blob b) b]))\n"))

(check-unsupported/src "zig rejects match on a target that is not a closed union"
  #rx"match target"
  (string-append
   "(ns zig.union-match-scalar)\n"
   "(defn f [n: Int] -> Int\n"
   "  (match n [1 10] [_ 0]))\n"))

(check-unsupported/src "zig rejects qualified calls to non-runtime namespaces"
  #rx"qualified"
  "(ns g)\n(require some.random.lib :as q)\n(defn f [s: String] -> String (q/frobnicate s))")

(test-case "extern: core namespaces land on rt; everything else gets its own module"
  ;; Phase 1: a declared-extern namespace lowers to a MODULE. Core
  ;; namespaces (clojure.*, babashka.*, kernel.rt) stay on the `rt`
  ;; prelude; any other namespace lowers to its own module — namespace
  ;; with '.'→'_' — with a matching @import header. So kernel.rt/draw →
  ;; rt.draw (no @import beyond beagle_rt), but app.rt/tick routes through a
  ;; collision-free binding for @import("app_rt.zig").
  (define out (compile-zig-string
               (string-append
                "(ns g)\n"
                "(declare-extern kernel.rt/draw [Int -> Int])\n"
                "(declare-extern app.rt/tick [Int -> Int])\n"
                "(defn f [x: Int] -> Int (app.rt/tick (kernel.rt/draw x)))")))
  (check-true (regexp-match? #rx"rt.draw" out))          ; kernel.rt → core rt
  (check-true (regexp-match? #rx"beagle_module_app_rt.tick" out))
  (check-true
   (regexp-match?
    #rx"const beagle_module_app_rt = @import\\(\"app_rt.zig\"\\);"
    out))
  (check-false (regexp-match? #rx"const kernel" out)))    ; kernel.rt NOT split

(test-case "los.rt and los.yaml each lower to their own module + @import"
  (define out (compile-zig-string
               (string-append
                "(ns g)\n"
                "(declare-extern los.rt/slugify [String -> String])\n"
                "(declare-extern los.yaml/parse [String -> Yaml])\n"
                "(defn f [s: String] -> String (los.rt/slugify s))")))
  (check-true (regexp-match? #rx"beagle_module_los_rt.slugify" out))
  (check-true
   (regexp-match?
    #rx"const beagle_module_los_rt = @import\\(\"los_rt.zig\"\\);"
    out))
  ;; los.yaml is declared but never CALLED → no spurious import.
  (check-false (regexp-match? #rx"los_yaml" out)))

;; --- higher-order, monomorphized to flat loops (the typed lowering) ----------

(define (ho-emit body)
  (compile-zig-string
   (string-append "(ns g)\n(defn f\n  [ctx: Ctx\n   xs: (Vec Int)] -> " body ")")))

(test-case "reduce: fn inlined into a flat fold, no allocation, no fn value"
  (define out (ho-emit "Int\n  (reduce (fn\n            [acc: Int\n             x: Int] -> Int\n            (+ acc x)) 0 xs)"))
  (check-true  (regexp-match? #rx"var acc: i64 = 0" out))   ; typed, not comptime_int
  (check-true  (regexp-match? #rx"for " out))               ; flat loop
  (check-true  (regexp-match? #rx"acc = .acc . x." out))    ; fold step, fn erased
  (check-false (regexp-match? #rx"alloc" out))              ; reduce folds, no alloc
  (check-false (regexp-match? #rx"rt.reduce" out)))         ; not a runtime HOF call

(test-case "mapv: fn inlined, output allocated in the caller arena, elem type from -> U"
  (define out (ho-emit "(Vec Int)\n  (mapv (fn [x: Int] -> Int (* x 2)) xs)"))
  (check-true  (regexp-match? #rx"ctx\\.tick\\.alloc" out)) ; caller-owned arena
  (check-true  (regexp-match? #rx"alloc.i64" out))         ; elem type from -> Int
  (check-true  (regexp-match? #rx"= .x . 2." out))          ; body inlined
  (check-false (regexp-match? #rx"rt.mapv" out)))

(test-case "filterv: fn inlined, predicate in the loop, kept-count slice"
  (define out (ho-emit "(Vec Int)\n  (filterv (fn [x: Int] -> Bool (> x 0)) xs)"))
  (check-true (regexp-match? #rx"std.meta.Elem" out))       ; elem type inferred
  (check-true (regexp-match? #rx"if ..x > 0." out))         ; predicate inlined
  (check-true (regexp-match? #rx"__n" out))                 ; kept-count
  (check-false (regexp-match? #rx"rt.filterv" out)))

(test-case "higher-order needs an annotated accumulator/return (typed lowering)"
  ;; reduce without an acc type can't pick a non-comptime_int var type
  (check-exn (lambda (e) (regexp-match? #rx"reduce accumulator" (exn-message e)))
             (lambda () (ho-emit "Int\n  (reduce (fn\n            [acc\n             x]\n            (+ acc x)) 0 xs)"))))

(when ZIG
  (test-case "monomorphized higher-order compiles as zig"
    (check-true (zig-compiles?
                 (ho-emit "Int\n  (reduce (fn\n            [acc: Int\n             x: Int] -> Int\n            (+ acc x)) 0 xs)")
                 "ho-reduce"))))

;; --- fn-name arguments, monomorphized per (callee, parameter, defn) ----------

(define reachable-from-src
  (string-append
   "(ns zig.hof-mono)\n"
   "(def A-SUCC: (Vec String) [\"b\"])\n"
   "(def B-SUCC: (Vec String) [\"c\"])\n"
   "(def C-SUCC: (Vec String) [\"a\"])\n"
   "(def NO-SUCC: (Vec String) [])\n"
   "(defn next-nodes [node: String] -> (Vec String)\n"
   "  (cond\n"
   "    [(= node \"a\") A-SUCC]\n"
   "    [(= node \"b\") B-SUCC]\n"
   "    [(= node \"c\") C-SUCC]\n"
   "    [:else NO-SUCC]))\n"
   "(defn reachable-from?\n"
   "  [succ: [String -> (Vec String)]\n"
   "   frontier: (Vec String)\n"
   "   fuel: Int\n"
   "   target: String] -> Bool\n"
   "  (loop [front frontier n fuel]\n"
   "    (cond\n"
   "      [(empty? front) false]\n"
   "      [(<= n 0) false]\n"
   "      [(= (nth front 0) target) true]\n"
   "      [:else (recur (vec (concat (rest front) (succ (nth front 0)))) (dec n))])))\n"
   "(defn cycle? [start: String] -> Bool\n"
   "  (reachable-from? next-nodes (next-nodes start) 16 start))\n"
   "(defn main [] -> Nil\n"
   "  (println (str (cycle? \"a\") \":\" (cycle? \"d\"))))\n"))

(test-case "a top-level defn in argument position specializes the callee"
  (define out (compile-zig-string reachable-from-src))
  ;; the fn argument is erased from the signature, not passed as a value
  (check-regexp-match
   #rx"pub fn reachableFrom__succ__nextNodes\\(__ctx: \\*rt\\.Ctx, frontier: \\[\\]const \\[\\]const u8, fuel: i64, target: \\[\\]const u8\\) bool"
   out)
  (check-regexp-match #rx"reachableFrom__succ__nextNodes\\(__ctx, nextNodes\\(start\\), 16, start\\)" out)
  ;; the generic form has no Zig representation and is never emitted
  (check-false (regexp-match? #rx"pub fn reachableFrom\\(" out))
  (check-false (regexp-match? #rx"succ" (regexp-replace* #rx"__succ__" out ""))))

(test-case "one callee specializes per distinct fn argument"
  (define out
    (compile-zig-string
     (string-append
      "(ns zig.hof-two)\n"
      "(defn double [x: Int] -> Int (* x 2))\n"
      "(defn negate [x: Int] -> Int (- 0 x))\n"
      "(defn apply-twice\n  [f: [Int -> Int]\n   x: Int] -> Int\n  (f (f x)))\n"
      "(defn main [] -> Nil\n"
      "  (println (str (apply-twice double 5) \":\" (apply-twice negate 5))))\n")))
  (check-regexp-match #rx"pub fn applyTwice__f__double\\(x: i64\\) i64 \\{\n    return double\\(double\\(x\\)\\);" out)
  (check-regexp-match #rx"pub fn applyTwice__f__negate\\(x: i64\\) i64 \\{\n    return negate\\(negate\\(x\\)\\);" out))

(when ZIG
  (test-case "a monomorphized traversal compiles, runs, and detects the cycle"
    (check-equal?
     (zig-build-exe-and-run (compile-zig-string reachable-from-src))
     "true:false\n")))

(check-unsupported/src "zig rejects a fn value in a monomorphized argument slot"
  #rx"higher-order argument"
  (string-append
   "(ns zig.hof-literal)\n"
   "(defn apply-twice\n  [f: [Int -> Int]\n   x: Int] -> Int\n  (f (f x)))\n"
   "(defn run [] -> Int (apply-twice (fn [x: Int] -> Int (+ x 1)) 5))\n"))

;; --- Phase 2: world-escape check + promote ------------------------------------

(define-syntax-rule (check-escape name rx src)
  (test-case name
    (check-exn (lambda (e)
                 (and (exn:fail? e)
                      (regexp-match? #rx"world-state type" (exn-message e))
                      (regexp-match? rx (exn-message e))))
               (lambda () (compile-zig-string src)))))

(check-escape "escape: World with a Vec field is rejected at compile time"
  #rx"tick-lifetime field log"
  "(ns g)\n(defrecord World\n  [score: Int\n   log: (Vec Int)])\n(defn world-tick\n  [ctx: Ctx\n   w: World] -> World\n  (->World (:score w) (:log w)))")

(check-escape "escape: String fields are slices too"
  #rx"strings are slices"
  "(ns g)\n(defrecord World [name: String])\n(defn world-tick\n  [ctx: Ctx\n   w: World] -> World\n  w)")

(check-escape "escape: nested record smuggling a slice is caught"
  #rx"tick-lifetime field xs"
  "(ns g)\n(defrecord Bag [xs: (Vec Int)])\n(defrecord World [bag: Bag])\n(defn tick-step\n  [ctx: Ctx\n   w: World] -> World\n  w)")

(test-case "value-level promote is the world-tick artifact; systems promote via SoA"
  (define out (compile-zig-string
               "(ns g)\n(defrecord S [v: Int])\n(defn tick-step\n  [ctx: Ctx\n   s: S] -> S\n  s)"))
  (check-false (regexp-match? #rx"pub fn promote\\(" out))
  (check-true (regexp-match? #rx"pub fn tickStepPromoteAll" out)))

;; --- engine layer (script→engine crossing) -------------------------------------

(define ENGINE-SRC
  (string-append
   "(ns g)\n"
   "(defrecord MindIn\n  [x: Int\n   belief: Int])\n"
   "(defrecord Obs [sig: Int])\n"
   "(defrecord StepOut\n  [x: Int\n   belief: Int\n   act: Int])\n"
   "(defn tick-step\n  [ctx: Ctx\n   m: MindIn\n   obs: Obs\n   max-x: Int] -> StepOut\n"
   "  (->StepOut (+ (:x m) (:sig obs)) (:belief m) 0))"))

(test-case "engine: SoA buffers generated for entity and output records"
  (define out (compile-zig-string ENGINE-SRC))
  (check-true (regexp-match? #rx"pub const MindInSoA = struct" out))
  (check-true (regexp-match? #rx"pub const StepOutSoA = struct" out)))

(test-case "engine: per-system range loop — record params per-entity, scalars broadcast"
  (define out (compile-zig-string ENGINE-SRC))
  (check-true (regexp-match?
               #rx"pub fn tickStepAllRange.tick: std.mem.Allocator, seed: u64, tick_no: u64, in: \\*const MindInSoA, obs: \\[\\]const Obs, max_x: i64, out: \\*StepOutSoA, lo: usize, hi: usize."
               out)))

(test-case "engine: counter-rng policy with a name-derived lane"
  (define out (compile-zig-string ENGINE-SRC))
  (check-true (regexp-match? #rx"rt.Splitmix64.init.rt.mix64.seed" out))
  (check-true (regexp-match? #rx"Lane 0x[0-9A-F]+ derives from the system name" out)))

(test-case "engine: promotion copies world-lifetime fields, transients stay behind"
  (define out (compile-zig-string ENGINE-SRC))
  (check-true (regexp-match? #rx"pub fn tickStepPromoteAll" out))
  (check-true (regexp-match? #rx"@memcpy.next.x.0..n., out.x.0..n.." out))
  (check-true (regexp-match? #rx"@memcpy.next.belief" out))
  (check-false (regexp-match? #rx"next.act" out)))

(define TWO-SYSTEM-SRC
  (string-append
   "(ns g)\n"
   "(defrecord MindIn\n  [x: Int\n   alarm: Int])\n"
   "(defrecord MindOut\n  [x: Int\n   alarm: Int\n   act: Int])\n"
   "(defrecord WolfIn\n  [x: Int\n   energy: Int])\n"
   "(defrecord WolfOut\n  [x: Int\n   energy: Int\n   howl: Int])\n"
   "(defn mind-step\n  [ctx: Ctx\n   m: MindIn] -> MindOut\n"
   "  (->MindOut (:x m) (:alarm m) 0))\n"
   "(defn wolf-step\n  [ctx: Ctx\n   w: WolfIn] -> WolfOut\n"
   "  (->WolfOut (:x w) (:energy w) 0))"))

(test-case "engine: two systems — two archetypes, each with stores + loop + promote"
  (define out (compile-zig-string TWO-SYSTEM-SRC))
  (check-true (regexp-match? #rx"pub const MindInSoA = struct" out))
  (check-true (regexp-match? #rx"pub const WolfInSoA = struct" out))
  (check-true (regexp-match? #rx"pub fn mindStepAllRange" out))
  (check-true (regexp-match? #rx"pub fn wolfStepAllRange" out))
  (check-true (regexp-match? #rx"pub fn mindStepPromoteAll" out))
  (check-true (regexp-match? #rx"pub fn wolfStepPromoteAll" out)))

(test-case "engine: per-system rng lanes are distinct"
  (define out (compile-zig-string TWO-SYSTEM-SRC))
  (define lanes (regexp-match* #rx"\\+% 0x([0-9A-F]+)\\)\\)\\)" out #:match-select cadr))
  (check-equal? 2 (length lanes))
  (check-false (equal? (car lanes) (cadr lanes))))

(when ZIG
  (test-case "engine: two-system generated layer compiles as zig"
    (check-true (zig-compiles? (compile-zig-string TWO-SYSTEM-SRC) "two-systems"))))

(test-case "literal-only branches get an @as anchor (zig comptime_int trap)"
  ;; In a binding position, (if c 1 0) is two comptime_int branches under
  ;; runtime control flow — zig rejects it unless one branch is anchored.
  (define out (compile-zig-string
               "(ns g)\n(defn f [x: Int] -> Int (let [v (if (> x 0) 1 0)] v))"))
  (check-true (regexp-match? #rx"@as.i64, 1." out)))

(when ZIG
  (test-case "literal-branch if compiles in binding position"
    (check-true (zig-compiles?
                 (compile-zig-string
                  "(ns g)\n(defn f [x: Int] -> Int (let [v (if (> x 0) 1 0)] v))")
                 "literal-if-binding"))))

(test-case "engine: a -step fn without Ctx first is an ordinary function"
  (define out (compile-zig-string
               "(ns g)\n(defn two-step\n  [a: Int\n   b: Int] -> Int\n  (+ a b))"))
  (check-false (regexp-match? #rx"AllRange" out))
  (check-true (regexp-match? #rx"pub fn twoStep" out)))

(test-case "engine: entity = output dedups to a single SoA struct"
  (define out (compile-zig-string
               "(ns g)\n(defrecord S [v: Int])\n(defn tick-step\n  [ctx: Ctx\n   s: S] -> S\n  s)"))
  (check-equal? 1 (length (regexp-match* #rx"pub const SSoA = struct" out))))

(test-case "engine: world-tick alone gets promote but no engine layer"
  (define out (compile-zig-string
               "(ns g)\n(defrecord World [score: Int])\n(defn world-tick\n  [ctx: Ctx\n   w: World] -> World\n  w)"))
  (check-true (regexp-match? #rx"pub fn promote" out))
  (check-false (regexp-match? #rx"tickAllRange" out)))

(when ZIG
  (test-case "engine: generated engine layer compiles as zig"
    (check-true (zig-compiles? (compile-zig-string ENGINE-SRC) "engine-layer"))))

;; --- lifecycle: alive verdict → generated compaction ---------------------------

(define LIFECYCLE-SRC
  (string-append
   "(ns g)\n"
   "(defrecord E\n  [x: Int\n   hp: Int])\n"
   "(defrecord O\n  [x: Int\n   hp: Int\n   alive: Bool])\n"
   "(defn life-step\n  [ctx: Ctx\n   e: E] -> O\n"
   "  (->O (:x e) (- (:hp e) 1) (> (:hp e) 1)))"))

(test-case "lifecycle: alive on the output record generates compaction, not promotion"
  (define out (compile-zig-string LIFECYCLE-SRC))
  (check-true (regexp-match? #rx"pub fn lifeStepCompactAll.out: \\*const OSoA, next: \\*ESoA, n: usize. usize" out))
  (check-true (regexp-match? #rx"if ..out.alive.i.. continue;" out))
  (check-false (regexp-match? #rx"lifeStepPromoteAll" out))
  ;; alive is the verdict — it is not copied into next state
  (check-false (regexp-match? #rx"next.alive" out)))

(when ZIG
  (test-case "lifecycle: generated compaction compiles as zig"
    (check-true (zig-compiles? (compile-zig-string LIFECYCLE-SRC) "lifecycle"))))

(define SPAWN-SRC
  (string-append
   "(ns g)\n"
   "(defrecord E\n  [x: Int\n   hp: Int])\n"
   "(defrecord O\n  [x: Int\n   hp: Int\n   alive: Bool\n   spawn: Bool])\n"
   "(defn life-step\n  [ctx: Ctx\n   e: E] -> O\n"
   "  (->O (:x e) (- (:hp e) 1) (> (:hp e) 1) (> (:hp e) 9)))"))

(test-case "lifecycle: spawn verdict adds births to the generated compaction"
  (define out (compile-zig-string SPAWN-SRC))
  (check-true (regexp-match? #rx"pub fn lifeStepCompactAll.out: \\*const OSoA, next: \\*ESoA, n: usize, cap: usize. usize" out))
  (check-true (regexp-match? #rx"if ..out.spawn.i. or .out.alive.i. or w >= cap. continue;" out))
  ;; verdicts are not state
  (check-false (regexp-match? #rx"next.spawn" out))
  (check-false (regexp-match? #rx"next.alive" out)))

(when ZIG
  (test-case "lifecycle: compaction-with-births compiles as zig"
    (check-true (zig-compiles? (compile-zig-string SPAWN-SRC) "spawn"))))

(check-unsupported/src "lifecycle: spawn without alive is rejected pointedly"
  #rx"spawn requires alive"
  (string-append
   "(ns g)\n"
   "(defrecord E [x: Int])\n"
   "(defrecord O\n  [x: Int\n   spawn: Bool])\n"
   "(defn life-step\n  [ctx: Ctx\n   e: E] -> O\n  (->O (:x e) false))"))

(check-unsupported/src "lifecycle: alive on both records is rejected pointedly"
  #rx"alive is the survival verdict"
  (string-append
   "(ns g)\n"
   "(defrecord E\n  [x: Int\n   alive: Bool])\n"
   "(defrecord O\n  [x: Int\n   alive: Bool])\n"
   "(defn life-step\n  [ctx: Ctx\n   e: E] -> O\n  (->O (:x e) true))"))

(check-unsupported/src "lifecycle: a non-Bool alive is rejected pointedly"
  #rx"alive must be Bool"
  (string-append
   "(ns g)\n"
   "(defrecord E [x: Int])\n"
   "(defrecord O\n  [x: Int\n   alive: Int])\n"
   "(defn life-step\n  [ctx: Ctx\n   e: E] -> O\n  (->O (:x e) 1))"))

(check-unsupported/src "engine: param 1 must be the entity record"
  #rx"tick-step param 1"
  "(ns g)\n(defrecord S [v: Int])\n(defn tick-step\n  [ctx: Ctx\n   n: Int] -> S\n  (->S n))")

(check-unsupported/src "engine: entity fields must be scalar for the commit memcpy"
  #rx"engine entity record with non-scalar field"
  (string-append
   "(ns g)\n(defrecord Inner [v: Int])\n"
   "(defrecord E [inner: Inner])\n(defrecord O [v: Int])\n"
   "(defn tick-step\n  [ctx: Ctx\n   e: E] -> O\n  (->O (:v (:inner e))))"))

(check-unsupported/src "engine: param names can't collide with engine bindings"
  #rx"seed collides with a generated engine binding"
  "(ns g)\n(defrecord S [v: Int])\n(defn tick-step\n  [ctx: Ctx\n   s: S\n   seed: Int] -> S\n  s)")

(check-unsupported/src "engine: name-matched promotion fields must agree on type"
  #rx"share a name but not a type"
  (string-append
   "(ns g)\n(defrecord E [x: Int])\n(defrecord O [x: Float])\n"
   "(defn tick-step\n  [ctx: Ctx\n   e: E] -> O\n  (->O 1.0))"))
