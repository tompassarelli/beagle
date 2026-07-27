#lang racket/base

;; scriptc-oracle.rkt — the executable ScriptC oracle used by the conformance
;; gate (certify.rkt) and the focused behavioral suite
;; (beagle-test/tests/emit-scriptc-behavioral.rkt).
;;
;; ScriptC compiles ordinary TypeScript to a native executable with no JS
;; engine in the binary, and reports — construct by construct — how much of a
;; program it compiles STATICALLY. That gives beagle's scriptc target three
;; dimensions no golden diff can supply:
;;
;;   1. VALIDITY   the emitted .ts must type-check under ScriptC's real tsc.
;;   2. STATIC     `scriptc coverage` must analyze MORE THAN ZERO statements
;;                 and compile all of them statically. The zero-statement case
;;                 is called out separately (`static-vacuous`) because a row
;;                 that analyzes nothing proves nothing — 0/0 is not 100%.
;;   3. NATIVE     the native executable's stdout, stderr AND exit status must
;;                 equal Node's on the same .ts. ScriptC's own contract is
;;                 "what compiles behaves byte-for-byte like Node", so Node is
;;                 the differential oracle.
;;
;; TOOL CONTRACT — the ScriptC CLI is NOT vendored and is not a beagle
;; dependency. It is located via $BEAGLE_SCRIPTC (a command line, e.g.
;; `node /path/to/scriptc/packages/cli/dist/main.js`) or a `scriptc` on PATH.
;; When it — or clang, which ScriptC shells out to, or node — is missing, every
;; dependent dimension reports 'unavailable. Callers MUST surface that as an
;; explicit UNENFORCED state; silently passing the row would bless whatever the
;; emitter happens to produce.
;;
;; Nothing here is derived from ScriptC's source: the CLI is used only as a
;; black-box executable oracle (Apache-2.0, rev 20c3a6c27da4807f607ebe496663842b67e87f0e).

(require racket/file
         racket/list
         racket/port
         racket/string
         racket/system)

(provide scriptc-cli
         scriptc-native-tools
         scriptc-static-enforceable?
         scriptc-native-enforceable?
         scriptc-tooling-summary
         materialize-modules
         scriptc-coverage
         scriptc-node-differential)

;; ---------------------------------------------------------------------------
;; Tool discovery
;; ---------------------------------------------------------------------------

