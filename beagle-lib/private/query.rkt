#lang racket/base

(require racket/match
         racket/format
         "parse.rkt"
         "types.rkt"
         "ast.rkt"
         "extensions.rkt"
         "expand-tool.rkt")

(define (read-expanded-datums f)
  (map strip-target-export
       (with-handlers ([exn:fail? (lambda (e) (read-beagle-datums f))])
         (expand-datums f))))

(define (str-downcase s)
  (list->string (map char-downcase (string->list s))))

;; --- datum-level extraction --------------------------------------------------

;; Docstrings are real surface ((defn name "doc" [params] ...)) —
;; normalize them away before matching. Return marker is `->` (`:-` legacy);
;; matching the wrong one here makes every annotated fn silently report
;; `-> Any` rather than erroring, so it must stay in step with parse.rkt.
(define (strip-doc d)
  (match d
    [(list* head (? symbol? name) (? string? _doc) rest)
     (list* head name rest)]
    [_ d]))

(define (extract-defn-entry d0)
  (define d (strip-doc d0))
  (match d
    [(list (or 'defn 'defn-) (? symbol? name) params-form (? return-marker? _) ret-type body ...)
     (define-values (parsed rest-p) (parse-params params-form))
     (define ptypes (map (lambda (p) (or (param-type p) (type-prim 'Any))) parsed))
     (define pnames (map param-name parsed))
     (define rtype (and rest-p (or (param-type rest-p) (type-prim 'Any))))
     (list name pnames (type-fn ptypes rtype (parse-type ret-type)))]
    [(list (or 'defn 'defn-) (? symbol? name) params-form body ...)
     #:when (or (null? body) (not (return-marker? (car body))))
     (define-values (parsed rest-p) (parse-params params-form))
     (define ptypes (map (lambda (p) (or (param-type p) (type-prim 'Any))) parsed))
     (define pnames (map param-name parsed))
     (define rtype (and rest-p (or (param-type rest-p) (type-prim 'Any))))
     (list name pnames (type-fn ptypes rtype (type-prim 'Any)))]
    [_ #f]))

(define (extract-def-entry d0)
  (define d (match d0
              ;; (def name: T "doc" v) — the doc sits AFTER the type
              [(list 'def (? symbol? name) (? annotation-marker? m) type-expr (? string? _doc) v)
               (list 'def name m type-expr v)]
              [_ (strip-doc d0)]))
  (match d
    [(list 'def (? symbol? name) (? annotation-marker? _) type-expr _)
     (list name (parse-type type-expr))]
    [(list 'def (? symbol? name) _)
     (list name (type-prim 'Any))]
    [_ #f]))

(define (extract-record-entry d)
  (match d
    [(list 'defrecord (? symbol? name) fields-form)
     (define fields (parse-record-fields fields-form))
     (list name fields)]
    [_ #f]))

(define (extract-extern-entry d)
  (match d
    [(list 'declare-extern (? symbol? name) type-expr)
     (list (list name (parse-type type-expr)))]
    [(list 'declare-extern (? bracketed? names-form) type-expr)
     (define t (parse-type type-expr))
     (for/list ([name (in-list (bracket-body names-form))])
       (list name t))]
    [_ '()]))

(define (extract-ns d)
  (match d
    [(list 'ns (? symbol? n)) n]
    [_ #f]))

;; --- beagle-sig: print function signature ------------------------------------

(define (query-sig name files)
  (define target (if (string? name) (string->symbol name) name))
  (for ([f (in-list files)])
    (with-handlers ([exn:fail? (lambda (e) (void))])
      (define datums (read-expanded-datums f))
      (for ([d (in-list datums)])
        (define entry (extract-defn-entry d))
        (when (and entry (eq? (car entry) target))
          (define pnames (cadr entry))
          (define ftype (caddr entry))
          (printf "~a : ~a\n" target (type->string ftype))
          (define params (type-fn-params ftype))
          (for ([pn (in-list pnames)]
                [pt (in-list params)])
            (printf "  ~a : ~a\n" pn (type->string pt)))
          (printf "  -> ~a\n" (type->string (type-fn-ret ftype))))
        (for ([ext (in-list (extract-extern-entry d))])
          (when (eq? (car ext) target)
            (printf "~a : ~a  (extern)\n" target (type->string (cadr ext)))))))))

;; --- beagle-fields: print record fields + accessors --------------------------

(define (expand-fields-file-args args)
  (define files
    (apply append
      (for/list ([a (in-list args)])
        (cond
          [(directory-exists? a)
           (with-handlers ([exn:fail?
                            (lambda (e)
                              (raise-user-error
                               'beagle-fields
                               "failed to read input path ~a: ~a"
                               a
                               (exn-message e)))])
             (find-rkt-files a))]
          [(file-exists? a) (list a)]
          [else
           (raise-user-error 'beagle-fields
                             "input path does not exist: ~a"
                             a)]))))
  (when (null? files)
    (raise-user-error
     'beagle-fields
     "no Beagle source files found in provided paths: ~a"
     (string-join* args ", ")))
  files)

(define (query-field-matches rec-name files
                             #:read-datums [read-datums read-expanded-datums])
  (when (null? files)
    (raise-user-error 'beagle-fields "no Beagle source files were provided"))
  (define target (if (string? rec-name) (string->symbol rec-name) rec-name))
  (define matches
    (for*/list ([f (in-list files)]
                [d (in-list
                    (with-handlers ([exn:fail?
                                     (lambda (e)
                                       (raise-user-error
                                        'beagle-fields
                                        "failed to read ~a: ~a"
                                        f
                                        (exn-message e)))])
                      (read-datums f)))]
                #:do [(define entry (extract-record-entry d))]
                #:when (and entry (eq? (car entry) target)))
      (cons f entry)))
  (when (null? matches)
    (raise-user-error 'beagle-fields
                      "record ~a not found in provided files"
                      target))
  matches)

(define (query-fields rec-name files)
  (define target (if (string? rec-name) (string->symbol rec-name) rec-name))
  (for ([match (in-list (query-field-matches target files))])
    (define fields (caddr match))
    (define name-str (symbol->string target))
    (define name-lower (str-downcase name-str))
    (printf "~a\n" target)
    (for ([fld (in-list fields)])
      (printf "  ~a : ~a    accessor: ~a-~a\n"
              (param-name fld)
              (type->string (param-type fld))
              name-lower
              (param-name fld)))
    (define ctor-types (map (lambda (fld) (type->string (param-type fld))) fields))
    (printf "  constructor: ->~a : [~a -> ~a]\n"
            name-str
            (string-join* ctor-types " ")
            name-str)))

;; --- beagle-callers: find call sites -----------------------------------------

(define (query-callers target-name files)
  (define target (if (string? target-name) (string->symbol target-name) target-name))
  (for ([f (in-list files)])
    (with-handlers ([exn:fail? (lambda (e) (void))])
      (define datums (read-expanded-datums f))
      (define ns-name #f)
      (for ([d (in-list datums)])
        (define ns (extract-ns d))
        (when ns (set! ns-name ns)))
      (for ([d (in-list datums)])
        (define defn-entry (extract-defn-entry d))
        (when defn-entry
          (define fn-name (car defn-entry))
          (define calls (find-calls-in target d))
          (for ([call (in-list calls)])
            (printf "~a  in ~a  (~a)\n"
                    (format-call call)
                    fn-name
                    f)))))))

(define (find-calls-in target datum)
  (cond
    [(and (pair? datum)
          (not (bracketed? datum))
          (eq? (car datum) target))
     (list datum)]
    [(pair? datum)
     (append-map (lambda (sub) (find-calls-in target sub))
                 (if (bracketed? datum) (bracket-body datum) datum))]
    [else '()]))

(define (append-map f xs)
  (apply append (map f xs)))

(define (format-call call)
  (define args (cdr call))
  (format "(~a~a)"
          (car call)
          (if (null? args) ""
              (string-append " " (string-join* (map ~v args) " ")))))

;; --- beagle-provides: list all exports from a module -------------------------

(define (query-provides file)
  (with-handlers ([exn:fail? (lambda (e)
                                (fprintf (current-error-port)
                                         "error reading ~a: ~a\n" file (exn-message e)))])
    (define datums (read-expanded-datums file))
    (define ns-name #f)
    (for ([d (in-list datums)])
      (define ns (extract-ns d))
      (when ns (set! ns-name ns)))
    (when ns-name (printf "namespace: ~a\n\n" ns-name))

    (define records '())
    (define fns '())
    (define defs '())
    (define externs '())

    (for ([d (in-list datums)])
      (define rec (extract-record-entry d))
      (when rec (set! records (cons rec records)))
      (define fn (extract-defn-entry d))
      (when fn (set! fns (cons fn fns)))
      (define df (extract-def-entry d))
      (when df (set! defs (cons df defs)))
      (set! externs (append (extract-extern-entry d) externs)))

    (unless (null? records)
      (printf "records:\n")
      (for ([r (in-list (reverse records))])
        (define name (car r))
        (define fields (cadr r))
        (printf "  ~a [~a]\n" name
                (string-join*
                 (map (lambda (f) (format "~a:~a" (param-name f) (type->string (param-type f))))
                      fields)
                 " ")))
      (newline))

    (unless (null? fns)
      (printf "functions:\n")
      (for ([fn (in-list (reverse fns))])
        (printf "  ~a : ~a\n" (car fn) (type->string (caddr fn))))
      (newline))

    (unless (null? defs)
      (printf "defs:\n")
      (for ([d (in-list (reverse defs))])
        (printf "  ~a : ~a\n" (car d) (type->string (cadr d))))
      (newline))

    (unless (null? externs)
      (printf "externs:\n")
      (for ([e (in-list (reverse externs))])
        (printf "  ~a : ~a\n" (car e) (type->string (cadr e))))
      (newline))))

;; --- beagle-impact: dry-run impact analysis ----------------------------------

(define (query-impact target-name files)
  (define target (if (string? target-name) (string->symbol target-name) target-name))
  ;; Find the definition first
  (define sig #f)
  (define def-file #f)
  (for ([f (in-list files)])
    (with-handlers ([exn:fail? (lambda (e) (void))])
      (define datums (read-expanded-datums f))
      (for ([d (in-list datums)])
        (define entry (extract-defn-entry d))
        (when (and entry (eq? (car entry) target))
          (set! sig (caddr entry))
          (set! def-file f))
        (define rec (extract-record-entry d))
        (when rec
          (define rec-name (car rec))
          (define fields (cadr rec))
          (define name-lower (str-downcase (symbol->string rec-name)))
          (for ([fld (in-list fields)])
            (define accessor-name
              (string->symbol (string-append name-lower "-" (symbol->string (param-name fld)))))
            (when (eq? accessor-name target)
              (set! sig (type-fn (list (type-prim rec-name)) #f (param-type fld)))
              (set! def-file f)))))))

  (cond
    [sig
     (printf "~a : ~a\n  defined in: ~a\n\n" target (type->string sig) def-file)
     (printf "callers:\n")
     (for ([f (in-list files)])
       (with-handlers ([exn:fail? (lambda (e) (void))])
         (define datums (read-expanded-datums f))
         (for ([d (in-list datums)])
           (define defn-entry (extract-defn-entry d))
           (when defn-entry
             (define fn-name (car defn-entry))
             (define calls (find-calls-in target d))
             (for ([call (in-list calls)])
               (printf "  ~a  in ~a (~a)  args: ~a\n"
                       (format-call call)
                       fn-name
                       f
                       (length (cdr call))))))))]
    [else
     (printf "~a: not found in provided files\n" target)]))

;; --- utilities ---------------------------------------------------------------

(define (string-join* xs sep)
  (cond
    [(null? xs) ""]
    [(null? (cdr xs)) (car xs)]
    [else (string-append (car xs) sep (string-join* (cdr xs) sep))]))

(define (find-rkt-files dir)
  (for/list ([p (in-directory dir)]
             #:when (regexp-match? BEAGLE-FILE-RX (path->string p)))
    (path->string p)))

;; --- CLI dispatch ------------------------------------------------------------

(define (run-query args)
  (when (< (length args) 1)
    (fprintf (current-error-port) "usage: query <command> <args...>\n")
    (exit 2))
  (define cmd (car args))
  (define rest (cdr args))
  (case cmd
    [("sig")
     (when (< (length rest) 2)
       (fprintf (current-error-port) "usage: beagle-sig <name> <file-or-dir> ...\n")
       (exit 2))
     (define name (car rest))
     (define files (expand-file-args (cdr rest)))
     (query-sig name files)]
    [("fields")
     (when (< (length rest) 2)
       (fprintf (current-error-port) "usage: beagle-fields <RecordName> <file-or-dir> ...\n")
       (exit 2))
     (define name (car rest))
     (define files (expand-fields-file-args (cdr rest)))
     (query-fields name files)]
    [("callers")
     (when (< (length rest) 2)
       (fprintf (current-error-port) "usage: beagle-callers <name> <file-or-dir> ...\n")
       (exit 2))
     (define name (car rest))
     (define files (expand-file-args (cdr rest)))
     (query-callers name files)]
    [("provides")
     (when (< (length rest) 1)
       (fprintf (current-error-port) "usage: beagle-provides <file.rkt>\n")
       (exit 2))
     (for ([f (in-list (expand-file-args rest))])
       (query-provides f)
       (newline))]
    [("impact")
     (when (< (length rest) 2)
       (fprintf (current-error-port) "usage: beagle-impact <name> <file-or-dir> ...\n")
       (exit 2))
     (define name (car rest))
     (define files (expand-file-args (cdr rest)))
     (query-impact name files)]
    [else
     (fprintf (current-error-port) "unknown command: ~a\n" cmd)
     (exit 2)]))

(define (expand-file-args args)
  (apply append
    (for/list ([a (in-list args)])
      (if (directory-exists? a)
        (find-rkt-files a)
        (list a)))))

(provide query-sig query-fields query-callers query-provides query-impact
         run-query find-rkt-files expand-fields-file-args query-field-matches
         extract-defn-entry extract-def-entry extract-record-entry
         extract-extern-entry extract-ns find-calls-in format-call)
