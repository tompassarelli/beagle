#lang racket/base

(require racket/match
         racket/format
         "parse.rkt"
         "types.rkt"
         "ast.rkt"
         "check.rkt"
         "extensions.rkt"
         "expand-tool.rkt")

(define (read-expanded-datums f)
  (map strip-target-export
       (with-handlers ([exn:fail? (lambda (e) (read-beagle-datums f))])
         (expand-datums f))))

(define (str-downcase s)
  (list->string (map char-downcase (string->list s))))

;; Query surfaces consume the same parsed and checked program as `beagle check`.
;; Keeping this seam here prevents the daemon and one-shot tools from growing
;; independent source grammars.
(define (checked-program/file path)
  (define prog (parse-program/file path))
  (type-check! prog)
  prog)

(define (query-target-local-name target namespace)
  (define target-string (symbol->string target))
  (define namespace-string (symbol->string namespace))
  (define qualified
    (regexp-match #rx"^(.+)/([^/]+)$" target-string))
  (if (and qualified
           (string=? (cadr qualified) namespace-string))
      (string->symbol (caddr qualified))
      target))

(define (definition-location program form [raw-form #f])
  (define table (program-src-table program))
  (or (hash-ref table form #f)
      (and raw-form (hash-ref table raw-form #f))))

;; --- datum-level extraction --------------------------------------------------

;; Docstrings are real surface ((defn name "doc" [params] ...)) —
;; normalize them away before matching.
(define (strip-doc d)
  (match d
    [(list* head (? symbol? name) (? string? _doc) rest)
     (list* head name rest)]
    [_ d]))

(define (extract-defn-entry d0)
  (define d (strip-doc d0))
  (match d
    [(list (or 'defn 'defn-) (? symbol? name) params-form ret-type body body-rest ...)
     (define-values (parsed rest-p) (parse-params params-form))
     (define ptypes (map (lambda (p) (or (param-type p) (type-prim 'Any))) parsed))
     (define pnames (map param-name parsed))
     (define rtype (and rest-p (or (param-type rest-p) (type-prim 'Any))))
     (list name pnames (type-fn ptypes rtype (parse-type ret-type)))]
    [_ #f]))

(define (extract-def-entry d0)
  (define d (match d0
              ;; (def name T "doc" v) — the doc sits AFTER the type
              [(list 'def (? symbol? name) type-expr (? string? _doc) v)
               (list 'def name type-expr v)]
              [_ (strip-doc d0)]))
  (match d
    [(list 'def (? symbol? name) type-expr _)
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

(define (callable-form? form)
  (or (defn-form? form) (defn-multi? form)))

(define (callable-name form)
  (cond
    [(defn-form? form) (defn-form-name form)]
    [(defn-multi? form) (defn-multi-name form)]
    [else (error 'beagle-sig "not a callable definition: ~v" form)]))

(define (callable-clauses form)
  (cond
    [(defn-form? form)
     (list (list (defn-form-params form)
                 (defn-form-rest-param form)
                 (defn-form-return-type form)))]
    [(defn-multi? form)
     (for/list ([clause (in-list (defn-multi-arities form))])
       (list (arity-clause-params clause)
             (arity-clause-rest-param clause)
             (arity-clause-return-type clause)))]
    [else '()]))

;; An inferred scheme belongs in the headline.  Parameter detail, however,
;; describes each executable clause, so it reads the function body beneath
;; the quantifier and (for multi-arity definitions) beneath the union.
(define (callable-signature-alternatives signature)
  (define body
    (if (type-poly? signature) (type-poly-body signature) signature))
  (if (type-union? body) (type-union-alts body) (list body)))

(define (binding-target->string target)
  (cond
    [(symbol? target) (symbol->string target)]
    [(seq-destructure? target)
     (define fixed
       (map binding-target->string (seq-destructure-names target)))
     (define items
       (if (seq-destructure-rest-name target)
           (append fixed
                   (list "&"
                         (symbol->string
                          (seq-destructure-rest-name target))))
           fixed))
     (format "[~a]" (string-join* items " "))]
    [(map-destructure? target)
     (define keys
       (map symbol->string (map-destructure-keys target)))
     (format "{:keys [~a]~a}"
             (string-join* keys " ")
             (if (map-destructure-as-name target)
                 (format " :as ~a" (map-destructure-as-name target))
                 ""))]
    [else (format "~a" target)]))

(define (callable-clause-details clauses alternatives)
  (unless (= (length clauses) (length alternatives))
    (error 'beagle-sig
           "effective signature has ~a clause~a for ~a source clause~a"
           (length alternatives) (if (= (length alternatives) 1) "" "s")
           (length clauses) (if (= (length clauses) 1) "" "s")))
  (for/list ([clause (in-list clauses)]
             [signature (in-list alternatives)])
    (unless (type-fn? signature)
      (error 'beagle-sig
             "effective clause signature is not a function: ~a"
             (type->string signature)))
    (define params (car clause))
    (define rest-param (cadr clause))
    (unless (= (length params) (length (type-fn-params signature)))
      (error 'beagle-sig
             "effective clause has ~a fixed parameter~a for ~a source parameter~a"
             (length (type-fn-params signature))
             (if (= (length (type-fn-params signature)) 1) "" "s")
             (length params)
             (if (= (length params) 1) "" "s")))
    (hasheq
     'params
     (for/list ([param (in-list params)]
                [param-type (in-list (type-fn-params signature))])
       (cons (binding-target->string (param-binding-target param)) param-type))
     'rest
     (and rest-param
          (cons (binding-target->string (param-binding-target rest-param))
                (type-fn-rest-type signature)))
     'return (type-fn-ret signature))))

(define (print-signature-clause-details clauses)
  (define multi? (> (length clauses) 1))
  (for ([clause (in-list clauses)])
    (define params (hash-ref clause 'params))
    (define rest-param (hash-ref clause 'rest))
    (define prefix (if multi? "    " "  "))
    (when multi?
      (printf "  arity ~a~a:\n"
              (length params)
              (if rest-param "+" "")))
    (for ([param (in-list params)])
      (printf "~a~a : ~a\n"
              prefix
              (car param)
              (type->string (cdr param))))
    (when rest-param
      (printf "~a& ~a : ~a\n"
              prefix
              (car rest-param)
              (type->string (cdr rest-param))))
    (printf "~a-> ~a\n"
            prefix
            (type->string (hash-ref clause 'return)))))

(define (authored-callable-type form)
  (define (rest-element-type rest-param)
    (define aggregate (and rest-param (param-type rest-param)))
    (cond
      [(and (type-app? aggregate)
            (eq? (type-app-ctor aggregate) 'Vec)
            (= (length (type-app-args aggregate)) 1))
       (car (type-app-args aggregate))]
      [aggregate aggregate]
      [else (type-prim 'Any)]))
  (define alternatives
    (for/list ([clause (in-list (callable-clauses form))])
      (define params (car clause))
      (define rest-param (cadr clause))
      (define return-type (caddr clause))
      (type-fn
       (map (lambda (param) (or (param-type param) (type-prim 'Any))) params)
       (and rest-param (rest-element-type rest-param))
       return-type)))
  (if (= (length alternatives) 1)
      (car alternatives)
      (type-union alternatives)))

(define (signature-match name file program signature clauses
                         #:extern? [extern? #f]
                         #:loc [loc #f])
  (hasheq 'name name
          'file file
          'namespace (program-namespace program)
          'signature signature
          'clauses clauses
          'extern? extern?
          'line (and loc (src-loc-line loc))
          'col (and loc (src-loc-col loc))))

(define (generated-signature-clause params signature)
  (callable-clause-details
   (list (list params #f #f))
   (list signature)))

(define (query-signature-matches name files)
  (define target (if (string? name) (string->symbol name) name))
  (apply
   append
   (for/list ([f (in-list files)])
    (define program (checked-program/file f))
    (define local-target
      (query-target-local-name target (program-namespace program)))
    (define matches '())
    (for ([raw-form (in-list (program-forms program))])
      (define form (unwrap-definition-form raw-form))
      (when (and (callable-form? form)
                 (eq? (callable-name form) local-target))
        (define signature
          (let ([effective
                 (program-effective-definition-type program local-target #f)])
            (cond
              [effective effective]
              ;; Dynamic programs deliberately do not publish inferred types.
              ;; Their canonical annotations remain useful authoring facts.
              [(eq? (program-mode program) 'dynamic)
               (authored-callable-type form)]
              [else
               (error 'beagle-sig
                      "checked program is missing the effective signature for ~a"
                      local-target)])))
        (set! matches
              (cons
               (signature-match
                target f program signature
                (callable-clause-details
                 (callable-clauses form)
                 (callable-signature-alternatives signature))
                #:loc (definition-location program form raw-form))
               matches)))
      ;; Record constructors and accessors are real emitted functions.  They
      ;; have no authored defn node, so expose their checker-owned signatures
      ;; from the checked record form instead of returning an empty success.
      (when (record-form? form)
        (define record-name (record-form-name form))
        (define record-type (type-prim record-name))
        (define fields (record-form-fields form))
        (define constructor-name
          (string->symbol (string-append "->" (symbol->string record-name))))
        (when (eq? local-target constructor-name)
          (define signature
            (type-fn (map param-type fields) #f record-type))
          (set! matches
                (cons
                 (signature-match
                  target f program signature
                  (generated-signature-clause fields signature)
                  #:loc (definition-location program form raw-form))
                 matches)))
        (for ([field (in-list fields)])
          (define accessor-name
            (string->symbol
             (format "~a-~a"
                     (str-downcase (symbol->string record-name))
                     (param-name field))))
          (when (eq? local-target accessor-name)
            (define signature
              (type-fn (list record-type) #f (param-type field)))
            (set! matches
                  (cons
                   (signature-match
                    target f program signature
                    (list
                     (hasheq 'params (list (cons "r" record-type))
                             'rest #f
                             'return (param-type field)))
                    #:loc (definition-location program form raw-form))
                   matches))))))
    (define extern-type (hash-ref (program-externs program) local-target #f))
    (when extern-type
      (set! matches
            (cons
             (signature-match target f program extern-type '() #:extern? #t)
             matches)))
    (reverse matches))))

(define (query-sig name files)
  (define target (if (string? name) (string->symbol name) name))
  (define matches (query-signature-matches target files))
  (when (null? matches)
    (raise-user-error 'beagle-sig
                      "callable ~a not found in provided files"
                      target))
  (for ([match (in-list matches)])
    (define signature (hash-ref match 'signature))
    (printf "~a : ~a~a\n"
            target
            (type->string signature)
            (if (hash-ref match 'extern?) "  (extern)" ""))
    (unless (hash-ref match 'extern?)
      (print-signature-clause-details (hash-ref match 'clauses)))))

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
             (find-beagle-files a))]
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
                             #:load-program [load-program checked-program/file])
  (when (null? files)
    (raise-user-error 'beagle-fields "no Beagle source files were provided"))
  (define target (if (string? rec-name) (string->symbol rec-name) rec-name))
  (define matches
    (apply
     append
     (for/list ([f (in-list files)])
       (define program
         (with-handlers ([exn:fail?
                          (lambda (e)
                            (raise-user-error
                             'beagle-fields
                             "failed to check ~a: ~a"
                             f
                             (exn-message e)))])
           (load-program f)))
       (define local-target
         (query-target-local-name target (program-namespace program)))
       (for/list ([raw-form (in-list (program-forms program))]
                  #:do [(define form (unwrap-definition-form raw-form))]
                  #:when (and (record-form? form)
                              (eq? (record-form-name form) local-target)))
         (define loc (definition-location program form raw-form))
         (list f
               (record-form-name form)
               (record-form-fields form)
               (program-namespace program)
               (and loc (src-loc-line loc))
               (and loc (src-loc-col loc)))))))
  (when (null? matches)
    (raise-user-error 'beagle-fields
                      "record ~a not found in provided files"
                      target))
  matches)

(define (query-fields rec-name files)
  (define target (if (string? rec-name) (string->symbol rec-name) rec-name))
  (for ([match (in-list (query-field-matches target files))])
    (define record-name (cadr match))
    (define fields (caddr match))
    (define name-str (symbol->string record-name))
    (define name-lower (str-downcase name-str))
    (printf "~a\n" target)
    (for ([fld (in-list fields)])
      (printf "  ~a : ~a    accessor: ~a-~a\n"
              (param-name fld)
              (type->string (param-type fld))
              name-lower
              (param-name fld)))
    (define ctor-types (map (lambda (fld) (type->string (param-type fld))) fields))
    (printf "  constructor: ->~a : (Fn [~a] ~a)\n"
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

(define (find-beagle-files dir)
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
       (fprintf (current-error-port) "usage: beagle-provides <source-file>\n")
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
        (find-beagle-files a)
        (list a)))))

(provide query-sig query-fields query-callers query-provides query-impact
         query-signature-matches checked-program/file query-target-local-name
         run-query find-beagle-files expand-fields-file-args query-field-matches
         extract-defn-entry extract-def-entry extract-record-entry
         extract-extern-entry extract-ns find-calls-in format-call)
