#lang racket/base

;; Beagle target-specific file extensions.
;;
;; Every beagle source file declares its target via extension:
;;   .bclj  → #lang beagle/clj
;;   .bcljs → #lang beagle/cljs
;;   .bjs   → #lang beagle/js
;;   .bnix  → #lang beagle/nix
;;   .bsql  → #lang beagle/sql (schema-typing live; emitter dormant)
;;   .bgl   → target-neutral
;;   .rkt   → legacy (no validation)
;;
;; Extension/header mismatch is a hard compile error.

(require racket/string)

(define BEAGLE-EXTENSIONS
  '(".bclj" ".bcljs" ".bjs" ".bnix" ".bsql" ".bodin" ".bgl" ".rkt"))

(define (beagle-source-file? path-str)
  (ormap (lambda (ext) (string-suffix? path-str ext))
         BEAGLE-EXTENSIONS))

(define EXTENSION-TARGET-MAP
  '((".bclj"  . clj)
    (".bcljs" . cljs)
    (".bjs"   . js)
    (".bnix"  . nix)
    (".bsql"  . sql)
    (".bodin" . odin)
    (".bgl"   . #f)     ; target-neutral; default-to-scheme deferred until Cyclone runtime
    (".rkt"   . #f)))   ; legacy — no validation

(define (expected-target-for-extension path-str)
  (define match
    (findf (lambda (pair) (string-suffix? path-str (car pair)))
           EXTENSION-TARGET-MAP))
  (and match (cdr match)))

;; Regex matching all beagle source extensions (for directory scanning).
(define BEAGLE-FILE-RX #rx"\\.(bclj|bcljs|bjs|bnix|bsql|bodin|bgl|rkt)$")

(provide BEAGLE-EXTENSIONS
         beagle-source-file?
         EXTENSION-TARGET-MAP
         expected-target-for-extension
         BEAGLE-FILE-RX)
