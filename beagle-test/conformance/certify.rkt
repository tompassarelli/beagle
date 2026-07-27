#lang racket/base

;; certify.rkt — per-backend conformance gate: the oracle ratchet.
;; Run via bin/beagle-certify (which pins racket + routes the beagle
;; collection at THIS checkout, so a worktree certifies its own compiler).
;;
;; Mechanics (ported from jolt test/conformance/certify.clj):
;;   * corpus.rktd rows = source file -> golden emitted output per target
;;     (kind 'emit), or -> golden diagnostic text (kind 'reject).
;;   * The ORACLE is the Racket beagle compiler at HEAD: --regen sources
;;     every golden from it (jolt's regen-corpus role). A later run diffs
;;     the live compiler against the blessed snapshot.
;;   * Emitted output is additionally VALIDITY-checked against the target's
;;     own parser (js: bun/node, nix: nix-instantiate, clj: bb reader,
;;     scriptc: ScriptC's real tsc) — this is what catches the
;;     silent-miscompile class, where output matches the golden but is not
;;     even parseable on the target.
;;   * The scriptc target adds two dimensions past validity (scriptc-oracle.rkt):
;;     non-vacuous STATIC coverage (kind 'static / 'native) and a NATIVE-vs-Node
;;     stdout/stderr/exit differential (kind 'native), plus multi-file module
;;     rows (kind 'module). When the ScriptC CLI / clang / node are absent those
;;     dimensions report UNENFORCED — a distinct state, never a pass.
;;   * Buckets per row:
;;       match / reject-match   good
;;       divergent              emitted != golden (regen after review, or classify)
;;       invalid-output         emitted == golden but fails target validity
;;       compile-fail           emit row no longer compiles
;;       reject-mismatch        reject row now compiles (accepted!)
;;       diag-divergent         reject row's diagnostic changed
;;       diag-unpointed         reject row's diagnostic fails its pointedness
;;                              contract (#:diag-requires / #:diag-forbids)
;;       static-vacuous         scriptc analyzed 0 statements — 0/0 is not 100%
;;       static-incomplete      scriptc cannot compile every statement statically
;;       native-divergent       native stdout/stderr/exit != Node's
;;       no-golden              row has no golden yet (run --regen)
;;       unenforced             a dimension could not run (tool absent); NOT a pass
;;   * THE RATCHET: known-divergences-<target>.edn classifies accepted
;;     divergence debt, keyed [:id :bucket]. The gate exits nonzero on a
;;     NEW (unclassified) flagged row OR a STALE entry (listed, not firing).
;;     The allowlist only shrinks: fixing a bug forces deleting its entry.
;;
;; Usage:
;;   bin/beagle-certify                    # gate (CI: exit 0/1)
;;   bin/beagle-certify --target js,clj    # subset of targets
;;   bin/beagle-certify --regen            # re-source goldens from the oracle

(require racket/cmdline
         racket/file
         racket/format
         racket/list
         racket/path
         racket/port
         racket/set
         racket/string
         racket/system
         racket/runtime-path
         "scriptc-oracle.rkt")

(define-runtime-path here ".")
(define repo-root (simplify-path (build-path here 'up 'up)))
(define repo-root-str (path->string repo-root))

;; ---------------------------------------------------------------------------
;; CLI
;; ---------------------------------------------------------------------------

(define regen? (make-parameter #f))
(define target-filter (make-parameter #f)) ; #f = all targets

(command-line
 #:program "beagle-certify"
 #:once-each
 [("--regen") "Re-source expected/ goldens from the current compiler (the oracle)"
              (regen? #t)]
 [("--target") targets "Comma-separated target subset (js,clj,nix,scriptc)"
               (target-filter
                (for/seteq ([t (string-split targets ",")]) (string->symbol t)))])

;; ---------------------------------------------------------------------------
;; Corpus
;; ---------------------------------------------------------------------------

(define corpus
  (with-input-from-file (build-path here "corpus.rktd") read))

(define (row-id r) (first r))
(define (row-path r) (second r))
(define (row-kind r) (third r))

;; Everything past the kind is an option plist (`#:modules (…)`,
;; `#:diag-requires "…"`, `#:diag-forbids "…"`) — authored data, jolt-style.
(define (row-opt r key [dflt #f])
  (let loop ([pl (cdddr r)])
    (cond [(or (null? pl) (null? (cdr pl))) dflt]
          [(eq? (car pl) key) (cadr pl)]
          [else (loop (cddr pl))])))

(define (row-target r)
  (define p (row-path r))
  (cond
    [(regexp-match? #rx"\\.bjs$" p)   'js]
    [(regexp-match? #rx"\\.bclj$" p)  'clj]
    [(regexp-match? #rx"\\.bnix$" p)  'nix]
    [(regexp-match? #rx"\\.bsc$" p)   'scriptc]
    [else (error 'certify "cannot derive target from path: ~a" p)]))

;; The golden's extension is the target's own source extension: scriptc emits
;; TypeScript, so its goldens are .ts (not .scriptc).
(define (golden-ext target)
  (case target
    [(scriptc) "ts"]
    [else (symbol->string target)]))

;; The emitted module's on-disk name. Module rows import siblings by relative
;; specifier (`./sc-module-two-file-lib.js`), which the emitter derives from the
;; ns — and the fixtures' file names ARE their ns tails, so the source basename
;; is the module name. Single-file rows use the same rule for uniformity.
(define (module-file-name src-path)
  (string-append
   (path->string (path-replace-extension (file-name-from-path src-path) #""))
   ".ts"))

;; A module row's sources: the entry (row-path) first, then #:modules siblings.
(define (row-sources r)
  (cons (row-path r) (row-opt r '#:modules '())))

(define (golden-path r [src #f])
  (define target (row-target r))
  (cond
    [(eq? (row-kind r) 'reject)
     (build-path here "expected" (symbol->string target)
                 (string-append (row-id r) ".diag"))]
    [(eq? (row-kind r) 'module)
     ;; one golden per module, in a per-row directory
     (build-path here "expected" (symbol->string target) (row-id r)
                 (module-file-name (or src (row-path r))))]
    [else
     (build-path here "expected" (symbol->string target)
                 (string-append (row-id r) "." (golden-ext target)))]))

;; duplicate-id guard — the ratchet keys on id
(let ([ids (map row-id corpus)])
  (unless (= (length ids) (set-count (list->set ids)))
    (error 'certify "corpus.rktd has duplicate row ids")))

(define rows
  (if (target-filter)
      (filter (lambda (r) (set-member? (target-filter) (row-target r))) corpus)
      corpus))

;; ---------------------------------------------------------------------------
;; Compile (in-process: running a #lang beagle module prints its emission;
;; one racket process amortizes the compiler load across the whole corpus)
;; ---------------------------------------------------------------------------

;; Diagnostics and emitted srcloc metadata embed absolute paths; strip the
;; checkout prefix so goldens are stable across checkouts/worktrees/CI.
(define (normalize-diag s)
  (regexp-replace* (regexp (regexp-quote repo-root-str)) s ""))

;; Strip per-form srcloc metadata before COMPARISON only: ^{:line N :file
;; "..."} is debug provenance, not semantic output.  Selfhost emitters never
;; produce it (BEAGLE_EMIT_SRCLOC=0 is their only mode); goldens and oracle
;; output that DO carry it still compare equal once stripped, so a selfhost
;; run and the Racket-oracle run both certify against the same golden.
;; This must NOT touch what gets WRITTEN to a golden on --regen: emit-clj.rkt
;; documents "Default is on, so beagle's own goldens ... are unchanged" —
;; the oracle (this script always runs the Racket compiler, never selfhost)
;; emits srcloc metadata by default, and the committed goldens are meant to
;; carry it verbatim. finalize-text is the write-path counterpart: trailing-
;; newline normalization only, no stripping, so --regen doesn't silently
;; discard real provenance the oracle actually emitted.
(define (strip-srcloc s)
  (regexp-replace* #rx"\\^\\{:line [0-9]+ :file \"[^\"]*\"\\} " s ""))

(define (finalize-text s) (regexp-replace #rx"\n*$" s "\n"))
(define (norm-text s) (finalize-text (strip-srcloc s)))

;; -> (list 'ok emitted-string) | (list 'fail diag-string)
(define (compile-fixture rel-path)
  (define abs (build-path repo-root rel-path))
  (with-handlers ([(lambda (e) #t)
                   (lambda (e)
                     (list 'fail (normalize-diag
                                  (if (exn? e) (exn-message e) (~a e)))))])
    (define out (open-output-string))
    (parameterize ([current-output-port out]
                   [current-error-port (open-output-string)])
      (dynamic-require `(file ,(path->string abs)) #f))
    (list 'ok (normalize-diag (get-output-string out)))))

;; ---------------------------------------------------------------------------
;; Target validity — parse the EMITTED output with the target's own tooling.
;; This dimension exists because a golden comparison alone would bless a
;; silent miscompile forever: golden == output, output == garbage.
;; ---------------------------------------------------------------------------

;; js is bun-or-skip, deliberately: node --check only surfaces invalid
;; assignment targets at runtime, so a node fallback half-detects the
;; silent-miscompile class and turns its ledger entries falsely STALE on
;; bun-less machines. A validity tool is all-or-nothing per target.
(define bun-path  (find-executable-path "bun"))
(define bb-path   (find-executable-path "bb"))
(define nix-path  (find-executable-path "nix-instantiate"))

;; #f when the target's validity dimension cannot run on this machine —
;; invalid-output ledger entries are then unenforceable, not stale.
(define (validity-tool target)
  (case target
    [(js)       bun-path]
    [(nix)      nix-path]
    [(clj)      bb-path]
    [(scriptc)  (and (scriptc-cli) (car (scriptc-cli)))]
    [else #f]))

;; Buckets that CANNOT fire for a target on this machine because the tool the
;; dimension needs is absent. Their ledger entries are reported unenforced
;; rather than stale — absence of a signal is not evidence the debt was paid.
(define (unenforceable-buckets target)
  (case target
    [(scriptc)
     (cond
       [(not (scriptc-static-enforceable?))
        (seteq 'invalid-output 'static-vacuous 'static-incomplete 'native-divergent)]
       [(not (scriptc-native-enforceable?)) (seteq 'native-divergent)]
       [else (seteq)])]
    [else (if (validity-tool target) (seteq) (seteq 'invalid-output))]))

(define tmp-dir (make-temporary-file "beagle-certify-~a" 'directory))

(define (run-quiet exe . args)
  (define err (open-output-string))
  (define ok?
    (parameterize ([current-output-port (open-output-string)]
                   [current-error-port err])
      (apply system* exe args)))
  (values ok? (get-output-string err)))

(define bb-reader-prog
  (string-append
   "(binding [*default-data-reader-fn* (fn [_ v] v)]"
   "  (with-open [r (java.io.PushbackReader. (clojure.java.io/reader (first *command-line-args*)))]"
   "    (loop [] (let [f (read {:eof :certify/eof :read-cond :allow} r)]"
   "               (when-not (= f :certify/eof) (recur))))))"))

;; -> (list 'valid tool) | (list 'invalid tool detail) | (list 'skipped why)
(define (check-validity target id text)
  (define (write-tmp ext)
    (define p (build-path tmp-dir (string-append id ext)))
    (call-with-output-file p #:exists 'truncate (lambda (o) (display text o)))
    p)
  (define (verdict tool ok? err)
    (if ok? (list 'valid tool) (list 'invalid tool (normalize-diag err))))
  (case target
    [(js)
     (cond
       [bun-path
        (define f (write-tmp ".mjs"))
        (define-values (ok? err)
          (run-quiet bun-path "build" "--no-bundle" (path->string f)))
        (verdict "bun" ok? err)]
       [else (list 'skipped "no bun")])]
    [(nix)
     (cond
       [nix-path
        (define f (write-tmp ".nix"))
        (define-values (ok? err) (run-quiet nix-path "--parse" (path->string f)))
        (verdict "nix-instantiate" ok? err)]
       [else (list 'skipped "no nix-instantiate")])]
    [(clj)
     (cond
       [bb-path
        (define f (write-tmp ".clj"))
        (define-values (ok? err)
          (run-quiet bb-path "-e" bb-reader-prog (path->string f)))
        (verdict "bb" ok? err)]
       [else (list 'skipped "no bb")])]
    [else (list 'skipped "no validity tool wired")]))

;; ---------------------------------------------------------------------------
;; Classify one row -> (list bucket detail)
;; ---------------------------------------------------------------------------

;; --- scriptc: validity + non-vacuous static coverage + native differential ---
;;
;; `modules` is (cons file-name emitted-text) for every module of the row, entry
;; first. Everything here runs on the EMITTED text that already matched its
;; golden, so a failure is always a real product gap, never a stale snapshot.
(define (classify-scriptc-dimensions r modules)
  (define entry (car (first modules)))
  (define dir (materialize-modules tmp-dir (row-id r) modules))
  (define cov (scriptc-coverage dir entry))
  (case (car cov)
    [(unavailable)
     (list 'unenforced
           (format "ScriptC dimensions NOT enforced for this ~a row: ~a"
                   (row-kind r) (cadr cov)))]
    [(not-analyzable) (list 'invalid-output (cadr cov))]
    [else
     (define total (second cov))
     (define static (third cov))
     (define static-detail (format "scriptc static ~a/~a" static total))
     (cond
       ;; A row that analyzes nothing proves nothing: 0/0 is not 100%.
       [(zero? total)
        (list 'static-vacuous
              "scriptc analyzed 0 statements — this row cannot certify static coverage")]
       [(< static total)
        (list 'static-incomplete
              (format "~a — blockers:\n~a" static-detail
                      (let ([ls (string-split (fourth cov) "\n")])
                        (string-join
                         (for/list ([l (in-list ls)]
                                    #:when (regexp-match? #px"SC[0-9]{4}" l))
                           (string-trim l))
                         "\n"))))]
       [(memq (row-kind r) '(emit static)) (list 'match static-detail)]
       [else
        (define diff (scriptc-node-differential dir entry))
        (case (car diff)
          [(unavailable)
           (list 'unenforced
                 (format "~a; native differential NOT enforced: ~a"
                         static-detail (cadr diff)))]
          [(divergent) (list 'native-divergent (cadr diff))]
          [else (list 'match (format "~a; ~a" static-detail (cadr diff)))])])]))

;; Emit one source file -> (list 'ok file-name emitted-text raw-text) | (list 'fail diag)
(define (emit-module r src)
  (define res (compile-fixture src))
  (if (eq? (car res) 'fail)
      res
      (list 'ok (module-file-name src) (norm-text (cadr res)) (cadr res))))

;; emit / static / native / module all share: compile every module, diff every
;; golden, then run the target dimensions. Only the golden LAYOUT differs.
(define (classify-emit r)
  (define srcs (row-sources r))
  (define emissions (for/list ([s (in-list srcs)]) (emit-module r s)))
  (define failed (findf (lambda (e) (eq? (car e) 'fail)) emissions))
  (cond
    [failed (list 'compile-fail (cadr failed))]
    [(regen?)
     (for ([s (in-list srcs)] [e (in-list emissions)])
       (define gp (golden-path r s))
       (make-parent-directory* gp)
       (call-with-output-file gp #:exists 'truncate
         (lambda (o) (display (finalize-text (fourth e)) o))))
     (list 'regen "golden written")]
    [else
     (define missing
       (for/list ([s (in-list srcs)] #:unless (file-exists? (golden-path r s))) s))
     (define divergences
       (for/list ([s (in-list srcs)] [e (in-list emissions)]
                  #:when (and (file-exists? (golden-path r s))
                              (not (string=? (third e)
                                             (norm-text (file->string (golden-path r s)))))))
         (golden-path r s)))
     (define modules (for/list ([e (in-list emissions)]) (cons (second e) (third e))))
     (cond
       [(pair? missing) (list 'no-golden "run bin/beagle-certify --regen")]
       [(pair? divergences)
        (list 'divergent
              (format "emitted output != golden (~a)"
                      (string-join
                       (for/list ([gp (in-list divergences)])
                         (path->string (find-relative-path repo-root (simplify-path gp))))
                       ", ")))]
       [(eq? (row-target r) 'scriptc) (classify-scriptc-dimensions r modules)]
       [else
        (define validity (check-validity (row-target r) (row-id r) (third (first emissions))))
        (cond
          [(eq? (car validity) 'invalid)
           (list 'invalid-output
                 (format "~a rejects the emitted output:\n~a"
                         (cadr validity)
                         (string-join
                          (take (string-split (caddr validity) "\n")
                                (min 4 (length (string-split (caddr validity) "\n"))))
                          "\n")))]
          [else (list 'match (if (eq? (car validity) 'skipped)
                                 (format "validity skipped: ~a" (cadr validity))
                                 ""))])])]))

(define (classify-reject r)
  (define res (compile-fixture (row-path r)))
  (define gp (golden-path r))
  (cond
    [(eq? (car res) 'ok)
     (list 'reject-mismatch "source expected to be rejected, but it now COMPILES")]
    [(regen?)
     (make-parent-directory* gp)
     (call-with-output-file gp #:exists 'truncate
       (lambda (o) (display (finalize-text (cadr res)) o)))
     (list 'regen "diag golden written")]
    [(not (file-exists? gp))
     (list 'no-golden "run bin/beagle-certify --regen")]
    [else
     (define golden (norm-text (file->string gp)))
     (define actual (norm-text (cadr res)))
     (define requires (row-opt r '#:diag-requires))
     (define forbids (row-opt r '#:diag-forbids))
     (cond
       [(not (string=? actual golden))
        (list 'diag-divergent
              (format "diagnostic changed:\n  golden: ~a\n  actual: ~a"
                      (string-trim golden) (string-trim (cadr res))))]
       ;; POINTEDNESS CONTRACT. A reject row whose golden merely records
       ;; today's message is a silent pass for an unpointed diagnostic: the
       ;; rejection is "correct" and the ratchet never fires. #:diag-requires /
       ;; #:diag-forbids assert what a USER-FACING message must (not) say, so a
       ;; known-bad message stays a classified :bug that goes STALE — forcing
       ;; the entry's deletion — the moment the message is fixed.
       [(and requires (not (regexp-match? (pregexp requires) actual)))
        (list 'diag-unpointed
              (format "diagnostic must match ~s but does not:\n  ~a"
                      requires (string-trim actual)))]
       [(and forbids (regexp-match? (pregexp forbids) actual))
        (list 'diag-unpointed
              (format "diagnostic must NOT match ~s (internal detail leaking at the user):\n  ~a"
                      forbids (string-trim actual)))]
       [else (list 'reject-match "")])]))

(define results
  (for/list ([r (in-list rows)])
    (define c (if (eq? (row-kind r) 'reject) (classify-reject r) (classify-emit r)))
    (list r (car c) (cadr c))))

(define (res-row x) (first x))
(define (res-bucket x) (second x))
(define (res-detail x) (third x))

;; ---------------------------------------------------------------------------
;; The ratchet: known-divergences-<target>.edn (dual EDN/Racket-readable —
;; curly braces read as parens, keywords read as symbols; commas are banned).
;; ---------------------------------------------------------------------------

(define (plist-ref pl key [dflt #f])
  (let loop ([pl pl])
    (cond [(or (null? pl) (null? (cdr pl))) dflt]
          [(eq? (car pl) key) (cadr pl)]
          [else (loop (cddr pl))])))

;; ':invalid-output (EDN keyword read as a symbol) -> 'invalid-output
(define (edn-kw->sym k)
  (string->symbol (regexp-replace #rx"^:" (symbol->string k) "")))

;; -> list of (list id bucket-sym category-sym note)
(define (read-known target)
  (define p (build-path here (format "known-divergences-~a.edn" target)))
  (if (file-exists? p)
      (for/list ([e (in-list (plist-ref (with-input-from-file p read) ':entries '()))])
        (list (plist-ref e ':id)
              (edn-kw->sym (plist-ref e ':bucket))
              (edn-kw->sym (plist-ref e ':category '|:unclassified|))
              (plist-ref e ':note "")))
      '()))

(define FLAGGED-BUCKETS
  (seteq 'divergent 'invalid-output 'compile-fail 'no-golden
         'reject-mismatch 'diag-divergent 'diag-unpointed
         'static-vacuous 'static-incomplete 'native-divergent))

(define targets-in-scope
  (remove-duplicates (map row-target rows)))

;; ---------------------------------------------------------------------------
;; Report (jolt-style: quiet about known debt, loud about NEW and STALE)
;; ---------------------------------------------------------------------------

(define by-bucket
  (for/fold ([h (hasheq)]) ([x (in-list results)])
    (hash-update h (res-bucket x) (lambda (v) (cons x v)) '())))
(define (cnt b) (length (hash-ref by-bucket b '())))

(printf "Certifying ~a corpus rows against the Racket beagle oracle (~a)\n\n"
        (length rows)
        (if (regen?) "REGEN: re-sourcing goldens" "committed goldens"))
(printf "  match            ~a\n" (~a (cnt 'match) #:width 4 #:align 'right))
(printf "  reject-match     ~a\n" (~a (cnt 'reject-match) #:width 4 #:align 'right))
(when (regen?)
  (printf "  regenerated      ~a\n" (~a (cnt 'regen) #:width 4 #:align 'right)))
(printf "  divergent        ~a  <- output != golden\n" (~a (cnt 'divergent) #:width 4 #:align 'right))
(printf "  invalid-output   ~a  <- fails target validity (silent-miscompile class)\n"
        (~a (cnt 'invalid-output) #:width 4 #:align 'right))
(printf "  compile-fail     ~a\n" (~a (cnt 'compile-fail) #:width 4 #:align 'right))
(printf "  reject-mismatch  ~a  <- rejected form now accepted\n" (~a (cnt 'reject-mismatch) #:width 4 #:align 'right))
(printf "  diag-divergent   ~a\n" (~a (cnt 'diag-divergent) #:width 4 #:align 'right))
(printf "  diag-unpointed   ~a  <- rejects, but the message is not user-facing\n" (~a (cnt 'diag-unpointed) #:width 4 #:align 'right))
(printf "  static-vacuous   ~a  <- 0 statements analyzed (0/0 is not 100%)\n" (~a (cnt 'static-vacuous) #:width 4 #:align 'right))
(printf "  static-incomplete~a  <- target cannot compile every statement statically\n" (~a (cnt 'static-incomplete) #:width 4 #:align 'right))
(printf "  native-divergent ~a  <- native stdout/stderr/exit != the oracle runtime\n" (~a (cnt 'native-divergent) #:width 4 #:align 'right))
(printf "  no-golden        ~a\n" (~a (cnt 'no-golden) #:width 4 #:align 'right))
(printf "  unenforced       ~a  <- dimension could not run (tool absent) — NOT a pass\n" (~a (cnt 'unenforced) #:width 4 #:align 'right))

(when (memq 'scriptc targets-in-scope)
  (printf "\n  scriptc tooling: ~a\n" (scriptc-tooling-summary))
  ;; NON-VACUITY IS A CLAIM, SO PRINT ITS EVIDENCE. The static-vacuous bucket
  ;; already fails a 0-statement row, but a silent `match` leaves a reader
  ;; unable to tell a real 12/12 from a vacuous 0/0. Every ACCEPTED scriptc row
  ;; therefore reports the statement counts (and the native comparison) it
  ;; passed on, so the gate's green is auditable rather than asserted.
  (define accepted-scriptc
    (sort (for/list ([x (in-list (hash-ref by-bucket 'match '()))]
                     #:when (and (eq? (row-target (res-row x)) 'scriptc)
                                 (not (string=? (res-detail x) ""))))
            x)
          string<? #:key (lambda (x) (row-id (res-row x)))))
  (unless (null? accepted-scriptc)
    (printf "\n  accepted scriptc rows (non-vacuity evidence):\n")
    (for ([x (in-list accepted-scriptc)])
      (printf "      ~a [~a] ~a\n"
              (row-id (res-row x)) (row-kind (res-row x)) (res-detail x)))))

(for ([x (in-list (hash-ref by-bucket 'unenforced '()))])
  (printf "      unenforced ~a: ~a\n" (row-id (res-row x)) (res-detail x)))

(define exit-code 0)

(unless (regen?)
  (for ([target (in-list targets-in-scope)])
    (define known (read-known target))
    (define known-keys (for/set ([e (in-list known)]) (cons (first e) (second e))))
    (define flagged
      (for/list ([x (in-list results)]
                 #:when (and (eq? (row-target (res-row x)) target)
                             (set-member? FLAGGED-BUCKETS (res-bucket x))))
        x))
    (define flagged-keys
      (for/set ([x (in-list flagged)]) (cons (row-id (res-row x)) (res-bucket x))))
    (define news (for/list ([x (in-list flagged)]
                            #:unless (set-member? known-keys
                                                  (cons (row-id (res-row x)) (res-bucket x))))
                   x))
    ;; Tool-dependent buckets are unenforceable when their tool is absent — the
    ;; bucket cannot fire, so its absence proves nothing. Exclude them from
    ;; stale instead of failing falsely on a partially-tooled box.
    (define blind (unenforceable-buckets target))
    (define unenforceable
      (for/set ([k (in-set known-keys)] #:when (set-member? blind (cdr k))) k))
    (define stale
      (set->list (set-subtract known-keys flagged-keys unenforceable)))
    (printf "\n  [~a] ratchet: ~a entr~a; ~a of ~a flagged known; ~a NEW; ~a stale\n"
            target (length known) (if (= (length known) 1) "y" "ies")
            (- (length flagged) (length news)) (length flagged)
            (length news) (length stale))
    (when (positive? (set-count unenforceable))
      (printf "      (~a entr~a NOT enforced — the ~a tooling for ~a is absent on this machine: ~a)\n"
              (set-count unenforceable)
              (if (= (set-count unenforceable) 1) "y" "ies")
              target
              (string-join (for/list ([b (in-set blind)]) (symbol->string b)) "/")
              (string-join (sort (for/list ([k (in-set unenforceable)])
                                   (format "~a[~a]" (car k) (cdr k)))
                                 string<?)
                           " ")))
    (for ([e (in-list known)]
          #:when (set-member? flagged-keys (cons (first e) (second e))))
      (printf "      known ~a [~a/~a] ~a\n" (first e) (third e) (second e) (fourth e)))
    (when (pair? news)
      (set! exit-code 1)
      (printf "\n  === [~a] NEW divergences (unclassified) — gate FAILS ===\n" target)
      (for ([x (in-list news)])
        (printf "    ~a (~a) [~a]\n      ~a\n"
                (row-id (res-row x)) (row-path (res-row x)) (res-bucket x)
                (string-replace (res-detail x) "\n" "\n      ")))
      (printf "    -> fix it, or classify it in known-divergences-~a.edn\n" target))
    (when (pair? stale)
      (set! exit-code 1)
      (printf "\n  === [~a] STALE ratchet entries (no longer diverging) — gate FAILS ===\n" target)
      (for ([k (in-list stale)])
        (printf "    ~a [~a]\n" (car k) (cdr k)))
      (printf "    -> the ratchet only shrinks: DELETE these entries from known-divergences-~a.edn\n"
              target))))

;; A --regen compile failure is only news when the row isn't already a
;; classified ratchet entry: rows that pin an accepted-but-unimplemented gap
;; (a `:bug`/`:host-model` compile-fail) never produce a golden by definition,
;; and failing regen on them would make the maintenance flow unusable.
(when (regen?)
  (define classified
    (for*/set ([target (in-list targets-in-scope)]
               [e (in-list (read-known target))]
               #:when (eq? (second e) 'compile-fail))
      (first e)))
  (define news
    (for/list ([x (in-list (hash-ref by-bucket 'compile-fail '()))]
               #:unless (set-member? classified (row-id (res-row x))))
      x))
  (when (positive? (cnt 'compile-fail))
    (printf "\n  === compile failures during --regen (~a classified as ratchet debt) ===\n"
            (- (cnt 'compile-fail) (length news)))
    (for ([x (in-list (hash-ref by-bucket 'compile-fail '()))])
      (printf "    ~a~a: ~a\n"
              (if (set-member? classified (row-id (res-row x))) "known " "NEW   ")
              (row-id (res-row x))
              (car (string-split (res-detail x) "\n")))))
  (when (pair? news) (set! exit-code 1)))

(printf "\n~a\n" (if (zero? exit-code)
                     "conformance gate: OK"
                     "conformance gate: FAIL"))
(delete-directory/files tmp-dir #:must-exist? #f)
(exit exit-code)
