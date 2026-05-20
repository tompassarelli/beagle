#lang racket/base

(require racket/list
         racket/string
         "tokenize.rkt"
         "scan.rkt"
         "infer.rkt"
         "diagnostics.rkt")

(provide repair
         apply-edits)

;; ============================================================================
;; Parinfer Indent Mode — rewrite trailing closers based on indentation
;; ============================================================================

(define (find-paren-trail-on-line tokens line-num)
  (define line-toks
    (filter (lambda (t) (= (token-line t) line-num)) tokens))
  (define reversed (reverse line-toks))
  (let loop ([ts reversed] [trail '()])
    (cond
      [(null? ts) trail]
      [(memq (token-type (car ts)) '(whitespace newline line-comment block-comment))
       (loop (cdr ts) trail)]
      [(closer? (car ts))
       (loop (cdr ts) (cons (car ts) trail))]
      [else trail])))

(define (max-line-number tokens)
  (for/fold ([m 0]) ([t (in-list tokens)])
    (max m (token-line t))))

(define (parinfer-indent-repair source)
  (define tokens (tokenize source))
  (cond
    [(null? tokens)
     (repair-result source #f '() 'high '())]
    [else
     (define num-lines (max-line-number tokens))
     (define src-len (string-length source))

     ;; Group tokens by line
     (define tokens-by-line (make-vector (add1 num-lines) '()))
     (for ([tok (in-list tokens)])
       (define ln (token-line tok))
       (when (<= ln num-lines)
         (vector-set! tokens-by-line ln
           (cons tok (vector-ref tokens-by-line ln)))))
     (for ([ln (in-range 1 (add1 num-lines))])
       (vector-set! tokens-by-line ln
         (reverse (vector-ref tokens-by-line ln))))

     ;; Per-line: trail, indent, content-end, trail-end
     (define trails-vec (make-vector (add1 num-lines) '()))
     (define trail-sets (make-vector (add1 num-lines) #f))
     (define indents (make-vector (add1 num-lines) #f))
     (define content-ends (make-vector (add1 num-lines) 0))
     (define trail-ends-vec (make-vector (add1 num-lines) 0))
     (define has-content-vec (make-vector (add1 num-lines) #f))

     (for ([ln (in-range 1 (add1 num-lines))])
       (define trail (find-paren-trail-on-line tokens ln))
       (vector-set! trails-vec ln trail)
       (vector-set! trail-sets ln (list->set trail))

       (define toks (vector-ref tokens-by-line ln))
       (define ts (vector-ref trail-sets ln))
       (define first-col #f)
       (define last-end 0)
       (define found #f)

       (for ([tok (in-list toks)])
         (when (and (not (memq (token-type tok) '(whitespace newline line-comment block-comment)))
                    (not (set-member? ts tok)))
           (unless first-col
             (set! first-col (token-col tok)))
           (set! found #t)
           (set! last-end (+ (token-offset tok) (string-length (token-text tok))))))

       (vector-set! indents ln first-col)
       (vector-set! has-content-vec ln (and found #t))
       (vector-set! content-ends ln
         (cond
           [found last-end]
           [(pair? trail) (token-offset (car trail))]
           [(pair? toks) (token-offset (car toks))]
           [else 0]))
       (vector-set! trail-ends-vec ln
         (if (pair? trail)
             (+ (token-offset (last trail)) (string-length (token-text (last trail))))
             (vector-ref content-ends ln))))

     ;; Main pass: close openers based on indentation, place closers on last content line
     (define stack '())
     (define new-trails (make-hash))
     (define last-content-line #f)

     (for ([ln (in-range 1 (add1 num-lines))])
       (define indent (vector-ref indents ln))
       (define content? (vector-ref has-content-vec ln))

       (when (and content? indent)
         (let loop ()
           (when (and (pair? stack) (>= (token-col (car stack)) indent))
             (define opener (car stack))
             (set! stack (cdr stack))
             (define c (closer-text (matching-closer-type (token-type opener))))
             (when last-content-line
               (hash-update! new-trails last-content-line
                 (lambda (prev) (append prev (list c))) '()))
             (loop)))
         (set! last-content-line ln))

       (define ts (vector-ref trail-sets ln))
       (for ([tok (in-list (vector-ref tokens-by-line ln))])
         (cond
           [(and (opener? tok) (not (set-member? ts tok)))
            (set! stack (cons tok stack))]
           [(and (closer? tok) (not (set-member? ts tok)))
            (when (pair? stack)
              (set! stack (cdr stack)))])))

     ;; EOF: close all remaining openers
     (let loop ()
       (when (pair? stack)
         (define opener (car stack))
         (set! stack (cdr stack))
         (define c (closer-text (matching-closer-type (token-type opener))))
         (when last-content-line
           (hash-update! new-trails last-content-line
             (lambda (prev) (append prev (list c))) '()))
         (loop)))

     ;; Generate edits: compare content-end..trail-end region to new trail
     (define edits '())

     (for ([ln (in-range 1 (add1 num-lines))])
       (define new-closers (hash-ref new-trails ln '()))
       (define new-text (apply string-append new-closers))
       (define c-end (min (vector-ref content-ends ln) src-len))
       (define t-end (min (vector-ref trail-ends-vec ln) src-len))
       (define old-region (substring source c-end t-end))

       (unless (equal? old-region new-text)
         (set! edits
           (cons (repair-edit c-end (- t-end c-end) new-text ln -1
                   (cond
                     [(and (equal? new-text "") (pair? (vector-ref trails-vec ln)))
                      (format "remove trail: ~a"
                        (apply string-append (map token-text (vector-ref trails-vec ln))))]
                     [(null? (vector-ref trails-vec ln))
                      (format "insert trail: ~a" new-text)]
                     [else
                      (format "rewrite trail: ~a -> ~a"
                        (apply string-append (map token-text (vector-ref trails-vec ln)))
                        new-text)]))
                 edits))))

     (cond
       [(null? edits)
        (repair-result source #f '() 'high '())]
       [else
        (define has-unclosed-string?
          (for/or ([tok (in-list tokens)])
            (and (eq? (token-type tok) 'string)
                 (not (string-suffix? (token-text tok) "\"")))))
        (define sorted (sort edits > #:key repair-edit-offset))
        (define repaired (apply-edits source sorted))
        (repair-result repaired
                       (not (string=? repaired source))
                       sorted
                       (if has-unclosed-string? 'low 'high)
                       '())])]))

(define (list->set lst)
  (let ([s (make-hasheq)])
    (for ([x (in-list lst)]) (hash-set! s x #t))
    s))

(define (set-member? s x) (hash-ref s x #f))

;; ============================================================================
;; Main repair — tries parinfer first, falls back to heuristic
;; ============================================================================

(define (repair source)
  (define tokens (tokenize source))
  (define result (scan-delimiters tokens))
  (define problems (scan-result-problems result))

  (cond
    [(null? problems)
     (repair-result source #f '() 'high '())]

    [else
     (define parinfer-result (parinfer-indent-repair source))
     (cond
       [(and (repair-result-changed? parinfer-result)
             (let ([check (scan-delimiters (tokenize (repair-result-output parinfer-result)))])
               (null? (scan-result-problems check))))
        parinfer-result]
       [else
        (heuristic-repair source tokens problems)])]))

;; ============================================================================
;; Heuristic repair — fallback for when parinfer can't fix it
;; ============================================================================

(define (heuristic-repair source tokens problems)
  (define edits '())
  (define unclosed-openers '())

  (for ([p (in-list problems)])
    (case (scan-problem-type p)
      [(mismatch)
       (define opener (scan-problem-opener p))
       (define bad-closer (scan-problem-closer p))
       (define correct-type (matching-closer-type (token-type opener)))
       (define correct-text (closer-text correct-type))
       (set! edits
         (cons (repair-edit
                (token-offset bad-closer)
                (string-length (token-text bad-closer))
                correct-text
                (token-line bad-closer) (token-col bad-closer)
                (format "~a should close ~a from ~a:~a"
                        (token-text bad-closer)
                        (opener-text (token-type opener))
                        (token-line opener) (token-col opener)))
               edits))]

      [(extra-closer)
       (define bad-closer (scan-problem-closer p))
       (define off (token-offset bad-closer))
       (define ws-start
         (let loop ([i (sub1 off)])
           (if (and (>= i 0) (char=? (string-ref source i) #\space))
               (loop (sub1 i))
               (add1 i))))
       (set! edits
         (cons (repair-edit
                ws-start
                (+ (- off ws-start) (string-length (token-text bad-closer)))
                ""
                (token-line bad-closer) (token-col bad-closer)
                (format "unmatched ~a" (token-text bad-closer)))
               edits))]

      [(unclosed)
       (set! unclosed-openers (cons (scan-problem-opener p) unclosed-openers))]))

  (set! unclosed-openers (reverse unclosed-openers))

  (when (pair? unclosed-openers)
    (define insertions (infer-closer-positions tokens unclosed-openers (string-length source)))
    (for ([ins (in-list insertions)])
      (define opener (closer-insertion-opener-token ins))
      (set! edits
        (cons (repair-edit
               (closer-insertion-offset ins)
               0
               (closer-insertion-closer-text ins)
               (closer-insertion-line ins) (closer-insertion-col ins)
               (format "close ~a from ~a:~a"
                       (opener-text (token-type opener))
                       (token-line opener) (token-col opener)))
              edits))))

  (define has-unclosed-string?
    (for/or ([tok (in-list tokens)])
      (and (eq? (token-type tok) 'string)
           (not (string-suffix? (token-text tok) "\"")))))

  (define confidence
    (cond
      [has-unclosed-string? 'low]
      [(> (length edits) 10) 'low]
      [else 'high]))

  (when (eq? confidence 'low)
    (define low-diags
      (for/list ([p (in-list problems)])
        (define tok (or (scan-problem-closer p) (scan-problem-opener p)))
        (structural-diagnostic
         'error
         (token-line tok) (token-col tok)
         (token-line tok) (+ (token-col tok) (string-length (token-text tok)))
         (case (scan-problem-type p)
           [(mismatch) (format "~a does not match ~a at ~a:~a"
                               (token-text (scan-problem-closer p))
                               (token-text (scan-problem-opener p))
                               (token-line (scan-problem-opener p))
                               (token-col (scan-problem-opener p)))]
           [(extra-closer) (format "unmatched ~a" (token-text (scan-problem-closer p)))]
           [(unclosed) (format "unclosed ~a" (token-text (scan-problem-opener p)))])
         (hasheq))))
    (repair-result source #f '() 'low low-diags))

  (define sorted-edits (sort (reverse edits) > #:key repair-edit-offset))
  (define merged-edits (merge-same-offset-inserts sorted-edits))
  (define repaired (apply-edits source merged-edits))

  (repair-result repaired
                 (not (string=? repaired source))
                 merged-edits
                 confidence
                 '()))

(define (merge-same-offset-inserts edits)
  (cond
    [(or (null? edits) (null? (cdr edits))) edits]
    [else
     (define grouped (make-hash))
     (define non-inserts '())
     (define insert-order '())

     (for ([e (in-list edits)])
       (cond
         [(= (repair-edit-length e) 0)
          (define off (repair-edit-offset e))
          (unless (hash-has-key? grouped off)
            (set! insert-order (cons off insert-order)))
          (hash-update! grouped off
            (lambda (prev) (cons e prev))
            '())]
         [else
          (set! non-inserts (cons e non-inserts))]))

     (define merged-inserts
       (for/list ([off (in-list (reverse insert-order))])
         (define group (reverse (hash-ref grouped off)))
         (if (= (length group) 1)
             (car group)
             (repair-edit
              off 0
              (apply string-append (map repair-edit-insert-text group))
              (repair-edit-line (car group))
              (repair-edit-col (car group))
              (string-join (map repair-edit-reason group) "; ")))))

     (sort (append (reverse non-inserts) merged-inserts) > #:key repair-edit-offset)]))

(define (apply-edits source edits)
  (define sorted (sort edits > #:key repair-edit-offset))
  (define result source)
  (for ([e (in-list sorted)])
    (define off (repair-edit-offset e))
    (define len (repair-edit-length e))
    (define ins (repair-edit-insert-text e))
    (define before (if (> off 0) (substring result 0 off) ""))
    (define after (if (< (+ off len) (string-length result))
                      (substring result (+ off len))
                      ""))
    (set! result (string-append before ins after)))
  result)
