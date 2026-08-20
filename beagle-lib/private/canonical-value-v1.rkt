#lang racket/base

;; Canonical semantic bytes shared by shadow fact kinds. Physical Store
;; layout is deliberately absent: these bytes own identity, not persistence.

(require (only-in file/sha1 bytes->hex-string)
         openssl/sha1
         racket/list
         racket/port
         racket/set
         racket/string)

(struct canonical-tagged-v1 (tag value) #:transparent)
(struct identity-reference-v1 (domain identity) #:transparent)
(struct canonical-field-v1 (name value) #:transparent)
(struct canonical-record-v1
  (shape-id schema-version fields unknown-fields)
  #:transparent)
(struct canonical-union-v1 (union-id variant-id payloads) #:transparent)

(define CANONICAL-VALUE-V1-PREFIX #"BEAGLE-CANONICAL-VALUE-V1\0")

(define (fail who message . fields)
  (apply raise-arguments-error who message fields))

(define (canonical-name who label value)
  (define text
    (cond
      [(string? value) value]
      [(symbol? value) (symbol->string value)]
      [else
       (fail who "expected a string or symbol" label value)]))
  (when (string=? text "")
    (fail who "expected a nonempty name" label value))
  (string-normalize-nfc text))

(define (write-uvarint value out)
  (unless (exact-nonnegative-integer? value)
    (raise-argument-error 'write-uvarint "exact-nonnegative-integer?" value))
  (let loop ([remaining value])
    (define low (bitwise-and remaining #x7f))
    (define rest (arithmetic-shift remaining -7))
    (write-byte (if (zero? rest) low (bitwise-ior low #x80)) out)
    (unless (zero? rest) (loop rest))))

(define (write-sized-payload bytes out)
  (write-uvarint (bytes-length bytes) out)
  (write-bytes bytes out))

(define (write-text text out)
  (write-sized-payload
   (string->bytes/utf-8 (string-normalize-nfc text))
   out))

(define (bytes<? left right)
  (let loop ([index 0])
    (cond
      [(= index (bytes-length left))
       (< index (bytes-length right))]
      [(= index (bytes-length right)) #f]
      [(< (bytes-ref left index) (bytes-ref right index)) #t]
      [(> (bytes-ref left index) (bytes-ref right index)) #f]
      [else (loop (add1 index))])))

(define (with-active who value active encode)
  (when (hash-ref active value #f)
    (fail who
          "implicit cyclic values are not canonical; use an identity reference"
          "value" value))
  (hash-set! active value #t)
  (dynamic-wind void encode (lambda () (hash-remove! active value))))

(define (inner-bytes value active)
  (call-with-output-bytes
   (lambda (out) (write-inner value out active))))

(define (write-sequence tag values out active)
  (write-byte tag out)
  (write-uvarint (length values) out)
  (for ([value (in-list values)])
    (write-sized-payload (inner-bytes value active) out)))

(define (sorted-unique who label entries)
  (define sorted (sort entries bytes<? #:key car))
  (for ([left (in-list sorted)]
        [right (in-list (if (null? sorted) '() (cdr sorted)))])
    (when (bytes=? (car left) (car right))
      (fail who
            "distinct inputs collapse to the same canonical value"
            "field" label
            "left" (cdr left)
            "right" (cdr right))))
  sorted)

(define (write-map value out active)
  (with-active
   'canonical-value-v1->bytes value active
   (lambda ()
     (define entries
       (for/list ([(key item) (in-hash value)])
         (define key-bytes (inner-bytes key active))
         (cons key-bytes (cons key (inner-bytes item active)))))
     (define sorted
       (sorted-unique 'canonical-value-v1->bytes "map keys" entries))
     (write-byte 12 out)
     (write-uvarint (length sorted) out)
     (for ([entry (in-list sorted)])
       (write-sized-payload (car entry) out)
       (write-sized-payload (cddr entry) out)))))

(define (write-set value out active)
  (with-active
   'canonical-value-v1->bytes value active
   (lambda ()
     (define entries
       (for/list ([item (in-set value)])
         (cons (inner-bytes item active) item)))
     (define sorted
       (sorted-unique 'canonical-value-v1->bytes "set members" entries))
     (write-byte 13 out)
     (write-uvarint (length sorted) out)
     (for ([entry (in-list sorted)])
       (write-sized-payload (car entry) out)))))

(define (field-vector who label fields)
  (unless (and (vector? fields)
               (for/and ([field (in-vector fields)])
                 (canonical-field-v1? field)))
    (fail who "expected a vector of canonical fields" label fields))
  fields)

(define (field-name field)
  (canonical-name 'canonical-value-v1->bytes
                  "field name"
                  (canonical-field-v1-name field)))

(define (duplicate-name? names)
  (not (= (length names) (set-count (list->set names)))))

(define (write-record value out active)
  (with-active
   'canonical-value-v1->bytes value active
   (lambda ()
     (define fields
       (field-vector 'canonical-value-v1->bytes
                     "fields"
                     (canonical-record-v1-fields value)))
     (define unknown-fields
       (field-vector 'canonical-value-v1->bytes
                     "unknown-fields"
                     (canonical-record-v1-unknown-fields value)))
     (define known-names
       (for/list ([field (in-vector fields)]) (field-name field)))
     (define unknown-names
       (for/list ([field (in-vector unknown-fields)]) (field-name field)))
     (when (or (duplicate-name? known-names)
               (duplicate-name? unknown-names)
               (for/or ([name (in-list unknown-names)])
                 (member name known-names)))
       (fail 'canonical-value-v1->bytes
             "record fields must have unique canonical names"
             "known-fields" known-names
             "unknown-fields" unknown-names))
     (define ordered-unknown
       (sort (vector->list unknown-fields) string<? #:key field-name))
     (write-byte 16 out)
     (write-text
      (canonical-name 'canonical-value-v1->bytes
                      "shape-id"
                      (canonical-record-v1-shape-id value))
      out)
     (define schema-version (canonical-record-v1-schema-version value))
     (unless (exact-positive-integer? schema-version)
       (fail 'canonical-value-v1->bytes
             "record schema version must be positive"
             "schema-version" schema-version))
     (write-uvarint schema-version out)
     (write-uvarint (vector-length fields) out)
     (for ([field (in-vector fields)])
       (write-text (field-name field) out)
       (write-sized-payload
        (inner-bytes (canonical-field-v1-value field) active)
        out))
     ;; Unknown fields are preserved in a distinct, name-sorted partition.
     (write-uvarint (length ordered-unknown) out)
     (for ([field (in-list ordered-unknown)])
       (write-text (field-name field) out)
       (write-sized-payload
        (inner-bytes (canonical-field-v1-value field) active)
        out)))))

(define (write-union value out active)
  (with-active
   'canonical-value-v1->bytes value active
   (lambda ()
     (define payloads (canonical-union-v1-payloads value))
     (unless (vector? payloads)
       (fail 'canonical-value-v1->bytes
             "union payloads must be a vector"
             "payloads" payloads))
     (write-byte 17 out)
     (write-text
      (canonical-name 'canonical-value-v1->bytes
                      "union-id"
                      (canonical-union-v1-union-id value))
      out)
     (write-text
      (canonical-name 'canonical-value-v1->bytes
                      "variant-id"
                      (canonical-union-v1-variant-id value))
      out)
     (write-uvarint (vector-length payloads) out)
     (for ([payload (in-vector payloads)])
       (write-sized-payload (inner-bytes payload active) out)))))

(define (write-inner value out active)
  (cond
    [(null? value) (write-byte 0 out)]
    [(eq? value #f) (write-byte 1 out)]
    [(eq? value #t) (write-byte 2 out)]
    [(exact-integer? value)
     (write-byte 3 out)
     (write-text (number->string value 10) out)]
    [(and (rational? value) (exact? value))
     (write-byte 4 out)
     (write-sized-payload (inner-bytes (numerator value) active) out)
     (write-sized-payload (inner-bytes (denominator value) active) out)]
    [(and (real? value) (inexact? value))
     (write-byte 5 out)
     (write-bytes
      (if (not (= value value))
          ;; Every NaN payload has one semantic representation.
          (bytes #x7f #xf8 0 0 0 0 0 0)
          (real->floating-point-bytes value 8 #t))
      out)]
    [(string? value)
     (write-byte 6 out)
     (write-text value out)]
    ;; Characters are distinct semantic values from their codepoint integers.
    ;; Keep the codepoint scalar in the canonical payload and reserve a tag so
    ;; `#\\A` cannot collide with the integer `65`.
    [(char? value)
     (write-byte 19 out)
     (write-uvarint (char->integer value) out)]
    [(bytes? value)
     (write-byte 7 out)
     (write-sized-payload value out)]
    [(symbol? value)
     (write-byte 8 out)
     (write-text (symbol->string value) out)]
    [(keyword? value)
     (write-byte 9 out)
     (write-text (keyword->string value) out)]
    [(list? value)
     (with-active
      'canonical-value-v1->bytes value active
      (lambda () (write-sequence 10 value out active)))]
    [(pair? value)
     (with-active
      'canonical-value-v1->bytes value active
      (lambda ()
        (write-byte 11 out)
        (write-sized-payload (inner-bytes (car value) active) out)
        (write-sized-payload (inner-bytes (cdr value) active) out)))]
    [(vector? value)
     (with-active
      'canonical-value-v1->bytes value active
      (lambda ()
        (write-sequence 14 (vector->list value) out active)))]
    [(hash? value) (write-map value out active)]
    [(set? value) (write-set value out active)]
    [(canonical-tagged-v1? value)
     (with-active
      'canonical-value-v1->bytes value active
      (lambda ()
        (write-byte 15 out)
        (write-text
         (canonical-name 'canonical-value-v1->bytes
                         "tag"
                         (canonical-tagged-v1-tag value))
         out)
        (write-sized-payload
         (inner-bytes (canonical-tagged-v1-value value) active)
         out)))]
    [(identity-reference-v1? value)
     (write-byte 18 out)
     (write-text
      (canonical-name 'canonical-value-v1->bytes
                      "reference domain"
                      (identity-reference-v1-domain value))
      out)
     (write-text
      (canonical-name 'canonical-value-v1->bytes
                      "reference identity"
                      (identity-reference-v1-identity value))
      out)]
    [(canonical-record-v1? value) (write-record value out active)]
    [(canonical-union-v1? value) (write-union value out active)]
    [else
     (fail 'canonical-value-v1->bytes
           "value is outside the V1 canonical semantic vocabulary"
           "value" value)]))

(define (canonical-value-v1->bytes value)
  (bytes-append
   CANONICAL-VALUE-V1-PREFIX
   (inner-bytes value (make-hasheq))))

(define (canonical-value-v1-id value)
  (string-append
   "sha256:"
   (bytes->hex-string (sha256-bytes (canonical-value-v1->bytes value)))))

(provide
 (struct-out canonical-tagged-v1)
 (struct-out identity-reference-v1)
 (struct-out canonical-field-v1)
 (struct-out canonical-record-v1)
 (struct-out canonical-union-v1)
 canonical-value-v1->bytes
 canonical-value-v1-id)
