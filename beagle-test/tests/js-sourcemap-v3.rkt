#lang racket/base

;; Direct JavaScript V3 source-map contract.  This file is deliberately
;; standalone until the emitter/build owners provide map artifacts.

(require rackunit
         racket/file
         racket/list
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         json)

(define-runtime-path repo-root "../..")
(define-runtime-path fixture "fixtures/sourcemap-v3/normalized-public.bjs")
(define beagle (build-path repo-root "bin" "beagle"))

(define base64-digits
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(define (base64-index char)
  (or (for/first ([index (in-range (string-length base64-digits))]
                  #:when (char=? char (string-ref base64-digits index)))
        index)
      (error 'decode-vlq "invalid base64 VLQ digit: ~a" char)))

(define (vlq-signed value)
  (if (odd? value) (- (quotient (add1 value) 2)) (quotient value 2)))

(define (decode-vlq segment start)
  (let loop ([index start] [shift 0] [value 0])
    (define digit (base64-index (string-ref segment index)))
    (define next-value
      (+ value (arithmetic-shift (bitwise-and digit #x1f) shift)))
    (if (zero? (bitwise-and digit #x20))
        (values (vlq-signed next-value) (add1 index))
        (loop (add1 index) (+ shift 5) next-value))))

(define (decode-segment segment)
  (let loop ([index 0] [values '()])
    (if (= index (string-length segment))
        (reverse values)
        (let-values ([(value next-index) (decode-vlq segment index)])
          (loop next-index (cons value values))))))

;; Return `(generated-line generated-column original-line)` triples from V3
;; segments. Source-map state is cumulative across generated lines, except
;; generated columns reset at each semicolon.
(define (mapped-segments mappings)
  (define source 0)
  (define original-line 0)
  (define original-column 0)
  (define name 0)
  (define mapped '())
  (for ([line-text (in-list (string-split mappings ";" #:trim? #f))]
        [generated-line (in-naturals)])
    (define generated-column 0)
    (unless (string=? line-text "")
      (for ([segment (in-list (string-split line-text ","))])
        (define values (decode-segment segment))
        (set! generated-column (+ generated-column (first values)))
        (when (>= (length values) 4)
          (set! source (+ source (second values)))
          (set! original-line (+ original-line (third values)))
          (set! original-column (+ original-column (fourth values)))
          (when (= (length values) 5)
            (set! name (+ name (fifth values))))
          (set! mapped
                (cons (list generated-line generated-column original-line)
                      mapped))))))
  (reverse mapped))

(define (mapping-at-token? js mapping token)
  (define generated-line (first mapping))
  (define generated-column (second mapping))
  (define lines (string-split js "\n"))
  (and (< generated-line (length lines))
       (let ([line (list-ref lines generated-line)])
         (and (<= (+ generated-column (string-length token))
                  (string-length line))
              (string=? (substring line generated-column
                                  (+ generated-column (string-length token)))
                        token)))))

(define (authored-line source needle)
  (for/first ([line (in-list (string-split source "\n"))]
              [index (in-naturals)]
              #:when (string-contains? line needle))
    index))

(define (build-fixture)
  (define scratch (make-temporary-file "beagle-js-sourcemap-v3-~a" 'directory))
  (define out-dir (build-path scratch "out"))
  (define stdout (open-output-string))
  (define stderr (open-output-string))
  (define exit-code
    (parameterize ([current-directory repo-root]
                   [current-output-port stdout]
                   [current-error-port stderr])
      (system*/exit-code beagle "build" "--target" "js"
                         (path->string fixture)
                         "--out" (path->string out-dir))))
  (values scratch
          exit-code
          (build-path out-dir "normalized-public.js")
          (build-path out-dir "normalized-public.js.map")
          (get-output-string stdout)
          (get-output-string stderr)))

(test-case "direct JS build writes a V3 map for normalized public ESM"
  (define-values (scratch exit-code js-path map-path stdout stderr)
    (build-fixture))
  (dynamic-wind
    void
    (lambda ()
      (check-equal? exit-code 0 (string-append stdout stderr))
      (check-true (file-exists? js-path) "the public ESM module must exist")
      (check-true (file-exists? map-path)
                  "D0: direct JS build must write the adjacent V3 map")
      (when (and (file-exists? js-path) (file-exists? map-path))
        (define js (file->string js-path))
        (define source (file->string fixture))
        (define map (call-with-input-file map-path read-json))
        ;; The public name is source-level API, not a generated placeholder.
        (check-true (string-contains? js "export { normalized as \"normalized\" };")
                    js)
        (check-true (string-suffix? js "//# sourceMappingURL=normalized-public.js.map\n")
                    js)
        (check-equal? (hash-ref map 'version) 3)
        (check-equal? (hash-ref map 'file) "normalized-public.js")
        (check-equal? (length (hash-ref map 'sources)) 1)
        (check-equal? (hash-ref map 'sourcesContent) (list source))
        (define mappings (hash-ref map 'mappings))
        (check-true (and (string? mappings) (positive? (string-length mappings))))
        ;; `when` is normalized to canonical `if`; both the normalized branch
        ;; and its authored body must remain present in the map's source lines.
        (define mapped-segments* (mapped-segments mappings))
        (for ([expectation (in-list (list (cons "(when true" "if (")
                                           (cons "(println value)" "console.log(")))])
          (define needle (car expectation))
          (define token (cdr expectation))
          (define line (authored-line source needle))
          (check-not-false line (format "fixture lost authored line for ~a" needle))
          (check-true
           (for/or ([mapping (in-list mapped-segments*)]
                    #:when (= line (third mapping)))
             (mapping-at-token? js mapping token))
           (format "V3 map lost ~a at emitted token boundary ~a"
                   needle token)))))
    (lambda () (delete-directory/files scratch #:must-exist? #f))))
