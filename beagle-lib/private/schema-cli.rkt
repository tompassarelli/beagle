#lang racket/base

;; schema-cli — CLI for interactive NixOS schema queries.
;;
;; Modes:
;;   <path>              exact lookup: show type, enum, inner type
;;   --children <prefix> list all options under a prefix with types
;;   --search <query>    fuzzy substring search (up to 20 results)
;;   --json <path>       machine-readable JSON output

(require racket/cmdline
         racket/string
         racket/list
         racket/format
         json
         "nixos-schema.rkt")

(provide schema-cli-main)

;; ============================================================================
;; Schema loading
;; ============================================================================

(define (find-and-load-schema)
  ;; find-schema-json expects a file path (it splits off the filename).
  ;; Pass a dummy file in cwd so the walk starts from the right directory.
  (define dummy (build-path (current-directory) "dummy.nix"))
  (define schema-path (find-schema-json dummy))
  (unless schema-path
    (eprintf "beagle-schema: no .beagle-cache/schema.json found (walked up from ~a)\n"
             (current-directory))
    (exit 1))
  (load-nixos-schema schema-path))

;; ============================================================================
;; Exact lookup (human)
;; ============================================================================

(define (run-lookup schema path-str)
  (define entry (nixos-option-lookup schema path-str))
  (cond
    [entry (print-entry path-str entry)]
    [else
     (printf "not found: ~a\n" path-str)
     (define suggestions (nixos-find-similar schema path-str))
     (when (pair? suggestions)
       (printf "\ndid you mean:\n")
       (for ([s (in-list (take suggestions (min 10 (length suggestions))))])
         (printf "  ~a\n" s)))
     (exit 1)]))

(define (print-entry path-str entry)
  (printf "~a\n" path-str)
  (printf "  type: ~a\n" (hash-ref entry 't "?"))
  (define enum-vals (hash-ref entry 'enum #f))
  (when enum-vals
    (printf "  enum: ~a\n" (string-join (map ~a enum-vals) ", ")))
  (define inner (hash-ref entry 'inner #f))
  (when inner
    (printf "  inner: ~a\n" (hash-ref inner 't "?")))
  (define decls (hash-ref entry 'declarations #f))
  (when (and decls (pair? decls))
    (printf "  declared in:\n")
    (for ([d (in-list decls)])
      (printf "    ~a\n" d))))

;; ============================================================================
;; Exact lookup (JSON)
;; ============================================================================

(define (run-lookup-json schema path-str)
  (define entry (nixos-option-lookup schema path-str))
  (cond
    [entry
     (write-json (hash-set entry 'schemaVersion 1))
     (newline)]
    [else
     (define suggestions (nixos-find-similar schema path-str))
     (write-json
      (hasheq 'schemaVersion 1
              'error "not found"
              'path path-str
              'suggestions (take suggestions (min 10 (length suggestions)))))
     (newline)
     (exit 1)]))

;; ============================================================================
;; Children mode
;; ============================================================================

(define (run-children schema prefix)
  (define prefix-dot (string-append prefix "."))
  (define prefix-len (string-length prefix-dot))
  (define table (nixos-schema-table schema))
  (define matches
    (sort
     (for/list ([key (in-hash-keys table)]
                #:when (and (string? key)
                            (>= (string-length key) prefix-len)
                            (string=? (substring key 0 prefix-len) prefix-dot)))
       key)
     string<?))
  (cond
    [(null? matches)
     (printf "no options under: ~a\n" prefix)
     (exit 1)]
    [else
     (printf "~a option(s) under ~a:\n\n" (length matches) prefix)
     (for ([key (in-list matches)])
       (define entry (hash-ref table key))
       (define type-str (hash-ref entry 't "?"))
       (printf "  ~a : ~a\n" key type-str))]))

;; ============================================================================
;; Search mode
;; ============================================================================

(define (run-search schema query)
  (define query-lower (string-downcase query))
  (define table (nixos-schema-table schema))
  (define matches
    (sort
     (for/list ([key (in-hash-keys table)]
                #:when (string-contains? (string-downcase key) query-lower))
       key)
     string<?))
  (define results (take matches (min 20 (length matches))))
  (cond
    [(null? results)
     (printf "no matches for: ~a\n" query)
     (exit 1)]
    [else
     (printf "~a match(es) for \"~a\"~a:\n\n"
             (length matches) query
             (if (> (length matches) 20)
                 (format " (showing 20 of ~a)" (length matches))
                 ""))
     (for ([key (in-list results)])
       (define entry (hash-ref table key))
       (define type-str (hash-ref entry 't "?"))
       (printf "  ~a : ~a\n" key type-str))]))

;; ============================================================================
;; Main
;; ============================================================================

(define (schema-cli-main)
  (define mode (make-parameter 'lookup))
  (define json-mode? (make-parameter #f))

  (define args
    (command-line
     #:program "beagle-schema"
     #:once-any
     [("--children") "List all options under a prefix" (mode 'children)]
     [("--search") "Substring search across all paths" (mode 'search)]
     [("--json") "Machine-readable JSON output" (json-mode? #t)]
     #:args rest
     rest))

  (when (null? args)
    (eprintf "usage: beagle-schema <path>\n")
    (eprintf "       beagle-schema --children <prefix>\n")
    (eprintf "       beagle-schema --search <query>\n")
    (eprintf "       beagle-schema --json <path>\n")
    (exit 2))

  (define query-str (car args))
  (define schema (find-and-load-schema))

  (case (mode)
    [(lookup)
     (if (json-mode?)
         (run-lookup-json schema query-str)
         (run-lookup schema query-str))]
    [(children) (run-children schema query-str)]
    [(search) (run-search schema query-str)]))

(module+ main
  (schema-cli-main))
