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

;; Reader-internal marker heads (mirror #%brackets/#%map/#%set): un-spoofable in
;; user source, so no collision with a real identifier. The render inversions in
;; claims-roundtrip.rkt key off the SAME interned symbols.
(define %symbolic-val (string->symbol "#%symbolic-val"))  ; ##Inf / ##-Inf / ##NaN
(define %discard      (string->symbol "#%discard"))       ; #_form
(define %js           (string->symbol "#%js"))            ; #js form

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
    ;; ## symbolic values: ##Inf / ##-Inf / ##NaN (Clojure symbolic-value reader).
    ;; Keep the symbolic NAME, not a +inf.0/+nan.0 double — a plain double datum
    ;; could not re-emit the `##Name` source on render.
    [(and (char? next) (char=? next #\#))
     (read-char port)  ; consume the second #
     (define name
       (parameterize ([current-readtable beagle-readtable])
         (if src (read-syntax src port) (read port))))
     (define nsym (if (syntax? name) (syntax-e name) name))
     (unless (memq nsym '(Inf -Inf NaN))
       (error 'beagle
              "## symbolic value: expected ##Inf, ##-Inf, or ##NaN, got ##~a" nsym))
     (define result (list %symbolic-val nsym))
     (if src
       (datum->syntax #f result (vector src line col pos #f))
       result)]
    ;; #_ discard reader macro. Clojure DROPS the next form; beagle KEEPS it as a
    ;; (#%discard form) datum — text is a view, no silent loss — inverted back to
    ;; `#_form` on render.
    [(and (char? next) (char=? next #\_))
     (read-char port)  ; consume _
     (define form
       (parameterize ([current-readtable beagle-readtable])
         (if src (read-syntax src port) (read port))))
     (when (eof-object? form)
       (error 'beagle "#_ discard: expected a form to follow"))
     (define result (list %discard form))
     (if src
       (datum->syntax #f result (vector src line col pos #f))
       result)]
    ;; #js tagged literal (ClojureScript JS object/array). Kept as (#%js form),
    ;; inverted to `#js form` on render. Guard the token so `#j…`/`#justfoo` fall
    ;; through to the default reader — fire only on `#js` + delimiter/open/EOF.
    [(and (char? next) (char=? next #\j)
          (let ([la (peek-string 3 0 port)])
            (and (string? la) (>= (string-length la) 2)
                 (string=? (substring la 0 2) "js")
                 (or (= (string-length la) 2)
                     (let ([c (string-ref la 2)])
                       (or (char-whitespace? c) (memv c '(#\[ #\{ #\( #\,))))))))
     (read-string 2 port)  ; consume js
     (define form
       (parameterize ([current-readtable beagle-readtable])
         (if src (read-syntax src port) (read port))))
     (when (eof-object? form)
       (error 'beagle "#js: expected a form (vector/map) to follow"))
     (define result (list %js form))
     (if src
       (datum->syntax #f result (vector src line col pos #f))
       result)]
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
;;
;; When SRC is non-#f, items are read with read-syntax so container CONTENTS
;; keep their true source positions. This matters for `[…]`: the type-view
;; delaborator injects `:- T` at a let-binding value's syntax-position, which is
;; lost if the contents are read as bare data (the injection then lands at the
;; `let` head). parse.rkt's old readtable got real `[…]` content srclocs for
;; free via Racket's native read-square-bracket-with-tag; this explicit reader
;; must match it so the two reader paths are truly identical (#19). datum->syntax
;; in the container readers preserves these inner syntax srclocs.
(define (read-until-close port close-ch [src #f])
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
       (define item (if src (read-syntax src port) (read port)))
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
  ;; Pass src so contents carry real srclocs (see read-until-close) — the
  ;; type-view delaborator needs let-binding value positions inside `[…]`.
  (define items (read-until-close port #\] src))
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

;; Clojure char literal reader.
;;
;; Clojure uses `\X` (backslash prefix) for character literals:
;;   \z          → char 'z'   (single printable char)
;;   \tab        → tab char   (named: tab / space / newline / return / formfeed / backspace)
;;   \uNNNN      → unicode char (4 hex digits)
;;
;; Racket's default readtable treats `\` as an identifier-escape that strips
;; the backslash and keeps the following char as part of an identifier, so
;; `\tab` → symbol `tab` and `\z` → symbol `z`. This is silent and wrong
;; for Beagle/Clojure sources. Registering `\` as a terminating-macro fixes it.
;;
;; Returns a Racket char? value; the parse/emit layers handle it from there.
(define (char-lit-reader ch port src line col pos)
  (define next (peek-char port))
  (cond
    [(eof-object? next)
     (error 'beagle "unexpected EOF after `\\` (char literal needs a character)")]
    ;; \uNNNN — four-hex-digit unicode escape
    [(char=? next #\u)
     (define lookahead (peek-string 5 0 port))  ; "uNNNN"
     (if (and (string? lookahead)
              (= (string-length lookahead) 5)
              ;; #px, not #rx: POSIX regexp syntax treats {4} literally, so the
              ;; hex check never matched and every \uNNNN fell through to the
              ;; single-char branch — reading as TWO datums (\u then a number).
              (regexp-match? #px"^u[0-9a-fA-F]{4}$" lookahead))
       (begin
         (read-char port) ; u
         (let* ([hex    (read-string 4 port)]
                [result (integer->char (string->number hex 16))])
           (if src (datum->syntax #f result (vector src line col pos 6)) result)))
       ;; not a unicode escape — `u` is the single char
       (begin (read-char port)
              (if src (datum->syntax #f next (vector src line col pos 2)) next)))]
    ;; alphabetic: may be a named char (tab, space, newline, …) or single letter
    [(char-alphabetic? next)
     (define name
       (let loop ([acc '()])
         (define c (peek-char port))
         (if (and (char? c) (char-alphabetic? c))
           (begin (read-char port) (loop (cons c acc)))
           (list->string (reverse acc)))))
     (define result
       (if (= (string-length name) 1)
         ;; single letter (\z, \a, etc.)
         (string-ref name 0)
         ;; named char
         (case (string->symbol name)
           [(space)     #\space]
           [(tab)       #\tab]
           [(newline)   #\newline]
           [(return)    #\return]
           [(formfeed)  #\page]
           [(backspace) #\backspace]
           [else
            (error 'beagle
                   "unknown character name: \\~a\n  known names: \\tab \\space \\newline \\return \\formfeed \\backspace\n  for single char: write \\~a"
                   name (substring name 0 1))])))
     (if src
       (datum->syntax #f result (vector src line col pos (+ 1 (string-length name))))
       result)]
    ;; single non-alphabetic char: \0, \!, \[, \newline (literal), etc.
    [else
     (read-char port)
     (if src (datum->syntax #f next (vector src line col pos 2)) next)]))

;; `.` bare-dot reader (Clojure interop special-form head). Racket's default
;; reader reserves a lone `.` as the improper-list (dotted-pair) separator and
;; errors on `(. Target member)` with "read: illegal use of `.`" (EXP-025 G9,
;; malli's java.time interop: `(. LocalTime -MIN)`, `(. obj method arg)`). In
;; Clojure `.` is an ordinary symbol — the interop special form's head — and
;; beagle is Clojure, so there are no dotted pairs to protect: `.` reads as the
;; symbol `.`.
;;
;; Registered NON-terminating (like `#` and `'`), so it fires ONLY at token
;; start — mid-token dots (`foo.bar`, `1.5`) stay untouched constituents. At
;; token start we accumulate the whole token against beagle's delimiter set,
;; matching the self-hosted reader's read-symbol-text (structural parity):
;;   `.`        (followed by delimiter/EOF) → symbol `.`      (the bare special form)
;;   `.method`                              → symbol `.method` (unchanged; method-call sugar)
;;   `.-field`                              → symbol `.-field` (unchanged; field-access sugar)
;; Delimiters mirror the readtable's terminating chars + whitespace; `'` and `#`
;; are NON-terminating constituents (so a primed/`#`-bearing tail stays one
;; symbol, per the G6 primed-symbol rule) and are therefore NOT delimiters.
(define (dot-token-delimiter? c)
  (or (eof-object? c)
      (char-whitespace? c)
      (memv c '(#\, #\( #\) #\[ #\] #\{ #\} #\" #\; #\~ #\^ #\` #\\))))

(define (dot-reader ch port src line col pos)
  ;; ch (the leading `.`) is already consumed by the readtable dispatch.
  (define sym
    (let loop ([acc (list #\.)])
      (define c (peek-char port))
      (if (dot-token-delimiter? c)
        (string->symbol (list->string (reverse acc)))
        (begin (read-char port) (loop (cons c acc))))))
  (if src
    (datum->syntax #f sym (vector src line col pos (string-length (symbol->string sym))))
    sym))

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
    ;; `'` is NON-terminating: it fires the quote-reader only when it STARTS a
    ;; token (`'x` → (quote x)), and is an ordinary symbol constituent mid-token
    ;; (`v'`, `x''`, `f'x` → one symbol). This matches Clojure, where `'` is a
    ;; legal symbol character except in leading position. A `terminating-macro`
    ;; here split primed bindings like `v'` into symbol `v` + a spurious quote of
    ;; the next form (EXP-025 G6). Mirrors `#` below (also non-terminating). The
    ;; self-hosted reader already agrees: reader.bclj's `delimiter?` excludes `'`.
    #\' 'non-terminating-macro quote-reader
    #\` 'terminating-macro quasiquote-reader
    ;; `,` is WHITESPACE in Clojure (ignored), NOT unquote. Unquote is `~` /
    ;; `~@` (Clojure's syntax-quote unquote). Beagle had the CL-style `,`=unquote
    ;; — a SILENT surface divergence from Clojure that taxes every AI keystroke.
    ;; (`~"…"`/`~''…''` tilde-strings are nix-only — handled by the nix readtable,
    ;; so `~`=unquote here does not collide.)
    #\, #\space #f
    #\~ 'terminating-macro unquote-reader
    ;; `\` is Clojure's char-literal prefix (\z, \tab, \space, \uNNNN).
    ;; Racket's default readtable treats `\` as an identifier-escape (strips it,
    ;; so `\tab` → symbol `tab`). Registering as terminating-macro intercepts it
    ;; before any identifier-reading starts.
    #\\ 'terminating-macro char-lit-reader
    ;; `.` is NON-terminating (like `#`): fires only when it STARTS a token
    ;; (`(. Target member)` → symbol `.`), and is an ordinary constituent
    ;; mid-token (`foo.bar`, `1.5`). Overrides Racket's default dotted-pair
    ;; reading of a lone `.` (EXP-025 G9). Self-hosted reader already agrees
    ;; (reader.bclj's `delimiter?` excludes `.`, so it reads `.` as a symbol).
    #\. 'non-terminating-macro dot-reader
    #\# 'non-terminating-macro hash-dispatch))

(define (beagle-read in)
  (parameterize ([current-readtable beagle-readtable])
    (read in)))

(define (beagle-read-syntax src in)
  (parameterize ([current-readtable beagle-readtable])
    (read-syntax src in)))

(provide beagle-read beagle-read-syntax beagle-readtable
         fn-shorthand->fn reading-fn-shorthand? unquote-reader)
