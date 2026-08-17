#lang racket/base

(require rackunit
         racket/list
         racket/set
         "../../beagle-lib/private/ast.rkt")

(define (identifier name scopes)
  (make-syntax-ident name #f scopes #f #hasheq()))

(define (local-name name)
  (make-structural-name #f name))

(define (binding stable name scopes kind)
  (scope-binding (make-binding-id stable) name scopes kind))

(define (table-with bindings)
  (for/fold ([table empty-binding-table])
            ([entry (in-list bindings)])
    (binding-table-add table entry)))

(define (add-scopes base extras)
  (for/fold ([scopes base])
            ([extra (in-list extras)])
    (scope-set-add scopes extra)))

(define (fresh-noise trial kind)
  (for/list ([_ (in-range (modulo trial 7))])
    (fresh-scope-id kind)))

(define (in-trial-order trial entries)
  (if (even? trial) entries (reverse entries)))

(test-case "fresh scopes use identity, and flip is an involution"
  (for ([trial (in-range 128)])
    (define left (fresh-scope-id 'macro-introduction))
    (define right (fresh-scope-id 'macro-introduction))
    (define original (scope-set left))
    (check-not-eq? left right (format "trial ~a" trial))
    (check-true (scope-set-member? original left))
    (check-false (scope-set-member? original right))
    (check-equal? (scope-set-flip (scope-set-flip original right) right)
                  original)))

(test-case "macro-introduced binding cannot capture a use-site identifier"
  (for ([trial (in-range 128)])
    (define shared (fresh-scope-id 'outer-lexical))
    (define use-site (fresh-scope-id 'use-site))
    (define introduction (fresh-scope-id 'macro-introduction))
    (define caller-scopes (scope-set shared use-site))
    (define introduced-scopes (scope-set shared introduction))
    (define caller-id (make-binding-id (format "caller:~a" trial)))
    (define macro-id (make-binding-id (format "macro:~a" trial)))
    (define name (local-name 'tmp))
    (define table
      (table-with
       (in-trial-order
        trial
        (list (scope-binding caller-id name caller-scopes 'let)
              (scope-binding macro-id name introduced-scopes 'macro)))))
    (define caller-occurrence
      (identifier
       name
       (add-scopes caller-scopes (fresh-noise trial 'occurrence-only))))
    (check-equal? (resolve-scoped-identifier table caller-occurrence)
                  (resolution-resolved caller-id))))

(test-case "use-site binding cannot capture a macro-introduced identifier"
  (for ([trial (in-range 128)])
    (define shared (fresh-scope-id 'outer-lexical))
    (define use-site (fresh-scope-id 'use-site))
    (define introduction (fresh-scope-id 'macro-introduction))
    (define caller-scopes (scope-set shared use-site))
    (define introduced-scopes (scope-set shared introduction))
    (define caller-id (make-binding-id (format "caller:~a" trial)))
    (define macro-id (make-binding-id (format "macro:~a" trial)))
    (define name (local-name 'tmp))
    (define table
      (table-with
       (in-trial-order
        trial
        (list (scope-binding caller-id name caller-scopes 'let)
              (scope-binding macro-id name introduced-scopes 'macro)))))
    (define introduced-occurrence
      (identifier
       name
       (add-scopes introduced-scopes (fresh-noise trial 'generated-only))))
    (check-equal? (resolve-scoped-identifier table introduced-occurrence)
                  (resolution-resolved macro-id))))

(test-case "nested definition contexts choose the largest subset"
  (for ([trial (in-range 128)])
    (define root (fresh-scope-id 'module))
    (define outer-context (fresh-scope-id 'definition-context))
    (define inner-context (fresh-scope-id 'definition-context))
    (define root-scopes (scope-set root))
    (define outer-scopes (scope-set root outer-context))
    (define inner-scopes (scope-set root outer-context inner-context))
    (define root-id (make-binding-id (format "root:~a" trial)))
    (define outer-id (make-binding-id (format "outer:~a" trial)))
    (define inner-id (make-binding-id (format "inner:~a" trial)))
    (define name (local-name 'item))
    (define table
      (table-with
       (in-trial-order
        trial
        (list (scope-binding root-id name root-scopes 'definition)
              (scope-binding outer-id name outer-scopes 'definition)
              (scope-binding inner-id name inner-scopes 'definition)))))
    (define noise (fresh-noise trial 'occurrence-only))
    (check-equal?
     (resolve-scoped-identifier
      table (identifier name (add-scopes root-scopes noise)))
     (resolution-resolved root-id))
    (check-equal?
     (resolve-scoped-identifier
      table (identifier name (add-scopes outer-scopes noise)))
     (resolution-resolved outer-id))
    (check-equal?
     (resolve-scoped-identifier
      table (identifier name (add-scopes inner-scopes noise)))
     (resolution-resolved inner-id))))

(test-case "incomparable maximal subsets are ambiguous, not cardinality-ranked"
  (for ([trial (in-range 128)])
    (define root (fresh-scope-id 'module))
    (define left (fresh-scope-id 'definition-context))
    (define left-extra (fresh-scope-id 'definition-context))
    (define right (fresh-scope-id 'definition-context))
    (define left-id (make-binding-id (format "left:~a" trial)))
    (define right-id (make-binding-id (format "right:~a" trial)))
    (define name (local-name 'item))
    (define table
      (table-with
       (in-trial-order
        trial
        (list
         (binding (format "root:~a" trial) name (scope-set root) 'definition)
         (scope-binding left-id name (scope-set root left left-extra) 'definition)
         (scope-binding right-id name (scope-set root right) 'definition)))))
    (define result
      (resolve-scoped-identifier
       table (identifier name (scope-set root left left-extra right))))
    (check-equal?
     result
     (resolution-ambiguous name (set left-id right-id)))))

(test-case "structural names attach without rendering or reparsing"
  (for ([trial (in-range 128)])
    (define lexical (fresh-scope-id 'lexical))
    (define binding-name
      (make-structural-name 'models 'Widget (list 'provider trial)))
    (define occurrence-name
      (make-structural-name 'models 'Widget (list 'provider trial)))
    (check-not-eq? binding-name occurrence-name)
    (define id (make-binding-id (format "qualified:~a" trial)))
    (define table
      (binding-table-add
       empty-binding-table
       (scope-binding id binding-name (scope-set lexical) 'import)))
    (check-equal?
     (resolve-scoped-identifier
      table (identifier occurrence-name (scope-set lexical)))
     (resolution-resolved id))))

(test-case "unbound names and missing binding scopes stay unbound"
  (for ([trial (in-range 128)])
    (define binding-scope (fresh-scope-id 'lexical))
    (define other-scope (fresh-scope-id 'lexical))
    (define name (local-name 'item))
    (define table
      (binding-table-add
       empty-binding-table
       (binding
        (format "bound:~a" trial) name (scope-set binding-scope) 'let)))
    (define other-name (local-name 'other))
    (check-equal?
     (resolve-scoped-identifier
      table (identifier other-name (scope-set binding-scope)))
     (resolution-unbound other-name))
    (check-equal?
     (resolve-scoped-identifier
      table (identifier name (scope-set other-scope)))
     (resolution-unbound name))))

(test-case "duplicate structural name and scope set is rejected"
  (define lexical (fresh-scope-id 'lexical))
  (define name (local-name 'item))
  (define table
    (binding-table-add
     empty-binding-table
     (binding "first" name (scope-set lexical) 'let)))
  (check-exn
   #rx"duplicate binding"
   (lambda ()
     (binding-table-add
      table (binding "second" name (scope-set lexical) 'let)))))
