#lang racket/base

;; Beagle target-specific file extensions — a DERIVED VIEW of the canonical
;; target table in targets.rkt. Nothing here is hand-enumerated: add a target
;; there and every map below picks it up.
;;
;; Every authored Beagle source file declares its profile via its extension
;; (`.bgl` → bare `#lang beagle`, `.bclj` → `#lang beagle/clj`, and so on).
;; Headerless `.bgl` remains a temporary compatibility seam for the compiler's
;; hosted Native Core implementation modules; an explicit mismatched header is
;; always a hard compile error.
;; Render the current mapping with `bin/beagle langs --view extensions`.

(require racket/string
         racket/list
         "targets.rkt")

(define BEAGLE-EXTENSIONS
  (append (list (core-profile-source-ext CORE-PROFILE))
          (map target-source-ext TARGETS)
          (map car NEUTRAL-EXTENSIONS)))

(define (beagle-source-file? path-str)
  (ormap (lambda (ext) (string-suffix? path-str ext))
         BEAGLE-EXTENSIONS))

(define EXTENSION-TARGET-MAP
  (append (list (cons (core-profile-source-ext CORE-PROFILE)
                      (core-profile-id CORE-PROFILE)))
          (for/list ([t (in-list TARGETS)])
            (cons (target-source-ext t) (target-id t)))
          ;; Legacy sources are recognized, but the extension names no profile,
          ;; so no header check applies.
          (for/list ([p (in-list NEUTRAL-EXTENSIONS)])
            (cons (car p) #f))))

(define (expected-target-for-extension path-str)
  (define match
    (findf (lambda (pair) (string-suffix? path-str (car pair)))
           EXTENSION-TARGET-MAP))
  (and match (cdr match)))

(define (source-has-lang-header? path-str)
  (and (file-exists? path-str)
       (call-with-input-file path-str
         (lambda (in)
           (define line (read-line in 'any))
           (and (string? line) (regexp-match? #rx"^#lang " line))))))

(define (extension-target-mismatch? path-str actual-target)
  (define expected-target (expected-target-for-extension path-str))
  (and expected-target
       (not (eq? expected-target actual-target))
       (not (and (eq? expected-target (core-profile-id CORE-PROFILE))
                 (not (source-has-lang-header? path-str))))))

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
         extension-target-mismatch?
         BEAGLE-FILE-RX)
