#lang racket/base
;; Falsify "valid beagle" standing in for "faithful". The high bar: the mutated,
;; re-projected, re-read tree must equal the ORIGINAL tree with EXACTLY the
;; symbol substitution applied and nothing else (types, structure, every other
;; form intact). With no substitution args, asserts the file is byte/datum-identical
;; (the untouched-file case).
;;   racket faith.rkt <orig.bjs> <mutated.edn> [<old-sym> <new-sym>]
;; BEAGLE_HOME can select another checkout; the default is the primary checkout.
(require racket/string racket/list racket/file)
(define beagle-home
  (or (getenv "BEAGLE_HOME")
      (build-path (find-system-path 'home-dir) "code" "beagle" "main")))
(define parse-path (build-path beagle-home "beagle-lib/private/parse.rkt"))
(define facts-roundtrip-path
  (build-path beagle-home "beagle-lib/private/facts-roundtrip.rkt"))
(define read-beagle-syntax (dynamic-require parse-path 'read-beagle-syntax))
(define edn-triples->datum (dynamic-require facts-roundtrip-path 'edn-triples->datum))
(define read-edn-triples (dynamic-require facts-roundtrip-path 'read-edn-triples))
(define datum->src (dynamic-require facts-roundtrip-path 'datum->src))
(define args (current-command-line-arguments))
(define orig-file (vector-ref args 0))
(define mut-edn   (vector-ref args 1))
(define subst?    (>= (vector-length args) 4))
(define old (and subst? (string->symbol (vector-ref args 2))))
(define new (and subst? (string->symbol (vector-ref args 3))))
(define (subst d)
  (cond [(and subst? (eq? d old)) new]
        [(pair? d) (cons (subst (car d)) (subst (cdr d)))]
        [(vector? d) (list->vector (map subst (vector->list d)))]
        [else d]))                                   ; strings, numbers, other symbols untouched
(define orig (map syntax->datum (read-beagle-syntax orig-file)))
(define expected (map subst orig))
(define mut-pre (cdr (edn-triples->datum (read-edn-triples mut-edn))))
(define txt (string-join (map datum->src mut-pre) "\n\n"))
(define tmp (make-temporary-file "faith-~a.bjs"))
(with-output-to-file tmp #:exists 'replace (lambda () (display txt)))
(define mut (with-handlers ([exn:fail? (lambda (e) (printf "REREAD ERROR: ~a\n" (exn-message e)) #f)])
              (map syntax->datum (read-beagle-syntax tmp))))
(cond
  [(not mut) (printf "FAIL — mutated source did not re-read\n")]
  [(equal? mut expected)
   (printf "PASS — mutated tree == original tree with ONLY ~a applied; ~a forms, nothing else changed\n"
           (if subst? (format "~a->~a" old new) "no substitution (untouched)") (length mut))]
  [else
   (printf "FAIL — mutated tree diverges from expected:\n")
   (unless (= (length expected) (length mut))
     (printf "  FORM COUNT expected ~a got ~a\n" (length expected) (length mut)))
   (for ([a expected] [b mut] [i (in-naturals)])
     (unless (equal? a b) (printf "  form ~a:\n   expected=~.s\n   got=     ~.s\n" i a b)))])
