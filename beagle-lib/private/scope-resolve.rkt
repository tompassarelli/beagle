#lang racket/base

;; One-phase sets-of-scopes expansion and lexical resolution.  Source syntax
;; receives lexical scopes before a macro invocation runs.  The expander's
;; introduction flip therefore leaves generated identifiers outside use-site
;; binders while exact antiquoted syntax keeps its caller scopes.

(require racket/list
         racket/set
         racket/string
         "ast.rkt"
         "macros.rkt"
         "tags.rkt"
         "types.rkt")

(provide expand-and-resolve-program
         current-scope-expansion-error-handler
         (struct-out exn:fail:scope-resolution)
         (struct-out exn:fail:duplicate-parameter))

(struct exn:fail:scope-resolution exn:fail (identifier binding-ids)
  #:transparent)

(struct exn:fail:duplicate-parameter exn:fail (identifier)
  #:transparent)

(define current-scope-expansion-error-handler
  (make-parameter (lambda (failure _call-syntax) (raise failure))))

(define META-HEADS
  '(define-target ns require import declare-extern defmacro defalias))

(define (syntax-datum value)
  (and (beagle-syntax? value) (beagle-syntax->datum value)))

(define (sequence-children value)
  (cond
    [(syntax-list? value) (syntax-list-children value)]
    [(syntax-vector? value) (syntax-vector-children value)]
    [else #f]))

(define (rebuild-sequence value children)
  (cond
    [(syntax-list? value)
     (make-syntax-list
      children
      (beagle-syntax-span value)
      (beagle-syntax-scopes value)
      (beagle-syntax-origin value)
      (beagle-syntax-properties value))]
    [(syntax-vector? value)
     (make-syntax-vector
      children
      (beagle-syntax-span value)
      (beagle-syntax-scopes value)
      (beagle-syntax-origin value)
      (beagle-syntax-properties value))]
    [else value]))

(define (syntax-add-scope value scope)
  (define scopes (scope-set-add (beagle-syntax-scopes value) scope))
  (define span (beagle-syntax-span value))
  (define origin (beagle-syntax-origin value))
  (define properties (beagle-syntax-properties value))
  (cond
    [(syntax-ident? value)
     (make-syntax-ident
      (syntax-ident-name value) span scopes origin properties)]
    [(syntax-list? value)
     (make-syntax-list
      (map (lambda (child) (syntax-add-scope child scope))
           (syntax-list-children value))
      span scopes origin properties)]
    [(syntax-vector? value)
     (make-syntax-vector
      (map (lambda (child) (syntax-add-scope child scope))
           (syntax-vector-children value))
      span scopes origin properties)]
    [(syntax-unquote? value)
     (make-syntax-unquote
      (syntax-add-scope (syntax-unquote-child value) scope)
      span scopes origin properties
      #:splicing? (syntax-unquote-splicing? value))]
    [(syntax-quote? value)
     (make-syntax-quote
      (syntax-quote-datum value) span scopes origin properties)]
    [(syntax-atom? value)
     (make-syntax-atom
      (syntax-atom-datum value) span scopes origin properties)]))

(define (syntax-add-scopes value scopes)
  (for/fold ([result value]) ([scope (in-list scopes)])
    (syntax-add-scope result scope)))

(define (path->text path)
  (string-join (map number->string path) "."))

(define (stable-binding-id identifier path kind)
  (define span (beagle-syntax-span identifier))
  (define name (structural-name->symbol (syntax-ident-name identifier)))
  (make-binding-id
   (format
    "~a:~a:~a:~a"
    (if (beagle-syntax-origin identifier)
        (string->symbol (format "introduced-~a" kind))
        kind)
    (if span (or (src-loc-source span) "generated") "generated")
    (path->text path)
    (symbol->string name))))

(define (syntax-ident-with-binding identifier id)
  (make-syntax-ident
   (syntax-ident-name identifier)
   (syntax-ident-span identifier)
   (syntax-ident-scopes identifier)
   (syntax-ident-origin identifier)
   (hash-set (syntax-ident-properties identifier) 'binding-id id)))

(define (bind-identifier identifier table kind path)
  (define id (stable-binding-id identifier path kind))
  (define bound (syntax-ident-with-binding identifier id))
  (values
   bound
   (binding-table-add
    table
    (scope-binding
     id
     (syntax-ident-name bound)
     (syntax-ident-scopes bound)
     kind))
   (hasheq (structural-name-leaf (syntax-ident-name bound)) id)))

(define (merge-identities left right)
  (for/fold ([result left]) ([(name id) (in-hash right)])
    (when (hash-has-key? result name)
      (raise-arguments-error
       'scope-resolve "binding target repeats a name" "name" name))
    (hash-set result name id)))

(define (bind-target value table scope kind path)
  (define scoped (syntax-add-scope value scope))
  (cond
    [(syntax-ident? scoped)
     (define leaf (structural-name-leaf (syntax-ident-name scoped)))
     (if (eq? leaf '&)
         (values scoped table #hasheq())
         (bind-identifier scoped table kind path))]
    [(syntax-vector? scoped)
     (define-values (children next-table identities)
       (for/fold ([out '()] [current table] [ids #hasheq()])
                 ([child (in-list (syntax-vector-children scoped))]
                  [index (in-naturals)])
         (define datum (syntax-datum child))
         (cond
           [(eq? datum '&)
            (values (cons child out) current ids)]
           [else
            (define-values (bound table* ids*)
              (bind-target child current scope kind (append path (list index))))
            (values
             (cons bound out) table* (merge-identities ids ids*))])))
     (values
      (rebuild-sequence scoped (reverse children)) next-table identities)]
    [(and (syntax-list? scoped)
          (eq? (syntax-datum (car (syntax-list-children scoped))) MAP-TAG))
     (define children (syntax-list-children scoped))
     (define-values (rendered next-table identities)
       (let loop ([rest (cdr children)]
                  [index 1]
                  [out (list (car children))]
                  [current table]
                  [ids #hasheq()])
         (cond
           [(null? rest) (values out current ids)]
           [(and (memq (syntax-datum (car rest)) '(:keys :as))
                 (pair? (cdr rest)))
            (define-values (bound table* ids*)
              (bind-target
               (cadr rest) current scope kind (append path (list (add1 index)))))
            (loop
             (cddr rest) (+ index 2) (append out (list (car rest) bound))
             table* (merge-identities ids ids*))]
           [(and (eq? (syntax-datum (car rest)) ':or)
                 (pair? (cdr rest)))
            (loop
             (cddr rest)
             (+ index 2)
             (append
              out
              (list
               (car rest)
               (walk (cadr rest) current (append path (list (add1 index))) #f)))
             current ids)]
           [else
            (loop (cdr rest) (add1 index) (append out (list (car rest)))
                  current ids)])))
     (values
      (rebuild-sequence scoped rendered) next-table identities)]
    [else (values scoped table #hasheq())]))

(define (typed-declaration? value)
  (define datum (syntax-datum value))
  (and (syntax-list? value)
       (list? datum)
       (memv (length datum) '(2 3))
       (not (memq (car datum) (list BRACKET-TAG MAP-TAG SET-TAG)))
       (or (symbol? (car datum))
           (and (pair? (car datum))
                (memq (caar datum) (list BRACKET-TAG MAP-TAG))))))

(define (bind-declaration value table scope kind path)
  (cond
    [(typed-declaration? value)
     (define children (syntax-list-children value))
     (define-values (target table* identities)
       (bind-target (car children) table scope kind (append path (list 0))))
     (define constraint
       (and (= (length children) 3)
            (walk (caddr children) table (append path (list 2)) #f)))
     (values
      (rebuild-sequence
       value
       (append (list target (cadr children)) (if constraint (list constraint) '())))
      table*
      identities)]
    [else (bind-target value table scope kind path)]))

(define (resolve-identifier identifier table)
  (define resolution (resolve-scoped-identifier table identifier))
  (cond
    [(resolution-resolved? resolution)
     (syntax-ident-with-binding
      identifier (resolution-resolved-binding-id resolution))]
    [(resolution-unbound? resolution) identifier]
    [else
     (raise
      (exn:fail:scope-resolution
       (format
        "ambiguous lexical reference ~a"
        (structural-name->symbol (syntax-ident-name identifier)))
       (current-continuation-marks)
       identifier
       (resolution-ambiguous-binding-ids resolution)))]))

(define (walk-generic-sequence value table path ctx)
  (rebuild-sequence
   value
   (for/list ([child (in-list (sequence-children value))]
              [index (in-naturals)])
     (walk child table (append path (list index)) ctx))))

(define (walk-sequential-bindings vector-value table path ctx)
  (define items (sequence-children vector-value))
  (define flat?
    (and (pair? items)
         (pair? (cdr items))
         (type-expression-datum? (syntax-datum (cadr items)))))
  (let loop ([rest items]
             [index 0]
             [out '()]
             [current table]
             [region-scopes '()])
    (cond
      [(null? rest)
       (values
        (rebuild-sequence vector-value out) current region-scopes)]
      [(or (null? (cdr rest))
           (and flat? (null? (cddr rest))))
       (values
        (rebuild-sequence
         vector-value
         (append out
                 (for/list ([item (in-list rest)]
                            [offset (in-naturals index)])
                   (walk
                    (syntax-add-scopes item region-scopes)
                    current (append path (list offset)) ctx))))
        current
        region-scopes)]
      [else
       (define declaration
         (syntax-add-scopes (car rest) region-scopes))
       (define rhs-offset (if flat? 2 1))
       (define rhs
         (walk
          (syntax-add-scopes (list-ref rest rhs-offset) region-scopes)
          current (append path (list (+ index rhs-offset))) ctx))
       (define scope (fresh-scope-id 'lexical))
       (define-values (bound table* _ids)
         (bind-declaration
          declaration current scope 'lexical (append path (list index))))
       (loop
        (if flat? (cdddr rest) (cddr rest))
        (+ index (if flat? 3 2))
        (append out
                (if flat?
                    (list bound (cadr rest) rhs)
                    (list bound rhs)))
        table*
        (append region-scopes (list scope)))])))

(define (walk-let-like value table path ctx)
  (define children (syntax-list-children value))
  (define-values (bindings body-table scopes)
    (walk-sequential-bindings
     (cadr children) table (append path (list 1)) ctx))
  (rebuild-sequence
   value
   (append
    (list (walk (car children) table (append path (list 0)) ctx) bindings)
    (for/list ([body (in-list (cddr children))]
               [index (in-naturals 2)])
      (walk
       (syntax-add-scopes body scopes)
       body-table (append path (list index)) ctx)))))

(define (walk-params params table path ctx)
  (define (target-bound-names value)
    (cond
      [(syntax-ident? value)
       (define leaf (structural-name-leaf (syntax-ident-name value)))
       (if (eq? leaf '&) '() (list leaf))]
      [(syntax-vector? value)
       (append-map target-bound-names (syntax-vector-children value))]
      [(and (syntax-list? value)
            (let ([children (syntax-list-children value)])
              (and (pair? children)
                   (eq? (syntax-datum (car children)) MAP-TAG))))
       (let loop ([rest (cdr (syntax-list-children value))] [names '()])
         (cond
           [(null? rest) names]
           [(and (memq (syntax-datum (car rest)) '(:keys :as))
                 (pair? (cdr rest)))
            (loop (cddr rest)
                  (append names (target-bound-names (cadr rest))))]
           [(and (eq? (syntax-datum (car rest)) ':or)
                 (pair? (cdr rest)))
            (loop (cddr rest) names)]
           [else (loop (cdr rest) names)]))]
      [else '()]))
  (define (declaration-bound-names value)
    (if (typed-declaration? value)
        (target-bound-names (car (syntax-list-children value)))
        (target-bound-names value)))
  (define items (sequence-children params))
  (define declarations
    (filter (lambda (item) (not (eq? (syntax-datum item) '&))) items))
  (define first-declaration
    (and (pair? declarations) (car declarations)))
  (define legacy? (and first-declaration (typed-declaration? first-declaration)))
  (define flat?
    (and (not legacy?)
         (pair? declarations)
         (pair? (cdr declarations))
         (type-expression-datum? (syntax-datum (cadr declarations)))))
  (define logical-declarations
    (if (or legacy? (not flat?))
        (filter (lambda (item) (not (eq? (syntax-datum item) '&))) items)
        (let loop ([rest items] [out '()])
          (cond
            [(null? rest) (reverse out)]
            [(eq? (syntax-datum (car rest)) '&)
             (loop (cdr rest) out)]
            [else
             (loop (if (pair? (cdr rest)) (cddr rest) '())
                   (cons (car rest) out))]))))
  (define duplicate
    (for*/fold ([seen (seteq)] [found #f] #:result found)
               ([item (in-list logical-declarations)]
                [name (in-list (declaration-bound-names item))])
      (values (set-add seen name)
              (or found (and (set-member? seen name) name)))))
  (when duplicate
    (raise
     (exn:fail:duplicate-parameter
      (format
       "parameter list binds `~a` more than once; every nested destructuring name and :as alias must be unique"
       duplicate)
      (current-continuation-marks)
      duplicate)))
  (define scope (fresh-scope-id 'parameter))
  (define-values (rendered body-table identities)
    (if (or legacy? (not flat?))
        (for/fold ([out '()] [current table] [ids #hasheq()])
                  ([item (in-list items)] [index (in-naturals)])
          (cond
            [(eq? (syntax-datum item) '&)
             (values (append out (list item)) current ids)]
            [else
             (define-values (bound table* ids*)
               (bind-declaration
                item current scope 'parameter (append path (list index))))
             (values
              (append out (list bound)) table*
              (merge-identities ids ids*))]))
        (let loop ([rest items]
                   [index 0]
                   [out '()]
                   [current table]
                   [ids #hasheq()])
          (cond
            [(null? rest) (values out current ids)]
            [(eq? (syntax-datum (car rest)) '&)
             (loop (cdr rest) (add1 index)
                   (append out (list (car rest))) current ids)]
            [else
             (define-values (bound table* ids*)
               (bind-declaration
                (car rest) current scope 'parameter (append path (list index))))
             (if (pair? (cdr rest))
                 (loop (cddr rest) (+ index 2)
                       (append out (list bound (cadr rest))) table*
                       (merge-identities ids ids*))
                 (values (append out (list bound)) table*
                         (merge-identities ids ids*)))]))))
  (values (rebuild-sequence params rendered) body-table scope identities))

(define (walk-function-clause clause table path ctx)
  (define children (and (syntax-list? clause) (syntax-list-children clause)))
  (cond
    [(and (pair? children) (syntax-vector? (car children)))
     (define-values (params body-table param-scope _ids)
       (walk-params (car children) table (append path (list 0)) ctx))
     (rebuild-sequence
      clause
      (for/list ([child (in-list children)] [index (in-naturals)])
        (cond
          [(zero? index) params]
          [(= index 1) child]
          [else
           (walk
            (syntax-add-scope child param-scope)
            body-table (append path (list index)) ctx)])))]
    [else (walk-generic-sequence clause table path ctx)]))

(define (walk-function value table path ctx #:name-index [name-index #f])
  (define children (syntax-list-children value))
  (define params-index (add1 (or name-index 0)))
  (cond
    [(or (>= params-index (length children))
         (not (sequence-children (list-ref children params-index))))
     (walk-generic-sequence value table path ctx)]
    [(and
      (syntax-list? (list-ref children params-index))
      (for/and ([clause (in-list (drop children params-index))])
        (and (syntax-list? clause)
             (let ([clause-children (syntax-list-children clause)])
               (and (pair? clause-children)
                    (syntax-vector? (car clause-children)))))))
     ;; Multi-arity functions give every clause its own parameter scope.  A
     ;; shared scope would make repeated authored parameter names duplicate
     ;; keys even though the clauses are disjoint lexical regions.
     (rebuild-sequence
      value
      (for/list ([child (in-list children)] [index (in-naturals)])
        (if (>= index params-index)
            (walk-function-clause
             child table (append path (list index)) ctx)
            (walk child table (append path (list index)) ctx))))]
    [else
     (define-values (params body-table param-scope _ids)
       (walk-params
        (list-ref children params-index)
        table
        (append path (list params-index))
        ctx))
     (define return-index (add1 params-index))
     (rebuild-sequence
      value
      (for/list ([child (in-list children)] [index (in-naturals)])
        (cond
          [(= index params-index) params]
          [(= index return-index) child]
          [(> index return-index)
           (walk
            (syntax-add-scope child param-scope)
            body-table (append path (list index)) ctx)]
          [else (walk child table (append path (list index)) ctx)])))]))

(define (walk-letfn value table path ctx)
  (define children (syntax-list-children value))
  (define functions (cadr children))
  (define scope (fresh-scope-id 'letfn))
  (define-values (named group-table)
    (for/fold ([out '()] [current table])
              ([fn-value (in-list (sequence-children functions))]
               [index (in-naturals)])
      (define fn-children (syntax-list-children fn-value))
      (define-values (name table* _ids)
        (bind-target
         (car fn-children) current scope 'letfn
         (append path (list 1 index 0))))
      (values
       (append
        out
        (list (rebuild-sequence fn-value (cons name (cdr fn-children)))))
       table*)))
  (define rendered-functions
    (rebuild-sequence
     functions
     (for/list ([fn-value (in-list named)] [index (in-naturals)])
       (walk-function
        (syntax-add-scope fn-value scope)
        group-table (append path (list 1 index)) ctx #:name-index 0))))
  (rebuild-sequence
   value
   (append
    (list (walk (car children) table (append path (list 0)) ctx)
          rendered-functions)
    (for/list ([body (in-list (cddr children))]
               [index (in-naturals 2)])
      (walk
       (syntax-add-scope body scope)
       group-table (append path (list index)) ctx)))))

(define (walk-for-like value table path ctx)
  (define children (syntax-list-children value))
  (define clauses (cadr children))
  (define items (sequence-children clauses))
  (define-values (rendered body-table scopes)
    (let loop ([rest items]
               [index 0]
               [out '()]
               [current table]
               [region-scopes '()])
      (cond
        [(null? rest) (values out current region-scopes)]
        [(and (memq (syntax-datum (car rest)) '(:when :while))
              (pair? (cdr rest)))
         (loop
          (cddr rest) (+ index 2)
          (append
           out
           (list
            (car rest)
            (walk
             (syntax-add-scopes (cadr rest) region-scopes)
             current (append path (list 1 (add1 index))) ctx)))
          current region-scopes)]
        [(and (eq? (syntax-datum (car rest)) ':let)
              (pair? (cdr rest))
              (syntax-vector? (cadr rest)))
         (define nested
           (syntax-add-scopes (cadr rest) region-scopes))
         (define-values (bindings table* nested-scopes)
           (walk-sequential-bindings
            nested current (append path (list 1 (add1 index))) ctx))
         (loop
          (cddr rest) (+ index 2)
          (append out (list (car rest) bindings))
          table*
          (append region-scopes nested-scopes))]
        [(pair? (cdr rest))
         (define declaration
           (syntax-add-scopes (car rest) region-scopes))
         (define rhs
           (walk
            (syntax-add-scopes (cadr rest) region-scopes)
            current (append path (list 1 (add1 index))) ctx))
         (define scope (fresh-scope-id 'comprehension))
         (define-values (bound table* _ids)
           (bind-declaration
            declaration current scope 'comprehension
            (append path (list 1 index))))
         (loop
          (cddr rest) (+ index 2) (append out (list bound rhs)) table*
          (append region-scopes (list scope)))]
        [else (values (append out rest) current region-scopes)])))
  (rebuild-sequence
   value
   (append
    (list (walk (car children) table (append path (list 0)) ctx)
          (rebuild-sequence clauses rendered))
    (for/list ([body (in-list (cddr children))]
               [index (in-naturals 2)])
      (walk
       (syntax-add-scopes body scopes)
       body-table (append path (list index)) ctx)))))

(define (walk-conditional-binding value table path ctx)
  (define children (syntax-list-children value))
  (define-values (bindings success-table scopes)
    (walk-sequential-bindings
     (cadr children) table (append path (list 1)) ctx))
  (define head (syntax-datum (car children)))
  (rebuild-sequence
   value
   (for/list ([child (in-list children)] [index (in-naturals)])
     (cond
       [(= index 1) bindings]
       [(and (>= index 2)
             (or (memq head '(when-let when-some)) (= index 2)))
        (walk
         (syntax-add-scopes child scopes)
         success-table (append path (list index)) ctx)]
       [else (walk child table (append path (list index)) ctx)]))))

(define (walk-single-binder-form value table path ctx binder-index body-start kind)
  (define children (syntax-list-children value))
  (define scope (fresh-scope-id kind))
  (define-values (binder body-table _ids)
    (bind-declaration
     (list-ref children binder-index)
     table scope kind (append path (list binder-index))))
  (rebuild-sequence
   value
   (for/list ([child (in-list children)] [index (in-naturals)])
     (cond
       [(= index binder-index) binder]
       [(>= index body-start)
        (walk
         (syntax-add-scope child scope)
         body-table (append path (list index)) ctx)]
       [else (walk child table (append path (list index)) ctx)]))))

(define (walk-as-thread value table path ctx)
  (define children (syntax-list-children value))
  (define init (cadr children))
  (define name (caddr children))
  (define steps (cdddr children))
  (define span (beagle-syntax-span value))
  (define scopes (beagle-syntax-scopes value))
  (define origin (beagle-syntax-origin value))
  (define properties (beagle-syntax-properties value))
  (define (generated datum)
    (datum->beagle-syntax datum span scopes origin properties))
  (define (chain values)
    (if (null? values)
        name
        (make-syntax-list
         (list
          (generated 'let)
          (make-syntax-vector
           (list name (car values)) span scopes origin properties)
          (chain (cdr values)))
         span scopes origin properties)))
  (define resolved-expansion
    (walk (chain (cons init steps)) table path ctx))
  ;; The marker's surface copy remains authored syntax.  Only INIT is an
  ;; expression in the surrounding lexical region; NAME and STEPS are kept
  ;; opaque here because the resolved nested-let expansion above is the
  ;; authoritative checked/emitted tree.
  (make-syntax-list
   (append
    (list (car children)
          (walk init table (append path (list 1)) ctx)
          name)
    steps)
   span scopes origin
   (hash-set properties 'as-thread-resolved resolved-expansion)))

(define (walk-pattern pattern table scope path)
  (cond
    [(syntax-ident? pattern)
     (define leaf (structural-name-leaf (syntax-ident-name pattern)))
     (if (eq? leaf '_)
         (values pattern table)
         (let-values ([(bound table* _ids)
                       (bind-target pattern table scope 'pattern path)])
           (values bound table*)))]
    [(syntax-list? pattern)
     (define children (syntax-list-children pattern))
     (define head (and (pair? children) (syntax-datum (car children))))
     (cond
       [(eq? head 'or) (values pattern table)]
       [else
        (define-values (out next-table)
          (for/fold ([result (if (pair? children) (list (car children)) '())]
                     [current table])
                    ([child (in-list (if (pair? children) (cdr children) '()))]
                     [index (in-naturals 1)])
            (define-values (bound table*)
              (walk-pattern child current scope (append path (list index))))
            (values (append result (list bound)) table*)))
        (values (rebuild-sequence pattern out) next-table)])]
    [else (values pattern table)]))

(define (walk-match value table path ctx)
  (define children (syntax-list-children value))
  (rebuild-sequence
   value
   (append
    (list (walk (car children) table (append path (list 0)) ctx)
          (walk (cadr children) table (append path (list 1)) ctx))
    (for/list ([clause (in-list (cddr children))]
               [index (in-naturals 2)])
      (define clause-children (sequence-children clause))
      (define scope (fresh-scope-id 'pattern))
      (define-values (pattern body-table)
        (walk-pattern
         (car clause-children) table scope (append path (list index 0))))
      (rebuild-sequence
       clause
       (cons
        pattern
        (for/list ([body (in-list (cdr clause-children))]
                   [body-index (in-naturals 1)])
          (walk
           (syntax-add-scope body scope)
           body-table (append path (list index body-index)) ctx))))))))

(define (walk value table path ctx)
  (cond
    [(syntax-ident? value) (resolve-identifier value table)]
    [(syntax-quote? value) value]
    [(syntax-unquote? value)
     (make-syntax-unquote
      (walk (syntax-unquote-child value) table (append path (list 0)) ctx)
      (syntax-unquote-span value)
      (syntax-unquote-scopes value)
      (syntax-unquote-origin value)
      (syntax-unquote-properties value)
      #:splicing? (syntax-unquote-splicing? value))]
    [(syntax-vector? value) (walk-generic-sequence value table path ctx)]
    [(syntax-list? value)
     (define raw (syntax-datum value))
     (define head (and (pair? raw) (car raw)))
     (cond
       [(and (symbol? head) (lookup-macro (current-registry) head))
        (define next-ctx
          (if ctx (push-ctx ctx head value) (make-root-ctx head value)))
        (define expanded
          (with-handlers
              ([exn:fail:macro-source?
                (lambda (failure)
                  ((current-scope-expansion-error-handler) failure value))])
            (expand-macro
             (current-registry)
             head
             (cdr (syntax-list-children value))
             next-ctx)))
        (walk expanded table path next-ctx)]
       [(memq head '(let loop with-open))
        (walk-let-like value table path ctx)]
       [(eq? head 'letfn) (walk-letfn value table path ctx)]
       [(memq head '(for doseq)) (walk-for-like value table path ctx)]
       [(memq head '(when-let if-let when-some if-some))
        (walk-conditional-binding value table path ctx)]
       [(eq? head 'fn) (walk-function value table path ctx)]
       [(memq head '(defn defn-))
        (walk-function value table path ctx #:name-index 1)]
       [(eq? head 'catch)
        (walk-single-binder-form value table path ctx 1 2 'catch)]
       [(and (eq? head 'rescue) (= (length raw) 4))
        (walk-single-binder-form value table path ctx 2 3 'rescue)]
       [(and (eq? head 'as->) (>= (length raw) 3))
        (walk-as-thread value table path ctx)]
       ;; JavaScript quote data is owned by the JS parser.  In particular,
       ;; `(let name value)` is a JS declaration, not a Beagle lexical form.
       [(eq? head 'js/quote) value]
       [(eq? head 'match) (walk-match value table path ctx)]
       [else (walk-generic-sequence value table path ctx)])]
    [else value]))

(define (meta-form? value)
  (define datum (syntax-datum value))
  (and (pair? datum) (memq (car datum) META-HEADS)))

(define (scope-program syntax-values module-scope)
  (for/list ([value (in-list syntax-values)])
    (if (meta-form? value) value (syntax-add-scope value module-scope))))

(define (expand-and-resolve-program registry syntax-values)
  (define module-scope (fresh-scope-id 'module))
  (define scoped (scope-program syntax-values module-scope))
  (parameterize ([current-registry registry])
    (for/list ([value (in-list scoped)] [index (in-naturals)])
      (if (meta-form? value)
          value
          (walk value empty-binding-table (list index) #f)))))
