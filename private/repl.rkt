#lang racket/base

;; beagle-repl: interactive REPL with type checking.
;;
;; Each expression is parsed, type-checked, and compiled to Clojure.
;; The type environment persists across inputs. Supports:
;;   - defn/def/defrecord at top level (extends persistent env)
;;   - Expressions (type-inferred and compiled)
;;   - :type EXPR — show type without compiling
;;   - :sig NAME — look up a definition's signature
;;   - :env — show all user-defined bindings
;;   - :quit — exit

(require racket/match
         racket/string
         racket/format
         racket/port
         racket/list
         racket/file
         json
         racket/tcp
         "parse.rkt"
         "types.rkt"
         "check.rkt"
         "emit.rkt"
         "stdlib-types.rkt")

;; Persistent environment across REPL inputs
(define repl-env (make-hash))
(define repl-records (make-hash))
(define repl-forms '())

(define (init-repl-env!)
  (for ([(k v) (in-hash STDLIB-TYPES)])
    (hash-set! repl-env k v)))

(define (repl-type-of expr-str)
  (with-handlers ([exn:fail? (lambda (e) (format "error: ~a" (exn-message e)))])
    (define stxs (read-repl-stxs expr-str))
    (define prog (parse-program stxs))
    (define env (build-repl-check-env prog))
    (define forms (program-forms prog))
    (cond
      [(null? forms) "()"]
      [else
       (define last-form (last forms))
       (cond
         [(defn-form? last-form)
          (define params (defn-form-params last-form))
          (define ptypes (map (lambda (p) (or (param-type p) (type-prim 'Any))) params))
          (define ret (or (defn-form-return-type last-form) (type-prim 'Any)))
          (type->string (type-fn ptypes #f ret))]
         [(def-form? last-form)
          (type->string (or (def-form-type last-form)
                            (infer-in-env (def-form-value last-form) env)))]
         [else
          (type->string (infer-in-env last-form env))])])))

(define (repl-compile expr-str)
  (with-handlers ([exn:fail? (lambda (e) (values #f (exn-message e)))])
    (define stxs (read-repl-stxs expr-str))
    (define prog (parse-program stxs))
    (define env (build-repl-check-env prog))
    ;; Type check
    (for ([form (in-list (program-forms prog))])
      (check-form form env))
    ;; Persist imported types from require into repl-env
    (for ([(k v) (in-hash (program-externs prog))])
      (unless (hash-has-key? repl-env k)
        (hash-set! repl-env k v)))
    ;; Register any new defs/defns/records in persistent env
    (for ([form (in-list (program-forms prog))])
      (register-form! form env))
    ;; Emit and strip ns boilerplate
    (define clj (emit-program prog))
    (define lines (string-split clj "\n"))
    (define stripped
      (string-join
       (filter (lambda (l)
                 (not (or (string=? l "")
                          (regexp-match? #rx"^\\(ns repl\\)" l))))
               lines)
       "\n"))
    (values stripped #f)))

(define (build-repl-check-env prog)
  (define env (make-hash))
  (for ([(k v) (in-hash repl-env)])
    (hash-set! env k v))
  (for ([(k v) (in-hash (program-externs prog))])
    (hash-set! env k v))
  env)

(define (register-form! form env)
  (cond
    [(defn-form? form)
     (define name (defn-form-name form))
     (define params (defn-form-params form))
     (define ptypes (map (lambda (p) (or (param-type p) (type-prim 'Any))) params))
     (define ret (or (defn-form-return-type form) (type-prim 'Any)))
     (hash-set! repl-env name (type-fn ptypes #f ret))]
    [(def-form? form)
     (define name (def-form-name form))
     (define t (or (def-form-type form)
                   (infer-in-env (def-form-value form) env)))
     (hash-set! repl-env name t)]
    [(record-form? form)
     (define name (record-form-name form))
     (hash-set! repl-records name form)
     (hash-set! repl-env name (type-prim name))
     (define fields (record-form-fields form))
     (define field-types
       (map (lambda (p) (or (param-type p) (type-prim 'Any))) fields))
     (define ctor-name (string->symbol (format "->~a" name)))
     (hash-set! repl-env ctor-name
                (type-fn field-types #f (type-prim name)))
     (define name-lower (string-downcase (symbol->string name)))
     (for ([fld (in-list fields)])
       (define acc-name
         (string->symbol (format "~a-~a" name-lower (param-name fld))))
       (hash-set! repl-env acc-name
                  (type-fn (list (type-prim name)) #f
                           (or (param-type fld) (type-prim 'Any)))))]
    [else (void)]))

(define (string-downcase s)
  (list->string (map char-downcase (string->list s))))

(define (infer-in-env form env)
  (with-handlers ([exn:fail? (lambda (_) (type-prim 'Any))])
    (infer-expr form env)))

(define (read-repl-stxs str)
  (define wrapped (string-append "#lang beagle\n(ns repl)\n" str "\n"))
  (define in (open-input-string wrapped))
  (parameterize ([read-square-bracket-with-tag BRACKET-TAG])
    (read-line in)
    (let loop ([acc '()])
      (define stx (read-syntax 'repl in))
      (if (eof-object? stx) (reverse acc) (loop (cons stx acc))))))

(define (daemon-port-file)
  (or (getenv "BEAGLE_DAEMON_PORTFILE")
      (build-path (find-system-path 'temp-dir) "beagle-daemon.port")))

(define (daemon-query cmd)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define port-file (daemon-port-file))
    (unless (file-exists? port-file) (error "no daemon"))
    (define port-num (string->number (string-trim (file->string port-file))))
    (define-values (in out) (tcp-connect "127.0.0.1" port-num))
    (fprintf out "~a\n" cmd)
    (flush-output out)
    (define resp (read-json in))
    (close-input-port in)
    (close-output-port out)
    (and (hash? resp) (hash-ref resp 'ok #f) resp)))

(define (daemon-sig name)
  (define resp (daemon-query (format "sig ~a ." name)))
  (and resp
       (let ([results (hash-ref resp 'results '())])
         (and (pair? results)
              (hash-ref (car results) 'signature #f)))))

(define (show-env)
  (define user-bindings
    (for/list ([(k v) (in-hash repl-env)]
               #:when (not (hash-has-key? STDLIB-TYPES k)))
      (cons k v)))
  (if (null? user-bindings)
      (displayln "  (no user bindings)")
      (for ([pair (in-list (sort user-bindings symbol<? #:key car))])
        (printf "  ~a : ~a\n" (car pair) (type->string (cdr pair))))))

(define (run-repl)
  (init-repl-env!)
  (displayln "beagle repl (type :quit to exit, :type EXPR for type, :env for bindings)")
  (let loop ()
    (display "beagle> ")
    (flush-output)
    (define line (read-line))
    (cond
      [(eof-object? line) (displayln "\nbye")]
      [(string=? (string-trim line) ":quit") (displayln "bye")]
      [(string=? (string-trim line) ":env")
       (show-env)
       (loop)]
      [(string-prefix? (string-trim line) ":type ")
       (define expr (substring (string-trim line) 6))
       (printf "~a\n" (repl-type-of expr))
       (loop)]
      [(string-prefix? (string-trim line) ":sig ")
       (define name (string-trim (substring (string-trim line) 5)))
       (define sym (string->symbol name))
       (define t (hash-ref repl-env sym #f))
       (cond
         [t (printf "~a : ~a\n" sym (type->string t))]
         [else
          (define daemon-t (daemon-sig name))
          (if daemon-t
              (printf "~a : ~a  (via daemon)\n" sym daemon-t)
              (printf "~a: not found\n" name))])
       (loop)]
      [(string=? (string-trim line) "") (loop)]
      [else
       (define-values (clj err) (repl-compile line))
       (cond
         [err (printf "error: ~a\n" err)]
         [else
          (define trimmed (string-trim clj))
          (unless (string=? trimmed "")
            (printf "~a\n" trimmed))
          (printf "  ; ~a\n" (repl-type-of line))])
       (loop)])))

(provide run-repl repl-compile repl-type-of)
