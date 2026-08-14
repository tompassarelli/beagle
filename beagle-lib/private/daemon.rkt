#lang racket/base

;; beagle-daemon: persistent query server.
;;
;; Keeps parsed ASTs and type environments in memory between invocations.
;; Protocol: one command per line on stdin, JSON response per line on stdout.
;;
;; Commands:
;;   sig <fn-name> <file-or-dir>...
;;   fields <record-name> <file-or-dir>...
;;   callers <fn-name> <file-or-dir>...
;;   provides <file>
;;   impact <fn-name> <file-or-dir>...
;;   check <file-or-dir>...
;;   check-enriched <file-or-dir>...     full type check + enriched context
;;   build <out-dir> <file-or-dir>...    parse + check + emit to out-dir (~100ms warm)
;;   repair <file>                        structural repair (fix delimiters in-place)
;;   check-result [<file>]               latest pre-computed result from watcher
;;   latest-results                      all results since last query (clears buffer)
;;   watch <dir>                         start inotify watcher on directory
;;   unwatch                             stop all watchers
;;   invalidate [<file>]
;;   ping
;;   quit
;;
;; Response: JSON object with "ok" or "error" key, one line per response.

(require json
         racket/string
         racket/port
         racket/match
         racket/tcp
         racket/file
         racket/list
         file/sha1
         "parse.rkt"
         "check.rkt"
         "check-all.rkt"
         "emit.rkt"
         "query.rkt"
         "blame.rkt"
         "types.rkt"
         "extensions.rkt"
         "syntax.rkt")

;; --- Cache -------------------------------------------------------------------

(define datum-cache (make-hash))  ; path -> (list mtime datums)

