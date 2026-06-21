#lang racket/base

;; #32 — `beagle expand` reads + renders the FULL surface.
;;
;; expand-tool used to carry its OWN subset readtable (only {…} #{…} #"re") and a
;; printer with no cases for reader conditionals / ^meta / #%regex / quote family,
;; so any modern beagle source corrupted: `#?(…)` read as a bare symbol `#?` plus
;; a stray list, `#(…)` as `#` + a list, `~x` as the symbol `~x`. For an
;; LLM-facing "show me the expansion" tool that is a surface-coherence hazard.
;;
;; expand-tool now reads with THE canonical beagle-readtable (datum mode) and the
;; renderer round-trips every reader tag back to surface. This suite pins both:
;;   (1) the reader no longer chokes — full surface reads to the right tags;
;;   (2) datum->beagle-src renders each tag to exact surface AND round-trips;
;;   (3) macro expansion still works end-to-end and its output re-reads.

(require rackunit
         racket/file
         (only-in beagle/lang/reader-impl beagle-read)
         (only-in beagle/private/expand-tool
                  read-file-datums datum->beagle-src expand-datums))

;; --- (1) reader reads the full surface without choking ----------------------

(define (read-src str)
  (define tmp (make-temporary-file "exp-~a.bclj"))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file tmp
       (lambda (o) (fprintf o "#lang beagle/clj\n~a\n" str))
       #:exists 'truncate/replace)
     (read-file-datums tmp))
   (lambda () (delete-file tmp))))

(test-case "reader: #?(…) reads as ONE reader-conditional form (not symbol #? + list)"
  (check-equal? (read-src "(def x #?(:clj 1 :nix 2))")
                '((def x (reader-conditional :clj 1 :nix 2)))))

(test-case "reader: #(…) fn-shorthand reads as a real fn (not symbol # + list)"
  (check-equal? (read-src "(def f #(inc %))")
                '((def f (fn (#%brackets %1) (inc %1))))))

(test-case "reader: ^meta reads as #%meta (not a mangled symbol)"
  (check-equal? (read-src "(def ^:dynamic *x* 1)")
                '((def (#%meta :dynamic *x*) 1))))

(test-case "reader: ~ / ~@ in a quasiquote read as unquote / unquote-splicing"
  (check-equal? (read-src "(def t `(a ~b ~@cs))")
                '((def t (quasiquote (a (unquote b) (unquote-splicing cs)))))))

(test-case "reader: #\"re\" reads as #%regex, #?@ splices inside a vector"
  (check-equal? (read-src "(def v [#\"a.*\" #?@(:clj [1 2] :default [])])")
                '((def v (#%brackets (#%regex "a.*")
                          (reader-conditional-splice :clj (#%brackets 1 2)
                                                     :default (#%brackets)))))))

;; --- (2) renderer: exact surface + round-trip -------------------------------

(define RT-BATTERY
  (list "[a b c]" "[[1 2] [3 4]]" "{:k v :j w}" "#{1 2 3}"
        "#\"a.*b\"" "^:dynamic *x*" "^{:doc \"d\"} y"
        "#?(:clj 1 :nix 2)" "#?@(:clj [1 2] :default [])"
        "'x" "'(a b)" "`(a ~b ~@cs)" "true" "false"
        "(fn [%1] (inc %1))" "(defn f [a :- Int] :- Int a)"))

(for ([s (in-list RT-BATTERY)])
  (test-case (format "renderer round-trips: ~a" s)
    (define d (beagle-read (open-input-string s)))
    (define d2 (beagle-read (open-input-string (datum->beagle-src d))))
    (check-equal? d2 d (format "round-trip changed datum for: ~a (rendered ~a)"
                               s (datum->beagle-src d)))))

(test-case "renderer: exact surface for the previously-broken tags"
  (define (render s) (datum->beagle-src (beagle-read (open-input-string s))))
  (check-equal? (render "#?(:clj 1 :nix 2)")        "#?(:clj 1 :nix 2)")
  (check-equal? (render "#?@(:clj [1 2] :default [])") "#?@(:clj [1 2] :default [])")
  (check-equal? (render "^:dynamic *x*")             "^:dynamic *x*")
  (check-equal? (render "#\"a.*b\"")                 "#\"a.*b\"")
  (check-equal? (render "'x")                        "'x")
  (check-equal? (render "`(a ~b ~@cs)")              "`(a ~b ~@cs)")
  (check-equal? (render "true")                      "true")
  (check-equal? (render "false")                     "false"))

;; --- (3) macro expansion still works, output re-reads -----------------------

(test-case "expand-datums: macro expands; full-surface neighbours survive + re-read"
  (define tmp (make-temporary-file "exp-int-~a.bclj"))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file tmp
       (lambda (o)
         (display (string-append
                   "#lang beagle/clj\n"
                   "(defmacro twice [x] `(do ~x ~x))\n"
                   "(def r #\"a.*b\")\n"
                   "(def v [1 2 #?@(:clj [3] :default [])])\n"
                   "(twice (f 1))\n") o))
       #:exists 'truncate/replace)
     (define out (expand-datums tmp))
     ;; the macro use expanded
     (check-true (and (member '(do (f 1) (f 1)) out) #t)
                 (format "twice did not expand as expected; got: ~s" out))
     ;; the regex + reader-conditional neighbours are preserved as tags
     (check-true (and (member '(def r (#%regex "a.*b")) out) #t))
     ;; every expanded form renders to re-readable surface
     (for ([form (in-list out)])
       (define rendered (datum->beagle-src form))
       (check-not-exn (lambda () (beagle-read (open-input-string rendered)))
                      (format "expanded form did not re-read: ~a" rendered))))
   (lambda () (delete-file tmp))))
