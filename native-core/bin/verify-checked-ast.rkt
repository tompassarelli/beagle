#lang racket/base

;; Verify the two digests already carried by a checked-program projection.  The
;; projection digest deliberately reuses Beagle's canonical JSON writer; a
;; second serializer would create a second, subtly different authority.

(require json
         openssl/sha1
         racket/file
         racket/string
         (only-in "../../beagle-lib/private/semantic-index.rkt"
                  write-canonical-json))

(define (die format-string . values)
  (apply eprintf (string-append "checked AST: " format-string "\n") values)
  (exit 2))

(define arguments (current-command-line-arguments))
(unless (= 2 (vector-length arguments))
  (die "expected AST.json SOURCE"))

(define ast-path (vector-ref arguments 0))
(define source-path (vector-ref arguments 1))
(define ast
  (call-with-input-file ast-path
    (lambda (in)
      (define value (read-json in))
      (unless (eof-object? (read-json in))
        (die "~a contains more than one JSON value" ast-path))
      value)))
(unless (hash? ast) (die "~a is not a checked-program object" ast-path))

(define (sha256-prefixed bytes)
  (string-append "sha256:" (bytes->hex-string (sha256-bytes bytes))))

(define (canonical-bytes value)
  (define out (open-output-bytes))
  (write-canonical-json value out)
  (get-output-bytes out))

(define expected-source (sha256-prefixed (file->bytes source-path)))
(define actual-source (hash-ref ast 'sourceSha256 #f))
(unless (equal? expected-source actual-source)
  (die "sourceSha256 does not bind ~a" source-path))

(define expected-projection
  (sha256-prefixed
   (canonical-bytes (hash-remove ast 'projectionSha256))))
(define actual-projection (hash-ref ast 'projectionSha256 #f))
(unless (equal? expected-projection actual-projection)
  (die "projectionSha256 does not bind canonical checked JSON in ~a" ast-path))

(define source-id (hash-ref ast 'sourceId #f))
(define namespace (hash-ref ast 'namespace #f))
(define safe-field? (lambda (value)
                      (and (string? value)
                           (positive? (string-length value))
                           (for/and ([character (in-string value)])
                             (define point (char->integer character))
                             (and (>= point 32) (not (= point 127)))))))
(unless (safe-field? source-id) (die "sourceId is not a safe single-line field"))
(unless (safe-field? namespace) (die "namespace is not a safe single-line field"))
(display source-id)
(write-byte 0)
(display namespace)
(write-byte 0)
(display actual-source)
(write-byte 0)
(display actual-projection)
(write-byte 0)
