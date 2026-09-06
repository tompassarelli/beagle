#lang racket/base

;; Regression test for a bug where read-message treated the LSP
;; Content-Length header (a byte count, per spec) as a character count when
;; reading the message body. For ASCII-only bodies these are numerically
;; identical, so the bug only surfaces once a body contains multi-byte
;; UTF-8 content: `read-string` under-reads characters relative to the
;; declared byte length, over-running into the next message's header bytes
;; and permanently desynchronizing the stream for the rest of the session.

(require rackunit
         racket/runtime-path
         json)

(define-runtime-path lsp-module "../../beagle-lib/private/lsp.rkt")

(define read-message
  (begin
    (dynamic-require lsp-module #f)
    (parameterize ([current-namespace (module->namespace lsp-module)])
      (eval 'read-message))))

(define (frame jsexpr)
  (define body-bytes (string->bytes/utf-8 (jsexpr->string jsexpr)))
  (bytes-append
   (string->bytes/utf-8
    (format "Content-Length: ~a\r\n\r\n" (bytes-length body-bytes)))
   body-bytes))

(test-case
 "read-message reads multi-byte UTF-8 bodies without over-reading into the next message"
 ;; Braille dot-pattern characters (U+28xx) are 3 bytes each in UTF-8 but a
 ;; single character once decoded -- exactly the shape that broke a
 ;; character-count read against a byte-count header. This mirrors the
 ;; real-world trigger: a minimap/scrollbar plugin's rendered preview
 ;; buffer, sent to the LSP as an ordinary didOpen.
 (define msg1
   (hasheq 'jsonrpc "2.0"
           'method "textDocument/didOpen"
           'params (hasheq 'textDocument
                            (hasheq 'text "⠭⠭⣭⣭⣭⣭⣭⣭⣭⣭⣭⣭"))))
 (define msg2
   (hasheq 'jsonrpc "2.0" 'id 1 'method "ping"))

 (define in (open-input-bytes (bytes-append (frame msg1) (frame msg2))))

 (define parsed1 (read-message in))
 (check-equal? (hash-ref parsed1 'method) "textDocument/didOpen")

 ;; The actual regression check: after reading the multi-byte message, the
 ;; port must sit exactly at the start of the second message's header, not
 ;; partway into it. Before the fix, over-reading here caused this second
 ;; read-message call to raise "missing Content-Length header" instead of
 ;; returning a valid message.
 (define parsed2 (read-message in))
 (check-equal? (hash-ref parsed2 'method) "ping")
 (check-equal? (hash-ref parsed2 'id) 1))
