#lang racket/base

;; emit-scriptc-behavioral.rkt — the FOCUSED behavioral gate for the scriptc
;; target: not "does it emit the same bytes" (that is bin/beagle-certify's
;; golden dimension) but "does the emitted TypeScript actually compile to
;; native code and BEHAVE like Node".
;;
;; Three claims, each with a falsifier:
;;
;;   1. NON-VACUITY. `scriptc coverage` reports 0/0 as "100% static" for an
;;      EMPTY program — so a coverage percentage alone can certify nothing.
;;      Every accepted row must analyze MORE THAN ZERO statements. The empty
;;      program below is the live falsifier: it pins the 0/0-is-100% behavior
;;      so the statementsTotal>0 rule can never quietly become decorative.
;;   2. FULL STATIC COVERAGE. Every green row compiles statically end to end
;;      (statementsFailed = 0), on ScriptC's real compiler, not a stub.
;;   3. NATIVE == NODE. stdout, stderr AND exit status of the native binary
;;      equal Node's on the same emitted .ts.
;;
;; Plus a structural claim about the ratchet itself: every entry in
;; known-divergences-scriptc.edn is an EXACT :bug (with a thread) or
;; :host-model classification against a real corpus row — never a generic
;; skip, never an "inapplicable" relabel of a target-neutral gap.
;;
;; TOOLING. The ScriptC CLI is not a beagle dependency; it is located via
;; $BEAGLE_SCRIPTC (e.g. `node /path/to/scriptc/packages/cli/dist/main.js`) or
;; a `scriptc` on PATH, and it shells out to clang. When the toolchain is
;; absent the behavioral claims print an explicit UNENFORCED banner and are
;; NOT asserted — they are never silently green. The structural claims always
;; run.
;;
;; Run: raco test beagle-test/tests/emit-scriptc-behavioral.rkt

(require rackunit
         rackunit/text-ui
         racket/file
         racket/list
         racket/path
         racket/runtime-path
         racket/string
         (only-in (file "../../beagle-lib/private/batch-compile.rkt") compile-source)
         (file "../conformance/scriptc-oracle.rkt"))

(define-runtime-path conformance-dir "../conformance")
(define-runtime-path repo-root "../..")

(define (conformance-path . parts)
  (apply build-path conformance-dir parts))