(define (get-datums path)
  (define mtime (file-or-directory-modify-seconds (string->path path)))
  (define cached (hash-ref datum-cache path #f))
  (if (and cached (= (car cached) mtime))
      (cadr cached)
      (let ([datums (map strip-target-export (read-beagle-datums path))])
        (hash-set! datum-cache path (list mtime datums))
        datums)))

(define (invalidate-cache! [path #f])
  (if path
      (hash-remove! datum-cache path)
      (hash-clear! datum-cache)))

(define (find-beagle-in args)
  (apply append
    (for/list ([a (in-list args)])
      (cond
        [(directory-exists? a)
         (for/list ([f (in-directory a)]
                    #:when (regexp-match? BEAGLE-FILE-RX (path->string f)))
           (path->string f))]
        [(file-exists? a)
         (require-beagle-source-extension! a 'beagle-daemon)
         (list a)]
        [else '()]))))

;; --- Check results cache -----------------------------------------------------

(define check-results (make-hash))   ; path -> hasheq with errors, hash, timestamp
(define check-sema (make-semaphore 1)) ; serialize type checking (global state)
(define watcher-threads (make-hash)) ; path -> thread
(define watch-dir-threads '())       ; list of directory watcher threads
(define watched-dirs '())            ; list of watched directory paths (simplified)
(define pending-results (make-hash)) ; path -> hasheq (consumed by latest-results)

(define (file-content-hash path)
  (with-handlers ([exn:fail? (lambda (_) "unknown")])
    (call-with-input-file path sha1)))

(define (try-structural-repair! path)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define source (file->string path))
    (define r (repair-structure source))
    (cond
      [(and (repair-result-changed? r)
            (eq? (repair-result-confidence r) 'high))
       (call-with-output-file path
         (lambda (out) (write-string (repair-result-output r) out))
         #:exists 'truncate/replace)
       (hasheq 'repaired #t
               'edits (for/list ([e (in-list (repair-result-edits r))])
                        (hasheq 'line (repair-edit-line e)
                                'text (repair-edit-insert-text e)
                                'reason (repair-edit-reason e)))
               'confidence "high")]
      [(repair-result-changed? r)
       (hasheq 'repaired #f
               'confidence (symbol->string (repair-result-confidence r))
               'diagnostics (for/list ([d (in-list (repair-result-diagnostics r))])
                              (hasheq 'line (structural-diagnostic-line d)
                                      'message (structural-diagnostic-message d))))]
      [else #f])))

(define (check-file-full path)
  (require-beagle-source-extension! path 'beagle-daemon)
  (define errors '())
  (define suspicions '())
  (define repair-info (try-structural-repair! path))
  (with-handlers
    ([exn:fail?
      (lambda (e)
        (set! errors (cons (hasheq 'line 0 'message (exn-message e)
                                   'kind "parse-error") errors)))])
    (define stxs (read-beagle-syntax path))
    (define prog (parse-program stxs #:source-path path))
    (type-check-with-locs! prog
      (lambda (e loc-stx)
        (define d (if (beagle-diagnostic? e) (beagle-diagnostic-details e) (hasheq)))
        (define kind (if (beagle-diagnostic? e)
                         (symbol->string (beagle-diagnostic-kind e))
                         "compile-error"))
        (define err-line (or (hash-ref d 'error-line #f)
                             (and loc-stx (syntax-line loc-stx))
                             0))
        (define err-col (or (hash-ref d 'error-col #f)
                            (and loc-stx (syntax-column loc-stx))))
        (define sig (hash-ref d 'signature #f))
        (define suggestions (hash-ref d 'suggestions '()))
        (define function (hash-ref d 'function #f))
        (define expected (hash-ref d 'expected #f))
        (define actual (hash-ref d 'actual #f))
        (define help (hash-ref d 'help #f))
        (define src-line
          (with-handlers ([exn:fail? (lambda (_) #f)])
            (define lines (file->lines path))
            (and (> err-line 0) (<= err-line (length lines))
                 (list-ref lines (sub1 err-line)))))
        (define fix-plan (generate-fix-plan e src-line))
        (define auto-fixable?
          (and fix-plan
               (member (hash-ref fix-plan 'confidence "")
                       '("high"))))
        (set! errors
              (cons (hasheq 'line err-line
                            'col (or err-col 'null)
                            'kind kind
                            'message (exn-message e)
                            'function (or function 'null)
                            'expected (or expected 'null)
                            'actual (or actual 'null)
                            'signature (or sig 'null)
                            'suggestions suggestions
                            'help (or help 'null)
                            'fix_plan (or fix-plan 'null)
                            'auto_fixable (and auto-fixable? #t)
                            'source_line (or src-line 'null))
                    errors))))
    ;; Capture undefined-ref and scalar-provenance notes from stderr
    (define provenance-output
      (with-output-to-string
        (lambda ()
          (parameterize ([current-error-port (current-output-port)])
            (check-scalar-provenance! prog)))))
    (for ([line (in-list (string-split provenance-output "\n"))])
      (when (and (non-empty-string? line)
                 (string-prefix? line "note:"))
        (set! errors
              (cons (hasheq 'line 0
                            'kind "provenance"
                            'message line
                            'function 'null 'expected 'null 'actual 'null
                            'signature 'null 'suggestions '() 'help 'null
                            'fix_plan 'null 'auto_fixable #f 'source_line 'null)
                    errors))))
    (define raw-suspicions (run-semantic-analysis! prog #:file path))
    (for ([s (in-list raw-suspicions)])
      (set! suspicions
            (cons (hasheq 'function (symbol->string (suspicion-function-name s))
                          'confidence (suspicion-confidence s)
                          'message (suspicion-message s))
                  suspicions))))
  (values (reverse errors) (reverse suspicions) repair-info))

(define (enrich-errors errors path)
  (for/list ([e (in-list errors)])
    (define expected (hash-ref e 'expected #f))
    (define actual (hash-ref e 'actual #f))
    (define context (make-hash))
    (define (try-lookup-fields type-name)
      (when (and type-name (not (eq? type-name 'null)) (string? type-name))
        (define clean-name
          (regexp-replace #rx"^[a-z]+/" type-name ""))
        (define target (string->symbol clean-name))
        (for ([f (in-list (find-beagle-in (list (path->string
                                               (let-values ([(base _name _ext)
                                                             (split-path (string->path path))])
                                                 base)))))])
          (with-handlers ([exn:fail? void])
            (define datums (get-datums f))
            (for ([d (in-list datums)])
              (define entry (extract-record-entry d))
              (when (and entry (eq? (car entry) target))
                (define name-lower (string-downcase clean-name))
                (hash-set! context
                  (string->symbol (format "~a_fields" (string-downcase clean-name)))
                  (for/list ([fld (in-list (cadr entry))])
                    (hasheq 'name (symbol->string (param-name fld))
                            'type (type->string (param-type fld))
                            'accessor (format "~a-~a" name-lower (param-name fld)))))))))))
    (try-lookup-fields expected)
    (try-lookup-fields actual)
    (if (hash-empty? context)
        e
        (hash-set e 'context (make-immutable-hash (hash->list context))))))

(define (run-check-and-cache! path)
  (call-with-semaphore check-sema
    (lambda ()
      (define hash-val (file-content-hash path))
      (define-values (errors suspicions repair-info) (check-file-full path))
      (define enriched (enrich-errors errors path))
      (define auto-count (count (lambda (e) (hash-ref e 'auto_fixable #f)) enriched))
      (define result
        (hasheq 'file path
                'content_hash hash-val
                'checked_at (current-seconds)
                'error_count (length enriched)
                'auto_fixable auto-count
                'errors enriched
                'suspicions suspicions
                'repair (or repair-info 'null)))
      (hash-set! check-results path result)
      (hash-set! pending-results path result)
      result)))

;; --- File watcher -----------------------------------------------------------

(define (start-file-watcher path)
  (unless (hash-has-key? watcher-threads path)
    (define t
      (thread
        (lambda ()
          (let loop ()
            (with-handlers ([exn:fail? (lambda (e)
                                         (eprintf "watcher error ~a: ~a\n" path (exn-message e)))])
              (sync (filesystem-change-evt path)))
            (when (file-exists? path)
              (invalidate-cache! path)
              (with-handlers ([exn:fail? (lambda (e)
                                           (eprintf "check error ~a: ~a\n" path (exn-message e)))])
                (run-check-and-cache! path))
              (loop))))))
    (hash-set! watcher-threads path t)))

(define (start-dir-watcher dir)
  (define (scan-and-watch)
    (for ([f (in-directory dir)]
          #:when (regexp-match? BEAGLE-FILE-RX (path->string f)))
      (define p (path->string f))
      (start-file-watcher p)
      (run-check-and-cache! p)))
  (scan-and-watch)
  (define t
    (thread
      (lambda ()
        (let loop ()
          (with-handlers ([exn:fail? void])
            (sync (filesystem-change-evt dir)))
          (scan-and-watch)
          (loop)))))
  (set! watch-dir-threads (cons t watch-dir-threads))
  (set! watched-dirs (cons (path->string (simplify-path (string->path dir)))
                           watched-dirs)))

(define (stop-all-watchers)
  (for ([(path t) (in-hash watcher-threads)])
    (kill-thread t))
  (hash-clear! watcher-threads)
  (for ([t (in-list watch-dir-threads)])
    (kill-thread t))
  (set! watch-dir-threads '())
  (set! watched-dirs '()))

;; --- New command handlers ---------------------------------------------------

(define (handle-watch args)
  (when (null? args) (error "watch requires: <dir>"))
  (define dir (car args))
  (unless (directory-exists? dir) (error (format "not a directory: ~a" dir)))
  (start-dir-watcher dir)
  (define file-count (hash-count watcher-threads))
  (hasheq 'ok #t 'watching dir 'files file-count))

(define (handle-unwatch _args)
  (stop-all-watchers)
  (hash-clear! check-results)
  (hash-clear! pending-results)
  (hasheq 'ok #t 'status "all watchers stopped"))

(define (handle-check-result args)
  (cond
    [(null? args)
     (define results
       (for/list ([(path result) (in-hash check-results)]
                  #:when (> (hash-ref result 'error_count 0) 0))
         result))
     (hasheq 'ok #t 'results results)]
    [else
     (define path (car args))
     (define result (hash-ref check-results path #f))
     (if result
         (hasheq 'ok #t 'result result)
         (hasheq 'ok #t 'result 'null 'note "no cached result"))]))

(define (handle-check-enriched args)
  (define files (find-beagle-in (if (null? args) (list ".") args)))
  (define results '())
  (for ([f (in-list files)])
    (with-handlers ([exn:fail? (lambda (e)
                                 (set! results
                                       (cons (hasheq 'file f 'error (exn-message e))
                                             results)))])
      (set! results (cons (run-check-and-cache! f) results))))
  (define all-errors (apply + (map (lambda (r) (hash-ref r 'error_count 0)) results)))
  (define all-auto (apply + (map (lambda (r) (hash-ref r 'auto_fixable 0)) results)))
  (hasheq 'ok (zero? all-errors)
          'total_errors all-errors
          'auto_fixable all-auto
          'files (reverse results)))

(define (handle-latest-results _args)
  (define results (hash-values pending-results))
  (hash-clear! pending-results)
  (define with-errors (filter (lambda (r) (> (hash-ref r 'error_count 0) 0)) results))
  (hasheq 'ok #t
          'results with-errors
          'files_checked (length results)
          'files_with_errors (length with-errors)))

;; --- Command handlers --------------------------------------------------------

(define (callable-form? form)
  (or (defn-form? form) (defn-multi? form)))

(define (callable-name form)
  (cond
    [(defn-form? form) (defn-form-name form)]
    [(defn-multi? form) (defn-multi-name form)]
    [else (error 'beagle-daemon "not a callable definition: ~v" form)]))

(define (callable-clauses form)
  (cond
    [(defn-form? form)
     (list (list (defn-form-params form)
                 (defn-form-rest-param form)))]
    [(defn-multi? form)
     (for/list ([clause (in-list (defn-multi-arities form))])
       (list (arity-clause-params clause)
             (arity-clause-rest-param clause)))]
    [else '()]))

(define (authored-rest-element-type rest-param)
  (define aggregate (and rest-param (param-type rest-param)))
  (cond
    [(and (type-app? aggregate)
          (eq? (type-app-ctor aggregate) 'Vec)
          (= (length (type-app-args aggregate)) 1))
     (car (type-app-args aggregate))]
    [aggregate aggregate]
    [else (type-prim 'Any)]))

(define (authored-callable-type form)
  (define alternatives
    (cond
      [(defn-form? form)
       (list
        (type-fn
         (map (lambda (p) (or (param-type p) (type-prim 'Any)))
              (defn-form-params form))
         (and (defn-form-rest-param form)
              (authored-rest-element-type (defn-form-rest-param form)))
         (defn-form-return-type form)))]
      [(defn-multi? form)
       (for/list ([clause (in-list (defn-multi-arities form))])
         (type-fn
          (map (lambda (p) (or (param-type p) (type-prim 'Any)))
               (arity-clause-params clause))
          (and (arity-clause-rest-param clause)
               (authored-rest-element-type (arity-clause-rest-param clause)))
          (arity-clause-return-type clause)))]
      [else '()]))
  (if (= (length alternatives) 1)
      (car alternatives)
      (type-union alternatives)))

(define (public-type->string type)
  (when (pair? (free-type-metas type))
    (error 'beagle-daemon
           "refusing to expose an unresolved effective signature"))
  (type->string type))

(define (effective-callable-type prog form)
  (define name (callable-name form))
  (define effective (program-effective-definition-type prog name #f))
  (cond
    [effective
     (public-type->string effective)
     effective]
    [else
     (error 'beagle-daemon
            "checked program is missing the effective signature for ~a"
            name)]))

(define (signature-alternatives signature)
  (define body
    (if (type-poly? signature) (type-poly-body signature) signature))
  (if (type-union? body) (type-union-alts body) (list body)))

(define (binding-target->string target)
  (cond
    [(symbol? target) (symbol->string target)]
    [(seq-destructure? target)
     (define fixed (map binding-target->string (seq-destructure-names target)))
     (define items
       (if (seq-destructure-rest-name target)
           (append fixed
                   (list "&"
                         (symbol->string (seq-destructure-rest-name target))))
           fixed))
     (format "[~a]" (string-join items " "))]
    [(map-destructure? target)
     (format "{:keys [~a]~a}"
             (string-join (map symbol->string (map-destructure-keys target)) " ")
             (if (map-destructure-as-name target)
                 (format " :as ~a" (map-destructure-as-name target))
                 ""))]
    [else (format "~a" target)]))

(define (callable-clause->jsexpr clause signature)
  (unless (type-fn? signature)
    (error 'beagle-daemon
           "effective callable clause is not a function type: ~a"
           (public-type->string signature)))
  (define params (car clause))
  (define rest-param (cadr clause))
  (unless (= (length params) (length (type-fn-params signature)))
    (error 'beagle-daemon "effective callable parameter count mismatch"))
  (define result
    (hasheq
     'params
     (for/list ([param (in-list params)]
                [param-type (in-list (type-fn-params signature))])
       (hasheq 'name (binding-target->string (param-binding-target param))
               'type (public-type->string param-type)))
     'return (public-type->string (type-fn-ret signature))))
  (if rest-param
      (hash-set result 'rest
                (hasheq 'name (binding-target->string
                               (param-binding-target rest-param))
                        'type (public-type->string
                               (type-fn-rest-type signature))))
      result))

(define (callable-result name file form signature)
  (define clauses (callable-clauses form))
  (define alternatives (signature-alternatives signature))
  (unless (= (length clauses) (length alternatives))
    (error 'beagle-daemon "effective callable clause count mismatch for ~a" name))
  (define details
    (for/list ([clause (in-list clauses)]
               [alternative (in-list alternatives)])
      (callable-clause->jsexpr clause alternative)))
  (define base
    (hasheq 'name name
            'file file
            'signature (public-type->string signature)))
  (if (= (length details) 1)
      (for/fold ([result base]) ([(key value) (in-hash (car details))])
        (hash-set result key value))
      (hash-set base 'arities details)))

(define (signature-clause-detail->jsexpr detail)
  (define result
    (hasheq
     'params
     (for/list ([param (in-list (hash-ref detail 'params))])
       (hasheq 'name (car param)
               'type (public-type->string (cdr param))))
     'return (public-type->string (hash-ref detail 'return))))
  (define rest-param (hash-ref detail 'rest))
  (if rest-param
      (hash-set result 'rest
                (hasheq 'name (car rest-param)
                        'type (public-type->string (cdr rest-param))))
      result))

(define (signature-match->jsexpr match)
  (define details
    (map signature-clause-detail->jsexpr (hash-ref match 'clauses)))
  (define base
    (hasheq 'name (symbol->string (hash-ref match 'name))
            'file (hash-ref match 'file)
            'namespace (symbol->string (hash-ref match 'namespace))
            'line (or (hash-ref match 'line) 'null)
            'col (or (hash-ref match 'col) 'null)
            'signature (public-type->string (hash-ref match 'signature))))
  (cond
    [(hash-ref match 'extern?) (hash-set base 'extern #t)]
    [(= (length details) 1)
     (for/fold ([result base]) ([(key value) (in-hash (car details))])
       (hash-set result key value))]
    [else (hash-set base 'arities details)]))

(define (handle-sig args)
  (when (< (length args) 2)
    (error "sig requires: <fn-name> <file-or-dir>..."))
  (define name (car args))
  (define files (find-beagle-in (cdr args)))
  (define results (query-signature-matches name files))
  (when (null? results)
    (raise-user-error 'beagle-sig
                      "callable ~a not found in provided files"
                      name))
  (hasheq 'ok #t 'results (map signature-match->jsexpr results)))

(define (handle-fields args)
  (when (< (length args) 2)
    (error "fields requires: <record-name> <file-or-dir>..."))
  (define rec-name (car args))
  (define files (expand-fields-file-args (cdr args)))
  (define matches (query-field-matches rec-name files))
  (hasheq
   'ok #t
   'results
   (for/list ([match (in-list matches)])
     (define record-name (cadr match))
     (define fields (caddr match))
     (define name-lower (string-downcase (symbol->string record-name)))
     (hasheq 'record (symbol->string record-name)
             'file (car match)
             'namespace (symbol->string (cadddr match))
             'line (or (list-ref match 4) 'null)
             'col (or (list-ref match 5) 'null)
             'fields (for/list ([fld (in-list fields)])
                       (hasheq 'name (symbol->string (param-name fld))
                               'type (type->string (param-type fld))
                               'accessor (format "~a-~a" name-lower (param-name fld))))))))

(define (handle-provides args)
  (when (null? args)
    (error "provides requires: <file>"))
  (define file (car args))
  (with-handlers ([exn:fail? (lambda (e) (hasheq 'ok #f 'error (exn-message e)))])
    (define prog (checked-program/file file))
    (define records '())
    (define fns '())

    (for ([raw-form (in-list (program-forms prog))])
      (define form (unwrap-definition-form raw-form))
      (when (record-form? form)
        (set! records (cons form records)))
      (when (callable-form? form)
        (set! fns
              (cons (cons form (effective-callable-type prog form)) fns))))

    (hasheq 'ok #t
            'namespace (symbol->string (program-namespace prog))
            'records (for/list ([r (in-list (reverse records))])
                       (hasheq 'name (symbol->string (record-form-name r))
                               'fields (for/list ([f (in-list (record-form-fields r))])
                                         (hasheq
                                          'name (binding-target->string
                                                 (param-binding-target f))
                                          'type (public-type->string
                                                 (param-type f))))))
            'functions (for/list ([fn (in-list (reverse fns))])
                         (hasheq 'name (symbol->string
                                        (callable-name (car fn)))
                                 'signature (public-type->string (cdr fn)))))))

(define (handle-callers args)
  (when (< (length args) 2)
    (error "callers requires: <fn-name> <file-or-dir>..."))
  (define name (car args))
  (define files (find-beagle-in (cdr args)))
  (define target (string->symbol name))
  (define results '())
  (for ([f (in-list files)])
    (with-handlers ([exn:fail? void])
      (define datums (get-datums f))
      (for ([d (in-list datums)])
        (define defn-entry (extract-defn-entry d))
        (when defn-entry
          (define fn-name (car defn-entry))
          (define calls (find-calls-in target d))
          (for ([call (in-list calls)])
            (set! results
                  (cons (hasheq 'caller (symbol->string fn-name)
                                'file f
                                'args (length (cdr call)))
                        results)))))))
  (hasheq 'ok #t 'results (reverse results)))

(define (handle-impact args)
  (when (< (length args) 2)
    (error "impact requires: <fn-name> <file-or-dir>..."))
  (define name (car args))
  (define files (find-beagle-in (cdr args)))
  (define target (string->symbol name))
  (define sig #f)
  (define def-file #f)
  (define callers '())
  (for ([f (in-list files)])
    (define prog (checked-program/file f))
    (for ([raw-form (in-list (program-forms prog))])
      (define form (unwrap-definition-form raw-form))
      (when (and (callable-form? form)
                 (eq? (callable-name form) target))
        (set! sig (effective-callable-type prog form))
        (set! def-file f)))
    (define datums (get-datums f))
    (for ([d (in-list datums)])
      (define entry (extract-defn-entry d))
      (when entry
        (define fn-name (car entry))
        (define calls (find-calls-in target d))
        (for ([call (in-list calls)])
          (set! callers
                (cons (hasheq 'caller (symbol->string fn-name)
                              'file f
                              'args (length (cdr call)))
                      callers))))))
  (hasheq 'ok #t
          'name name
          'signature (and sig (public-type->string sig))
          'defined-in def-file
          'callers (reverse callers)))

(define (handle-check args)
  (define files (find-beagle-in (if (null? args) (list ".") args)))
  (define all-errors '())
  (for ([f (in-list files)])
    (define-values (errs _suspicions _repair) (check-file-full f))
    (for ([e (in-list errs)])
      (set! all-errors
            (cons (hasheq 'file f 'error (hash-ref e 'message "unknown"))
                  all-errors))))
  (hasheq 'ok (null? all-errors)
          'files-checked (length files)
          'errors (reverse all-errors)))

(define (handle-ping _args)
  (hasheq 'ok #t 'status "running" 'cached (hash-count datum-cache)))

(define (handle-repair args)
  (when (null? args) (error "repair requires: <file>"))
  (define path (path->string (simplify-path (string->path (car args)))))
  (unless (file-exists? path) (error (format "file not found: ~a" path)))
  (require-beagle-source-extension! path 'beagle-daemon)
  ;; Restrict repair to files within watched directories (no path traversal)
  (when (pair? watched-dirs)
    (unless (for/or ([wd (in-list watched-dirs)])
              (define wd/ (if (string-suffix? wd "/") wd (string-append wd "/")))
              (string-prefix? path wd/))
      (error (format "repair blocked: ~a is outside watched directories" path))))
  (define source (file->string path))
  (define r (repair-structure source))
  (cond
    [(not (repair-result-changed? r))
     (hasheq 'ok #t 'changed #f 'message "no structural issues")]
    [(eq? (repair-result-confidence r) 'high)
     (call-with-output-file path
       (lambda (out) (write-string (repair-result-output r) out))
       #:exists 'truncate/replace)
     (invalidate-cache! path)
     (hasheq 'ok #t 'changed #t 'confidence "high"
             'edits (for/list ([e (in-list (repair-result-edits r))])
                      (hasheq 'line (repair-edit-line e)
                              'text (repair-edit-insert-text e)
                              'reason (repair-edit-reason e))))]
    [else
     (hasheq 'ok #t 'changed #f
             'confidence (symbol->string (repair-result-confidence r))
             'message "low confidence — not applied"
             'diagnostics (for/list ([d (in-list (repair-result-diagnostics r))])
                            (hasheq 'line (structural-diagnostic-line d)
                                    'message (structural-diagnostic-message d))))]))

(define (handle-invalidate args)
  (if (null? args)
      (begin (invalidate-cache!) (hasheq 'ok #t 'cleared "all"))
      (begin (invalidate-cache! (car args)) (hasheq 'ok #t 'cleared (car args)))))

;; --- Build (emit via warm daemon) -------------------------------------------

(define (target-extension target)
  (case target
    [(js)   ".js"]
    [(py)   ".py"]
    [else   ".clj"]))

(define (ns->out-path ns-sym target)
  (define s (symbol->string ns-sym))
  (define file-ns
    (if (eq? target 'clj)
        (regexp-replace* #rx"-" s "_")
        s))
  (string-append (regexp-replace* #rx"\\." file-ns "/")
                 (target-extension target)))

(define (handle-build args)
  (when (< (length args) 2)
    (error "build requires: <out-dir> <file-or-dir>..."))
  (define out-dir (car args))
  (define files (find-beagle-in (cdr args)))
  (define built 0)
  (define error-list '())

  (for ([f (in-list files)])
    (with-handlers ([exn:fail? (lambda (e)
                                 (set! error-list
                                       (cons (diagnostic->json e #f f)
                                             error-list)))])
      (define stxs (read-beagle-syntax f))
      (define prog (parse-program stxs #:source-path f))

      (define check-errors '())
      (type-check-with-locs! prog
        (lambda (e loc-stx)
          (set! check-errors
                (cons (diagnostic->json e loc-stx f) check-errors)))
        #:capture-types? #t)  ; emit-path: feed type table to emit-program below

      (if (pair? check-errors)
          ;; The callback accumulates in reverse source order; the response is
          ;; reversed once below, so append this batch directly to the global
          ;; reverse accumulator and skip emission for the rejected file.
          (set! error-list (append check-errors error-list))
          (let ()
            (define source (emit-program prog))
            (define ns (program-namespace prog))
            (define target (program-target prog))
            (define rel (ns->out-path ns target))
            (define out-path (build-path out-dir rel))

            (make-parent-directory* out-path)
            (with-output-to-file out-path #:exists 'replace
              (lambda () (display source)))

            (set! built (+ built 1))))))

  (hasheq 'ok (null? error-list)
          'built built
          'error_count (length error-list)
          'errors (reverse error-list)))

;; --- Dispatch ----------------------------------------------------------------

(define (dispatch-command parts)
  (match parts
    [(list "sig" args ...) (handle-sig args)]
    [(list "fields" args ...) (handle-fields args)]
    [(list "callers" args ...) (handle-callers args)]
    [(list "provides" args ...) (handle-provides args)]
    [(list "impact" args ...) (handle-impact args)]
    [(list "check" args ...) (handle-check args)]
    [(list "build" args ...) (handle-build args)]
    [(list "repair" args ...) (handle-repair args)]
    [(list "watch" args ...) (handle-watch args)]
    [(list "unwatch" args ...) (handle-unwatch args)]
    [(list "check-result" args ...) (handle-check-result args)]
    [(list "check-enriched" args ...) (handle-check-enriched args)]
    [(list "latest-results" args ...) (handle-latest-results args)]
    [(list "ping" args ...) (handle-ping args)]
    [(list "invalidate" args ...) (handle-invalidate args)]
    [(list "quit") (hasheq 'ok #t 'bye #t)]
    [(list) (hasheq 'ok #t 'noop #t)]
    [_ (hasheq 'ok #f 'error (format "unknown command: ~a" (car parts)))]))

;; --- Stdin/stdout mode -------------------------------------------------------

(define (run-daemon)
  (let loop ()
    (define line (read-line (current-input-port)))
    (cond
      [(eof-object? line) (void)]
      [else
       (define parts (string-split (string-trim line)))
       (define response
         (with-handlers ([exn:fail? (lambda (e)
                                      (hasheq 'ok #f 'error (exn-message e)))])
           (dispatch-command parts)))
       (write-json (hash-set response 'schemaVersion 1))
       (newline)
       (flush-output)
       (unless (hash-ref response 'bye #f)
         (loop))])))

;; --- TCP mode ----------------------------------------------------------------

(define (daemon-runtime-dir)
  (or (getenv "XDG_RUNTIME_DIR")
      (path->string (find-system-path 'temp-dir))))

(define (run-daemon-tcp [port-num 0])
  (define listener (tcp-listen port-num 4 #t "127.0.0.1"))
  (define-values (_local-host actual-port _remote-host _remote-port)
    (tcp-addresses listener #t))
  (define port-file
    (or (getenv "BEAGLE_DAEMON_PORTFILE")
        (build-path (daemon-runtime-dir) "beagle-daemon.port")))
  (call-with-output-file port-file #:exists 'replace
    (lambda (out) (fprintf out "~a\n" actual-port)))
  (file-or-directory-permissions port-file #o600)
  (fprintf (current-error-port) "beagle-daemon listening on 127.0.0.1:~a\n" actual-port)
  (flush-output (current-error-port))

  (let accept-loop ()
    (define-values (in out) (tcp-accept listener))
    (thread
     (lambda ()
       (let conn-loop ()
         (define line (read-line in))
         (cond
           [(eof-object? line)
            (close-input-port in)
            (close-output-port out)]
           [else
            (define parts (string-split (string-trim line)))
            (define response
              (with-handlers ([exn:fail? (lambda (e)
                                            (hasheq 'ok #f 'error (exn-message e)))])
                (dispatch-command parts)))
            (write-json (hash-set response 'schemaVersion 1) out)
            (newline out)
            (flush-output out)
            (if (hash-ref response 'bye #f)
                (begin (close-input-port in) (close-output-port out))
                (conn-loop))]))))
    (accept-loop)))

(provide run-daemon run-daemon-tcp invalidate-cache! get-datums
         run-check-and-cache! start-dir-watcher stop-all-watchers)
