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

(define kernel-rt
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (simplify-path (build-path dir 'up 'up "beagle-lib" "zig" "beagle_rt.zig"))))

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

(define (check-zig-forms . datums)
  (define forms (map (lambda (d) (datum->syntax #f d))
                     (cons '(define-target zig) datums)))
  (type-check! (parse-program forms)))

(define (br . xs) (cons BRACKET-TAG xs))

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

(define (zig-build-exe-and-run zig-src)
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
      (define ran?
        (parameterize ([current-output-port run-out]
                       [current-error-port run-out]
                       [current-directory dir])
          (system* exe)))
      (unless ran?
        (error 'zig-smoke "emitted binary failed:\n~a" (get-output-string run-out)))
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

;; --- semantic contract 1: concrete native boundaries -------------------------

(define semantic-bless? (and (getenv "BEAGLE_SEMANTIC_BLESS") #t))
(define any-boundary-src (build-path semantic-contract-dir "any-boundary.bgl"))
(define concrete-boundary-src (build-path semantic-contract-dir "concrete-boundary.bgl"))
(define regex-src (build-path semantic-contract-dir "regex.bgl"))
(define closed-dynamic-src (build-path semantic-contract-dir "closed-dynamic.bgl"))
(define collections-layout-src
  (build-path semantic-contract-dir "collections-layout.bgl"))

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
              (cons "def" '((def value :- Any 1)))
              (cons "parameter" '((defn f [value :- Any] :- Int 1)))
              (cons "return" '((defn f [] :- Any 1)))
              (cons "record field" '((defrecord Box [value :- Any])))
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
    try std.testing.expectEqualStrings("_b_c", replaceRuns("A--b c"));

    const pieces = splitRuns("a,b;;c");
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
            (def optional :- Regex (re-pattern "^(a)?b$"))
            (defn match-it [s :- String] :- (U (HVec String String?) Nil)
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

(test-case "zig regex checker admits a dynamic pattern with explicit match shape"
  (check-zig-forms
   '(ns regex-contract-dynamic)
   '(defn make-it [s :- String] :- (Regex String) (re-pattern s))))

(test-case "zig regex checker rejects unsupported pattern features"
  (check-exn
   #rx"not lookaround, inline flags, or named groups"
   (lambda ()
     (check-zig-forms
      '(ns regex-contract-feature)
      '(def value :- Regex (re-pattern "(?=a)a"))))))

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
    try std.testing.expectEqualStrings("string:ok", observe(roundTrip(dynString("ok"))));
    try std.testing.expectEqualStrings("int:7", observe(roundTrip(dynInt(7))));
    try std.testing.expectEqualStrings("bool:true", observe(roundTrip(dynBool(true))));
    try std.testing.expectEqualStrings("vec:2", observe(roundTrip(dynVector(&.{ "a", "b" }))));
    const value_map = rt.Map(i64).empty().assoc("k", 1);
    try std.testing.expectEqualStrings("map", observe(roundTrip(dynMap(value_map))));

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
                    '((defn bad [value :- (Dyn)] :- Int 0)))
              (cons "nested Any"
                    '((defn bad [value :- (Dyn String (Vec Any))] :- Int 0)))
              (cons "duplicate alternative"
                    '((defn bad [value :- (Dyn String String)] :- Int 0)))
              (cons "use without narrowing"
                    '((defn bad [value :- (Dyn String Int)] :- Int
                        (count value))))))])
  (test-case (format "closed dynamic checker rejects ~a" (car case))
    (check-exn dynamic-contract-rejection?
               (lambda () (apply check-zig-forms (cdr case))))))

(test-case "closed dynamic checker rejects an unlisted runtime value"
  (check-exn
   #rx"expected return \\(Dyn String Int\\), got Bool"
   (lambda ()
     (check-zig-forms
      '(defn bad [value :- Bool] :- (Dyn String Int) value)))))

(test-case "closed dynamic checker validates local annotations"
  (check-exn
   dynamic-contract-rejection?
   (lambda ()
     (check-zig-forms
      '(defn bad [] :- Int
         (let [value :- (Dyn String Any) "x"] 0))))))

(test-case "closed dynamic lowering discovers local-only contracts"
  (define out
    (compile-zig-forms
     '(defn local-dynamic [value :- String] :- String
        (let [closed :- (Dyn String Int) value]
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
      "(defn call-tag [value :- String] :- Int (app.rt/tag value))")))
  (check-true (regexp-match? #rx"pub const Dyn0 = union" out))
  (check-true
   (regexp-match? #rx"app_rt\\.tag\\(Dyn0\\{ \\.string = value \\}\\)" out)))

(test-case "closed dynamic contract records declared-order integer tags"
  (define prog
    (parse-program
     (map (lambda (datum) (datum->syntax #f datum))
          '((define-target zig)
            (ns dynamic-contract-shape)
            (defn identity [value :- (Dyn String Int Bool)]
              :- (Dyn String Int Bool)
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
      (regexp-replace* #px"(?m:^import [^\n]*\n)" js-src ""))
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
    try std.testing.expectEqual(@as(i64, 2), keywordMapCount());
    try std.testing.expect(keywordMapAbsent());
    try std.testing.expect(compoundMapPresent());
    try std.testing.expectEqual(@as(i64, 2), setDedupCount());
    try std.testing.expect(setPresent());
    try std.testing.expect(compoundEqual());
    try std.testing.expect(compoundHashConsistent());
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
      '(defn bad [values :- (Map Keyword Int)] :- Keyword
         (first (keys values)))))))

(test-case "collection checker rejects target-private map extern layout"
  (check-exn
   collection-contract-rejection?
   (lambda ()
     (check-zig-forms
      `(declare-extern app.rt/send
         ,(br '(Map Keyword Int) '-> 'Int))))))

;; --- determinism: same input → byte-identical output --------------------------

(test-case "emission is deterministic"
  (define f (build-path fixtures-dir "07-loop-recur.bgl"))
  (check-equal? (compile-zig-src f) (compile-zig-src f)))

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
  '(defn f [x :- Int] x))

(define-syntax-rule (check-unsupported/src name rx src)
  (test-case name
    (check-exn (lambda (e)
                 (and (exn:fail? e)
                      (regexp-match? #rx"not yet supported by zig backend" (exn-message e))
                      (regexp-match? rx (exn-message e))))
               (lambda () (compile-zig-string src)))))

(check-unsupported/src "zig rejects map literals pointedly"
  #rx"map literal"
  "(ns g)\n(defn f [x :- Int] :- Int (do {:a x} x))")

(check-unsupported/src "zig rejects multi-arity defn"
  #rx"multi-arity"
  "(ns g)\n(defn f ([a :- Int] :- Int a) ([a :- Int b :- Int] :- Int (+ a b)))")

(check-unsupported "zig rejects variable shift amounts"
  #rx"shift"
  '(defn f [x :- Int n :- Int] :- Int (bit-shift-left x n)))

(check-unsupported "zig rejects / pointing at quot"
  #rx"quot"
  '(defn f [a :- Int b :- Int] :- Int (/ a b)))

(check-unsupported/src "zig rejects qualified calls to non-runtime namespaces"
  #rx"qualified"
  "(ns g)\n(require some.random.lib :as q)\n(defn f [s :- String] :- String (q/frobnicate s))")

(test-case "extern: core namespaces land on rt; everything else gets its own module"
  ;; Phase 1: a declared-extern namespace lowers to a MODULE. Core
  ;; namespaces (clojure.*, babashka.*, kernel.rt) stay on the `rt`
  ;; prelude; any other namespace lowers to its own module — namespace
  ;; with '.'→'_' — with a matching @import header. So kernel.rt/draw →
  ;; rt.draw (no @import beyond beagle_rt), but app.rt/tick → app_rt.tick
  ;; behind const app_rt = @import("app_rt.zig").
  (define out (compile-zig-string
               (string-append
                "(ns g)\n"
                "(declare-extern kernel.rt/draw [Int -> Int])\n"
                "(declare-extern app.rt/tick [Int -> Int])\n"
                "(defn f [x :- Int] :- Int (app.rt/tick (kernel.rt/draw x)))")))
  (check-true (regexp-match? #rx"rt.draw" out))          ; kernel.rt → core rt
  (check-true (regexp-match? #rx"app_rt.tick" out))       ; app.rt → own module
  (check-true (regexp-match? #rx"const app_rt = @import\\(\"app_rt.zig\"\\);" out))
  (check-false (regexp-match? #rx"const kernel" out)))    ; kernel.rt NOT split

(test-case "los.rt and los.yaml each lower to their own module + @import"
  (define out (compile-zig-string
               (string-append
                "(ns g)\n"
                "(declare-extern los.rt/slugify [String -> String])\n"
                "(declare-extern los.yaml/parse [String -> Yaml])\n"
                "(defn f [s :- String] :- String (los.rt/slugify s))")))
  (check-true (regexp-match? #rx"los_rt.slugify" out))
  (check-true (regexp-match? #rx"const los_rt = @import\\(\"los_rt.zig\"\\);" out))
  ;; los.yaml is declared but never CALLED → no spurious import.
  (check-false (regexp-match? #rx"los_yaml" out)))

;; --- higher-order, monomorphized to flat loops (the typed lowering) ----------

(define (ho-emit body)
  (compile-zig-string
   (string-append "(ns g)\n(defn f [ctx :- Ctx xs :- (Vec Int)] :- " body ")")))

(test-case "reduce: fn inlined into a flat fold, no allocation, no fn value"
  (define out (ho-emit "Int\n  (reduce (fn [acc :- Int x :- Int] :- Int (+ acc x)) 0 xs)"))
  (check-true  (regexp-match? #rx"var acc: i64 = 0" out))   ; typed, not comptime_int
  (check-true  (regexp-match? #rx"for " out))               ; flat loop
  (check-true  (regexp-match? #rx"acc = .acc . x." out))    ; fold step, fn erased
  (check-false (regexp-match? #rx"alloc" out))              ; reduce folds, no alloc
  (check-false (regexp-match? #rx"rt.reduce" out)))         ; not a runtime HOF call

(test-case "mapv: fn inlined, output allocated in the CLI arena, elem type from :- U"
  (define out (ho-emit "(Vec Int)\n  (mapv (fn [x :- Int] :- Int (* x 2)) xs)"))
  (check-true  (regexp-match? #rx"cliAlloc" out))          ; CLI run-arena
  (check-true  (regexp-match? #rx"alloc.i64" out))         ; elem type from :- Int
  (check-true  (regexp-match? #rx"= .x . 2." out))          ; body inlined
  (check-false (regexp-match? #rx"rt.mapv" out)))

(test-case "filterv: fn inlined, predicate in the loop, kept-count slice"
  (define out (ho-emit "(Vec Int)\n  (filterv (fn [x :- Int] :- Bool (> x 0)) xs)"))
  (check-true (regexp-match? #rx"std.meta.Elem" out))       ; elem type inferred
  (check-true (regexp-match? #rx"if ..x > 0." out))         ; predicate inlined
  (check-true (regexp-match? #rx"__n" out))                 ; kept-count
  (check-false (regexp-match? #rx"rt.filterv" out)))

(test-case "higher-order needs an annotated accumulator/return (typed lowering)"
  ;; reduce without an acc type can't pick a non-comptime_int var type
  (check-exn (lambda (e) (regexp-match? #rx"reduce accumulator" (exn-message e)))
             (lambda () (ho-emit "Int\n  (reduce (fn [acc x] (+ acc x)) 0 xs)"))))

(when ZIG
  (test-case "monomorphized higher-order compiles as zig"
    (check-true (zig-compiles?
                 (ho-emit "Int\n  (reduce (fn [acc :- Int x :- Int] :- Int (+ acc x)) 0 xs)")
                 "ho-reduce"))))

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
  "(ns g)\n(defrecord World [score :- Int log :- (Vec Int)])\n(defn world-tick [ctx :- Ctx w :- World] :- World (->World (:score w) (:log w)))")

(check-escape "escape: String fields are slices too"
  #rx"strings are slices"
  "(ns g)\n(defrecord World [name :- String])\n(defn world-tick [ctx :- Ctx w :- World] :- World w)")

(check-escape "escape: nested record smuggling a slice is caught"
  #rx"tick-lifetime field xs"
  "(ns g)\n(defrecord Bag [xs :- (Vec Int)])\n(defrecord World [bag :- Bag])\n(defn tick-step [ctx :- Ctx w :- World] :- World w)")

(test-case "value-level promote is the world-tick artifact; systems promote via SoA"
  (define out (compile-zig-string
               "(ns g)\n(defrecord S [v :- Int])\n(defn tick-step [ctx :- Ctx s :- S] :- S s)"))
  (check-false (regexp-match? #rx"pub fn promote\\(" out))
  (check-true (regexp-match? #rx"pub fn tickStepPromoteAll" out)))

;; --- engine layer (script→engine crossing) -------------------------------------

(define ENGINE-SRC
  (string-append
   "(ns g)\n"
   "(defrecord MindIn [x :- Int belief :- Int])\n"
   "(defrecord Obs [sig :- Int])\n"
   "(defrecord StepOut [x :- Int belief :- Int act :- Int])\n"
   "(defn tick-step [ctx :- Ctx m :- MindIn obs :- Obs max-x :- Int] :- StepOut\n"
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
   "(defrecord MindIn [x :- Int alarm :- Int])\n"
   "(defrecord MindOut [x :- Int alarm :- Int act :- Int])\n"
   "(defrecord WolfIn [x :- Int energy :- Int])\n"
   "(defrecord WolfOut [x :- Int energy :- Int howl :- Int])\n"
   "(defn mind-step [ctx :- Ctx m :- MindIn] :- MindOut\n"
   "  (->MindOut (:x m) (:alarm m) 0))\n"
   "(defn wolf-step [ctx :- Ctx w :- WolfIn] :- WolfOut\n"
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
               "(ns g)\n(defn f [x :- Int] :- Int (let [v (if (> x 0) 1 0)] v))"))
  (check-true (regexp-match? #rx"@as.i64, 1." out)))

(when ZIG
  (test-case "literal-branch if compiles in binding position"
    (check-true (zig-compiles?
                 (compile-zig-string
                  "(ns g)\n(defn f [x :- Int] :- Int (let [v (if (> x 0) 1 0)] v))")
                 "literal-if-binding"))))

(test-case "engine: a -step fn without Ctx first is an ordinary function"
  (define out (compile-zig-string
               "(ns g)\n(defn two-step [a :- Int b :- Int] :- Int (+ a b))"))
  (check-false (regexp-match? #rx"AllRange" out))
  (check-true (regexp-match? #rx"pub fn twoStep" out)))

(test-case "engine: entity = output dedups to a single SoA struct"
  (define out (compile-zig-string
               "(ns g)\n(defrecord S [v :- Int])\n(defn tick-step [ctx :- Ctx s :- S] :- S s)"))
  (check-equal? 1 (length (regexp-match* #rx"pub const SSoA = struct" out))))

(test-case "engine: world-tick alone gets promote but no engine layer"
  (define out (compile-zig-string
               "(ns g)\n(defrecord World [score :- Int])\n(defn world-tick [ctx :- Ctx w :- World] :- World w)"))
  (check-true (regexp-match? #rx"pub fn promote" out))
  (check-false (regexp-match? #rx"tickAllRange" out)))

(when ZIG
  (test-case "engine: generated engine layer compiles as zig"
    (check-true (zig-compiles? (compile-zig-string ENGINE-SRC) "engine-layer"))))

;; --- lifecycle: alive verdict → generated compaction ---------------------------

(define LIFECYCLE-SRC
  (string-append
   "(ns g)\n"
   "(defrecord E [x :- Int hp :- Int])\n"
   "(defrecord O [x :- Int hp :- Int alive :- Bool])\n"
   "(defn life-step [ctx :- Ctx e :- E] :- O\n"
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
   "(defrecord E [x :- Int hp :- Int])\n"
   "(defrecord O [x :- Int hp :- Int alive :- Bool spawn :- Bool])\n"
   "(defn life-step [ctx :- Ctx e :- E] :- O\n"
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
   "(defrecord E [x :- Int])\n"
   "(defrecord O [x :- Int spawn :- Bool])\n"
   "(defn life-step [ctx :- Ctx e :- E] :- O (->O (:x e) false))"))

(check-unsupported/src "lifecycle: alive on both records is rejected pointedly"
  #rx"alive is the survival verdict"
  (string-append
   "(ns g)\n"
   "(defrecord E [x :- Int alive :- Bool])\n"
   "(defrecord O [x :- Int alive :- Bool])\n"
   "(defn life-step [ctx :- Ctx e :- E] :- O (->O (:x e) true))"))

(check-unsupported/src "lifecycle: a non-Bool alive is rejected pointedly"
  #rx"alive must be Bool"
  (string-append
   "(ns g)\n"
   "(defrecord E [x :- Int])\n"
   "(defrecord O [x :- Int alive :- Int])\n"
   "(defn life-step [ctx :- Ctx e :- E] :- O (->O (:x e) 1))"))

(check-unsupported/src "engine: param 1 must be the entity record"
  #rx"tick-step param 1"
  "(ns g)\n(defrecord S [v :- Int])\n(defn tick-step [ctx :- Ctx n :- Int] :- S (->S n))")

(check-unsupported/src "engine: entity fields must be scalar for the commit memcpy"
  #rx"engine entity record with non-scalar field"
  (string-append
   "(ns g)\n(defrecord Inner [v :- Int])\n"
   "(defrecord E [inner :- Inner])\n(defrecord O [v :- Int])\n"
   "(defn tick-step [ctx :- Ctx e :- E] :- O (->O (:v (:inner e))))"))

(check-unsupported/src "engine: param names can't collide with engine bindings"
  #rx"seed collides with a generated engine binding"
  "(ns g)\n(defrecord S [v :- Int])\n(defn tick-step [ctx :- Ctx s :- S seed :- Int] :- S s)")

(check-unsupported/src "engine: name-matched promotion fields must agree on type"
  #rx"share a name but not a type"
  (string-append
   "(ns g)\n(defrecord E [x :- Int])\n(defrecord O [x :- Float])\n"
   "(defn tick-step [ctx :- Ctx e :- E] :- O (->O 1.0))"))
