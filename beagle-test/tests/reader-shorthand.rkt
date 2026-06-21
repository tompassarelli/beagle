#lang racket/base

;; #(...) anonymous-fn reader shorthand — added 2026-06-12.
;; The rewrite happens at read time (fn-shorthand->fn in
;; beagle-lib/lang/reader-impl.rkt); these tests pin the datum shape the
;; reader produces and the sibling dispatches (#{...}, #"...") it must
;; not disturb.

(require rackunit
         beagle/lang/reader-impl)

(define (rd s) (beagle-read (open-input-string s)))

(test-case "#() with bare % reads as single-param fn"
  (check-equal? (rd "#(inc %)")
                '(fn (#%brackets %1) (inc %1))))

(test-case "#() positional placeholders set arity by max index"
  (check-equal? (rd "#(+ %1 %2)")
                '(fn (#%brackets %1 %2) (+ %1 %2))))

(test-case "#() %2 alone still declares two params"
  (check-equal? (rd "#(str %2)")
                '(fn (#%brackets %1 %2) (str %2))))

(test-case "#() rest placeholder %&"
  (check-equal? (rd "#(apply + %1 %&)")
                '(fn (#%brackets %1 & %&) (apply + %1 %&))))

(test-case "#() zero placeholders is a thunk"
  (check-equal? (rd "#(rand)")
                '(fn (#%brackets) (rand))))

(test-case "#() placeholders inside nested containers are found"
  (check-equal? (rd "#(assoc {} :k %)")
                '(fn (#%brackets %1) (assoc (#%map) :k %1))))

(test-case "nested #() is rejected with a pointed error"
  (check-exn #rx"nested"
             (lambda () (rd "#(map #(inc %) xs)"))))

(test-case "#{...} still reads as a set"
  (check-equal? (rd "#{1 2}") '(#%set 1 2)))

(test-case "#\"...\" still reads as a regex literal"
  (check-equal? (rd "#\"a+\"") '(#%regex "a+")))

(test-case "#?() reader conditional still reads"
  (check-equal? (rd "#?(:clj 1 :nix 2)")
                '(reader-conditional :clj 1 :nix 2)))

;; --- ^ metadata reader (added for dynamic vars) --------------------------
;; `^META FORM` → (#%meta META FORM), matching Clojure's metadata reader.
;; The `#%meta` consumers (def/defn name arms, expression with-meta) already
;; existed; this macro wires the previously-missing producer.

(test-case "^:dynamic on a def reads as #%meta"
  (check-equal? (rd "(def ^:dynamic *x* nil)")
                '(def (#%meta :dynamic *x*) nil)))

(test-case "^:keyword metadata shorthand reads keyword value"
  (check-equal? (rd "^:dynamic *x*")
                '(#%meta :dynamic *x*)))

(test-case "^{:map} metadata longhand reads the map"
  (check-equal? (rd "^{:dynamic true} *x*")
                '(#%meta (#%map :dynamic true) *x*)))

(test-case "^:private on defn name reads as #%meta (activates private arm)"
  (check-equal? (rd "(defn ^:private f [x] x)")
                '(defn (#%meta :private f) (#%brackets x) x)))

(test-case "^ with no following form errors"
  (check-exn #rx"metadata"
             (lambda () (rd "^:dynamic"))))
