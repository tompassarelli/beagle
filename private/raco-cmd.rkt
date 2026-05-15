#lang racket/base

(require racket/port
         racket/file
         racket/format
         "expand-tool.rkt")

(define args (vector->list (current-command-line-arguments)))

(define (usage)
  (eprintf "usage: raco beagle <command> [args...]\n")
  (eprintf "  build  <source.rkt> [output.clj]  compile to Clojure\n")
  (eprintf "  check  <source.rkt>               type-check only\n")
  (eprintf "  expand <source.rkt>               show macro expansion\n")
  (exit 2))

(when (null? args) (usage))

(define (resolve-source src)
  (define path (path->complete-path (string->path src)))
  (unless (file-exists? path)
    (eprintf "beagle: file not found: ~a\n" src)
    (exit 1))
  path)

(define (compile-source src-path)
  (with-handlers ([exn:fail? (lambda (e) (eprintf "~a\n" (exn-message e)) (exit 1))])
    (with-output-to-string (lambda () (dynamic-require src-path #f)))))

(define subcommand (car args))
(define subargs (cdr args))

(case subcommand
  [("build")
   (unless (and (>= (length subargs) 1) (<= (length subargs) 2))
     (eprintf "usage: raco beagle build <source.rkt> [output.clj]\n")
     (exit 2))
   (define src-path (resolve-source (car subargs)))
   (define output (compile-source src-path))
   (cond
     [(= (length subargs) 2)
      (define out (cadr subargs))
      (make-parent-directory* (string->path out))
      (call-with-output-file out
        (lambda (port) (display output port))
        #:exists 'replace)
      (eprintf "~a -> ~a\n" (car subargs) out)]
     [else (display output)])]

  [("check")
   (unless (= (length subargs) 1)
     (eprintf "usage: raco beagle check <source.rkt>\n")
     (exit 2))
   (define src-path (resolve-source (car subargs)))
   (compile-source src-path)
   (eprintf "~a: ok\n" (car subargs))]

  [("expand")
   (unless (= (length subargs) 1)
     (eprintf "usage: raco beagle expand <source.rkt>\n")
     (exit 2))
   (define src (car subargs))
   (unless (file-exists? src)
     (eprintf "beagle: file not found: ~a\n" src)
     (exit 1))
   (expand-file src)]

  [else
   (eprintf "raco beagle: unknown command '~a'\n" subcommand)
   (usage)])
