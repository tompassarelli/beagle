#lang racket/base

;; Contextual source canonicalization for the ruled flat typed-binding surface.
;; Reader datums retain delimiters, so this pass can remove only declaration
;; parens while leaving ordinary lists and data untouched.

(require racket/list
         "tags.rkt")

(define (bracketed? datum)
  (and (pair? datum) (eq? (car datum) BRACKET-TAG)))

(define (map-tagged? datum)
  (and (pair? datum) (eq? (car datum) MAP-TAG)))

(define (binding-form? datum)
  (or (symbol? datum) (bracketed? datum) (map-tagged? datum)))

;; A grouped declaration is written with PARENS and its head is the binder. The
;; reader represents brackets, maps, sets, metadata, and regexes as lists led by
;; a `#%` tag, and those lists hit the same 2-or-3 length — so `[a b]`,
;; `{:keys [x] :or {}}`, and `^String s` would each be rewritten as though the
;; tag itself were the binder being declared. A tag is never a binder, so
;; excluding tagged heads is exact and covers every tag the reader may add.
(define (reader-tagged? datum)
  (and (pair? datum)
       (symbol? (car datum))
       (regexp-match? #rx"^#%" (symbol->string (car datum)))))

(define (legacy-declaration? datum)
  (and (list? datum)
       (not (reader-tagged? datum))
       (memq (length datum) '(2 3))
       (binding-form? (car datum))))

(define (declaration->flat declaration)
  (define binder (car declaration))
  (define type (cadr declaration))
  (list binder
        (if (= (length declaration) 3)
            (list type 'where (caddr declaration))
            type)))

(define (canonical-binding-vector datum)
  (define items (cdr datum))
  (define legacy?
    (and (pair? items) (legacy-declaration? (car items))))
  (define flat-items
    (if legacy?
        (let loop ([rest items] [out '()])
          (cond
            [(null? rest) (reverse out)]
            [(and (eq? (car rest) '&)
                  (pair? (cdr rest))
                  (legacy-declaration? (cadr rest)))
             (define pair (declaration->flat (cadr rest)))
             (loop (cddr rest)
                   (append (reverse pair) (cons '& out)))]
            [(legacy-declaration? (car rest))
             (loop (cdr rest)
                   (append (reverse (declaration->flat (car rest))) out))]
            [else
             ;; Malformed mixed input is rejected by the parser. Preserve it
             ;; here so a source writer never invents a repair.
             (loop (cdr rest) (cons (car rest) out))]))
        items))
  (cons BRACKET-TAG (map canonicalize-beagle-datum flat-items)))

(define (canonical-let-vector datum)
  (let loop ([items (cdr datum)] [out '()])
    (cond
      [(null? items) (cons BRACKET-TAG (reverse out))]
      [(null? (cdr items))
       ;; The parser owns the diagnostic for a malformed binding vector. A
       ;; source writer preserves the stray form instead of inventing a value.
       (cons BRACKET-TAG
             (reverse (cons (canonicalize-beagle-datum (car items)) out)))]
      [else
       (define binder (car items))
       (define value (cadr items))
       (cond
         [(legacy-declaration? binder)
          (define flat (declaration->flat binder))
          (loop (cddr items)
                (cons (list ': (canonicalize-beagle-datum value)
                            (canonicalize-beagle-datum (cadr flat)))
                      (cons (canonicalize-beagle-datum (car flat)) out)))]
         [else
          (define canonical-value
            (if (and (eq? binder ':let) (bracketed? value))
                (canonical-let-vector value)
                (canonicalize-beagle-datum value)))
          (loop (cddr items)
                (cons canonical-value
                      (cons (canonicalize-beagle-datum binder) out)))])])))

(define (canonical-def elems)
  (define count* (length elems))
  (cond
    ;; (def name Type value)
    [(and (= count* 4) (symbol? (list-ref elems 1))
          (not (string? (list-ref elems 2))))
     (list (car elems) (list-ref elems 1)
           (list ': (canonicalize-beagle-datum (list-ref elems 3))
                 (canonicalize-beagle-datum (list-ref elems 2))))]
    ;; (def name Type "doc" value)
    [(and (= count* 5) (symbol? (list-ref elems 1))
          (not (string? (list-ref elems 2)))
          (string? (list-ref elems 3)))
     (list (car elems) (list-ref elems 1) (list-ref elems 3)
           (list ': (canonicalize-beagle-datum (list-ref elems 4))
                 (canonicalize-beagle-datum (list-ref elems 2))))]
    [else (map canonicalize-beagle-datum elems)]))

(define (typed-vector-index elems start)
  (for/first ([item (in-list elems)] [index (in-naturals)]
              #:when (and (>= index start) (bracketed? item)))
    index))

(define (canonical-owner-list datum)
  (define vector-index (typed-vector-index datum 1))
  (for/list ([item (in-list datum)] [index (in-naturals)])
    (if (and vector-index (= index vector-index))
        (canonical-binding-vector item)
        (canonicalize-beagle-datum item))))

(define (canonical-method-child item)
  (if (and (list? item)
           (pair? item)
           (symbol? (car item))
           (typed-vector-index item 1))
      (canonical-owner-list item)
      (canonicalize-beagle-datum item)))

(define (canonical-letfn-vector datum)
  (cons BRACKET-TAG
        (for/list ([item (in-list (cdr datum))])
          (canonical-method-child item))))

(define (canonicalize-list datum)
  (define elems datum)
  (define head (and (pair? elems) (symbol? (car elems)) (car elems)))
  (cond
    [(memq head '(quote quasiquote comment defmacro)) datum]
    [(memq head '(def defonce)) (canonical-def elems)]
    [(memq head '(let loop binding for doseq with-open with-local-vars
                       when-let if-let when-some if-some))
     (define vector-index (typed-vector-index elems 1))
     (for/list ([item (in-list elems)] [index (in-naturals)])
       (if (and vector-index (= index vector-index))
           (canonical-let-vector item)
           (canonicalize-beagle-datum item)))]
    [(eq? head 'letfn)
     (for/list ([item (in-list elems)] [index (in-naturals)])
       (if (and (= index 1) (bracketed? item))
           (canonical-letfn-vector item)
           (canonicalize-beagle-datum item)))]
    [(eq? head 'defprotocol)
     (for/list ([item (in-list elems)] [index (in-naturals)])
       (if (>= index 2)
           (canonical-method-child item)
           (canonicalize-beagle-datum item)))]
    [(eq? head 'extend-type)
     (for/list ([item (in-list elems)] [index (in-naturals)])
       (if (>= index 2)
           (canonical-method-child item)
           (canonicalize-beagle-datum item)))]
    [(eq? head 'defunion)
     (for/list ([item (in-list elems)] [index (in-naturals)])
       (if (and (>= index 2) (list? item))
           (canonical-owner-list item)
           (canonicalize-beagle-datum item)))]
    [else
     (define vector-index
       (cond
         [(memq head '(defn defn- fn defrecord))
          (typed-vector-index elems 1)]
         [(and (pair? elems) (bracketed? (car elems))) 0]
         [else #f]))
     (for/list ([item (in-list elems)] [index (in-naturals)])
       (cond
         [(and vector-index (= index vector-index))
          (canonical-binding-vector item)]
         ;; Current typed method/variant sites are nested owner forms. Their
         ;; own recursive pass discovers the vector without special casing the
         ;; outer protocol/union declaration.
         [else (canonicalize-beagle-datum item)]))]))

(define (canonicalize-beagle-datum datum)
  (cond
    [(bracketed? datum)
     (cons BRACKET-TAG (map canonicalize-beagle-datum (cdr datum)))]
    [(map-tagged? datum)
     (cons MAP-TAG (map canonicalize-beagle-datum (cdr datum)))]
    [(and (pair? datum) (eq? (car datum) SET-TAG))
     (cons SET-TAG (map canonicalize-beagle-datum (cdr datum)))]
    [(list? datum) (canonicalize-list datum)]
    [(pair? datum)
     (cons (canonicalize-beagle-datum (car datum))
           (canonicalize-beagle-datum (cdr datum)))]
    [(vector? datum)
     (list->vector (map canonicalize-beagle-datum (vector->list datum)))]
    [else datum]))

(provide canonicalize-beagle-datum legacy-declaration?)
