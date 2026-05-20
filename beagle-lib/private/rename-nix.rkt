#lang racket/base

;; beagle-rename — rename option paths across .bnix files.
;;
;; Text-based refactoring: dotted paths in .bnix appear as keywords
;; (`:myConfig.modules.foo.enable`) or dotted identifiers, making them
;; easy to match textually with word-boundary semantics.
;;
;; Skips matches inside string literals (tracks quote nesting).

(require racket/cmdline
         racket/string
         racket/file
         racket/list
         racket/port)

;; ---------------------------------------------------------------------------
;; File discovery
;; ---------------------------------------------------------------------------

(define skip-dirs '(".git" "tests" "scripts" "node_modules" ".direnv" "result"))

(define (find-bnix-files root)
  (let loop ([dir root] [acc '()])
    (define entries
      (with-handlers ([exn:fail:filesystem? (lambda (_) '())])
        (sort (directory-list dir) path<?)))
    (for/fold ([acc acc])
              ([p (in-list entries)])
      (define full (build-path dir p))
      (define name (path->string p))
      (cond
        [(directory-exists? full)
         (if (member name skip-dirs)
             acc
             (loop full acc))]
        [(and (file-exists? full)
              (regexp-match? #rx"\\.bnix$" name))
         (cons (path->string full) acc)]
        [else acc]))))

;; ---------------------------------------------------------------------------
;; Word-boundary matching
;; ---------------------------------------------------------------------------

;; Word-boundary semantics for dotted option paths:
;;
;; BEFORE the match: the preceding char must not be part of a path
;; (alphanumeric, dot, hyphen, underscore). Colon is fine (keyword prefix).
;;
;; AFTER the match: the following char may be a dot (subpath continues —
;; e.g. `services.openssh.enable` matches `services.openssh`) but must
;; NOT be alphanumeric, hyphen, or underscore (which would mean the
;; segment continues — e.g. `services.opensshd` does NOT match
;; `services.openssh`).
(define segment-chars
  (string->list "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"))

(define path-chars
  (cons #\. segment-chars))

(define (path-char? c)
  (memv c path-chars))

(define (segment-char? c)
  (memv c segment-chars))

(define (word-boundary-before? line pos)
  (or (zero? pos)
      (let ([c (string-ref line (sub1 pos))])
        (not (path-char? c)))))

(define (word-boundary-after? line pos len)
  (define end (+ pos len))
  (or (>= end (string-length line))
      (let ([c (string-ref line end)])
        ;; Allow dot (subpath continues) but reject segment chars
        ;; (would mean partial match within the same segment)
        (not (segment-char? c)))))

;; ---------------------------------------------------------------------------
;; Quote-context detection
;; ---------------------------------------------------------------------------

;; Returns #t if the position `pos` in `line` is inside a string literal.
;; Tracks quote nesting from the start of the line — this is a simple
;; heuristic that handles the common case of single-line strings.
;; Escaped quotes (\") are handled.
(define (inside-string? line pos)
  (let loop ([i 0] [in-str #f])
    (cond
      [(>= i pos) in-str]
      [else
       (define c (string-ref line i))
       (cond
         [(and (char=? c #\\) in-str)
          ;; skip escaped char
          (loop (+ i 2) in-str)]
         [(char=? c #\")
          (loop (add1 i) (not in-str))]
         [else
          (loop (add1 i) in-str)])])))

;; ---------------------------------------------------------------------------
;; Line-level replacement
;; ---------------------------------------------------------------------------

;; Replace all word-bounded occurrences of `old` with `new` in `line`,
;; skipping matches inside string literals.
;; Returns (values new-line edit-count).
(define (replace-in-line line old new)
  (define old-len (string-length old))
  (define line-len (string-length line))
  (let loop ([start 0] [acc ""] [count 0])
    (define idx (for/first ([i (in-range start line-len)]
                            #:when (and (<= (+ i old-len) line-len)
                                        (string=? (substring line i (+ i old-len)) old)))
                  i))
    (cond
      [(not idx)
       (values (string-append acc (substring line start)) count)]
      [(and (word-boundary-before? line idx)
            (word-boundary-after? line idx old-len)
            (not (inside-string? line idx)))
       ;; Match: replace
       (loop (+ idx old-len)
             (string-append acc (substring line start idx) new)
             (add1 count))]
      [else
       ;; Not a valid match (partial word or inside string): skip past
       (loop (add1 idx)
             (string-append acc (substring line start (add1 idx)))
             count)])))

;; ---------------------------------------------------------------------------
;; File processing
;; ---------------------------------------------------------------------------

(struct file-result (path old-lines new-lines edit-count) #:transparent)

(define (process-file path old-path new-path)
  (define content (file->string path))
  (define lines (string-split content "\n" #:trim? #f))
  (define total-edits 0)
  (define new-lines
    (for/list ([line (in-list lines)])
      (define-values (new-line edits) (replace-in-line line old-path new-path))
      (set! total-edits (+ total-edits edits))
      new-line))
  (file-result path lines new-lines total-edits))

;; ---------------------------------------------------------------------------
;; Diff display
;; ---------------------------------------------------------------------------

(define (print-diff result)
  (define path (file-result-path result))
  (define old-lines (file-result-old-lines result))
  (define new-lines (file-result-new-lines result))
  (printf "--- a/~a\n" path)
  (printf "+++ b/~a\n" path)
  (for ([old-line (in-list old-lines)]
        [new-line (in-list new-lines)]
        [i (in-naturals 1)])
    (unless (string=? old-line new-line)
      (printf "@@ -~a,1 +~a,1 @@\n" i i)
      (printf "-~a\n" old-line)
      (printf "+~a\n" new-line))))

;; ---------------------------------------------------------------------------
;; Main
;; ---------------------------------------------------------------------------

(module+ main
  (define dry-run? (make-parameter #f))

  (define args
    (command-line
     #:program "beagle-rename"
     #:once-each
     [("--dry-run") "Show planned changes without writing" (dry-run? #t)]
     #:args (old-path new-path)
     (list old-path new-path)))

  (define old-path (first args))
  (define new-path (second args))

  (when (string=? old-path new-path)
    (eprintf "beagle-rename: old and new paths are identical\n")
    (exit 1))

  (define root (current-directory))
  (define files (sort (find-bnix-files root) string<?))

  (when (null? files)
    (eprintf "beagle-rename: no .bnix files found under ~a\n" (path->string root))
    (exit 1))

  (define results
    (for/list ([f (in-list files)])
      (process-file f old-path new-path)))

  (define changed (filter (lambda (r) (> (file-result-edit-count r) 0)) results))

  (cond
    [(null? changed)
     (printf "No occurrences of ~a found in ~a file(s).\n" old-path (length files))]
    [else
     (for ([r (in-list changed)])
       (cond
         [(dry-run?)
          (print-diff r)]
         [else
          (define new-content (string-join (file-result-new-lines r) "\n"))
          (display-to-file new-content (file-result-path r) #:exists 'replace)]))

     (define total-edits (apply + (map file-result-edit-count changed)))
     (printf "\n~a: ~a edit(s) in ~a file(s)~a (scanned ~a file(s))\n"
             (if (dry-run?) "dry-run" "renamed")
             total-edits
             (length changed)
             (if (dry-run?) "" (format " — ~a → ~a" old-path new-path))
             (length files))]))