;; certify.rkt's comparison normalization, mirrored so this suite and the gate
;; agree on what "equal to the golden" means.
(define (finalize-text s) (regexp-replace #rx"\n*$" s "\n"))
(define (strip-srcloc s)
  (regexp-replace* #rx"\\^\\{:line [0-9]+ :file \"[^\"]*\"\\} " s ""))
(define (norm-text s) (finalize-text (strip-srcloc s)))

;; ---------------------------------------------------------------------------
;; Corpus + ratchet, read from the same authored data the gate reads
;; ---------------------------------------------------------------------------

(define corpus (with-input-from-file (conformance-path "corpus.rktd") read))

(define (row-id r) (first r))
(define (row-path r) (second r))
(define (row-kind r) (third r))

(define scriptc-rows
  (filter (lambda (r) (regexp-match? #rx"\\.bsc$" (row-path r))) corpus))

(define (plist-ref pl key [dflt #f])
  (let loop ([pl pl])
    (cond [(or (null? pl) (null? (cdr pl))) dflt]
          [(eq? (car pl) key) (cadr pl)]
          [else (loop (cddr pl))])))

(define ledger
  (plist-ref (with-input-from-file
                 (conformance-path "known-divergences-scriptc.edn") read)
             ':entries '()))

(define ratcheted-ids
  (for/list ([e (in-list ledger)]) (plist-ref e ':id)))

;; The rows this suite asserts behavior for: green `native` rows — the ones
;; carrying no ratchet entry, i.e. the ones beagle claims already work.
(define green-native-rows
  (for/list ([r (in-list scriptc-rows)]
             #:when (and (eq? (row-kind r) 'native)
                         (not (member (row-id r) ratcheted-ids))))
    r))

(define (golden-for r)
  (conformance-path "expected" "scriptc" (string-append (row-id r) ".ts")))

;; ---------------------------------------------------------------------------
;; Tooling banner — an absent toolchain is UNENFORCED, never a silent pass
;; ---------------------------------------------------------------------------

(define behavioral-armed? (scriptc-native-enforceable?))

(printf "scriptc behavioral suite — tooling: ~a\n" (scriptc-tooling-summary))
(unless behavioral-armed?
  (printf
   (string-append
    "UNENFORCED: the ScriptC toolchain is incomplete, so the static-coverage\n"
    "and native-vs-Node claims below are NOT asserted (they are not passing —\n"
    "they did not run). Set $BEAGLE_SCRIPTC to the ScriptC CLI command and\n"
    "install clang + node to arm them.\n")))

(define scratch
  (and behavioral-armed?
       (make-temporary-file "beagle-scriptc-behavioral-~a" 'directory)))

;; ---------------------------------------------------------------------------
;; Suites
;; ---------------------------------------------------------------------------

(define structural-suite
  (test-suite "scriptc ratchet is exact, not a skip list"
    (test-case "every scriptc corpus row declares a supported kind"
      (check-true (>= (length scriptc-rows) 18)
                  (format "expected the synthesized seed rows, found ~a"
                          (length scriptc-rows)))
      (for ([r (in-list scriptc-rows)])
        ;; memq answers with the matching TAIL, not #t, so this must be
        ;; check-not-false — check-true would fail every legitimate kind.
        (check-not-false (memq (row-kind r) '(emit reject static native module))
                         (format "row ~a has unsupported kind ~a" (row-id r) (row-kind r)))
        (check-true (file-exists? (build-path repo-root (row-path r)))
                    (format "row ~a points at a missing source ~a"
                            (row-id r) (row-path r)))))

    (test-case "every ledger entry is an exact :bug/:host-model on a real row"
      (define ids (map row-id scriptc-rows))
      (for ([e (in-list ledger)])
        (define id (plist-ref e ':id))
        (define category (plist-ref e ':category))
        (check-not-false (member id ids)
                         (format "ratchet entry ~a matches no scriptc corpus row" id))
        ;; Every scriptc row is a target-neutral or JS-family construct, so the
        ;; only licensed classifications are exact ones. There is no skip
        ;; category and no "inapplicable" category — that is the point.
        (check-not-false (memq category '(|:bug| |:host-model| |:strictness|))
                         (format "ratchet entry ~a has category ~a; the gate accepts only exact classifications"
                                 id category))
        (when (eq? category '|:bug|)
          (check-true (regexp-match? #rx"^@" (or (plist-ref e ':thread "") ""))
                      (format "ratchet entry ~a is a :bug with no tracked thread" id)))
        (check-true (> (string-length (or (plist-ref e ':note "") "")) 40)
                    (format "ratchet entry ~a carries no justification" id))))

    (test-case "green rows exist and are disjoint from the ratchet"
      ;; A ratchet that swallowed every row would make the gate vacuous, and a
      ;; row that is both green and ratcheted would be a contradiction the
      ;; STALE check could never resolve.
      (check-true (>= (length green-native-rows) 6)
                  (format "expected the green native rows, found ~a"
                          (map row-id green-native-rows)))
      (for ([r (in-list green-native-rows)])
        (check-false (member (row-id r) ratcheted-ids)
                     (format "~a is claimed green AND ratcheted" (row-id r)))))))

(define vacuity-suite
  (test-suite "0/0 is not 100% — the non-vacuity falsifier"
    (test-case "scriptc reports an empty program as 0 statements at 100%"
      (cond
        [(not behavioral-armed?)
         (printf "  UNENFORCED (no ScriptC toolchain): vacuity falsifier not run\n")]
        [else
         (define dir (materialize-modules scratch "vacuous"
                                          (list (cons "vacuous.ts" "// no statements\n"))))
         (define cov (scriptc-coverage dir "vacuous.ts"))
         (check-eq? (car cov) 'ok)
         ;; THIS is why statementsTotal>0 is a hard rule: the percentage says
         ;; 100% while the program proves nothing at all.
         (check-equal? (second cov) 0 "empty program must analyze 0 statements")
         (check-equal? (third cov) 0)
         (check-true (regexp-match? #rx"100%" (fourth cov))
                     "scriptc still calls 0/0 a 100% static program")]))))

(define (native-row-test r)
  (test-case (format "~a: emits its golden, 100% static, native == node" (row-id r))
    (define-values (status emitted)
      (compile-source (build-path repo-root (row-path r))
                      #:root (path->string (simplify-path repo-root))))
    (check-eq? status 'ok (format "~a failed to compile: ~a" (row-id r) emitted))
    (check-true (file-exists? (golden-for r))
                (format "~a has no committed golden" (row-id r)))
    (when (and (eq? status 'ok) (file-exists? (golden-for r)))
      (check-equal? (norm-text emitted) (norm-text (file->string (golden-for r)))
                    (format "~a emission drifted from its committed golden" (row-id r)))
      (cond
        [(not behavioral-armed?)
         (printf "  UNENFORCED (no ScriptC toolchain): ~a static + native claims not run\n"
                 (row-id r))]
        [else
         (define file-name (string-append (row-id r) ".ts"))
         (define dir (materialize-modules scratch (row-id r)
                                          (list (cons file-name emitted))))
         (define cov (scriptc-coverage dir file-name))
         (check-eq? (car cov) 'ok
                    (format "~a: emitted TypeScript is not analyzable:\n~a"
                            (row-id r) (if (eq? (car cov) 'ok) "" (cadr cov))))
         (when (eq? (car cov) 'ok)
           (check-true (> (second cov) 0)
                       (format "~a analyzed 0 statements — a vacuous pass" (row-id r)))
           (check-equal? (third cov) (second cov)
                         (format "~a is only ~a/~a static" (row-id r)
                                 (third cov) (second cov)))
           (define diff (scriptc-node-differential dir file-name))
           (check-eq? (car diff) 'match
                      (format "~a: ~a" (row-id r) (cadr diff))))]))))

(define native-suite
  (test-suite "scriptc native rows behave exactly like Node"
    (for ([r (in-list green-native-rows)]) (native-row-test r))))

(define failures
  (+ (run-tests structural-suite)
     (run-tests vacuity-suite)
     (run-tests native-suite)))

(when scratch (delete-directory/files scratch #:must-exist? #f))
(exit (if (zero? failures) 0 1))
