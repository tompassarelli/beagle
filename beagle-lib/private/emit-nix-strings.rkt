#lang racket/base

;; Nix string emission — escaping + interp + multiline + indented.
;; Calls back into emit-expr via current-emit-expr (set by emit-nix.rkt).

(require racket/string
         racket/format
         "parse.rkt")

(provide escape-nix
         current-emit-expr
         emit-nix-interp-string
         emit-nix-interp-string-inline
         emit-nix-multiline-string
         emit-nix-indented-string)

(define current-emit-expr (make-parameter #f))

(define (emit-expr* e depth)
  (define f (current-emit-expr))
  (unless f (error 'emit-nix-strings "current-emit-expr not set"))
  (f e depth))

(define (indent n) (make-string (* 2 n) #\space))

;; Single source of truth for Nix string escaping.
;; #:multiline? — produce ''…'' string semantics (escapes are different from "…")
;; #:keep-interp? — do NOT escape ${ (the caller is composing an interpolated string)
(define (escape-nix s
                    #:multiline? [multiline? #f]
                    #:keep-interp? [keep-interp? #f])
  (cond
    [multiline?
     (let* ([s (regexp-replace* #rx"''" s "'''")])
       (if keep-interp? s (regexp-replace* #rx"\\$\\{" s "''${")))]
    [else
     (let* ([s (regexp-replace* #rx"\\\\" s "\\\\\\\\")]
            [s (regexp-replace* #rx"\n" s "\\\\n")]
            [s (regexp-replace* #rx"\"" s "\\\\\"")])
       (if keep-interp? s (regexp-replace* #rx"\\$\\{" s "\\\\${")))]))

(define (emit-nix-interp-string-inline parts depth)
  (define chunks
    (for/list ([part (in-list parts)])
      (cond
        [(string? part) (escape-nix #:multiline? #t #:keep-interp? #t part)]
        [else (format "${~a}" (emit-expr* part depth))])))
  (string-join chunks ""))

(define (emit-nix-interp-string parts depth)
  (define chunks
    (for/list ([part (in-list parts)])
      (cond
        [(string? part) (escape-nix #:keep-interp? #t part)]
        [else (format "${~a}" (emit-expr* part depth))])))
  (format "\"~a\"" (string-join chunks "")))

(define (emit-nix-multiline-string lines depth)
  (define ind (indent (+ depth 1)))
  (define line-strs
    (for/list ([line (in-list lines)])
      (cond
        [(string? line) (string-append ind line)]
        [(nix-interpolated-string? line)
         (string-append ind (emit-nix-interp-string-inline
                             (nix-interpolated-string-parts line) depth))]
        [else (string-append ind "${" (emit-expr* line depth) "}")])))
  (string-append
   "''\n"
   (string-join line-strs "\n")
   "\n" (indent depth) "''"))

(define (emit-nix-indented-string text depth #:escape? [escape? #t])
  (define ind (indent (+ depth 1)))
  (define lines (regexp-split #rx"\n" text))
  (define (process-line l)
    (if (string=? l "") ""
        (string-append ind (if escape? (escape-nix #:multiline? #t l) l))))
  (string-append
   "''\n"
   (string-join (map process-line lines) "\n")
   "\n" (indent depth) "''"))
