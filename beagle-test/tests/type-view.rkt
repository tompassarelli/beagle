#lang racket/base

;; types-as-view / the delaborator: beagle-explain-type projects the checker's
;; inferred per-node types back into surface, at three verbosity levels, with
;; NO type stored in the source (pure projection — the anti-reification point).

(require rackunit
         racket/file
         racket/string
         beagle/private/type-view
         beagle/private/parse)

(define SRC
  (string-append
   "#lang beagle/clj\n"
   "(defn process [n :- Int] :- Int\n"
   "  (let [a (* n 2)\n"
   "        b (+ a 1)]\n"
   "    (- b n)))\n"))

(define (with-fixture src thunk)
  (define tmp (make-temporary-file "type-view-~a.bclj"))
  (dynamic-wind
   (lambda () (call-with-output-file tmp
                (lambda (o) (display src o)) #:exists 'truncate/replace))
   (lambda () (thunk tmp))
   (lambda () (delete-file tmp))))

(test-case "clean view is the source as written (no interior types injected)"
  (with-fixture SRC
    (lambda (f)
      (define out (explain-type f #:name "process" #:level "clean"))
      ;; clean must be a byte-exact substring of the original source: no
      ;; annotations added (the file IS the clean view — anti-reification).
      (check-true (string-contains? SRC out)
                  "clean view must be verbatim source text")
      (check-true (string-contains? out "(* n 2)"))
      (check-false (string-contains? out ":- Int (* n 2)")
                   "clean must NOT inject inferred annotations"))))

(test-case "inferred view injects `:- T` on un-annotated let-bindings"
  (with-fixture SRC
    (lambda (f)
      (define out (explain-type f #:name "process" #:level "inferred"))
      (check-true (string-contains? out "a :- Int (* n 2)")
                  (format "expected inferred annotation on `a`; got:\n~a" out))
      (check-true (string-contains? out "b :- Int (+ a 1)")
                  (format "expected inferred annotation on `b`; got:\n~a" out))
      ;; the authored boundary annotation is preserved verbatim, not doubled
      (check-true (string-contains? out "[n :- Int]")))))

(test-case "all view prefixes every typed interior node with ^T"
  (with-fixture SRC
    (lambda (f)
      (define out (explain-type f #:name "process" #:level "all"))
      (check-true (string-contains? out "^Int")
                  (format "expected ^Int annotations; got:\n~a" out))
      ;; the binding values are typed Int
      (check-true (regexp-match? #rx"a \\^Int \\(\\* n 2\\)" out)))))

(test-case "no NAME yields the whole file (clean)"
  (with-fixture SRC
    (lambda (f)
      (define out (explain-type f))
      (check-true (string-contains? out "(defn process")))))

(test-case "unknown NAME is a pointed error"
  (with-fixture SRC
    (lambda (f)
      (check-exn #rx"no top-level definition named"
                 (lambda () (explain-type f #:name "nope" #:level "clean"))))))

(test-case "annotation-free source stays annotation-free in clean, gains types in inferred"
  ;; The headline: you author no interior types; the view summons them.
  (with-fixture SRC
    (lambda (f)
      (define clean (explain-type f #:name "process" #:level "clean"))
      (define inferred (explain-type f #:name "process" #:level "inferred"))
      (check-false (string-contains? clean ":- Int (* n 2)"))
      (check-true  (string-contains? inferred ":- Int (* n 2)"))
      ;; inferred is exactly clean + `:- Int ` injections: stripping them
      ;; recovers clean byte-for-byte (proves pure projection, no rewrite).
      (check-equal? (string-replace inferred ":- Int " "") clean))))

;; --- edge cases the first fixture hid (from adversarial review) --------------

(define MIXED
  (string-append
   "#lang beagle/clj\n"
   "(defn process [n :- Int] :- String\n"
   "  (let [a (* n 2)\n"
   "        s (str a)]\n"
   "    s))\n"))

(test-case "inferred reflects the ACTUAL per-binding type, not a hardcoded Int"
  (with-fixture MIXED
    (lambda (f)
      (define out (explain-type f #:name "process" #:level "inferred"))
      (check-true (string-contains? out "a :- Int (* n 2)") out)
      (check-true (string-contains? out "s :- String (str a)") out))))

(test-case "inferred output re-parses (round-trips through the reader)"
  (for ([src (in-list (list SRC MIXED))])
    (with-fixture src
      (lambda (f)
        (define out (explain-type f #:name "process" #:level "inferred"))
        ;; write the rendered view back out and confirm it still parses —
        ;; the injected `:- T` is real beagle surface, not a debug artifact.
        (define g (make-temporary-file "type-view-rt-~a.bclj"))
        (call-with-output-file g (lambda (o) (display out o)) #:exists 'truncate/replace)
        (check-not-exn (lambda () (parse-program (read-beagle-syntax g)))
                       (format "inferred view did not re-parse:\n~a" out))
        (delete-file g)))))

(test-case "tab-indented source: annotation lands at the right codepoint (not tab-expanded col)"
  ;; syntax-column expands tabs to tab-stops; using it for offsets would
  ;; mis-place the injection. We use syntax-position (codepoint), so a leading
  ;; tab is handled correctly.
  (define tabbed
    (string-append "#lang beagle/clj\n"
                   "(defn process [n :- Int] :- Int\n"
                   "\t(let [a (* n 2)]\n"
                   "\t  a))\n"))
  (with-fixture tabbed
    (lambda (f)
      (define out (explain-type f #:name "process" #:level "inferred"))
      (check-true (string-contains? out "a :- Int (* n 2)")
                  (format "tab-indented injection mis-placed:\n~a" out)))))

(test-case "CRLF source: clean is not truncated/shifted; inferred still works"
  (define crlf
    (string-append "#lang beagle/clj\r\n"
                   "(defn process [n :- Int] :- Int\r\n"
                   "  (let [a (* n 2)]\r\n"
                   "    a))\r\n"))
  (with-fixture crlf
    (lambda (f)
      (define clean (explain-type f #:name "process" #:level "clean"))
      ;; clean must start at the form (no spurious leading blank line) and
      ;; include the whole form (no trailing truncation).
      (check-true (string-prefix? clean "(defn process")
                  (format "CRLF clean view shifted:\n~v" clean))
      (check-true (string-suffix? (string-trim clean) "a))")
                  (format "CRLF clean view truncated:\n~v" clean))
      (define inferred (explain-type f #:name "process" #:level "inferred"))
      (check-true (string-contains? inferred "a :- Int (* n 2)") inferred))))

(test-case "promote (--write) materializes inferred types into the file, idempotently"
  (with-fixture SRC
    (lambda (f)
      ;; before: no interior annotations
      (check-false (string-contains? (file->string f) ":- Int (* n 2)"))
      (explain-type f #:name "process" #:level "inferred" #:write? #t)
      (define after (file->string f))
      ;; after: the inferred types are now in the file
      (check-true (string-contains? after "a :- Int (* n 2)") after)
      (check-true (string-contains? after "b :- Int (+ a 1)") after)
      ;; and it still parses (we wrote real surface, not a debug view)
      (define g (make-temporary-file "promote-rt-~a.bclj"))
      (call-with-output-file g (lambda (o) (display after o)) #:exists 'truncate/replace)
      (check-not-exn (lambda () (parse-program (read-beagle-syntax g))))
      (delete-file g)
      ;; idempotent: promoting again is a no-op (bindings are now annotated,
      ;; so annotate-inferred skips them) — no double `:- Int :- Int`.
      (explain-type f #:name "process" #:level "inferred" #:write? #t)
      (check-equal? (file->string f) after)
      (check-false (string-contains? (file->string f) ":- Int :- Int")))))

(test-case "promote refuses the non-round-tripping `all` level"
  (with-fixture SRC
    (lambda (f)
      (check-exn #rx"--write supports only --level inferred"
                 (lambda () (explain-type f #:name "process" #:level "all" #:write? #t))))))
