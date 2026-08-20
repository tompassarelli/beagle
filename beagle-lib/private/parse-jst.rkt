#lang racket/base

;; Typed JS target (js/*) parse helpers — minimal set.
;; Only forms with no core beagle equivalent.

(require racket/string
         "ast.rkt")

(define (parse-jst-member-key form)
  (define d (->datum form))
  (if (dot-method-sym? d)
      (let ([spelling (symbol->string d)])
        (store-src! (jst-selector (substring spelling
                                             (if (string-prefix? spelling ".-") 2 1)))
                    (and (syntax? form) (stx->src-loc form))))
      ((current-parse-expr) form)))

(provide parse-jst-member-key)
