#lang racket/base

;; Canonical physical layout for function parameters and typed fields. Parsing
;; accepts every whitespace layout; this module owns the deterministic source
;; rewrite used by `beagle fmt`.

(require racket/cmdline
         racket/file
         racket/list
         racket/path
         racket/string
         "parse.rkt")

(provide format-signature-files)

(struct file-format (path source edits) #:transparent)

(define (analyze-file path-like)
  (define path
    (simplify-path
     (path->complete-path
      (if (path? path-like) path-like (string->path path-like)))))
  (unless (file-exists? path)
    (raise-user-error 'beagle-fmt "file does not exist: ~a" path))
  (file-format path (file->string path) (signature-layout-edits path)))

(define (print-edit edit)
  (eprintf "~a:~a:~a: signature layout: ~a~a\n"
           (layout-edit-path edit)
           (or (layout-edit-line edit) 1)
           (add1 (or (layout-edit-col edit) 0))
           (layout-edit-role edit)
           (if (layout-edit-safe? edit)
               ""
               " (automatic rewrite refused: line comment reach could change)")))

(define (atomic-write-string path content)
  (define parent (or (path-only path) (current-directory)))
  (define tmp (make-temporary-file ".beagle-fmt-~a" #f parent))
  (with-handlers ([exn:fail?
                   (lambda (exn)
                     (when (file-exists? tmp) (delete-file tmp))
                     (raise exn))])
    (call-with-output-file tmp
      (lambda (out) (display content out))
      #:exists 'truncate/replace)
    (file-or-directory-permissions
     tmp (file-or-directory-permissions path 'bits))
    (rename-file-or-directory tmp path #t)))

(define (format-signature-files mode paths)
  (unless (memq mode '(check write))
    (raise-argument-error 'format-signature-files "(or/c 'check 'write)" mode))
  (define files (map analyze-file paths))
  (define edits (append-map file-format-edits files))
  (for ([edit (in-list edits)]) (print-edit edit))
  (cond
    [(null? edits) 0]
    [(eq? mode 'check) 3]
    [(ormap (lambda (edit) (not (layout-edit-safe? edit))) edits) 2]
    [else
     (for ([file (in-list files)] #:when (pair? (file-format-edits file)))
       (atomic-write-string
        (file-format-path file)
        (apply-signature-layout-edits
         (file-format-source file) (file-format-edits file))))
     (eprintf "beagle fmt: formatted ~a file~a\n"
              (count (lambda (file) (pair? (file-format-edits file))) files)
              (if (= (count (lambda (file) (pair? (file-format-edits file))) files) 1)
                  "" "s"))
     0]))

(module+ main
  (define mode #f)
  (define mode-count 0)
  (command-line
   #:program "beagle fmt"
   #:once-each
   [("--check") "Report canonical signature-layout drift"
    (set! mode 'check) (set! mode-count (add1 mode-count))]
   [("--write") "Rewrite canonical signature layout in place"
    (set! mode 'write) (set! mode-count (add1 mode-count))]
   #:args paths
   (unless (= mode-count 1)
     (raise-user-error 'beagle-fmt "expected exactly one of --check or --write"))
   (when (null? paths)
     (raise-user-error 'beagle-fmt "expected at least one Beagle source file"))
   (exit (format-signature-files mode paths))))
