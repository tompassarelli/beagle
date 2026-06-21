#lang racket/base

;; Shared reader logic for all #lang beagle/* variants.
;;
;; Reader produces tagged data containers per role-locality §5:
;;   [a b]   → (#%brackets a b)   — vector data literal (inert)
;;   {:k v}  → (#%map :k v)       — map data literal (inert)
;;   #{a b}  → (#%set a b)        — set data literal (inert)
;; Parentheses produce structure forms — heads dispatch by operator.
;; Contents of data literals are still read with the same reader, so
;; nesting works: `{:k [1 2 3]}` reads as `(#%map :k (#%brackets 1 2 3))`.

(require racket/port)

(define (read-regex-pattern port)
  (let loop ([acc '()])
    (define c (read-char port))
    (cond
      [(eof-object? c) (error 'beagle "unterminated regex literal")]
      [(char=? c #\")
       (list->string (reverse acc))]
      [(char=? c #\\)
       (define next (read-char port))
       (cond
         [(eof-object? next) (error 'beagle "unterminated regex literal")]
         [else (loop (cons next (cons #\\ acc)))])]
      [else (loop (cons c acc))])))

;; Heredoc reader (`#<<TAG`) removed per audit row 5. Raw strings (`#r#"..."#`)
;; were also removed there ("never used in any user-facing corpus") but are
;; RESTORED below: eddy's JS/SQL emitters are a real user (49 blocks), and the
;; only alternative on the js target is escaped-string churn. Rust-style:
;; opener `#r` + N `#` + `"`, closer `"` + N `#`, body verbatim.
(define (read-raw-string port hashes)
  (define tail (make-string hashes #\#))
  (let loop ([acc '()])
    (define c (read-char port))
    (cond
      [(eof-object? c)
       (error 'beagle "unterminated raw string (missing closing \"~a)" tail)]
      [(char=? c #\")
       (define peeked (peek-string hashes 0 port))
       (if (and (string? peeked) (string=? peeked tail))
         (begin (read-string hashes port)
                (list->string (reverse acc)))
         (loop (cons c acc)))]
      [else (loop (cons c acc))])))

;; --- #(...) anonymous fn shorthand ------------------------------------------
;;
;; Clojure reader sugar: #(inc %) → (fn [%1] (inc %1)). Placeholders:
;;   %, %1..%N  — positional params (% is an alias for %1)
;;   %&         — rest param
;; The rewrite happens at read time (like Clojure); the resulting (fn ...)
;; datum flows through the ordinary parse/check/emit pipeline, so #() bodies
;; are fully type-checked. Nested #() is rejected (as in Clojure).

(define reading-fn-shorthand? (make-parameter #f))

(define (fn-shorthand->fn items)
  (define max-idx 0)
  (define rest-used? #f)
  (define (note! sym)
    (define s (symbol->string sym))
    (cond
      [(string=? s "%")  (set! max-idx (max max-idx 1))]
      [(string=? s "%&") (set! rest-used? #t)]
      [(regexp-match? #rx"^%[1-9][0-9]*$" s)
       (set! max-idx (max max-idx (string->number (substring s 1))))]))
  (define (walk d)
    (cond
      [(symbol? d) (note! d) (if (eq? d '%) '%1 d)]
      [(pair? d)   (cons (walk (car d)) (walk (cdr d)))]
      [else d]))
  (define body (walk items))
  (define params
    (append
     (for/list ([i (in-range 1 (+ max-idx 1))])
       (string->symbol (string-append "%" (number->string i))))
     (if rest-used? (list '& '%&) '())))
  (list 'fn (cons '#%brackets params) body))

;; Reader conditionals (#? and #?@) — Clojure-style read-time dispatch.
;;
;; Surface:
;;   #?(:clj X :cljs Y :nix Z :default W)        — read one form
;;   #?@(:clj [1 2] :cljs [3] :default [])       — read list of forms to splice
;;
;; Reading produces tagged data containers — the actual target selection
;; happens at PARSE time (see resolve-reader-conditionals in parse.rkt),
;; not at READ time. This is intentional: the reader doesn't know the
;; current target (it's set by `define-target` later in the program), so
;; it would be wrong to discard branches here.
;;
;;   #?(:clj X :nix Y) → (reader-conditional :clj X :nix Y)
;;   #?@(:clj X :nix Y) → (reader-conditional-splice :clj X :nix Y)
;;
;; The splice marker is recognised inside containing lists/brackets/maps
;; during the parse-time resolution pass: its chosen branch (which must
;; itself be a sequence) is spliced into the surrounding container.
;;
;; COEXISTENCE WITH `target-case`:
;;   reader-conditional — READ-time dispatch; non-matching branches are
;;     discarded before any AST is built. Use when the non-matching
;;     branches would not even parse (e.g. they call out to target-only
;;     stdlib functions, or use forms the other target rejects).
;;   target-case        — PARSE/RUNTIME-time form-level dispatch; all
;;     branches must parse and type-check, only one is emitted. Use when
;;     each branch is well-formed in every target and you just want a
;;     different value/expression per target.
;;
;; Both surfaces are intentionally kept. They aren't redundant — they
;; solve different problems (one elides at read time, the other selects
;; at emit time).

(define (read-reader-conditional-body port src line col pos splice?)
  (define opening (read-char port))
  (unless (and (char? opening) (char=? opening #\())
    (error 'beagle
           "#?~a: expected `(` to open reader-conditional body, got ~a"
           (if splice? "@" "")
           (if (char? opening) opening 'eof)))
  (define items (read-until-close port #\)))
  (define head (if splice? 'reader-conditional-splice 'reader-conditional))
  (define result (cons head items))
  (if src
    (datum->syntax #f result (vector src line col pos #f))
    result))

(define (hash-dispatch ch port src line col pos)
  (define next (peek-char port))
  (cond
    ;; #<<TAG heredoc reader: HARD-REMOVED per audit row 5. Heredocs were
    ;; never used in any user-facing .bgl/.bnix corpus; the `(s …)` / `(ms …)`
    ;; interpolation forms cover single- and multi-line Nix strings. The
    ;; `#%block-string` AST node remains for internal use (fmt-form
    ;; sometimes receives explicit `(#%block-string ...)` lists in tests).
    [(and (char? next) (char=? next #\<))
     (error 'beagle
            "#<<TAG heredoc reader is not supported. Use `(s \"…\" expr …)` (single line) or `(ms \"…\" …)` (multi-line) for Nix strings instead.")]
    ;; Reader conditional: #?(:tag form ...) or #?@(:tag form ...)
    [(and (char? next) (char=? next #\?))
     (read-char port)
     (define after-? (peek-char port))
     (cond
       [(and (char? after-?) (char=? after-? #\@))
        (read-char port)
        (read-reader-conditional-body port src line col pos #t)]
       [else
        (read-reader-conditional-body port src line col pos #f)])]
    [(and (char? next) (char=? next #\{))
     (read-char port)
     (define items (read-until-close port #\}))
     (define result (cons '#%set items))
     (if src
       (datum->syntax #f result (vector src line col pos #f))
       result)]
    ;; #(...) anonymous fn shorthand → (fn [%1 ...] body)
    [(and (char? next) (char=? next #\())
     (when (reading-fn-shorthand?)
       (error 'beagle
              "nested #(...) is not supported — use (fn [x] ...) for the inner function"))
     (read-char port)
     (define items
       (parameterize ([reading-fn-shorthand? #t])
         (read-until-close port #\))))
     (define result (fn-shorthand->fn items))
     (if src
       (datum->syntax #f result (vector src line col pos #f))
       result)]
    [(and (char? next) (char=? next #\"))
     (read-char port)
     (define pattern (read-regex-pattern port))
     (define result (list '#%regex pattern))
     (if src
       (datum->syntax #f result (vector src line col pos
                                        (+ 3 (string-length pattern))))
       result)]
    ;; #r#"..."# raw string (restored — see read-raw-string above).
    [(and (char? next) (char=? next #\r))
     (read-char port) ; consume r
     (define hashes
       (let loop ([n 0])
         (define p (peek-char port))
         (if (and (char? p) (char=? p #\#))
           (begin (read-char port) (loop (add1 n)))
           n)))
     (when (zero? hashes)
       (error 'beagle "raw string: write #r#\"...\"# (at least one #)"))
     (define oq (read-char port))
     (unless (and (char? oq) (char=? oq #\"))
       (error 'beagle "raw string: expected \" after #r~a" (make-string hashes #\#)))
     (define s (read-raw-string port hashes))
     (if src
       (datum->syntax #f s (vector src line col pos #f))
       s)]
    [else
     (define combined (input-port-append #f (open-input-string "#") port))
     (parameterize ([current-readtable (make-readtable #f)])
       (if src
         (read-syntax src combined)
         (read combined)))]))

;; `'` IS a quote-prefix reader macro (see quote-reader below): 'x reads
;; as (quote x) for any datum, matching Clojure. (An earlier design used
;; `(' OPERAND)` with no prefix sugar — see plan
;; 20260528220000-beagle_quote_operator_clarification — that design was
;; superseded; this comment was stale until 2026-06-12.)

;; (pipe-reader removed alongside the pipe family. `|>` / `|>>` are no
;; longer reserved threading symbols. `|` now reverts to Racket's default
;; quoted-identifier delimiter (`|foo bar|` → symbol `foo bar`). The
;; replacement for the pipe family is the Clojure threading macros
;; `->`, `->>`, `as->`, `cond->`, `cond->>`, `some->`, `some->>` —
;; implemented at parse time, see beagle-lib/private/parse.rkt.)

;; Read items until the given close character, using the beagle readtable
;; recursively so nested forms parse the same way.
(define (read-until-close port close-ch)
  (let loop ([acc '()])
    (skip-whitespace-and-comments port)
    (define c (peek-char port))
    (cond
      [(eof-object? c)
       (error 'beagle "unexpected EOF while reading data container (expected `~a`)" close-ch)]
      [(char=? c close-ch)
       (read-char port)
       (reverse acc)]
      [else
       (define item (read port))
       (loop (cons item acc))])))

(define (skip-whitespace-and-comments port)
  (let loop ()
    (define c (peek-char port))
    (cond
      [(eof-object? c) (void)]
      ;; `,` is Clojure whitespace. This manual loop doesn't consult the
      ;; readtable, so it must skip `,` explicitly — else a trailing comma
      ;; before a close (`[a b,]` / `{k v,}` / `#{x,}`) errors.
      [(or (char-whitespace? c) (char=? c #\,)) (read-char port) (loop)]
      [(char=? c #\;) ; line comment
       (let inner ()
         (define cc (read-char port))
         (unless (or (eof-object? cc) (char=? cc #\newline)) (inner)))
       (loop)]
      [else (void)])))

(define (bracket-reader ch port src line col pos)
  (define items (read-until-close port #\]))
  (define result (cons '#%brackets items))
  (if src
    (datum->syntax #f result (vector src line col pos #f))
    result))

(define (curly-reader ch port src line col pos)
  (define items (read-until-close port #\}))
  (define result (cons '#%map items))
  (if src
    (datum->syntax #f result (vector src line col pos #f))
    result))

;; Quote-prefix reader. `'X` reads as `(quote X)` for any next datum X:
;; `'(a b)`  → (quote (a b))           — inert list
;; `'[a b]`  → (quote (#%brackets a b)) — inert vector
;; `'{a b}`  → (quote (#%map a b))     — inert map
;; `'foo`    → (quote foo)             — inert symbol
;; This is the canonical inert marker — the old `(' a b)` quote-inside
;; list form is retired.
(define (quote-reader ch port src line col pos)
  (define inner
    (parameterize ([current-readtable beagle-readtable])
      (if src (read-syntax src port) (read port))))
  (define result (list 'quote inner))
  (if src
    (datum->syntax #f result (vector src line col pos #f))
    result))

;; Quasiquote-prefix reader. `` `X `` reads as `(quasiquote X)`.
;; Mirrors Racket's default quasiquote reader, but stays inside the
;; beagle readtable so brackets/curlies/etc. parse with beagle semantics.
;; Provides templating surface for proc/beagle macros (paired with
;; unquote-reader and unquote-splicing).
(define (quasiquote-reader ch port src line col pos)
  (define inner
    (parameterize ([current-readtable beagle-readtable])
      (if src (read-syntax src port) (read port))))
  (when (eof-object? inner)
    (error 'beagle "unexpected EOF after `` ` `` (quasiquote needs a following datum)"))
  (define result (list 'quasiquote inner))
  (if src
    (datum->syntax #f result (vector src line col pos #f))
    result))

;; Unquote-prefix reader. `~X` reads as `(unquote X)` (Clojure syntax-quote
;; unquote). If the next char after `~` is `@`, dispatches to unquote-splicing:
;; `~@X` → `(unquote-splicing X)`. Inside a quasiquoted template
;; (`` `(... ~x ...) ``) the unquote escapes back to the surrounding
;; evaluation context for the duration of one datum.
(define (unquote-reader ch port src line col pos)
  (define next (peek-char port))
  (cond
    [(and (char? next) (char=? next #\@))
     (read-char port)
     (define inner
       (parameterize ([current-readtable beagle-readtable])
         (if src (read-syntax src port) (read port))))
     (when (eof-object? inner)
       (error 'beagle "unexpected EOF after `~~@` (unquote-splicing needs a following datum)"))
     (define result (list 'unquote-splicing inner))
     (if src
       (datum->syntax #f result (vector src line col pos #f))
       result)]
    [else
     (define inner
       (parameterize ([current-readtable beagle-readtable])
         (if src (read-syntax src port) (read port))))
     (when (eof-object? inner)
       (error 'beagle "unexpected EOF after `~~` (unquote needs a following datum)"))
     (define result (list 'unquote inner))
     (if src
       (datum->syntax #f result (vector src line col pos #f))
       result)]))

;; Metadata-prefix reader. `^META FORM` reads as `(#%meta META FORM)`,
;; matching Clojure's `^` metadata reader. Both datums are read with the
;; beagle readtable so nested containers/keywords parse normally:
;;   ^:dynamic *x*        → (#%meta :dynamic *x*)
;;   ^{:dynamic true} *x* → (#%meta (#%map :dynamic true) *x*)
;; The parser consumes `#%meta` in def/defn (privacy, dynamic) and in
;; expression position (→ with-meta). Without this macro the `#%meta`
;; consumer arms were dead code (the producer was never wired).
(define (meta-reader ch port src line col pos)
  (define meta
    (parameterize ([current-readtable beagle-readtable])
      (if src (read-syntax src port) (read port))))
  (when (eof-object? meta)
    (error 'beagle "unexpected EOF after `^` (metadata needs a value and a target form)"))
  (define form
    (parameterize ([current-readtable beagle-readtable])
      (if src (read-syntax src port) (read port))))
  (when (eof-object? form)
    (error 'beagle "unexpected EOF after `^` metadata (needs a target form to attach to)"))
  (define result (list '#%meta meta form))
  (if src
    (datum->syntax #f result (vector src line col pos #f))
    result))

(define beagle-readtable
  (make-readtable #f
    #\^ 'terminating-macro meta-reader
    #\[ 'terminating-macro bracket-reader
    #\] 'terminating-macro
                            (lambda (ch port src line col pos)
                              (error 'beagle "unexpected `]`"))
    #\{ 'terminating-macro curly-reader
    #\} 'terminating-macro
                            (lambda (ch port src line col pos)
                              (error 'beagle "unexpected `}`"))
    #\' 'terminating-macro quote-reader
    #\` 'terminating-macro quasiquote-reader
    ;; `,` is WHITESPACE in Clojure (ignored), NOT unquote. Unquote is `~` /
    ;; `~@` (Clojure's syntax-quote unquote). Beagle had the CL-style `,`=unquote
    ;; — a SILENT surface divergence from Clojure that taxes every AI keystroke.
    ;; (`~"…"`/`~''…''` tilde-strings are nix-only — handled by the nix readtable,
    ;; so `~`=unquote here does not collide.)
    #\, #\space #f
    #\~ 'terminating-macro unquote-reader
    #\# 'non-terminating-macro hash-dispatch))

(define (beagle-read in)
  (parameterize ([current-readtable beagle-readtable])
    (read in)))

(define (beagle-read-syntax src in)
  (parameterize ([current-readtable beagle-readtable])
    (read-syntax src in)))

(provide beagle-read beagle-read-syntax beagle-readtable
         fn-shorthand->fn reading-fn-shorthand? unquote-reader)