;; -> (list exe arg ...) | #f
;; $BEAGLE_SCRIPTC is a whitespace-separated command so a checkout that ships
;; the CLI as a plain .js entry (`node .../main.js`) needs no wrapper script.
(define scriptc-cli
  (let ([cached
         (let* ([env (getenv "BEAGLE_SCRIPTC")]
                [words (if (and env (not (string=? (string-trim env) "")))
                           (string-split (string-trim env))
                           '())])
           (cond
             [(pair? words)
              (define exe (find-executable-path (first words)))
              (define direct (string->path (first words)))
              (define resolved
                (or exe (and (file-exists? direct) direct)))
              (and resolved (cons resolved (rest words)))]
             [else
              (define p (find-executable-path "scriptc"))
              (and p (list p))]))])
    (lambda () cached)))

;; ScriptC shells out to clang to link the native executable, and the
;; differential needs node. Either missing => the native dimension cannot run.
(define node-exe (find-executable-path "node"))
(define clang-exe (find-executable-path "clang"))

(define (scriptc-native-tools)
  (and node-exe clang-exe (list node-exe clang-exe)))

(define (scriptc-static-enforceable?) (and (scriptc-cli) #t))
(define (scriptc-native-enforceable?)
  (and (scriptc-cli) (scriptc-native-tools) #t))

(define (scriptc-tooling-summary)
  (string-join
   (list (format "scriptc=~a" (if (scriptc-cli)
                                  (path->string (first (scriptc-cli)))
                                  "MISSING (set $BEAGLE_SCRIPTC)"))
         (format "node=~a" (if node-exe (path->string node-exe) "MISSING"))
         (format "clang=~a" (if clang-exe (path->string clang-exe) "MISSING")))
   " "))

;; ---------------------------------------------------------------------------
;; Process plumbing
;; ---------------------------------------------------------------------------

;; -> (values exit-code stdout stderr)
(define (run-capture exe args dir)
  (define out (open-output-string))
  (define err (open-output-string))
  (define code
    (parameterize ([current-directory dir]
                   [current-output-port out]
                   [current-error-port err]
                   [current-input-port (open-input-string "")])
      (apply system*/exit-code exe args)))
  (values code (get-output-string out) (get-output-string err)))

(define (run-scriptc dir . args)
  (define cli (scriptc-cli))
  (run-capture (first cli) (append (rest cli) args) dir))

;; ---------------------------------------------------------------------------
;; Materializing a row's emitted modules on disk
;; ---------------------------------------------------------------------------

;; modules: list of (cons file-name text). Written verbatim into a fresh
;; directory under `parent`; the emitted ESM import specifiers are relative, so
;; a module row only resolves when its siblings sit beside the entry.
(define (materialize-modules parent name modules)
  (define dir (build-path parent name))
  (delete-directory/files dir #:must-exist? #f)
  (make-directory* dir)
  (for ([m (in-list modules)])
    (call-with-output-file (build-path dir (car m)) #:exists 'truncate
      (lambda (o) (display (cdr m) o))))
  dir)

;; ---------------------------------------------------------------------------
;; Dimension 1+2 — validity and static coverage
;; ---------------------------------------------------------------------------

(define (first-lines s n)
  (define ls (filter (lambda (l) (not (string=? (string-trim l) "")))
                     (string-split s "\n")))
  (string-join (take ls (min n (length ls))) "\n"))

;; -> (list 'ok statements-total statements-static report)
;;  | (list 'not-analyzable detail)     ; emitted .ts fails ScriptC's tsc
;;  | (list 'unavailable why)
(define (scriptc-coverage dir entry)
  (cond
    [(not (scriptc-cli)) (list 'unavailable "no ScriptC CLI ($BEAGLE_SCRIPTC unset, none on PATH)")]
    [else
     (define-values (code out err) (run-scriptc dir "coverage" entry))
     (define report (string-append out err))
     (define total (regexp-match #px"statements analyzed\\s+([0-9]+)" report))
     (define static (regexp-match #px"compile statically\\s+([0-9]+)" report))
     (cond
       [(and (zero? code) total static)
        (list 'ok
              (string->number (cadr total))
              (string->number (cadr static))
              report)]
       [else
        (list 'not-analyzable
              (format "scriptc coverage (exit ~a) rejects the emitted TypeScript:\n~a"
                      code (first-lines report 6)))])]))

;; ---------------------------------------------------------------------------
;; Dimension 3 — native vs Node differential
;; ---------------------------------------------------------------------------

(define (describe-run label code out err)
  (format "~a: exit ~a\n  stdout ~s\n  stderr ~s" label code out err))

;; -> (list 'match detail) | (list 'divergent detail) | (list 'unavailable why)
(define (scriptc-node-differential dir entry)
  (cond
    [(not (scriptc-cli)) (list 'unavailable "no ScriptC CLI ($BEAGLE_SCRIPTC unset, none on PATH)")]
    [(not clang-exe) (list 'unavailable "no clang (ScriptC links the native executable with it)")]
    [(not node-exe) (list 'unavailable "no node (the differential oracle)")]
    [else
     (define bin (build-path dir "row.bin"))
     ;; Build and RUN as separate steps: build-time notes on stderr are toolchain
     ;; chatter, not program output, and must not pollute the differential.
     (define-values (bcode bout berr) (run-scriptc dir "build" entry "-o" (path->string bin)))
     (cond
       [(or (not (zero? bcode)) (not (file-exists? bin)))
        (list 'divergent
              (format "scriptc build failed (exit ~a):\n~a" bcode
                      (first-lines (string-append bout berr) 6)))]
       [else
        (define-values (ncode nout nerr) (run-capture node-exe (list entry) dir))
        (define-values (scode sout serr) (run-capture bin '() dir))
        (if (and (= ncode scode) (string=? nout sout) (string=? nerr serr))
            (list 'match (format "native == node (exit ~a)" scode))
            (list 'divergent
                  (format "native run diverges from Node\n  ~a\n  ~a"
                          (describe-run "node  " ncode nout nerr)
                          (describe-run "native" scode sout serr))))])]))
