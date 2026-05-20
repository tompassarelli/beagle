#lang racket/base

;; Structured error output for agent consumption.
;;
;; When the env var `BEAGLE_ERROR_FORMAT=json` is set, beagle compile errors
;; are written to stderr as a single line of JSON instead of Racket's default
;; multi-line rendering. Agent runners can parse this and feed it back to
;; the model for self-correction.

(require racket/format
         json
         "check.rkt")

(define (json-error-mode?)
  (define v (getenv "BEAGLE_ERROR_FORMAT"))
  (and v (string=? v "json")))

(define (path-or-source stx)
  (cond
    [(not stx) #f]
    [else
     (define src (syntax-source stx))
     (cond
       [(path? src)   (path->string src)]
       [(string? src) src]
       [else          (and src (~a src))])]))

(define (extract-kind msg)
  ;; Heuristic categorization — look for keywords in the message.
  ;; LLMs can branch on kind to decide which fix to try.
  (cond
    [(regexp-match? #rx"unknown type" msg)             "unknown-type"]
    [(regexp-match? #rx"unknown beagle form" msg)      "unknown-form"]
    [(regexp-match? #rx"unknown mode" msg)             "unknown-mode"]
    [(regexp-match? #rx"duplicate" msg)                "duplicate-definition"]
    [(regexp-match? #rx"not a defined instance" msg)   "undefined-instance"]
    [(regexp-match? #rx"not a declared entity" msg)    "undefined-entity"]
    [(regexp-match? #rx"expected ~a, got" msg)         "type-mismatch"]
    [(regexp-match? #rx"expected at least .* arg" msg) "arity-too-few"]
    [(regexp-match? #rx"expected .* arg.*, got" msg)   "arity-mismatch"]
    [(regexp-match? #rx"macro .* expected" msg)        "macro-arity"]
    [(regexp-match? #rx"bad field spec" msg)           "syntax"]
    [(regexp-match? #rx"bad binding spec" msg)         "syntax"]
    [(regexp-match? #rx"bad let bindings" msg)         "syntax"]
    [(regexp-match? #rx"bad parameter" msg)            "syntax"]
    [(regexp-match? #rx"unsafe.*string" msg)           "syntax"]
    [else                                              "compile-error"]))

(define (clean-message msg)
  ;; Strip Racket's standard prefixes ("beagle: beagle: ...") to a single
  ;; "beagle: ...". Also drop the trailing "in: ..." context (the full form
  ;; is often huge and unhelpful when the file/line are already given).
  (define stripped
    (regexp-replace* #rx"^beagle: beagle: " msg "beagle: "))
  (define no-in
    (regexp-replace #rx"\n *in: .*$" stripped ""))
  no-in)

;; Heuristic suggestions for common error patterns. Surfaced as a "hint"
;; field in JSON output and (optionally) appended to plain-text errors.
(define (hint-for msg)
  (cond
    [(regexp-match? #rx"unknown beagle form" msg)
     "see docs/cheatsheet.md for the form catalog"]
    [(regexp-match? #rx"unknown type" msg)
     "primitives: String Int Float Bool Keyword Symbol Nil Any; or [A B -> R], (Vec T), (U A B)"]
    [(regexp-match? #rx"bad field spec" msg)
     "field spec must be [name : Type]"]
    [(regexp-match? #rx"bad binding spec" msg)
     "binding spec must be [name value]"]
    [(regexp-match? #rx"bad let bindings" msg)
     "let bindings: [name value], [name : Type value], or [(name : Type) value]"]
    [(regexp-match? #rx"bad parameter" msg)
     "parameter must be: name, (name : Type), or inline name : Type"]
    [(regexp-match? #rx"expected ~a, got|expected (\\w+), got" msg)
     "either change the annotation or change the value type"]
    [(regexp-match? #rx"expected at least .* arg" msg)
     "call has too few arguments — check the function signature"]
    [(regexp-match? #rx"expected .* arg.*, got" msg)
     "call arity mismatch — check the function signature"]
    [(regexp-match? #rx"macro .* expected" msg)
     "macro arity mismatch — check the macro definition"]
    [(regexp-match? #rx"duplicate" msg)
     "remove the redundant definition"]
    [(regexp-match? #rx"unknown mode" msg)
     "valid modes: strict (default) or dynamic"]
    [(regexp-match? #rx"function type missing" msg)
     "function types use the form [Arg1 Arg2 -> Ret]"]
    [(regexp-match? #rx"unsafe.*string" msg)
     "(unsafe ...) takes a single string literal: (unsafe \"raw clojure\")"]
    [(regexp-match? #rx"violates constraint" msg)
     "literal value is outside the range declared in defscalar :where"]
    [else #f]))

(define (write-json-error msg-or-exn stx)
  (cond
    [(beagle-diagnostic? msg-or-exn)
     (define d (beagle-diagnostic-details msg-or-exn))
     (define msg (exn-message msg-or-exn))
     (define file (or (hash-ref d 'error-file #f) (path-or-source stx)))
     (define line (or (hash-ref d 'error-line #f) (and stx (syntax-line stx))))
     (define base
       (hasheq 'schemaVersion 1
               'tool "beagle"
               'kind (symbol->string (beagle-diagnostic-kind msg-or-exn))
               'message msg
               'file (or file 'null)
               'line (or line 'null)
               'col (or (and stx (syntax-column stx)) 'null)))
     (define enriched
       (for/fold ([h base]) ([(k v) (in-hash d)])
         (hash-set h (if (symbol? k) k (string->symbol k)) v)))
     (write-json enriched (current-error-port))
     (newline (current-error-port))
     (flush-output (current-error-port))]
    [else
     (define msg (if (exn? msg-or-exn) (exn-message msg-or-exn) msg-or-exn))
     (define clean (clean-message msg))
     (define hint (hint-for clean))
     (write-json
      (hasheq 'schemaVersion 1
              'tool "beagle"
              'kind (extract-kind clean)
              'message clean
              'hint   (or hint 'null)
              'file (path-or-source stx)
              'line (and stx (syntax-line stx))
              'col  (and stx (syntax-column stx)))
      (current-error-port))
     (newline (current-error-port))
     (flush-output (current-error-port))]))

;; For non-JSON mode: build the message with a hint appended if applicable.
(define (augment-with-hint msg)
  (define clean (clean-message msg))
  (define hint (hint-for clean))
  (cond
    [hint (string-append clean "\nhint: " hint)]
    [else clean]))

(provide json-error-mode? write-json-error augment-with-hint)
