#lang racket/base

(require rackunit
         racket/list
         racket/set
         "../../beagle-lib/private/ast.rkt"
         "../../beagle-lib/private/macros.rkt"
         "../../beagle-lib/private/scope-resolve.rkt")

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

(test-case "reader-produced nested binders resolve to the innermost occurrence edge"
  (define source
    (racket-syntax->beagle-syntax
     (datum->syntax
      #f
      '(let (#%brackets x 1)
         (let (#%brackets x 2) x)))
     #""))
  (define resolved
    (car (expand-and-resolve-program (make-macro-registry) (list source))))
  (define outer-children (syntax-list-children resolved))
  (define outer-binding
    (car (syntax-vector-children (cadr outer-children))))
  (define inner (caddr outer-children))
  (define inner-children (syntax-list-children inner))
  (define inner-binding
    (car (syntax-vector-children (cadr inner-children))))
  (define occurrence (caddr inner-children))
  (define outer-id (beagle-syntax-binding-id outer-binding))
  (define inner-id (beagle-syntax-binding-id inner-binding))
  (check-true (and (binding-id? outer-id) (binding-id? inner-id)))
  (check-not-equal? outer-id inner-id)
  (check-equal? (beagle-syntax-binding-id occurrence) inner-id)
  (check-true
   (scope-set-subset?
    (beagle-syntax-scopes outer-binding)
    (beagle-syntax-scopes inner-binding))))

(define (nested-binding-edges source-position)
  (define span
    (src-loc 1 0 'layout.bclj 'original #f source-position 1))
  (define source
    (datum->beagle-syntax
     '(let (#%brackets x 1)
        (let (#%brackets x 2) x))
     span))
  (define resolved
    (car (expand-and-resolve-program (make-macro-registry) (list source))))
  (define outer-children (syntax-list-children resolved))
  (define outer-binding
    (car (syntax-vector-children (cadr outer-children))))
  (define inner-children
    (syntax-list-children (caddr outer-children)))
  (define inner-binding
    (car (syntax-vector-children (cadr inner-children))))
  (list (beagle-syntax-binding-id outer-binding)
        (beagle-syntax-binding-id inner-binding)
        (beagle-syntax-binding-id (caddr inner-children))))

(test-case "binding edges ignore layout offsets and retain structural identity"
  (define earlier (nested-binding-edges 10))
  (define later (nested-binding-edges 210))
  (define outer-id (car earlier))
  (define inner-id (cadr earlier))
  (check-equal? earlier later)
  (check-equal? (binding-id-stable outer-id)
                "lexical:layout.bclj:0.1.0:x")
  (check-equal? (binding-id-stable inner-id)
                "lexical:layout.bclj:0.2.1.0:x")
  (check-not-equal? outer-id inner-id)
  (check-equal? (caddr earlier) inner-id)
  (check-equal?
   (binding-id-output-symbol
    (make-binding-id "introduced-lexical:layout.bclj:0.2.1.0:tmp")
    'tmp)
   'tmp__scope_0_2_1_0))

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

(test-case "SyntaxIdent survives the Racket adapter with distinct identity axes"
  (define lexical (fresh-scope-id 'lexical))
  (define scopes (scope-set lexical))
  (define span (src-loc 4 6 'fixture 'synthetic #t 31 9))
  (define origin (make-expansion-origin 'introduce span))
  (define provider-id '(provider fixture))
  (define name (make-structural-name 'models 'Widget provider-id))
  (define lexical-id (make-binding-id "fixture:31:Widget"))
  (define properties
    (hasheq 'reader (reader-metadata #"models/Widget" 'atom)
            'binding-id lexical-id
            'custom 'retained))
  (define identifier
    (make-syntax-ident name span scopes origin properties))
  (define restored-form
    (racket-syntax->beagle-syntax
     (beagle-syntax->racket-syntax
      (make-syntax-list (list identifier) span))))
  (define restored (car (syntax-list-children restored-form)))
  (check-equal? (syntax-ident-name restored) name)
  (check-equal? (syntax-ident-scopes restored) scopes)
  (check-equal? (syntax-ident-span restored) span)
  (check-equal? (syntax-ident-origin restored) origin)
  (check-equal? (syntax-ident-properties restored) properties)
  (check-equal?
   (structural-name-provider-id (syntax-ident-name restored))
   provider-id)
  (check-equal? (beagle-syntax-binding-id restored) lexical-id)
  (check-not-equal?
   (structural-name-provider-id (syntax-ident-name restored))
   (beagle-syntax-binding-id restored)))

(test-case "scope, binding, and resolution constructors enforce their contracts"
  (check-exn exn:fail:contract?
             (lambda () (fresh-scope-id "not-a-kind")))
  (check-exn exn:fail:contract?
             (lambda () (make-binding-id 17)))
  (check-equal? (binding-id-stable (make-binding-id 'stable)) "stable")
  (check-exn exn:fail:contract?
             (lambda () (resolution-resolved 'not-a-binding-id)))
  (check-exn exn:fail:contract?
             (lambda () (resolution-unbound 'not-a-structural-name)))
  (check-exn
   exn:fail:contract?
   (lambda ()
     (resolution-ambiguous
      (local-name 'item)
      (set (make-binding-id "only-one"))))))

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
