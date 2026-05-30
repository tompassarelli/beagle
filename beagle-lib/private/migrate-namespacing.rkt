#lang racket/base

;; beagle-migrate-namespacing — corpus migration for nix/ namespacing.
;;
;; Walks a directory of .bnix files, parses each with a position-preserving
;; readtable (a custom variant that uses read-syntax recursively where the
;; production beagle readtable uses plain read), then walks the resulting
;; syntax tree and rewrites bare head symbols that have a nix/-prefixed
;; canonical spelling:
;;
;;   (assert    COND BODY)            → (nix/assert    COND BODY)
;;   (with-cfg  PATH BODY)            → (nix/with-cfg  PATH BODY)
;;   (with      NS   BODY)            → (nix/with      NS   BODY)
;;     ONLY when the form has the Nix-scope shape:
;;       — exactly one body arg,
;;       — body arg is NOT a bracket whose first elem is a :keyword
;;         (that's the record-update shape and stays bare).
;;
;; Source positions on the head syntax-object give precise character
;; offsets; rewrites are applied end-to-start so earlier offsets remain
;; valid.
;;
;; Usage:
;;   racket -l beagle/private/migrate-namespacing -- [--dry-run]
;;          [--emit-patch] [DIR]
;;
;; Default DIR is the current directory.
;;
;; WHY A CUSTOM READTABLE: the production beagle readtable (in
;; beagle-lib/lang/reader-impl.rkt) reads bracket/curly children via
;; plain `read`, which discards srcloc on nested syntax objects. For
;; byte-precise position rewriting we need srcloc all the way down, so
;; we build a parallel readtable that uses `read-syntax` everywhere.
;; Semantically identical to the production reader for the surface
;; forms we care about; we only consume the file once for analysis,
;; so the duplication is contained.

(require racket/cmdline
         racket/file
         racket/list
         racket/string
         racket/path
         racket/port)

;; ---------------------------------------------------------------------------
;; Constants
;; ---------------------------------------------------------------------------

(define BRACKET-TAG '#%brackets)
(define MAP-TAG     '#%map)
(define SET-TAG     '#%set)
(define skip-dirs '(".git" "node_modules" ".direnv" "result" ".beagle-cache"))

;; ---------------------------------------------------------------------------
;; Position-preserving readtable
;; ---------------------------------------------------------------------------

(define (skip-ws-and-comments port)
  (let loop ()
    (define c (peek-char port))
    (cond
      [(eof-object? c) (void)]
      [(char-whitespace? c) (read-char port) (loop)]
      [(char=? c #\;)
       (let inner ()
         (define cc (read-char port))
         (unless (or (eof-object? cc) (char=? cc #\newline)) (inner)))
       (loop)]
      [else (void)])))

;; Read items (as syntax) up to `close-ch`, recursively using read-syntax.
(define (read-syntax-until-close port src close-ch)
  (let loop ([acc '()])
    (skip-ws-and-comments port)
    (define c (peek-char port))
    (cond
      [(eof-object? c)
       (error 'beagle-migrate "unexpected EOF; expected `~a`" close-ch)]
      [(char=? c close-ch)
       (read-char port)
       (reverse acc)]
      [else
       (define item (read-syntax src port))
       (loop (cons item acc))])))

;; Construct a stx with explicit srcloc from a tag + items + (line col pos).
(define (mk-stx src line col pos result)
  (datum->syntax #f result (vector src line col pos #f)))

(define (bracket-reader/stx ch port src line col pos)
  (define items (read-syntax-until-close port src #\]))
  (mk-stx src line col pos (cons (mk-stx src line col pos BRACKET-TAG) items)))

(define (curly-reader/stx ch port src line col pos)
  (define items (read-syntax-until-close port src #\}))
  (mk-stx src line col pos (cons (mk-stx src line col pos MAP-TAG) items)))

(define (close-error close-name)
  (lambda (ch port src line col pos)
    (error 'beagle-migrate "unexpected `~a`" close-name)))

(define (quote-reader/stx ch port src line col pos)
  ;; '<datum> → (quote <datum>) — but we DON'T need to recurse here for
  ;; our purposes; reading the inner via read-syntax keeps positions.
  (define inner (read-syntax src port))
  (mk-stx src line col pos
          (list (mk-stx src line col pos 'quote) inner)))

(define (pipe-reader/stx ch port src line col pos)
  ;; Identical semantics to the production pipe-reader: read characters
  ;; until a delimiter, return a symbol.
  (let loop ([acc (list #\|)])
    (define c (peek-char port))
    (cond
      [(or (eof-object? c)
           (char-whitespace? c)
           (memq c '(#\( #\) #\[ #\] #\{ #\} #\" #\; #\, #\` #\')))
       (define sym (string->symbol (list->string (reverse acc))))
       (mk-stx src line col pos sym)]
      [else
       (read-char port)
       (loop (cons c acc))])))

;; Hash dispatch — we only care about #{...} (set) and #r"..." raw strings
;; and #<<TAG heredocs. For #r" we read the rest as a single string and
;; produce a stx that won't trip our walker (it's just a string literal).
;; For #{...} we produce (#%set ...) with positions. Anything else, fall
;; back to default Racket dispatch by routing the `#` through a new port.
(define (hash-reader/stx ch port src line col pos)
  (define next (peek-char port))
  (cond
    [(and (char? next) (char=? next #\{))
     (read-char port)
     (define items (read-syntax-until-close port src #\}))
     (mk-stx src line col pos (cons (mk-stx src line col pos SET-TAG) items))]
    [(and (char? next) (char=? next #\r))
     ;; #r"…" raw string — slurp it. Body has optional # delimiters: #r#"..."#
     ;; This is rare in nixos-config but we implement a permissive scanner.
     (read-char port) ; consume r
     (define hash-count
       (let loop ([n 0])
         (define c (peek-char port))
         (if (and (char? c) (char=? c #\#)) (begin (read-char port) (loop (add1 n))) n)))
     (define open (read-char port))
     (unless (and (char? open) (char=? open #\"))
       (error 'beagle-migrate "expected '\"' after #r"))
     (define content
       (let loop ([acc '()])
         (define c (read-char port))
         (cond
           [(eof-object? c) (error 'beagle-migrate "unterminated #r\"...\"")]
           [(char=? c #\")
            (define hashes
              (let hloop ([n 0])
                (if (and (< n hash-count)
                         (char? (peek-char port))
                         (char=? (peek-char port) #\#))
                    (begin (read-char port) (hloop (add1 n)))
                    n)))
            (if (= hashes hash-count)
                (list->string (reverse acc))
                (loop (foldl cons acc
                             (cons #\" (build-list hashes (lambda (_) #\#))))))]
           [else (loop (cons c acc))])))
     (mk-stx src line col pos content)]
    [(and (char? next) (char=? next #\<))
     ;; #<<TAG ... heredoc. Slurp the body as raw text — we don't need
     ;; to interpret it because we won't be rewriting inside.
     (read-char port) ; consume <
     (define next2 (peek-char port))
     (unless (and (char? next2) (char=? next2 #\<))
       (error 'beagle-migrate "expected `<` after `#<`"))
     (read-char port)
     (define tag
       (let loop ([acc '()])
         (define c (read-char port))
         (cond
           [(eof-object? c) (error 'beagle-migrate "unterminated #<<TAG")]
           [(char=? c #\newline) (list->string (reverse acc))]
           [(char-whitespace? c) (loop acc)]
           [else (loop (cons c acc))])))
     (define body
       (let loop ([lines '()] [cur '()])
         (define c (read-char port))
         (cond
           [(eof-object? c) (error 'beagle-migrate "unterminated heredoc ~a" tag)]
           [(char=? c #\newline)
            (define line (list->string (reverse cur)))
            (define stripped (string-trim line))
            (if (string=? stripped tag)
                (reverse lines)
                (loop (cons line lines) '()))]
           [else (loop lines (cons c cur))])))
     (mk-stx src line col pos
             (list (mk-stx src line col pos '#%block-string)
                   (mk-stx src line col pos tag)
                   (mk-stx src line col pos (string-join body "\n"))))]
    [else
     ;; Fallback: route through default reader.
     (define combined (input-port-append #f (open-input-string "#") port))
     (parameterize ([current-readtable (make-readtable #f)])
       (read-syntax src combined))]))

;; ~"..." and ~''...'' — for our migration purposes, we don't need to
;; analyse the inside. Read the whole thing as an opaque blob (a string)
;; so the walker sees no `with` heads inside.
(define (tilde-reader/stx ch port src line col pos)
  (define next (peek-char port))
  (cond
    [(and (char? next) (char=? next #\"))
     ;; ~"..." — read until matching ", handling escapes. Sub-${expr}
     ;; bodies are NOT parsed; they're opaque text for our purposes.
     (read-char port)
     (define content
       (let loop ([acc '()])
         (define c (read-char port))
         (cond
           [(eof-object? c) (error 'beagle-migrate "unterminated ~~\"...\"")]
           [(char=? c #\")
            (list->string (reverse acc))]
           [(char=? c #\\)
            (define esc (read-char port))
            (cond
              [(eof-object? esc) (error 'beagle-migrate "unterminated ~~\"...\"")]
              [else (loop (cons esc (cons c acc)))])]
           [else (loop (cons c acc))])))
     (mk-stx src line col pos (list (mk-stx src line col pos 's) content))]
    [(and (char? next) (char=? next #\'))
     (read-char port)
     (define n2 (peek-char port))
     (unless (and (char? n2) (char=? n2 #\'))
       (error 'beagle-migrate "expected `''` after `~~'`"))
     (read-char port)
     ;; ~''...'' — slurp until ''. Sub-${...} bodies are opaque.
     ;; The actual closing rule per beagle-nix-readtable is complex; we
     ;; mirror just enough: ''' → '', ''$ → $, ''\X → \X, then '' = close.
     (define raw
       (let loop ([acc '()])
         (define c (read-char port))
         (cond
           [(eof-object? c) (error 'beagle-migrate "unterminated ~~''...''")]
           [(char=? c #\')
            (define c2 (peek-char port))
            (cond
              [(and (char? c2) (char=? c2 #\'))
               (define c3 (peek-char port 1))
               (cond
                 [(and (char? c3) (char=? c3 #\'))
                  (read-char port) (read-char port)
                  (loop (cons #\' (cons #\' acc)))]
                 [(and (char? c3) (char=? c3 #\$))
                  (read-char port) (read-char port)
                  (loop (cons #\$ acc))]
                 [(and (char? c3) (char=? c3 #\\))
                  (read-char port) (read-char port) (read-char port)
                  (loop acc)]
                 [else
                  (read-char port)
                  (list->string (reverse acc))])]
              [else (loop (cons c acc))])]
           [else (loop (cons c acc))])))
     (mk-stx src line col pos (list (mk-stx src line col pos 'ms) raw))]
    [else
     ;; ~foo — symbol prefix, gather until delimiter.
     (let loop ([acc (list ch)])
       (define c (peek-char port))
       (cond
         [(or (eof-object? c)
              (memv c '(#\space #\newline #\tab #\) #\] #\} #\( #\[ #\{ #\;)))
          (mk-stx src line col pos
                  (string->symbol (list->string (reverse acc))))]
         [else (read-char port) (loop (cons c acc))]))]))

(define migrate-readtable
  (make-readtable #f
    #\[ 'terminating-macro bracket-reader/stx
    #\] 'terminating-macro (close-error #\])
    #\{ 'terminating-macro curly-reader/stx
    #\} 'terminating-macro (close-error #\})
    #\| 'non-terminating-macro pipe-reader/stx
    #\' 'terminating-macro quote-reader/stx
    #\# 'non-terminating-macro hash-reader/stx
    #\~ 'non-terminating-macro tilde-reader/stx))

;; ---------------------------------------------------------------------------
;; Rename rules
;; ---------------------------------------------------------------------------

(define (keyword-sym? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 1)
              (char=? (string-ref s 0) #\:)))))

(define (with-nix-scope? body-datums)
  ;; body-datums is everything AFTER 'with in `(with TARGET UPDATES…)`,
  ;; so it has shape `(TARGET UPDATE…)`. Nix-scope form is `(with NS BODY)`
  ;; — exactly one UPDATE whose top-level form is NOT a [:keyword value …]
  ;; update bracket. Mirrors disambiguation in parse.rkt:1363-1369 where
  ;; `target-expr` is bound and `updates` = the rest.
  (and (>= (length body-datums) 2)
       (let ([updates (cdr body-datums)])
         (and (= (length updates) 1)
              (let ([d (car updates)])
                (not (and (pair? d)
                          (eq? (car d) BRACKET-TAG)
                          (>= (length (cdr d)) 2)
                          (let ([first (cadr d)])
                            (and (symbol? first)
                                 (keyword-sym? first))))))))))

(define (arity-2? body-datums) (= (length body-datums) 2))

(define RENAMES
  ;; (old-head new-head shape-predicate)
  ;; assert and with-cfg both take exactly 2 args (COND BODY / PATH BODY).
  ;; Requiring arity-2 avoids accidentally rewriting any Clojure-style
  ;; `(assert X)` or `(assert)` that some macro might emit.
  (list (list 'assert   'nix/assert   arity-2?)
        (list 'with-cfg 'nix/with-cfg arity-2?)
        (list 'with     'nix/with     with-nix-scope?)))

;; ---------------------------------------------------------------------------
;; File discovery
;; ---------------------------------------------------------------------------

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
;; Reading .bnix with the migrate readtable, preserving source positions
;; ---------------------------------------------------------------------------

(define (read-bnix-syntax path)
  (with-input-from-file path
    (lambda ()
      (define ip (current-input-port))
      (port-count-lines! ip)
      ;; Peek the first line. If it's #lang ..., consume it; otherwise rewind.
      (define first-line (read-line))
      (unless (and (string? first-line)
                   (regexp-match? #rx"^#lang " first-line))
        (file-position ip 0)
        (port-count-lines! ip))
      (parameterize ([read-square-bracket-with-tag BRACKET-TAG]
                     [current-readtable migrate-readtable])
        (let loop ([acc '()])
          (define stx (read-syntax path ip))
          (if (eof-object? stx)
              (reverse acc)
              (loop (cons stx acc))))))))

;; ---------------------------------------------------------------------------
;; AST walk: collect rewrites
;; ---------------------------------------------------------------------------

(struct rewrite (pos span old-text new-text line col context) #:transparent)

(define (collect-rewrites stx)
  (define acc '())
  (define (walk! s)
    (define d (and (syntax? s) (syntax-e s)))
    (cond
      [(pair? d)
       (define head-stx (car d))
       (when (syntax? head-stx)
         (define head-datum (syntax-e head-stx))
         (when (symbol? head-datum)
           (for ([rule (in-list RENAMES)])
             (when (eq? head-datum (car rule))
               (define new-head (cadr rule))
               (define pred (caddr rule))
               ;; Body datums = cdr of full datum.
               (define body-datums (cdr (syntax->datum s)))
               (when (pred body-datums)
                 (define pos  (syntax-position head-stx))
                 (define span (syntax-span head-stx))
                 (define line (or (syntax-line head-stx) 0))
                 (define col  (or (syntax-column head-stx) 0))
                 (when (and pos span
                            (= span (string-length (symbol->string head-datum))))
                   (set! acc
                         (cons (rewrite pos span
                                        (symbol->string head-datum)
                                        (symbol->string new-head)
                                        line col
                                        (format "~s" (syntax->datum s)))
                               acc))))))))
       (walk-pairs! d)]
      [(vector? d) (for ([e (in-vector d)]) (walk! e))]
      [else (void)]))
  (define (walk-pairs! d)
    (cond
      [(syntax? d) (walk! d)]
      [(pair? d) (walk! (car d)) (walk-pairs! (cdr d))]
      [else (void)]))
  (walk! stx)
  (reverse acc))

;; ---------------------------------------------------------------------------
;; Patch application
;; ---------------------------------------------------------------------------

(define (apply-rewrites content rewrites)
  (define sorted (sort rewrites > #:key rewrite-pos))
  (for/fold ([s content])
            ([r (in-list sorted)])
    (define start (sub1 (rewrite-pos r)))  ; 1-based → 0-based
    (define end (+ start (rewrite-span r)))
    (define actual (substring s start end))
    (unless (string=? actual (rewrite-old-text r))
      (error 'migrate-namespacing
             "position mismatch at line ~a col ~a: expected ~s, got ~s"
             (rewrite-line r) (rewrite-col r)
             (rewrite-old-text r) actual))
    (string-append (substring s 0 start)
                   (rewrite-new-text r)
                   (substring s end))))

;; ---------------------------------------------------------------------------
;; Reporting
;; ---------------------------------------------------------------------------

(define (truncate-str s n)
  (if (> (string-length s) n)
      (string-append (substring s 0 (- n 3)) "...")
      s))

(define (print-summary file-rewrites total-files)
  (define changed (filter (lambda (p) (pair? (cdr p))) file-rewrites))
  (define total
    (apply + (map (lambda (p) (length (cdr p))) file-rewrites)))
  (define by-head (make-hash))
  (for ([p (in-list file-rewrites)])
    (for ([r (in-list (cdr p))])
      (hash-update! by-head (rewrite-old-text r) add1 0)))
  (printf "\n=== summary ===\n")
  (printf "scanned: ~a .bnix files\n" total-files)
  (printf "files with rewrites: ~a\n" (length changed))
  (printf "total rewrites: ~a\n" total)
  (for ([(k v) (in-hash by-head)])
    (printf "  ~a -> nix/~a : ~a\n" k k v)))

(define (print-sample file-rewrites n)
  (printf "\n=== sample rewrites (first ~a) ===\n" n)
  (define all
    (for*/list ([p (in-list file-rewrites)]
                [r (in-list (cdr p))])
      (cons (car p) r)))
  (for ([item (in-list (if (<= (length all) n) all (take all n)))])
    (define path (car item))
    (define r (cdr item))
    (printf "  ~a:~a:~a  ~a -> ~a    [~a]\n"
            path (rewrite-line r) (rewrite-col r)
            (rewrite-old-text r) (rewrite-new-text r)
            (truncate-str (rewrite-context r) 80))))

(define (print-patch file-rewrites)
  (for ([p (in-list file-rewrites)])
    (define path (car p))
    (define rs (cdr p))
    (unless (null? rs)
      (define old-content (file->string path))
      (define new-content (apply-rewrites old-content rs))
      (define old-lines (string-split old-content "\n" #:trim? #f))
      (define new-lines (string-split new-content "\n" #:trim? #f))
      (printf "--- a/~a\n" path)
      (printf "+++ b/~a\n" path)
      (for ([old (in-list old-lines)]
            [new (in-list new-lines)]
            [i (in-naturals 1)])
        (unless (string=? old new)
          (printf "@@ -~a,1 +~a,1 @@\n" i i)
          (printf "-~a\n" old)
          (printf "+~a\n" new))))))

;; ---------------------------------------------------------------------------
;; Main
;; ---------------------------------------------------------------------------

(module+ main
  (define dry-run? (make-parameter #f))
  (define emit-patch? (make-parameter #f))

  (define positional
    (command-line
     #:program "beagle-migrate-namespacing"
     #:once-each
     [("--dry-run")    "Report rewrites without writing"      (dry-run? #t)]
     [("--emit-patch") "Print unified diff (implies dry-run)" (emit-patch? #t) (dry-run? #t)]
     #:args dirs
     dirs))

  (define root
    (cond
      [(null? positional) (path->string (current-directory))]
      [else (car positional)]))

  (unless (directory-exists? root)
    (eprintf "beagle-migrate-namespacing: not a directory: ~a\n" root)
    (exit 2))

  (define files (sort (find-bnix-files root) string<?))
  (when (null? files)
    (eprintf "beagle-migrate-namespacing: no .bnix files found under ~a\n" root)
    (exit 1))

  (define file-rewrites
    (for/list ([f (in-list files)])
      (cons f
            (with-handlers
              ([exn:fail?
                (lambda (e)
                  (eprintf "beagle-migrate-namespacing: skip ~a -- ~a\n"
                           f (exn-message e))
                  '())])
              (define stxs (read-bnix-syntax f))
              (apply append (map collect-rewrites stxs))))))

  (cond
    [(emit-patch?)
     (print-patch file-rewrites)
     (print-summary file-rewrites (length files))]
    [(dry-run?)
     (print-sample file-rewrites 20)
     (print-summary file-rewrites (length files))]
    [else
     (for ([p (in-list file-rewrites)])
       (define path (car p))
       (define rs (cdr p))
       (unless (null? rs)
         (define old-content (file->string path))
         (define new-content (apply-rewrites old-content rs))
         (display-to-file new-content path #:exists 'replace)))
     (print-summary file-rewrites (length files))
     (printf "(applied)\n")]))
