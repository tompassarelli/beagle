#lang racket/base

;; #33 L2 datum-IR spike — `--build-edn` compiles straight from claim triples,
;; skipping the text round-trip (claims → EDN → datum→src → TEXT →
;; read-beagle-syntax → datum). The text trip is pure overhead because
;; `datum->src` (render) and `read-beagle-syntax` (build) are exact inverses over
;; the SAME datum, and `edn-triples->datum` already reconstructs that datum from
;; triples.
;;
;; This guard pins the SOUNDNESS INVARIANT the cut rests on: the datum the
;; compiler would get from the claim triples is byte-identical to the datum it
;; gets from the reader. Identical datums ⇒ identical parse/check/emit — so
;; `--build-edn` produces the same program as the text path (the slice-1 srcloc
;; degradation aside: edn-triples->datum yields a bare datum, no line/col claims
;; yet). If the reader and the round-trip ever diverge, this goes red.

(require rackunit
         racket/file
         racket/port
         racket/string
         beagle/private/parse
         (only-in beagle/private/facts-roundtrip
                  datum->edn-lines edn-triples->datum
                  stx->edn-lines edn-triples->syntax
                  emit-edn-typed-file))

;; The forms the READER produces for a module.
(define (reader-forms src)
  (define tmp (make-temporary-file "edn33-~a.bclj"))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file tmp (lambda (o) (display src o)) #:exists 'truncate/replace)
     (map syntax->datum (read-beagle-syntax tmp)))
   (lambda () (delete-file tmp))))

