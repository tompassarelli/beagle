#lang racket/base

(require rackunit
         beagle/private/types)

(define INT (type-prim 'Int))
(define FLOAT (type-prim 'Float))
(define STRING (type-prim 'String))
(define ANY (type-prim 'Any))

(test-case "fresh metavariable ids are deterministic within an inference scope"
  (define first
    (call-with-fresh-type-metas
     (lambda () (map type-meta-id (list (fresh-type-meta) (fresh-type-meta))))))
  (define second
    (call-with-fresh-type-metas
     (lambda () (map type-meta-id (list (fresh-type-meta) (fresh-type-meta))))))
  (check-equal? first '(0 1))
  (check-equal? second first))

(test-case "metavariable identity is distinct across deterministic scopes"
  (define first (call-with-fresh-type-metas fresh-type-meta))
  (define second (call-with-fresh-type-metas fresh-type-meta))
  (check-equal? (type-meta-id first) (type-meta-id second))
  (check-false (equal? first second)))

(test-case "metavariable chains prune and zonk to their solution"
  (call-with-fresh-type-metas
   (lambda ()
     (define left (fresh-type-meta))
     (define right (fresh-type-meta))
     (unify-types! left right)
     (unify-types! right INT)
     (check-equal? (prune-type left) INT)
     (check-equal?
      (zonk-type (type-fn (list left) #f (type-app 'Vec (list right))))
      (type-fn (list INT) #f (type-app 'Vec (list INT)))))))

(test-case "Any supplies no inference evidence"
  (call-with-fresh-type-metas
   (lambda ()
     (define meta (fresh-type-meta))
     (unify-types! meta ANY)
     (check-false (type-meta-solution meta))
     (unify-types! ANY meta)
     (check-false (type-meta-solution meta))
     (unify-types! meta INT)
     (check-equal? (prune-type meta) INT))))

(test-case "occurs check rejects infinite types without linking the meta"
  (call-with-fresh-type-metas
   (lambda ()
     (define meta (fresh-type-meta))
     (check-exn
      (lambda (error)
        (and (exn:fail:type-unification? error)
             (regexp-match? #rx"occurs check failed" (exn-message error))))
      (lambda () (unify-types! meta (type-app 'Vec (list meta)))))
     (check-false (type-meta-solution meta)))))

(test-case "unification is structural and retains directional compatibility"
  (call-with-fresh-type-metas
   (lambda ()
     (define element (fresh-type-meta))
     (unify-types! (type-app 'Vec (list element))
                   (type-app 'Vec (list STRING)))
     (check-equal? (prune-type element) STRING)
     (check-not-exn (lambda () (unify-types! INT FLOAT)))
     (check-exn exn:fail:type-unification?
                (lambda () (unify-types! FLOAT INT))))))

(test-case "unification preserves Atom element invariance"
  (define atom-int (type-app 'Atom (list INT)))
  (define atom-any (type-app 'Atom (list ANY)))
  (check-exn exn:fail:type-unification?
             (lambda () (unify-types! atom-int atom-any)))
  (call-with-fresh-type-metas
   (lambda ()
     (define element (fresh-type-meta))
     (unify-types! (type-app 'Atom (list element)) atom-int)
     (check-equal? (prune-type element) INT))))

(test-case "authored type variables remain rigid in the inference solver"
  (check-exn exn:fail:type-unification?
             (lambda () (unify-types! (type-var 'A) INT)))
  ;; Their established compatibility behavior is unchanged outside the solver.
  (check-true (type-compatible? (type-var 'A) INT))
  (check-true (type-compatible? INT (type-var 'A))))

(test-case "generalization follows stable source traversal order"
  (call-with-fresh-type-metas
   (lambda ()
     (define created-first (fresh-type-meta))
     (define created-second (fresh-type-meta))
     (define scheme
       (generalize-type
        (type-fn (list created-second created-first) #f created-second)))
     (check-true (inferred-type-poly? scheme))
     (check-equal? (type-poly-origin scheme) 'inferred)
     (check-equal? (type-poly-vars scheme) '(A B))
     (check-equal? (type->string scheme) "(forall [A B] [A B -> A])"))))

(test-case "generalization avoids capture by authored variable names"
  (call-with-fresh-type-metas
   (lambda ()
     (define meta (fresh-type-meta))
     (define scheme
       (generalize-type (type-fn (list (type-var 'A) meta) #f meta)))
     (check-equal? (type-poly-vars scheme) '(B))
     (check-equal? (type->string scheme) "(forall [B] [A B -> B])"))))

(test-case "environment-owned metas remain monomorphic during generalization"
  (call-with-fresh-type-metas
   (lambda ()
     (define shared (fresh-type-meta))
     (define local (fresh-type-meta))
     (define scheme
       (generalize-type (type-fn (list shared local) #f local)
                        #:excluding (list shared)))
     (check-true (inferred-type-poly? scheme))
     (check-equal? (type-poly-vars scheme) '(A))
     (define body (type-poly-body scheme))
     (check-eq? (car (type-fn-params body)) shared)
     (check-equal? (type-var-name (cadr (type-fn-params body))) 'A))))

(test-case "free metavariables are deduplicated in source order"
  (call-with-fresh-type-metas
   (lambda ()
     (define first (fresh-type-meta))
     (define second (fresh-type-meta))
     (define signature (type-fn (list second first second) #f first))
     (check-equal? (free-type-metas signature) (list second first))
     (check-equal? (free-type-metas-in (list signature (type-app 'Vec (list first))))
                   (list second first)))))

(test-case "explicit Any is preserved and never generalized"
  (define signature (type-fn (list ANY) #f INT))
  (define generalized (generalize-type signature))
  (check-false (type-poly? generalized))
  (check-equal? generalized signature)
  (call-with-fresh-type-metas
   (lambda ()
     (define meta (fresh-type-meta))
     (define scheme (generalize-type (type-fn (list ANY meta) #f meta)))
     (check-true (inferred-type-poly? scheme))
     (check-equal? (car (type-fn-params (type-poly-body scheme))) ANY))))

(test-case "each inferred-scheme instantiation gets independent fresh metas"
  (call-with-fresh-type-metas
   (lambda ()
     (define original (fresh-type-meta))
     (define scheme (generalize-type (type-fn (list original) #f original)))
     (define first (instantiate-type scheme))
     (define second (instantiate-type scheme))
     (define first-meta (car (type-fn-params first)))
     (define second-meta (car (type-fn-params second)))
     (check-true (type-meta? first-meta))
     (check-eq? first-meta (type-fn-ret first))
     (check-eq? second-meta (type-fn-ret second))
     (check-false (eq? first-meta second-meta))
     (unify-types! first-meta INT)
     (check-equal? (prune-type first-meta) INT)
     (check-true (type-meta? (prune-type second-meta))))))

(test-case "explicit forall stays on its authored resolution path"
  (define authored
    (type-poly '(A) (type-fn (list (type-var 'A)) #f (type-var 'A)) #f))
  (check-equal? (type-poly-origin authored) 'authored)
  (check-false (inferred-type-poly? authored))
  (check-eq? (instantiate-type authored) authored))

(test-case "type JSON keeps inference origin private and rejects unsolved metas"
  (call-with-fresh-type-metas
   (lambda ()
     (define meta (fresh-type-meta))
     (check-exn #rx"unresolved inference metavariable escaped type serialization"
                (lambda () (type->jsexpr meta)))
     (define scheme (generalize-type (type-fn (list meta) #f meta)))
     (define json (type->jsexpr scheme))
     (check-false (hash-has-key? json 'origin))
     (check-equal? (hash-ref json 'kind) "poly"))))
