#lang racket/base

;; beagle-lsp: Language Server Protocol implementation.
;;
;; Speaks JSON-RPC 2.0 messages over stdin/stdout with Content-Length headers.
;; Uses the daemon's AST cache + query engine for fast responses.
;;
;; Capabilities:
;;   textDocument/hover          — type signatures
;;   textDocument/publishDiagnostics — type errors on save
;;   textDocument/definition     — jump to definition (cross-module)
;;   textDocument/documentSymbol — outline of defn/def/defrecord in file

(require json
         racket/match
         racket/port
         racket/string
         racket/format
         racket/list
         racket/file
         "parse.rkt"
         "query.rkt"
         "types.rkt"
         "check.rkt"
         "stdlib-types.rkt"
         "extensions.rkt"
         "expand-tool.rkt")

;; --- JSON-RPC transport -----------------------------------------------------

(define (read-message in)
  (define headers (read-headers in))
  (when (eof-object? headers) (exit 0))
  (define len (hash-ref headers "Content-Length" #f))
  (unless len (error 'lsp "missing Content-Length header"))
  (define n (string->number len))
  (define body (read-string n in))
  (when (eof-object? body) (exit 0))
  (string->jsexpr body))

(define (read-headers in)
  (define first-line (read-line in 'return-linefeed))
  (cond
    [(eof-object? first-line) eof]
    [else
     (let loop ([h (hash)] [line first-line])
       (cond
         [(or (eof-object? line) (equal? line "")) h]
         [else
          (define parts (regexp-match #rx"^([^:]+): (.+)$" line))
          (loop (if parts (hash-set h (cadr parts) (caddr parts)) h)
                (read-line in 'return-linefeed))]))]))

(define (send-message out msg)
  (define body (jsexpr->string msg))
  (define len (string-utf-8-length body))
  (fprintf out "Content-Length: ~a\r\n\r\n~a" len body)
  (flush-output out))

(define (send-response out id result)
  (send-message out (hasheq 'jsonrpc "2.0" 'id id 'result result)))

(define (send-error out id code message)
  (send-message out (hasheq 'jsonrpc "2.0" 'id id
                            'error (hasheq 'code code 'message message))))

(define (send-notification out method params)
  (send-message out (hasheq 'jsonrpc "2.0" 'method method 'params params)))

;; --- Document state ---------------------------------------------------------

(define open-docs (make-hash))  ; uri -> content string

(define (uri->path uri)
  (cond
    [(string-prefix? uri "file://") (substring uri 7)]
    [else uri]))

(define (path->uri path)
  (string-append "file://" path))

;; --- Hover ------------------------------------------------------------------

(define (handle-hover params)
  (define uri (hash-ref (hash-ref params 'textDocument) 'uri))
  (define pos (hash-ref params 'position))
  (define line (hash-ref pos 'line))
  (define col (hash-ref pos 'character))
  (define path (uri->path uri))
  (define word (word-at-position path line col))
  (cond
    [(not word) 'null]
    [else
     (define info (lookup-symbol-info path word))
     (if info
         (hasheq 'contents (hasheq 'kind "markdown" 'value info))
         'null)]))

(define (word-at-position path line col)
  (define content (or (hash-ref open-docs (path->uri path) #f)
                      (and (file-exists? path)
                           (file->string path))))
  (when (not content) #f)
  (define lines (string-split content "\n" #:trim? #f))
  (cond
    [(>= line (length lines)) #f]
    [else
     (define ln (list-ref lines line))
     (cond
       [(>= col (string-length ln)) #f]
       [else
        (define word-chars
          (string->list "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-?!<>*/+."))
        (define (word-char? c) (member c word-chars))
        (define start
          (let loop ([i col])
            (if (and (> i 0) (word-char? (string-ref ln (sub1 i))))
                (loop (sub1 i))
                i)))
        (define end
          (let loop ([i col])
            (if (and (< i (string-length ln)) (word-char? (string-ref ln i)))
                (loop (add1 i))
                i)))
        (if (= start end) #f
            (substring ln start end))])]))

(define (lsp-read-datums path)
  (with-handlers ([exn:fail? (lambda (e) (read-beagle-datums path))])
    (expand-datums path)))

(define (lsp-checked-program path)
  (require-beagle-source-extension! path 'beagle-lsp)
  (define content (hash-ref open-docs (path->uri path) #f))
  (define prog
    (if content
        (parse-program/bytes
         (string->bytes/utf-8 content)
         #:source-path path)
        (parse-program/file path)))
  (type-check! prog)
  prog)

(define (callable-form? form)
  (or (defn-form? form) (defn-multi? form)))

(define (callable-name form)
  (cond
    [(defn-form? form) (defn-form-name form)]
    [(defn-multi? form) (defn-multi-name form)]
    [else (error 'beagle-lsp "not a callable definition: ~v" form)]))

(define (value-definition-form? form)
  (or (def-form? form) (defonce-form? form)))

(define (value-definition-name form)
  (cond
    [(def-form? form) (def-form-name form)]
    [(defonce-form? form) (defonce-form-name form)]
    [else (error 'beagle-lsp "not a value definition: ~v" form)]))

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
    (error 'beagle-lsp
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
     (error 'beagle-lsp
            "checked program is missing the effective signature for ~a"
            name)]))

(define (effective-value-definition-type prog form)
  (define name (value-definition-name form))
  (define effective (program-effective-definition-type prog name #f))
  (cond
    [effective
     (public-type->string effective)
     effective]
    [else
     (error 'beagle-lsp
            "checked program is missing the effective type for ~a"
            name)]))

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

(define (lookup-symbol-info path word)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define prog (lsp-checked-program path))
    (define target (string->symbol word))
    (define results '())
    (for ([raw-form (in-list (program-forms prog))])
      (define form (unwrap-definition-form raw-form))
      (when (and (callable-form? form)
                 (eq? (callable-name form) target))
        (define ftype (effective-callable-type prog form))
        (set! results
              (cons (format "```\n~a : ~a\n```"
                            target (public-type->string ftype))
                    results)))
      (when (and (record-form? form)
                 (eq? (record-form-name form) target))
        (define fields (record-form-fields form))
        (set! results
              (cons (format "```\ndefrecord ~a\n~a\n```"
                            target
                            (string-join
                             (map (lambda (f)
                                    (format
                                     "  ~a : ~a"
                                     (binding-target->string
                                      (param-binding-target f))
                                     (public-type->string (param-type f))))
                                  fields)
                             "\n"))
                    results)))
      (when (and (value-definition-form? form)
                 (eq? (value-definition-name form) target))
        (define effective (effective-value-definition-type prog form))
        (set! results
              (cons (format "```\n~a : ~a\n```"
                            target
                            (public-type->string effective))
                    results))))
    (define extern-type (hash-ref (program-externs prog) target #f))
    (when extern-type
      (set! results
            (cons (format "```\n~a : ~a  (extern)\n```"
                          target (public-type->string extern-type))
                  results)))
    ;; Also check stdlib (target-aware: pick the right catalog for .bnix/.bjs/etc)
    (when (null? results)
      (define file-target (or (expected-target-for-extension path) 'clj))
      (define stdlib (stdlib-for-target file-target))
      (define stdlib-type
        (hash-ref stdlib ((current-parse-expr) target) #f))
      (when stdlib-type
        (set! results
              (list (format "```\n~a : ~a  (stdlib)\n```"
                            target (public-type->string stdlib-type))))))
    (if (null? results) #f (string-join (reverse results) "\n\n"))))

;; --- Diagnostics ------------------------------------------------------------

(define (publish-diagnostics out path)
  (define uri (path->uri path))
  (define content (hash-ref open-docs uri #f))
  (define diags
    (with-handlers ([exn:fail? (lambda (e) (list (make-diag 0 0 1 (exn-message e))))])
      (cond
        [(not (beagle-source-file? path)) '()]
        [(and (not content) (not (file-exists? path))) '()]
        [else (check-file-for-diagnostics path content)])))
  (send-notification out "textDocument/publishDiagnostics"
                     (hasheq 'uri uri 'diagnostics diags)))

(define (make-diag line col severity message)
  (hasheq 'range (hasheq 'start (hasheq 'line line 'character col)
                         'end (hasheq 'line line 'character (+ col 1)))
          'severity severity
          'source "beagle"
          'message message))

(define (check-file-for-diagnostics path [content #f])
  (with-handlers ([exn:fail? (lambda (e)
                                (list (make-diag 0 0 1 (exn-message e))))])
    (require-beagle-source-extension! path 'beagle-lsp)
    (define stxs
      (if content
          (read-beagle-stxs-from-string path content)
          (read-beagle-stxs path)))
    (define prog (parse-program stxs))
    (define errors '())
    (type-check-with-locs! prog
                           (lambda (e stx)
                             (define loc (and (syntax? stx)
                                              (syntax-line stx)))
                             (define col (and (syntax? stx)
                                              (syntax-column stx)))
                             (define line (if loc (sub1 loc) 0))
                             (set! errors
                                   (cons (make-diag line (or col 0) 1
                                                    (exn-message e))
                                         errors))))
    (reverse errors)))

(define (read-beagle-stxs path)
  (define (read-until-brace port)
    (let loop ([acc '()])
      (define c (peek-char port))
      (cond
        [(eof-object? c) (reverse acc)]
        [(char-whitespace? c) (read-char port) (loop acc)]
        [(char=? c #\}) (read-char port) (reverse acc)]
        [else (loop (cons (read-syntax (string->path path) port) acc))])))
  (define lsp-readtable
    (make-readtable #f
      #\{ 'terminating-macro
           (lambda (ch port src line col pos)
             (define items (read-until-brace port))
             (datum->syntax #f (cons MAP-TAG (map syntax->datum items))
                            (vector src line col pos #f)))
      #\} 'terminating-macro
           (lambda (ch port src line col pos) (error 'beagle "unexpected `}`"))
      #\# 'non-terminating-macro
           (lambda (ch port src line col pos)
             (define next (peek-char port))
             (cond
               [(and (char? next) (char=? next #\{))
                (read-char port)
                (define items (read-until-brace port))
                (datum->syntax #f (cons SET-TAG (map syntax->datum items))
                               (vector src line col pos #f))]
               [(and (char? next) (char=? next #\"))
                (read-char port)
                (define pattern
                  (let rloop ([acc '()])
                    (define c (read-char port))
                    (cond
                      [(eof-object? c) (list->string (reverse acc))]
                      [(char=? c #\") (list->string (reverse acc))]
                      [(char=? c #\\) (rloop (cons (read-char port) (cons #\\ acc)))]
                      [else (rloop (cons c acc))])))
                (datum->syntax #f (list '#%regex pattern)
                               (vector src line col pos #f))]
               [else (error 'beagle "unexpected dispatch: #~a" next)]))))
  (with-input-from-file path
    (lambda ()
      (parameterize ([read-square-bracket-with-tag BRACKET-TAG]
                     [current-readtable lsp-readtable])
        (port-count-lines! (current-input-port))
        (read-line)
        (let loop ([acc '()])
          (define stx (read-syntax (string->path path)))
          (if (eof-object? stx) (reverse acc) (loop (cons stx acc))))))))

(define (read-beagle-stxs-from-string path content)
  (define lsp-readtable
    (make-readtable #f
      #\{ 'terminating-macro
           (lambda (ch port src line col pos)
             (define items
               (let loop ([acc '()])
                 (define c (peek-char port))
                 (cond
                   [(eof-object? c) (reverse acc)]
                   [(char-whitespace? c) (read-char port) (loop acc)]
                   [(char=? c #\}) (read-char port) (reverse acc)]
                   [else (loop (cons (read-syntax (string->path path) port) acc))])))
             (datum->syntax #f (cons MAP-TAG (map syntax->datum items))
                            (vector src line col pos #f)))
      #\} 'terminating-macro
           (lambda (ch port src line col pos) (error 'beagle "unexpected `}`"))
      #\# 'non-terminating-macro
           (lambda (ch port src line col pos)
             (define next (peek-char port))
             (cond
               [(and (char? next) (char=? next #\{))
                (read-char port)
                (define items
                  (let loop ([acc '()])
                    (define c (peek-char port))
                    (cond
                      [(eof-object? c) (reverse acc)]
                      [(char-whitespace? c) (read-char port) (loop acc)]
                      [(char=? c #\}) (read-char port) (reverse acc)]
                      [else (loop (cons (read-syntax (string->path path) port) acc))])))
                (datum->syntax #f (cons SET-TAG (map syntax->datum items))
                               (vector src line col pos #f))]
               [(and (char? next) (char=? next #\"))
                (read-char port)
                (define pattern
                  (let rloop ([acc '()])
                    (define c (read-char port))
                    (cond
                      [(eof-object? c) (list->string (reverse acc))]
                      [(char=? c #\") (list->string (reverse acc))]
                      [(char=? c #\\) (rloop (cons (read-char port) (cons #\\ acc)))]
                      [else (rloop (cons c acc))])))
                (datum->syntax #f (list '#%regex pattern)
                               (vector src line col pos #f))]
               [else (error 'beagle "unexpected dispatch: #~a" next)]))))
  (define in (open-input-string content))
  (port-count-lines! in)
  (parameterize ([read-square-bracket-with-tag BRACKET-TAG]
                 [current-readtable lsp-readtable])
    (read-line in)
    (let loop ([acc '()])
      (define stx (read-syntax (string->path path) in))
      (if (eof-object? stx) (reverse acc) (loop (cons stx acc))))))

;; --- Document symbols -------------------------------------------------------

(define (handle-document-symbols params)
  (define uri (hash-ref (hash-ref params 'textDocument) 'uri))
  (define path (uri->path uri))
  (with-handlers ([exn:fail? (lambda (_) '())])
    (define datums (lsp-read-datums path))
    (define symbols '())
    (define line-no 0)
    (for ([d (in-list datums)])
      (define defn-entry (extract-defn-entry d))
      (when defn-entry
        (set! symbols
              (cons (hasheq 'name (symbol->string (car defn-entry))
                            'kind 12  ; Function
                            'range (zero-range line-no)
                            'selectionRange (zero-range line-no))
                    symbols)))
      (define rec (extract-record-entry d))
      (when rec
        (set! symbols
              (cons (hasheq 'name (symbol->string (car rec))
                            'kind 23  ; Struct
                            'range (zero-range line-no)
                            'selectionRange (zero-range line-no))
                    symbols)))
      (define def-e (extract-def-entry d))
      (when def-e
        (set! symbols
              (cons (hasheq 'name (symbol->string (car def-e))
                            'kind 13  ; Variable
                            'range (zero-range line-no)
                            'selectionRange (zero-range line-no))
                    symbols)))
      (set! line-no (add1 line-no)))
    (reverse symbols)))

(define (zero-range line)
  (hasheq 'start (hasheq 'line line 'character 0)
          'end (hasheq 'line line 'character 0)))

;; --- Definition (jump to def) -----------------------------------------------

(define (handle-definition params)
  (define uri (hash-ref (hash-ref params 'textDocument) 'uri))
  (define pos (hash-ref params 'position))
  (define line (hash-ref pos 'line))
  (define col (hash-ref pos 'character))
  (define path (uri->path uri))
  (define word (word-at-position path line col))
  (cond
    [(not word) 'null]
    [else
     (define target (string->symbol word))
     (define result (find-definition path target))
     (or result 'null)]))

(define (find-definition origin-path target)
  (define (search-file path)
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (define datums (lsp-read-datums path))
      (for/first ([d (in-list datums)]
                  #:when (or (let ([e (extract-defn-entry d)])
                               (and e (eq? (car e) target)))
                             (let ([r (extract-record-entry d)])
                               (and r (eq? (car r) target)))
                             (let ([e (extract-def-entry d)])
                               (and e (eq? (car e) target)))))
        (hasheq 'uri (path->uri path)
                'range (zero-range 0)))))
  ;; First search current file
  (define local (search-file origin-path))
  (or local
      ;; Then search Beagle sources in the same directory.
      (let ([dir (path->string (let-values ([(base _name _must-be-dir?) (split-path (string->path origin-path))])
                                 base))])
        (for/first ([f (in-directory dir)]
                    #:when (regexp-match? BEAGLE-FILE-RX (path->string f))
                    #:when (not (equal? (path->string f) origin-path))
                    #:when (search-file (path->string f)))
          (search-file (path->string f))))))

;; --- Completion -------------------------------------------------------------

(define (handle-completion params)
  (define uri (hash-ref (hash-ref params 'textDocument) 'uri))
  (define pos (hash-ref params 'position))
  (define line (hash-ref pos 'line))
  (define col (hash-ref pos 'character))
  (define path (uri->path uri))
  (define prefix (prefix-at-position path line col))
  (cond
    [(or (not prefix) (< (string-length prefix) 1)) '()]
    [else
     (define items (collect-completions path prefix))
     (if (null? items) '() items)]))

(define (prefix-at-position path line col)
  (define content (or (hash-ref open-docs (path->uri path) #f)
                      (and (file-exists? path) (file->string path))))
  (and content
       (let ([lines (string-split content "\n" #:trim? #f)])
         (cond
           [(>= line (length lines)) #f]
           [else
            (define ln (list-ref lines line))
            (define word-chars
              (string->list "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-?!<>*/+.:"))
            (define (word-char? c) (member c word-chars))
            (define start
              (let loop ([i col])
                (if (and (> i 0) (word-char? (string-ref ln (sub1 i))))
                    (loop (sub1 i))
                    i)))
            (if (= start col) #f
                (substring ln start col))]))))

(define (collect-completions path prefix)
  (define items '())
  ;; File-local definitions
  (with-handlers ([exn:fail? (lambda (_) (void))])
    (define prog (lsp-checked-program path))
    (for ([raw-form (in-list (program-forms prog))])
      (define form (unwrap-definition-form raw-form))
      (when (callable-form? form)
        (define name (symbol->string (callable-name form)))
        (when (string-prefix? name prefix)
          (define ftype (effective-callable-type prog form))
          (set! items
                (cons (hasheq 'label name
                              'kind 3  ; Function
                              'detail (public-type->string ftype))
                      items))))
      (when (record-form? form)
        (define name (symbol->string (record-form-name form)))
        (when (string-prefix? name prefix)
          (set! items
                (cons (hasheq 'label name
                              'kind 22  ; Struct
                              'detail "defrecord")
                      items)))
        (define ctor (format "->~a" name))
        (when (string-prefix? ctor prefix)
          (set! items
                (cons (hasheq 'label ctor
                              'kind 4  ; Constructor
                              'detail (format "-> ~a" name))
                      items))))
      (when (value-definition-form? form)
        (define name (symbol->string (value-definition-name form)))
        (when (string-prefix? name prefix)
          (define effective (effective-value-definition-type prog form))
          (set! items
                (cons (hasheq 'label name
                              'kind 6  ; Variable
                              'detail (public-type->string effective))
                      items))))))
  ;; Directory-sibling definitions (for cross-module)
  (with-handlers ([exn:fail? (lambda (_) (void))])
    (define dir (path->string
                  (let-values ([(base _name _dir?) (split-path (string->path path))])
                    base)))
    (for ([f (in-directory dir)]
          #:when (beagle-source-file? (path->string f))
          #:when (not (equal? (path->string f) path)))
      (define mod-name
        (path->string (let-values ([(_base name _dir?) (split-path f)]) name)))
      (define mod-prefix
        (string-append (regexp-replace #rx"\\.[^.]+$" mod-name "") "/"))
      (when (string-prefix? mod-prefix prefix)
        (with-handlers ([exn:fail? (lambda (_) (void))])
          (define sibling (lsp-checked-program (path->string f)))
          (for ([raw-form (in-list (program-forms sibling))])
            (define form (unwrap-definition-form raw-form))
            (when (callable-form? form)
              (define qual
                (string-append mod-prefix
                               (symbol->string (callable-name form))))
              (when (string-prefix? qual prefix)
                (set! items
                      (cons (hasheq 'label qual
                                    'kind 3
                                    'detail
                                    (public-type->string
                                     (effective-callable-type sibling form)))
                            items)))))))))
  ;; Stdlib completions (target-aware)
  (define file-target (or (expected-target-for-extension path) 'clj))
  (define stdlib (stdlib-for-target file-target))
  (for ([(k v) (in-hash stdlib)])
    (define name
      (cond
        [(qualified-ref? k)
         (format "~a/~a" (qualified-ref-qualifier k)
                 (qualified-ref-name k))]
        [else (symbol->string k)]))
    (when (string-prefix? name prefix)
      (set! items
            (cons (hasheq 'label name
                          'kind 3
                          'detail (public-type->string v))
                  items))))
  (if (> (length items) 100) (take items 100) items))

;; --- Initialization ---------------------------------------------------------

(define (server-capabilities)
  (hasheq 'capabilities
          (hasheq 'textDocumentSync
                  (hasheq 'openClose #t
                          'change 1  ; full sync
                          'save (hasheq 'includeText #f))
                  'hoverProvider #t
                  'definitionProvider #t
                  'documentSymbolProvider #t
                  'completionProvider
                  (hasheq 'triggerCharacters (list "(" ":" "/")
                          'resolveProvider #f))))

;; --- Main dispatch ----------------------------------------------------------

(define (handle-request method params id out)
  (case method
    [("initialize")
     (send-response out id (server-capabilities))]
    [("initialized") (void)]
    [("shutdown")
     (send-response out id 'null)]
    [("textDocument/hover")
     (send-response out id (handle-hover params))]
    [("textDocument/definition")
     (send-response out id (handle-definition params))]
    [("textDocument/documentSymbol")
     (send-response out id (handle-document-symbols params))]
    [("textDocument/completion")
     (send-response out id (handle-completion params))]
    [else
     (send-error out id -32601 (format "method not found: ~a" method))]))

(define (handle-notification method params out)
  (case method
    [("textDocument/didOpen")
     (define td (hash-ref params 'textDocument))
     (hash-set! open-docs (hash-ref td 'uri) (hash-ref td 'text))
     (publish-diagnostics out (uri->path (hash-ref td 'uri)))]
    [("textDocument/didChange")
     (define td (hash-ref params 'textDocument))
     (define changes (hash-ref params 'contentChanges))
     (when (pair? changes)
       (hash-set! open-docs (hash-ref td 'uri) (hash-ref (car changes) 'text)))]
    [("textDocument/didSave")
     (define td (hash-ref params 'textDocument))
     (publish-diagnostics out (uri->path (hash-ref td 'uri)))]
    [("textDocument/didClose")
     (hash-remove! open-docs (hash-ref (hash-ref params 'textDocument) 'uri))]
    [("exit") (exit 0)]
    [else (void)]))

(define (run-lsp)
  (define in (current-input-port))
  (define out (current-output-port))
  (file-stream-buffer-mode out 'none)
  (let loop ([consecutive-errors 0])
    (with-handlers ([exn:fail? (lambda (e)
                                  (fprintf (current-error-port) "lsp error: ~a\n" (exn-message e))
                                  (flush-output (current-error-port))
                                  (if (>= consecutive-errors 5)
                                      (begin (fprintf (current-error-port)
                                                      "lsp: too many consecutive errors, exiting\n")
                                             (exit 1))
                                      (loop (add1 consecutive-errors))))])
      (define msg (read-message in))
      (define method (hash-ref msg 'method #f))
      (define params (hash-ref msg 'params (hasheq)))
      (define id (hash-ref msg 'id #f))
      (cond
        [id (handle-request method params id out)]
        [method (handle-notification method params out)]
        [else (void)])
      (loop 0))))

(provide run-lsp lookup-symbol-info collect-completions
         check-file-for-diagnostics)
