#lang racket/base

;; CLI backend for bin/beagle-rewrite.
;;
;; Usage:
;;   bin/beagle-rewrite <rule-name> <file-or-dir>           # dry-run, show diff
;;   bin/beagle-rewrite --apply <rule-name> <file-or-dir>   # apply changes
;;   bin/beagle-rewrite --list                              # list available rules

(require racket/cmdline
         racket/file
         racket/path
         racket/port
         racket/string
         "rewrite.rkt"
         ;; Side-effect: register all rewrite rules.
         "rewrites/drop-when.rkt")

(define apply-changes? (make-parameter #f))
(define list-rules? (make-parameter #f))

(define (file-is-beagle? path)
  (define ext (path-get-extension path))
  (and ext
       (member (bytes->string/utf-8 ext)
               '(".bgl" ".bclj" ".bcljs" ".bjs" ".bnix" ".bpy" ".bsql" ".rkt"))
       #t))

(define (collect-files target)
  (cond
    [(file-exists? target) (list target)]
    [(directory-exists? target)
     (find-files (lambda (p)
                   (and (file-exists? p) (file-is-beagle? p)))
                 target)]
    [else (error 'beagle-rewrite "not a file or directory: ~a" target)]))

(define (process-file rule path)
  (define result
    (with-handlers ([exn:fail? (lambda (e)
                                 (eprintf "  SKIP ~a: ~a\n" path (exn-message e))
                                 #f)])
      (rewrite-file rule path)))
  (cond
    [(not result) #f]
    [(not (rewrite-result-changed? result)) #f]
    [else
     (printf "~a:\n" path)
     (cond
       [(apply-changes?)
        (call-with-output-file path #:exists 'truncate
          (lambda (out) (display (rewrite-result-rewritten result) out)))
        (printf "  APPLIED\n")]
       [else
        ;; Show simple diff hint (line count change).
        (define new-lines (length (string-split (rewrite-result-rewritten result) "\n")))
        (printf "  CHANGED (would write ~a lines; pass --apply to write)\n" new-lines)])
     #t]))

(define (run-list)
  (printf "Available rewrite rules:\n\n")
  (for ([r (in-list (all-rules))])
    (printf "  ~a — ~a\n" (rewrite-rule-name r) (rewrite-rule-doc r))))

(define (run-rewrite rule-name-str target)
  (define rule-name (string->symbol rule-name-str))
  (define rule (get-rule rule-name))
  (printf "Rewrite rule: ~a — ~a\n\n" rule-name (rewrite-rule-doc rule))
  (define files (collect-files target))
  (printf "Scanning ~a file(s)...\n\n" (length files))
  (define n-changed
    (for/sum ([f (in-list files)])
      (if (process-file rule f) 1 0)))
  (cond
    [(zero? n-changed)
     (printf "\nNo changes needed.\n")]
    [(apply-changes?)
     (printf "\nApplied to ~a file(s).\n" n-changed)]
    [else
     (printf "\n~a file(s) would change. Pass --apply to write.\n" n-changed)]))

(command-line
 #:program "beagle-rewrite"
 #:once-each
 [("--apply") "Write changes back to source files (default: dry-run)"
              (apply-changes? #t)]
 [("--list") "List available rewrite rules"
             (list-rules? #t)]
 #:args args
 (cond
   [(list-rules?) (run-list)]
   [(< (length args) 2)
    (eprintf "usage: beagle-rewrite [--apply] <rule-name> <file-or-dir>\n")
    (eprintf "       beagle-rewrite --list\n")
    (exit 2)]
   [else
    (run-rewrite (car args) (cadr args))]))