;; The forms recovered through claims — mirrors --build-edn EXACTLY: serialize to
;; EDN triple lines (datum->edn-lines, as --emit-edn writes), parse each line
;; (as read-edn-triples does), reconstruct (edn-triples->datum), drop the
;; (beagle-file …) wrapper head.
(define (datum-ir-forms forms)
  (define lines (datum->edn-lines (cons 'beagle-file forms)))
  (define triples (map (lambda (l) (read (open-input-string l))) lines))
  (define wrapped (edn-triples->datum triples))
  (cdr wrapped))

(define SRC
  (string-append
   "#lang beagle/clj\n"
   "(def ^:dynamic *ctx* \"root\")\n"
   "(defn area [w :- Int h :- Int] :- Int (* w h))\n"
   "(defn label [xs :- (Vec String)] :- String\n"
   "  (let [n (count xs)]\n"
   "    (str \"items:\" n)))\n"
   "(def cfg {:enable true :tags #{:a :b}})\n"
   "(def nested [[1 2] {:k [3 4]} #{:x}])\n"
   "(defn pipe [x :- Int] :- Int (-> x (+ 1) (* 2)))\n"))

(test-case "datum-IR round-trip is identity — the --build-edn soundness invariant"
  (define reader (reader-forms SRC))
  (define via-claims (datum-ir-forms reader))
  (check-equal? via-claims reader
                "the datum recovered from claim triples must equal the reader's datum"))

(test-case "round-trip is faithful form-by-form (localizes any drift)"
  (define reader (reader-forms SRC))
  (define via-claims (datum-ir-forms reader))
  (check-equal? (length via-claims) (length reader))
  (for ([r (in-list reader)] [c (in-list via-claims)])
    (check-equal? c r (format "form drifted through claims: ~s" r))))

;; --- slice-2: srcloc claims carry through (closes the slice-1 srcloc gap) -----
;; stx->claims emits per-node line/col/pos/span; edn-triples->syntax rebuilds
;; SYNTAX with those positions. So --build-edn emits byte-identical ^{:line :file}
;; provenance + blame to the text path (verified end-to-end at the CLI; here we
;; pin the unit invariant: pos survives the claim round-trip, datum unchanged).
(define (datum-ir-syntax-forms src-path)
  (define stxs (read-beagle-syntax src-path))
  (define lines (stx->edn-lines (datum->syntax #f (cons 'beagle-file stxs))))
  (define triples (map (lambda (l) (read (open-input-string l))) lines))
  (define wrapper (edn-triples->syntax triples (string->symbol "test-src")))
  (values stxs (cdr (syntax->list wrapper))))   ; drop (beagle-file …) head

(test-case "slice-2: syntax-positions survive the claim round-trip (and datum unchanged)"
  (define tmp (make-temporary-file "edn33s-~a.bclj"))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file tmp (lambda (o) (display SRC o)) #:exists 'truncate/replace)
     (define-values (reader-stxs ir-stxs) (datum-ir-syntax-forms tmp))
     (check-equal? (length ir-stxs) (length reader-stxs))
     (for ([r (in-list reader-stxs)] [c (in-list ir-stxs)])
       ;; datum identity preserved
       (check-equal? (syntax->datum c) (syntax->datum r))
       ;; the load-bearing srcloc field (codepoint pos) carried through
       (check-equal? (syntax-position c) (syntax-position r)
                     (format "pos dropped for: ~s" (syntax->datum r)))
       (check-equal? (syntax-span c) (syntax-span r))))
   (lambda () (delete-file tmp))))

;; --- slice-3: the TYPED layer — derived [node "type" T] claims, additive -------
;; --emit-edn-typed emits the slice-2 datum+srcloc claims PLUS each checked node's
;; inferred type, joined to the datum node by (pos,span). Types are DERIVED +
;; ADDITIVE: the build path ignores them, so the datum still reconstructs.
(define (typed-triples src)
  (define tmp (make-temporary-file "edn33t-~a.bclj"))
  (call-with-output-file tmp (lambda (o) (display src o)) #:exists 'truncate/replace)
  (define out (with-output-to-string (lambda () (emit-edn-typed-file tmp))))
  (delete-file tmp)
  (for/list ([line (in-list (string-split out "\n"))]
             #:when (and (> (string-length line) 0) (char=? (string-ref line 0) #\[)))
    (read (open-input-string line))))

(test-case "slice-3: typed dump carries [node \"type\" T] claims joined by (pos,span)"
  (define triples (typed-triples SRC))
  (define type-claims (filter (lambda (t) (equal? (cadr t) "type")) triples))
  (check-true (>= (length type-claims) 1) "expected at least one inferred type claim")
  ;; every type claim attaches to a node that ALSO has kind + pos + span (a real
  ;; datum node, i.e. the (pos,span) join landed on a structural node)
  (define by-id (make-hash))
  (for ([t (in-list triples)])
    (hash-update! by-id (car t) (lambda (h) (hash-set! h (cadr t) (caddr t)) h) (lambda () (make-hash))))
  (for ([tc (in-list type-claims)])
    (define h (hash-ref by-id (car tc)))
    (check-true (and (hash-has-key? h "kind") (hash-has-key? h "pos") (hash-has-key? h "span"))
                (format "type claim on node ~a lacks kind/pos/span" (car tc)))))

(test-case "slice-3: type claims are ADDITIVE — datum still reconstructs (build ignores types)"
  (define triples (typed-triples SRC))
  (define wrapped (edn-triples->datum triples))   ; consumes the FULL typed dump
  (check-equal? (cdr wrapped) (reader-forms SRC)
                "type claims must not perturb the reconstructed datum"))

;; --- #36 CRDT slot regression — verb-authored forms must NOT be dropped --------
;; fram's chartroom verbs (insert-form/upsert-form) position a node's children with
;; LOGOOT order keys: the predicate is "f<path>~<tie>" (e.g. f262144~12), NOT the
;; legacy sequential "fN". `--build-edn` consumes such a dump straight from the fram
;; code-log. The original ordered-fN walked f0,f1,… sequentially and STOPPED at the
;; first gap → it kept the seed (f0) and SILENTLY DROPPED every verb-positioned form.
;; This pins the dual-spelling parse + (path,tie) sort: all forms survive, in order.
;;
;; We hand-build the wrapper's child slots with CRDT keys to mirror exactly what
;; fram-build-code emits — independent of the reader, which only mints plain fN.
(define (manual-triples-build lines)
  (edn-triples->datum (map (lambda (l) (read (open-input-string l))) lines)))

(test-case "#36: verb-positioned f<path>~<tie> children all survive in (path,tie) order"
  ;; wrapper node 1 = (beagle-file A B C D); head is plain f0, the four "forms" are
  ;; symbols positioned by CRDT keys given OUT OF SORTED ORDER on purpose, so a
  ;; correct (path,tie) sort is what produces A B C D — not hash/emission order.
  (define lines
    (list
     "[1 \"kind\" \"list\"]"
     "[1 \"f0\" 2]"                       ; head: plain legacy slot (path [65536], tie 0)
     "[2 \"kind\" \"symbol\"] [2 \"v\" \"beagle-file\"]"
     ;; deliberately scrambled emission order; deliberately mixed legacy + CRDT keys
     "[1 \"f393216~34\" 6]"               ; D  (path [393216])
     "[1 \"f1\" 3]"                       ; A  (legacy path [131072])  ← between head & CRDT
     "[1 \"f327680~18\" 5]"               ; C  (path [327680])
     "[1 \"f262144~12\" 4]"               ; B  (path [262144])
     "[3 \"kind\" \"symbol\"] [3 \"v\" \"A\"]"
     "[4 \"kind\" \"symbol\"] [4 \"v\" \"B\"]"
     "[5 \"kind\" \"symbol\"] [5 \"v\" \"C\"]"
     "[6 \"kind\" \"symbol\"] [6 \"v\" \"D\"]"))
  ;; one line may carry several triples; split them out the way read-edn-triples does
  (define flat (apply append (map (lambda (l) (string-split l "] [")) lines)))
  (define norm (map (lambda (s)
                      (string-append (if (string-prefix? s "[") "" "[")
                                     s
                                     (if (string-suffix? s "]") "" "]")))
                    flat))
  (define wrapped (manual-triples-build norm))
  (check-equal? wrapped '(beagle-file A B C D)
                "CRDT-positioned children dropped or misordered through --build-edn"))

(test-case "#36: a single legacy f0 + many CRDT siblings — none lost (the seed+verbs shape)"
  ;; mirrors the reproduction: a seed form at f0, then three verb-inserted forms at
  ;; f<path>~<tie>. The pre-fix bug kept ONLY the f0 form.
  (define norm
    (list
     "[1 \"kind\" \"list\"]"
     "[1 \"f0\" 2]"
     "[1 \"f262144~12\" 3]"
     "[1 \"f327680~18\" 4]"
     "[1 \"f393216~34\" 5]"
     "[2 \"kind\" \"symbol\"]" "[2 \"v\" \"seed\"]"
     "[3 \"kind\" \"symbol\"]" "[3 \"v\" \"verb1\"]"
     "[4 \"kind\" \"symbol\"]" "[4 \"v\" \"verb2\"]"
     "[5 \"kind\" \"symbol\"]" "[5 \"v\" \"verb3\"]"))
  (check-equal? (manual-triples-build norm) '(seed verb1 verb2 verb3)
                "verb-authored forms must not be dropped (seed-only is the old bug)"))
