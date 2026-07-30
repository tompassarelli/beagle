#lang racket/base

;; Beagle target-specific file extensions — a DERIVED VIEW of the canonical
;; target table in targets.rkt. Nothing here is hand-enumerated: add a target
;; there and every map below picks it up.
;;
;; Every beagle source file declares its target via its extension (`.bnix` →
;; `#lang beagle/nix`, and so on); `.bgl` is target-neutral and `.rkt` is
;; legacy/unvalidated. Extension/header mismatch is a hard compile error.
;; Render the current mapping with `bin/beagle langs --view extensions`.

(require racket/string
         racket/list
         "targets.rkt")

(define BEAGLE-EXTENSIONS
  (append (map target-source-ext TARGETS)
          (map car NEUTRAL-EXTENSIONS)))

(define (beagle-source-file? path-str)
  (ormap (lambda (ext) (string-suffix? path-str ext))
         BEAGLE-EXTENSIONS))

(define EXTENSION-TARGET-MAP
  (append (for/list ([t (in-list TARGETS)])
            (cons (target-source-ext t) (target-id t)))
          ;; target-neutral / legacy: recognized as beagle sources, but the
          ;; extension names no target, so no header check applies.
          (for/list ([p (in-list NEUTRAL-EXTENSIONS)])
            (cons (car p) #f))))

(define (expected-target-for-extension path-str)
  (define match
    (findf (lambda (pair) (string-suffix? path-str (car pair)))
           EXTENSION-TARGET-MAP))
  (and match (cdr match)))

;; Regex matching all beagle source extensions (for directory scanning).
(define BEAGLE-FILE-RX
  (regexp
   (string-append "\\.("
                  (string-join (for/list ([e (in-list BEAGLE-EXTENSIONS)])
                                 (regexp-quote (substring e 1)))
                               "|")
                  ")$")))

(provide BEAGLE-EXTENSIONS
         beagle-source-file?
         EXTENSION-TARGET-MAP
         expected-target-for-extension
         BEAGLE-FILE-RX)
