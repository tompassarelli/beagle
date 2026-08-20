#lang racket/base

;; Foreground source-closure watcher. The watched set is always the exact
;; module closure; compilation remains owned by the ordinary Store-backed Core
;; build command supplied after `--`.

(require racket/list
         racket/string
         racket/system
         "module-source-root.rkt")

(struct watch-config (roots inputs command) #:transparent)

(define (parse-arguments args)
  (let loop ([remaining args] [roots '()] [inputs '()])
    (cond
      [(null? remaining)
       (error 'beagle-watch "expected `--` followed by a build command")]
      [(string=? (car remaining) "--module-root")
       (when (null? (cdr remaining))
         (error 'beagle-watch "--module-root requires LOGICAL=PHYSICAL"))
       (loop (cddr remaining)
             (cons (parse-module-source-root (cadr remaining)) roots)
             inputs)]
      [(string=? (car remaining) "--source")
       (when (< (length remaining) 3)
         (error 'beagle-watch "--source requires PHYSICAL LOGICAL"))
       (loop (cdddr remaining)
             roots
             (cons (module-source-input (caddr remaining) (cadr remaining))
                   inputs))]
      [(string=? (car remaining) "--")
       (when (null? (cdr remaining))
         (error 'beagle-watch "expected a build command after `--`"))
       (when (null? inputs)
         (error 'beagle-watch "expected at least one explicit source"))
       (watch-config (reverse roots) (reverse inputs) (cdr remaining))]
      [else (error 'beagle-watch "unknown argument: ~a" (car remaining))])))

(define (closure-paths config)
  (for/list ([snapshot
              (in-list
               (module-source-closure-snapshots
                (resolve-module-source-closure
                 (watch-config-inputs config)
                 (watch-config-roots config))))])
    (module-source-snapshot-physical-path snapshot)))

(define (run-build config)
  (define environment (environment-variables-copy
                       (current-environment-variables)))
  (environment-variables-set!
   environment #"BEAGLE_DEV_FACT_REUSE" #"1")
  (parameterize ([current-environment-variables environment])
    (apply system*/exit-code
           (car (watch-config-command config))
           (cdr (watch-config-command config)))))

(define (start-watchers paths changed)
  (for/list ([path (in-list paths)])
    (thread
     (lambda ()
       (let loop ()
         (with-handlers
             ([exn:fail?
               (lambda (error)
                 (eprintf "beagle watch: watcher stopped for ~a: ~a\n"
                          path (exn-message error)))])
           (sync (filesystem-change-evt path))
           (semaphore-post changed)
           (loop)))))))

(define (stop-watchers threads)
  (for ([watcher (in-list threads)])
    (kill-thread watcher)))

(define (drain-changes changed)
  (let loop ()
    (when (semaphore-try-wait? changed) (loop))))

(define (run-watch config)
  (define paths (closure-paths config))
  (define initial-status (run-build config))
  (unless (zero? initial-status) (exit initial-status))
  (define changed (make-semaphore 0))
  (let loop ([current-paths paths]
             [watchers (start-watchers paths changed)])
    (eprintf "beagle watch: watching ~a source~a\n"
             (length current-paths)
             (if (= 1 (length current-paths)) "" "s"))
    (semaphore-wait changed)
    (drain-changes changed)
    (define status (run-build config))
    (if (zero? status)
        (let ([next-paths (closure-paths config)])
          (stop-watchers watchers)
          (drain-changes changed)
          (loop next-paths (start-watchers next-paths changed)))
        (loop current-paths watchers))))

(module+ main
  (with-handlers
      ([exn:fail?
        (lambda (error)
          (eprintf "beagle watch: ~a\n" (exn-message error))
          (exit 2))])
    (run-watch
     (parse-arguments
      (vector->list (current-command-line-arguments))))))
