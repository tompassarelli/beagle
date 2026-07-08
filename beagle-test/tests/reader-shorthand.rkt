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

;; --- EXP-025 G8/G10/G11 reader macros (malli) ----------------------------
;; The reader keeps each as an un-spoofable #%-marker datum; the renderer
;; (facts-roundtrip.rkt) inverts it back to the surface glyph.

;; G8 #_ discard — Clojure DROPS the next form; beagle KEEPS it (text is a view).
(test-case "#_ discard keeps the form as (#%discard …)"
  (check-equal? (rd "[1 #_2 3]")
                '(#%brackets 1 (#%discard 2) 3)))
(test-case "#_ discard of a list form"
  (check-equal? (rd "#_(a b c)")
                '(#%discard (a b c))))
(test-case "#_ with no following form errors"
  (check-exn #rx"discard"
             (lambda () (rd "#_"))))

;; G10 #js tagged literal
(test-case "#js [] reads as (#%js (#%brackets))"
  (check-equal? (rd "#js []") '(#%js (#%brackets))))
(test-case "#js {…} reads as (#%js (#%map …))"
  (check-equal? (rd "#js {:a 1}") '(#%js (#%map :a 1))))
(test-case "#js is guarded — #jsx is NOT the js tagged literal"
  ;; the 3rd char is a symbol constituent, so the js arm must not fire;
  ;; it falls through to the default reader (reads `#jsx…` some other way,
  ;; or errors — either way it is NOT (#%js …)).
  (check-false (equal? (with-handlers ([exn:fail? (lambda (_) 'threw)])
                         (rd "#jsx"))
                       '(#%js x))))

;; G12 #^ legacy metadata shorthand (pre-Clojure-1.2, still legal) — behaves
;; EXACTLY like `^`, producing the same (#%meta …) datum (render normalizes #^ → ^).
(test-case "#^:keyword reads identically to ^:keyword"
  (check-equal? (rd "#^:dynamic *x*") '(#%meta :dynamic *x*)))
(test-case "#^{:map} longhand reads the map, same as ^{…}"
  (check-equal? (rd "#^{:tag String} x") '(#%meta (#%map :tag String) x)))
(test-case "#^String tag reads as (#%meta String …)"
  (check-equal? (rd "#^String s") '(#%meta String s)))
(test-case "#^ with no following form errors"
  (check-exn #rx"metadata"
             (lambda () (rd "#^:dynamic"))))

;; G11 ##Inf / ##-Inf / ##NaN symbolic values — kept as symbolic name, not a double
(test-case "##Inf reads as (#%symbolic-val Inf)"
  (check-equal? (rd "##Inf") '(#%symbolic-val Inf)))
(test-case "##-Inf reads as (#%symbolic-val -Inf)"
  (check-equal? (rd "##-Inf") '(#%symbolic-val -Inf)))
(test-case "##NaN reads as (#%symbolic-val NaN)"
  (check-equal? (rd "##NaN") '(#%symbolic-val NaN)))
(test-case "## with an unknown symbolic name errors"
  (check-exn #rx"symbolic value"
             (lambda () (rd "##Bogus"))))

;; --- EXP-025 G9 bare-dot interop `(. Target member)` (malli java.time) --------
;; Racket's default reader reserves a lone `.` as the dotted-pair separator and
;; errors on `(. LocalTime -MIN)` ("illegal use of `.`"). Beagle is Clojure, so
;; `.` is the ordinary interop special-form head → the symbol `.`. `.method` /
;; `.-field` prefixed tokens are constituents already and MUST stay unchanged.
(test-case "G9 bare `.` reads as the symbol `.`"
  (check-equal? (rd ".") (string->symbol ".")))
(test-case "G9 `(. Target -field)` interop reads with `.` head"
  (check-equal? (rd "(. LocalTime -MIN)")
                (list (string->symbol ".") 'LocalTime '-MIN)))
(test-case "G9 `(. obj method arg)` interop reads with `.` head"
  (check-equal? (rd "(. obj method arg)")
                (list (string->symbol ".") 'obj 'method 'arg)))
(test-case "G9 `.method` sugar is UNCHANGED (single symbol, `.` not fired)"
  (check-equal? (rd "(.method obj)") '(.method obj)))
(test-case "G9 `.-field` sugar is UNCHANGED (single symbol)"
  (check-equal? (rd "(.-field obj)") '(.-field obj)))
(test-case "G9 mid-token dot is a constituent — `foo.bar` stays one symbol"
  (check-equal? (rd "foo.bar") 'foo.bar))
(test-case "G9 mid-token dot in a number — `1.5` still a number"
  (check-equal? (rd "1.5") 1.5))
(test-case "G9 the java.time schema shape round-trips at read"
  (check-equal? (rd "{:min (. LocalTime -MIN) :max (. LocalTime -MAX)}")
                (list '#%map ':min (list (string->symbol ".") 'LocalTime '-MIN)
                            ':max (list (string->symbol ".") 'LocalTime '-MAX))))
