#lang racket/base

;; Pure Source Map V3 encoding.  The emitter supplies already-normalized,
;; zero-based locations; this module only orders and delta-encodes them.

(require racket/list
         racket/string)

(struct source-map-v3-segment
  (generated-line generated-column
   source-index original-line original-column name-index)
  #:transparent)

(define base64-digits
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(define (require-list who label value)
  (unless (list? value)
    (raise-arguments-error who "expected a list" label value)))

(define (require-string-list who label value)
  (require-list who label value)
  (unless (andmap string? value)
    (raise-arguments-error who "expected a list of strings" label value)))

(define (require-nonnegative-integer who label value)
  (unless (and (exact-integer? value) (>= value 0))
    (raise-arguments-error who "expected an exact non-negative integer" label value)))

(define (encode-base64-vlq value)
  (unless (exact-integer? value)
    (raise-argument-error 'encode-base64-vlq "exact-integer?" value))
  (define unsigned
    (if (negative? value)
        (add1 (* -2 value))
        (* 2 value)))
  (let loop ([remaining unsigned] [pieces '()])
    (define payload (bitwise-and remaining #x1f))
    (define next (arithmetic-shift remaining -5))
    (define digit
      (if (zero? next) payload (bitwise-ior payload #x20)))
    (define next-pieces (cons (string-ref base64-digits digit) pieces))
    (if (zero? next)
        (list->string (reverse next-pieces))
        (loop next next-pieces))))

(define (segment<? left right)
  (or (< (source-map-v3-segment-generated-line left)
         (source-map-v3-segment-generated-line right))
      (and (= (source-map-v3-segment-generated-line left)
              (source-map-v3-segment-generated-line right))
           (< (source-map-v3-segment-generated-column left)
              (source-map-v3-segment-generated-column right)))))

(define (same-generated-position? left right)
  (and (= (source-map-v3-segment-generated-line left)
          (source-map-v3-segment-generated-line right))
       (= (source-map-v3-segment-generated-column left)
          (source-map-v3-segment-generated-column right))))

(define (validate-segment! segment source-count name-count)
  (unless (source-map-v3-segment? segment)
    (raise-argument-error 'source-map-v3-document "source-map-v3-segment?" segment))
  (for ([field (in-list
               (list (cons "generated line"
                           (source-map-v3-segment-generated-line segment))
                     (cons "generated column"
                           (source-map-v3-segment-generated-column segment))
                     (cons "source index"
                           (source-map-v3-segment-source-index segment))
                     (cons "original line"
                           (source-map-v3-segment-original-line segment))
                     (cons "original column"
                           (source-map-v3-segment-original-column segment))))])
    (require-nonnegative-integer 'source-map-v3-document (car field) (cdr field)))
  (define source-index (source-map-v3-segment-source-index segment))
  (unless (< source-index source-count)
    (raise-arguments-error 'source-map-v3-document
                           "segment source index is outside the sources table"
                           "source index" source-index
                           "source count" source-count))
  (define name-index (source-map-v3-segment-name-index segment))
  (unless (or (not name-index)
              (and (exact-integer? name-index)
                   (>= name-index 0)
                   (< name-index name-count)))
    (raise-arguments-error 'source-map-v3-document
                           "segment name index is outside the names table"
                           "name index" name-index
                           "name count" name-count)))

(define (source-map-v3-document file sources sources-content names segments)
  (unless (string? file)
    (raise-argument-error 'source-map-v3-document "string?" file))
  (require-string-list 'source-map-v3-document "sources" sources)
  (require-string-list 'source-map-v3-document "sources content" sources-content)
  (require-string-list 'source-map-v3-document "names" names)
  (require-list 'source-map-v3-document "segments" segments)
  (unless (= (length sources) (length sources-content))
    (raise-arguments-error 'source-map-v3-document
                           "sources and sources content must have equal lengths"
                           "sources" sources
                           "sources content" sources-content))
  (for ([segment (in-list segments)])
    (validate-segment! segment (length sources) (length names)))
  (define ordered-segments (sort segments segment<?))
  (for ([left (in-list ordered-segments)]
        [right (in-list (cdr ordered-segments))])
    (when (same-generated-position? left right)
      (raise-arguments-error 'source-map-v3-document
                             "segments cannot share a generated position"
                             "generated line"
                             (source-map-v3-segment-generated-line left)
                             "generated column"
                             (source-map-v3-segment-generated-column left))))
  (define mappings
    (if (null? ordered-segments)
        ""
        (let ([previous-source 0]
              [previous-original-line 0]
              [previous-original-column 0]
              [previous-name 0]
              [last-line
               (source-map-v3-segment-generated-line (last ordered-segments))])
          (string-join
           (for/list ([generated-line (in-range (add1 last-line))])
             (define previous-generated-column 0)
             (string-join
              (for/list ([segment (in-list ordered-segments)]
                         #:when (= generated-line
                                   (source-map-v3-segment-generated-line segment)))
                (define generated-column
                  (source-map-v3-segment-generated-column segment))
                (define source-index (source-map-v3-segment-source-index segment))
                (define original-line (source-map-v3-segment-original-line segment))
                (define original-column
                  (source-map-v3-segment-original-column segment))
                (define name-index (source-map-v3-segment-name-index segment))
                (define fields
                  (list (- generated-column previous-generated-column)
                        (- source-index previous-source)
                        (- original-line previous-original-line)
                        (- original-column previous-original-column)))
                (set! previous-generated-column generated-column)
                (set! previous-source source-index)
                (set! previous-original-line original-line)
                (set! previous-original-column original-column)
                (when name-index
                  (set! fields (append fields (list (- name-index previous-name))))
                  (set! previous-name name-index))
                (string-join (map encode-base64-vlq fields) ""))
              ","))
           ";"))))
  (hasheq 'version 3
          'file file
          'sources sources
          'sourcesContent sources-content
          'names names
          'mappings mappings))

(provide
 (struct-out source-map-v3-segment)
 encode-base64-vlq
 source-map-v3-document)
