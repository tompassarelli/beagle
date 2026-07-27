#lang racket/base

;; #32 — the codemod framework reads + writes the FULL surface.
;;
;; rewrite.rkt used to carry its own subset readtable (only {…} #{…} #"re") paired
;; with a subset writer. Modern beagle source corrupted on read (#?/#(/^/~), so a
;; codemod over such a file produced garbage. It now reads with THE canonical
;; beagle-readtable (datum mode) and the writer round-trips every reader tag. This
;; guard pins the read→write→re-read identity across the full surface.

(require rackunit
         racket/file
         racket/port
         (only-in beagle/lang/reader-impl beagle-read)
         (only-in beagle/private/rewrite
                  read-beagle-source write-beagle-source
                  define-rewrite get-rule rewrite-text
                  rewrite-result-changed? rewrite-result-rewritten)
         beagle/private/rewrites/case-to-match)

(define (read-all str)
  (let ([in (open-input-string str)])
    (let loop ([acc '()])
      (define d (beagle-read in))
      (if (eof-object? d) (reverse acc) (loop (cons d acc))))))

(define FULL-SURFACE
  (string-append
   "#lang beagle/clj\n"
   "(def v [1 2 #?@(:clj [3 4] :default [])])\n"
   "(def r #\"a.*b\")\n"
   "(def ^:dynamic *x* 1)\n"
   "(def t `(a ~b ~@cs))\n"
   "(def q 'sym)\n"
   "(def m {:k v :j #{:a :b}})\n"
   "(def f #(inc %))\n"))

(test-case "read-beagle-source → write-beagle-source → re-read is identity (full surface)"
  (define tmp (make-temporary-file "rwrt-~a.bclj"))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file tmp (lambda (o) (display FULL-SURFACE o))
       #:exists 'truncate/replace)
     (define-values (lang forms) (read-beagle-source tmp))
     (define out (open-output-string))
     (write-beagle-source forms out)
     (define re (read-all (get-output-string out)))
     (check-equal? re forms
                   (format "rewrite round-trip changed forms.\nwritten:\n~a"
                           (get-output-string out))))
   (lambda () (delete-file tmp))))

(test-case "an identity rewrite preserves full-surface forms"
  (define-rewrite noop "identity")  ; no match clauses → falls through to identity
  (define res (rewrite-text (get-rule 'noop)
                            "(def v [#?@(:clj [1] :default [])]) (def f #(+ %1 %2))"))
  ;; re-reading the rewritten text yields the same datums the reader produced
  (check-equal? (read-all (rewrite-result-rewritten res))
                (read-all "(def v [#?@(:clj [1] :default [])]) (def f (fn [%1 %2] (+ %1 %2)))")))

(test-case "case-to-match preserves keyword and string dispatch shape"
  (define res
    (rewrite-text
     (get-rule 'case-to-match)
     "(defn dispatch [x] (case x :open 1 :closed 2 0))
      (defn mode [x] (case x \"read\" :r \"write\" :w))"))
  (check-true (rewrite-result-changed? res))
  (check-equal?
   (read-all (rewrite-result-rewritten res))
   (read-all
    "(defn dispatch [x] (match x [:open 1] [:closed 2] [_ 0]))
     (defn mode [x] (match x [\"read\" :r] [\"write\" :w]))")))

(test-case "case-to-match turns grouped constants into an or-pattern"
  (define res
    (rewrite-text
     (get-rule 'case-to-match)
     "(case kind (:assert :link) :write (:retract :untell) :remove :unknown)"))
  (check-equal?
   (read-all (rewrite-result-rewritten res))
   (read-all
    "(match kind [(or :assert :link) :write] [(or :retract :untell) :remove] [_ :unknown])")))

(test-case "case-to-match rewrites nested cases bottom-up"
  (define res
    (rewrite-text
     (get-rule 'case-to-match)
     "(case outer :a (case inner \"x\" 1 0) 2)"))
  (check-equal?
   (read-all (rewrite-result-rewritten res))
   (read-all
    "(match outer [:a (match inner [\"x\" 1] [_ 0])] [_ 2])")))

(test-case "case-to-match leaves symbol dispatch for manual cond migration"
  (define source "(case (first form) ns :namespace require :dependency :other)")
  (define res (rewrite-text (get-rule 'case-to-match) source))
  (check-false (rewrite-result-changed? res))
  (check-equal? (read-all (rewrite-result-rewritten res))
                (read-all source)))
