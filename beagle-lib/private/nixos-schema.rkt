#lang racket/base

;; nixos-schema — NixOS option schema loading, lookup, and type checking.
;;
;; Loads a NixOS option schema (JSON array) and provides:
;;   - path lookup with did-you-mean
;;   - value type checking (schema type vs beagle type)
;;   - schema discovery (walk up from source file to find cache)

(require racket/list
         racket/string
         racket/port
         racket/set
         json
         "types.rkt")

(provide
 ;; Schema state
 (struct-out nixos-schema)

 ;; Loading
 load-nixos-schema
 find-schema-json

 ;; Lookup
 nixos-option-lookup
 nixos-option-lookup/wildcard
 nixos-namespace-exists?

 ;; Type checking
 nixos-check-value-type

 ;; Did-you-mean
 nixos-find-similar
 levenshtein)

;; ============================================================================
;; Schema state
;; ============================================================================

(struct nixos-schema (table prefixes) #:transparent)
;; table    : (hash string? -> hash?)     path -> schema entry
;; prefixes : (setof string?)             all known path prefixes for namespace checks

;; ============================================================================
;; Loading
;; ============================================================================

(define (load-nixos-schema path)
  (define entries (call-with-input-file path read-json))
  (define table (make-hash))
  (define prefixes (mutable-set))
  (for ([e (in-list entries)])
    (define p (hash-ref e 'p #f))
    (when (and p (string? p))
      (hash-set! table p e)
      ;; Add all prefixes for namespace checking
      (let loop ([s p])
        (define dot (for/or ([i (in-range (sub1 (string-length s)) 0 -1)])
                      (and (char=? (string-ref s i) #\.) i)))
        (when dot
          (define prefix (substring s 0 dot))
          (set-add! prefixes prefix)
          (loop prefix)))))
  (nixos-schema (hash-copy table) prefixes))

(define (find-schema-json source-path)
  (define dir
    (cond
      [(path? source-path) (let-values ([(base name dir?) (split-path source-path)])
                             (if (path? base) base (current-directory)))]
      [(string? source-path) (let-values ([(base name dir?) (split-path (string->path source-path))])
                               (if (path? base) base (current-directory)))]
      [else #f]))
  (and dir
       (let loop ([d (simplify-path (path->complete-path dir))])
         (define candidate (build-path d ".nisp-cache" "schema.json"))
         (cond
           [(file-exists? candidate) candidate]
           [else
            (define-values (parent name dir?) (split-path d))
            (and (path? parent)
                 (not (equal? parent d))
                 (loop parent))]))))

;; ============================================================================
;; Lookup
;; ============================================================================

(define (nixos-option-lookup schema path-str)
  (hash-ref (nixos-schema-table schema) path-str #f))

(define SUBMODULE-BOUNDARY-TYPES
  '("attrsOf" "lazyAttrsOf" "listOf" "submodule"))

(define (nixos-option-lookup/wildcard schema path-str)
  (or (nixos-option-lookup schema path-str)
      (let ([parts (string-split path-str ".")])
        (and (>= (length parts) 2)
             (let loop ([i 1])
               (cond
                 [(>= i (length parts)) #f]
                 [else
                  (define wildcard-path
                    (string-join
                     (append (take parts i) (cons "<name>" (drop parts (add1 i))))
                     "."))
                  (define wildcard-entry (nixos-option-lookup schema wildcard-path))
                  (cond
                    [wildcard-entry wildcard-entry]
                    [else
                     (define prefix (string-join (take parts i) "."))
                     (define prefix-entry (nixos-option-lookup schema prefix))
                     (cond
                       [(and prefix-entry
                             (let ([t (hash-ref prefix-entry 't "?")])
                               (member t SUBMODULE-BOUNDARY-TYPES)))
                        'permissive]
                       [else (loop (add1 i))])])]))))))

(define (nixos-namespace-exists? schema path-str)
  (set-member? (nixos-schema-prefixes schema) path-str))

;; ============================================================================
;; Type checking
;; ============================================================================

(define STR-TYPES
  '("str" "string" "singleLineStr" "passwdEntry" "separatedString"
    "lines" "commas" "envVar" "nonEmptyStr"))

(define INT-TYPES
  '("int" "ints.unsigned" "ints.positive" "ints.between"
    "unsignedInt8" "unsignedInt16" "unsignedInt32" "unsignedInt64"
    "signedInt8" "signedInt16" "signedInt32" "signedInt64"
    "port" "u8" "u16" "u32" "u64" "s8" "s16" "s32" "s64"
    "positiveInt" "unsignedInt" "intBetween"))

(define PERMISSIVE-TYPES
  '("submodule" "anything" "unspecified" "raw"
    "either" "oneOf" "coercedTo" "addCheck" "functionTo" "package"
    "deferredModule" "optionType" "loaOf" "uniq" "attrs" "freeformType"))

(define (str-type? t)
  (or (and (member t STR-TYPES) #t)
      (and (string? t) (regexp-match? #rx"^strMatching" t) #t)))

(define (int-type? t)
  (or (and (member t INT-TYPES) #t)
      (and (string? t) (regexp-match? #rx"^ints\\." t) #t)))

(define (path-type? t) (and (member t '("path" "pathInStore")) #t))
(define (bool-type? t) (equal? t "bool"))
(define (float-type? t) (or (equal? t "float") (equal? t "number")))
(define (permissive-type? t) (and (member t PERMISSIVE-TYPES) #t))

(define (any-type? t)
  (and (type-prim? t) (eq? (type-prim-name t) 'Any)))

(define (nixos-check-value-type entry beagle-type)
  (define t (hash-ref entry 't "?"))
  (cond
    [(permissive-type? t) 'ok]
    [(equal? t "?") 'ok]
    [(any-type? beagle-type) 'ok]

    [(bool-type? t)
     (if (type-compatible? beagle-type (type-prim 'Bool)) 'ok
         `(mismatch ,(format "expected bool, got ~a" (type->string beagle-type))))]

    [(str-type? t)
     (if (or (type-compatible? beagle-type (type-prim 'String))
             (type-compatible? beagle-type (type-prim 'Keyword)))
         'ok
         `(mismatch ,(format "expected ~a, got ~a" t (type->string beagle-type))))]

    [(int-type? t)
     (if (type-compatible? beagle-type (type-prim 'Int)) 'ok
         `(mismatch ,(format "expected ~a, got ~a" t (type->string beagle-type))))]

    [(float-type? t)
     (if (or (type-compatible? beagle-type (type-prim 'Float))
             (type-compatible? beagle-type (type-prim 'Int)))
         'ok
         `(mismatch ,(format "expected ~a, got ~a" t (type->string beagle-type))))]

    [(path-type? t)
     (if (or (type-compatible? beagle-type (type-prim 'String))
             (and (type-prim? beagle-type) (eq? (type-prim-name beagle-type) 'Any)))
         'ok
         `(mismatch ,(format "expected path, got ~a" (type->string beagle-type))))]

    [(equal? t "nullOr")
     (cond
       [(type-compatible? beagle-type (type-prim 'Nil)) 'ok]
       [(hash-ref entry 'inner #f)
        => (lambda (inner) (nixos-check-value-type inner beagle-type))]
       [else 'ok])]

    [(equal? t "enum")
     (define enum-vals (hash-ref entry 'enum #f))
     (cond
       [(not enum-vals) 'ok]
       [(type-compatible? beagle-type (type-prim 'String)) 'ok]
       [else `(mismatch ,(format "expected enum string, got ~a" (type->string beagle-type)))])]

    [(equal? t "listOf")
     (if (or (and (type-app? beagle-type)
                  (memq (type-app-ctor beagle-type) '(Vec List)))
             (any-type? beagle-type))
         'ok
         `(mismatch ,(format "expected list, got ~a" (type->string beagle-type))))]

    [(member t '("attrsOf" "lazyAttrsOf"))
     (if (or (and (type-app? beagle-type)
                  (eq? (type-app-ctor beagle-type) 'Map))
             (any-type? beagle-type))
         'ok
         `(mismatch ,(format "expected attrset, got ~a" (type->string beagle-type))))]

    [else 'ok]))

;; ============================================================================
;; Did-you-mean (Levenshtein)
;; ============================================================================

(define (levenshtein a b)
  (define la (string-length a))
  (define lb (string-length b))
  (cond
    [(zero? la) lb]
    [(zero? lb) la]
    [else
     (define prev (make-vector (add1 lb)))
     (define curr (make-vector (add1 lb)))
     (for ([j (in-range (add1 lb))])
       (vector-set! prev j j))
     (for ([i (in-range 1 (add1 la))])
       (vector-set! curr 0 i)
       (for ([j (in-range 1 (add1 lb))])
         (define cost (if (char=? (string-ref a (sub1 i))
                                  (string-ref b (sub1 j)))
                          0 1))
         (vector-set! curr j
                      (min (add1 (vector-ref curr (sub1 j)))
                           (add1 (vector-ref prev j))
                           (+ cost (vector-ref prev (sub1 j))))))
       (vector-copy! prev 0 curr))
     (vector-ref prev lb)]))

(define (nixos-find-similar schema path-str)
  (define threshold (max 2 (min 4 (quotient (string-length path-str) 3))))
  (define candidates
    (for/list ([key (in-hash-keys (nixos-schema-table schema))]
               #:when (let ([d (levenshtein path-str key)])
                        (and (> d 0) (<= d threshold))))
      (cons (levenshtein path-str key) key)))
  (map cdr (sort candidates < #:key car)))
