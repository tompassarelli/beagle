#lang racket/base

;; Beagle target-specific file extensions — a DERIVED VIEW of the canonical
;; target table in targets.rkt. Nothing here is hand-enumerated: add a target
;; there and every map below picks it up.
;;
;; Every authored Beagle source file declares its profile via its extension
;; (`.bgl` → bare `#lang beagle`, `.bclj` → `#lang beagle/clj`, and so on).
;; The extension and declared target must agree.
;; Render the current mapping with `bin/beagle langs --view extensions`.

(require racket/string
         racket/list
         "targets.rkt")

(define BEAGLE-EXTENSIONS
  (append (list (core-profile-source-ext CORE-PROFILE))
          (map target-source-ext TARGETS)))

(define (beagle-source-file? path-str)
  (ormap (lambda (ext) (string-suffix? path-str ext))
         BEAGLE-EXTENSIONS))

(define (require-beagle-source-extension! path [who 'beagle])
  (define path-str (if (path? path) (path->string path) (format "~a" path)))
  (unless (beagle-source-file? path-str)
    (error who
           "unsupported source extension for ~a; expected one of ~a"
           path-str
           (string-join BEAGLE-EXTENSIONS ", "))))

(define EXTENSION-TARGET-MAP
  (append (list (cons (core-profile-source-ext CORE-PROFILE)
                      (core-profile-id CORE-PROFILE)))
          (for/list ([t (in-list TARGETS)])
            (cons (target-source-ext t) (target-id t)))))

(define (expected-target-for-extension path-str)
  (define match
    (findf (lambda (pair) (string-suffix? path-str (car pair)))
           EXTENSION-TARGET-MAP))
  (and match (cdr match)))

(define (extension-target-mismatch? path-str actual-target)
  (define expected-target (expected-target-for-extension path-str))
  (and expected-target
       (not (eq? expected-target actual-target))))

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
         require-beagle-source-extension!
         EXTENSION-TARGET-MAP
         expected-target-for-extension
         extension-target-mismatch?
         BEAGLE-FILE-RX)
