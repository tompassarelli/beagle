#lang racket/base

;; #19 GUARD — the two reader entry points must agree, forever.
;;
;; Beagle has two ways into the reader:
;;   • the #lang path     — beagle-read / beagle-read-syntax (module load →
;;     `bin/beagle check`); drives #lang beagle/* compilation.
;;   • the parse.rkt path — read-beagle-syntax (check --agent / build / build-all
;;     / repair loop / PostToolUse hook).
;;
;; Historically these were TWO hand-maintained readtables that silently drifted:
;; the parse.rkt copy lacked #?/#?@ reader conditionals and the #<<heredoc
;; pointed error (it read `#?` as a bare symbol → "malformed def"/"unexpected
;; dispatch sequence" on the build path only). #19 collapsed them to ONE
;; imported `beagle-readtable`. This suite is the regression guard: if anyone
;; re-introduces a divergent reader in parse.rkt, the battery below diverges and
;; this test goes red. It also covers two features that had ZERO tests
;; (#<<heredoc error, #r#"…"# raw strings).
;;
;; Method: read each form through BOTH paths and assert identical datums. The
;; parse path canonicalizes the leading `#lang beagle/clj` into a
;; `(define-target clj)` form, so we read the SECOND form back.

(require rackunit
         racket/file
         beagle/lang/reader-impl
         (only-in beagle/private/parse read-beagle-syntax))

;; --- the two paths ----------------------------------------------------------

;; #lang path: one datum from the string, via the (now single) beagle readtable.
(define (lang-path form-str)
  (beagle-read (open-input-string form-str)))

;; parse.rkt path: write `#lang beagle/clj\n<form>` to a temp file, read it with
;; read-beagle-syntax, and return the user form's datum (after define-target).
(define (parse-path form-str)
  (define tmp (make-temporary-file "rpp-~a.bclj"))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file tmp
       (lambda (o) (fprintf o "#lang beagle/clj\n~a\n" form-str))
       #:exists 'truncate/replace)
     (define forms (map syntax->datum (read-beagle-syntax tmp)))
     ;; forms = ((define-target clj) <user-form>)
     (unless (and (= (length forms) 2)
                  (equal? (car forms) '(define-target clj)))
       (error 'parse-path "unexpected framing: ~v" forms))
     (cadr forms))
   (lambda () (delete-file tmp))))

(define (check-paths-agree form-str)
  (check-equal? (parse-path form-str) (lang-path form-str)
                (format "reader paths diverge on: ~a" form-str)))

;; --- battery: every reader feature, with nesting + combinations -------------

(define BATTERY
  (list
   ;; containers + nesting
   "[a b c]"
   "[[1 2] [3 4]]"
   "{:k v :j [1 2 3]}"
   "{:m {:n #{1 2}}}"
   "#{1 2 3}"
   "#{[a b] {:k v}}"
   ;; commas-as-whitespace (Clojure), trailing comma close-edge
   "[a, b, c,]"
   "{:k v, :j w,}"
   "#{x, y,}"
   ;; quote family
   "'x"
   "'(a b c)"
   "'[a b]"
   "'{:k v}"
   ;; quasiquote / unquote / splice (uniform across targets)
   "`(a ~b ~@cs)"
   "`[~x ~@ys z]"
   "`{:k ~v}"
   ;; metadata reader
   "^:dynamic *x*"
   "^{:doc \"d\"} y"
   "(def ^:private z 1)"
   ;; regex + raw string
   "#\"a.*b\""
   "#r#\"raw \\ \" string\"#"
   ;; #(...) fn-shorthand (body wrapped in [%1 ...])
   "#(inc %)"
   "#(+ %1 %2)"
   "#(apply f %&)"
   ;; reader conditionals — read-time tagged containers (selection is parse-time)
   "#?(:clj 1 :cljs 2 :nix 3)"
   "#?(:default 0 :clj 1)"
   "#?@(:clj [1 2] :cljs [3])"
   ;; reader conditional spliced INSIDE a container
   "[a #?@(:clj [b c] :default []) d]"
   "{:a 1 #?@(:clj [:b 2] :default [])}"
   ;; realistic mixed form — typed defn with destructuring + threading + brackets
   "(defn f [a: Int [x y] -> Vec] -> Int (-> a (+ x) (* y)))"))

(for ([form (in-list BATTERY)])
  (test-case (format "reader paths agree: ~a" form)
    (check-paths-agree form)))

;; --- coverage for the two previously-untested reader features ---------------

(test-case "#<<heredoc gives the pointed (s …)/(ms …) error on BOTH paths"
  ;; #lang path
  (check-exn #rx"(?i:heredoc|\\(s |\\(ms )"
             (lambda () (lang-path "#<<EOF\nx\nEOF")))
  ;; parse path
  (define tmp (make-temporary-file "rpp-heredoc-~a.bclj"))
  (check-exn #rx"(?i:heredoc|\\(s |\\(ms )"
             (lambda ()
               (call-with-output-file tmp
                 (lambda (o) (display "#lang beagle/clj\n(def x #<<EOF\nbody\nEOF\n)\n" o))
                 #:exists 'truncate/replace)
               (read-beagle-syntax tmp)))
  (delete-file tmp))

(test-case "#r#\"…\"# raw string reads its body verbatim (no escape processing)"
  ;; backslash and embedded quote survive literally; agreement across paths.
  (check-equal? (lang-path "#r#\"a\\nb \" c\"#") "a\\nb \" c")
  (check-paths-agree "#r#\"a\\nb \" c\"#")
  ;; N-hash variant so a single #" inside the body is not a close
  (check-equal? (lang-path "#r##\"has \"# inside\"##") "has \"# inside"))
