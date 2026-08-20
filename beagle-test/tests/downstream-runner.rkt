#lang racket/base
;; Gate C2 red/green: the hermetic compile runner compiles each consumer's
;; derived roster into EXTERNAL scratch, is byte-clean by construction, records
;; diagnostics on failure, honors the store-before-north resolve staging, and
;; emits a schema-versioned receipt.
;;
;; All fixtures are throwaway git repos under a temp dir — no real consumer is
;; touched, so the suite is hermetic and parallel-safe.
(require rackunit
         racket/file
         racket/path
         racket/string
         racket/port
         racket/system
         "../../contrib/downstream/registry.rkt"
         "../../contrib/downstream/runner.rkt")

;; --- fixture helpers ---------------------------------------------------------
(define (write-file! path content)
  (make-directory* (path-only path))
  (call-with-output-file path #:exists 'replace
    (lambda (o) (write-string content o))))

(define (git! repo . args)
  (parameterize ([current-output-port (open-output-nowhere)]
                 [current-error-port (open-output-nowhere)])
    (apply system* (find-executable-path "git") "-C" (path->string repo) args)))

;; A git repo whose tracked, committed state is clean (so byte-clean before ==
;; after unless the runner wrongly writes into it).
(define (init-repo! repo)
  (make-directory* repo)
  (git! repo "init" "-q")
  (git! repo "config" "user.email" "t@example.com")
  (git! repo "config" "user.name" "t")
  (git! repo "add" "-A")
  (git! repo "commit" "-q" "-m" "fixture" "--allow-empty"))

(define (commit-all! repo) (git! repo "add" "-A") (git! repo "commit" "-q" "-m" "x"))

(define GOOD-JS "#lang beagle/js\n(ns fixture.good)\n(defn add\n  [(a Int)\n   (b Int)]\n  Int\n  (+ a b))\n")
(define BAD-JS  "#lang beagle/js\n(ns fixture.bad)\n(defn f [] Int \"not an int\")\n")

;; A glob consumer spec pointing at a fixture repo (no staging: name != north).
(define (glob-consumer name repo root ext)
  `(consumer (name ,name) (repo-env ,(string-append (string-upcase name) "_FIXREPO"))
             (repo-default ,(path->string repo)) (target ,ext)
             (enumerators ((enumerator (kind glob) (source #f) (root ,root) (ext ,ext)
                            (recursive #t) (skip-basenames ()) (skip-suffixes ())
                            (skip-prefixes ()) (shape-markers ()))))))

(define (with-scratch proc)
  (define scratch (make-temporary-file "beagle-downstream-test-~a" 'directory))
  (dynamic-wind void (lambda () (proc scratch))
                (lambda () (when (directory-exists? scratch)
                             (delete-directory/files scratch)))))

(define (result-named results name)
  (findf (lambda (r) (string=? (run-result-name r) name)) results))

;; --- GREEN: a healthy consumer compiles clean, byte-clean, receipt=pass ------
(test-case "green: valid roster compiles, byte-clean, verdict pass"
  (define base (make-temporary-file "c2-green-~a" 'directory))
  (define repo (build-path base "repo"))
  (write-file! (build-path repo "js" "good.bjs") GOOD-JS)
  (write-file! (build-path repo "js" "also.bjs")
               "#lang beagle/js\n(ns fixture.also)\n(defn g [(x Int)] Int x)\n")
  (init-repo! repo)
  (define consumers (list (glob-consumer "greenjs" repo "js" ".bjs")))
  (with-scratch
   (lambda (scratch)
     (define results (run-consumers consumers scratch #:jobs 2 #:timeout 120))
     (define r (result-named results "greenjs"))
     (check-equal? (run-result-status r) "pass")
     (check-equal? (run-result-count r) 2)
     (check-true (run-result-byteclean? r) "runner wrote nothing into the repo")
     (check-equal? (run-result-diagnostics r) '())
     (define receipt (run->jsexpr results (hasheq 'repo "x" 'rev "y" 'dirty #f)
                                  "2026-01-01T00:00:00" 42 2))
     (check-equal? (hash-ref receipt 'schema) "beagle-downstream/1")
     (check-equal? (hash-ref receipt 'verdict) "pass")
     (check-true (hash-ref receipt 'byteclean_all))))
  (delete-directory/files base))

;; --- RED: a type error fails the consumer with recorded diagnostics ----------
(test-case "red: type error yields fail + diagnostics, still byte-clean"
  (define base (make-temporary-file "c2-red-~a" 'directory))
  (define repo (build-path base "repo"))
  (write-file! (build-path repo "js" "good.bjs") GOOD-JS)
  (write-file! (build-path repo "js" "bad.bjs") BAD-JS)
  (init-repo! repo)   ; bad.bjs is COMMITTED, so failure is compile — not dirtiness
  (define consumers (list (glob-consumer "redjs" repo "js" ".bjs")))
  (with-scratch
   (lambda (scratch)
     (define results (run-consumers consumers scratch #:jobs 1 #:timeout 120))
     (define r (result-named results "redjs"))
     (check-equal? (run-result-status r) "fail")
     (check-true (pair? (run-result-diagnostics r)) "a diagnostic was recorded")
     (check-true (run-result-byteclean? r) "a failing compile still touches no repo bytes")
     (define receipt (run->jsexpr results (hasheq 'repo "x" 'rev "y" 'dirty #f)
                                  "2026-01-01T00:00:00" 1 1))
     (check-equal? (hash-ref receipt 'verdict) "fail")
     ;; not-always-green: the gate is sensitive to a real defect
     (check-true (hash-ref receipt 'byteclean_all))))
  (delete-directory/files base))

;; --- DRIFT TRANSPORT: registry drift surfaces synchronously, not from a worker
;; A drift in membership derivation must reach run-consumers' CALLER as
;; exn:fail:drift (the CLI's exit-3 seam), NOT escape a worker thread as an
;; uncaught traceback that leaves a #f in the results vector (the pre-fix exit-1
;; bug). run-consumers derives every roster up front, in the caller's thread,
;; before spawning any worker — so this check-exn catches the drift class.
(test-case "drift: bash-array shape drift reaches run-consumers' caller as exn:fail:drift"
  (define base (make-temporary-file "c2-drift-array-~a" 'directory))
  (define repo (build-path base "repo"))
  (write-file! (build-path repo "web" "bin" "wake-compile") "MODULES=(alpha)\n") ; marker gone
  (write-file! (build-path repo "web" "compiler" "alpha.bjs") ";;\n")
  (init-repo! repo)
  (define consumers
    (list `(consumer (name "wakedrift") (repo-env "WAKEDRIFT_FIXREPO")
                     (repo-default ,(path->string repo)) (target "js")
                     (enumerators ((enumerator (kind bash-array)
                                    (source "web/bin/wake-compile") (array-name "modules")
                                    (template "web/compiler/{}.bjs")
                                    (shape-markers ("modules=("))))))))
  (with-scratch
   (lambda (scratch)
     (check-exn exn:fail:drift?
                (lambda () (run-consumers consumers scratch #:jobs 2 #:timeout 120)))))
  (delete-directory/files base))

(test-case "drift: missing consumer repo reaches the caller as exn:fail:drift (not a worker traceback)"
  (define base (make-temporary-file "c2-drift-missing-~a" 'directory))
  (define gone (build-path base "not-there"))   ; never created
  (define consumers (list (glob-consumer "gonejs" gone "js" ".bjs")))
  (with-scratch
   (lambda (scratch)
     (check-exn exn:fail:drift?
                (lambda () (run-consumers consumers scratch #:jobs 1 #:timeout 60)))))
  (delete-directory/files base))

;; A drift in ONE consumer aborts the whole run before any partial result — the
;; up-front derivation fails closed rather than compiling the healthy siblings.
(test-case "drift: one drifting consumer aborts the run (no partial results)"
  (define base (make-temporary-file "c2-drift-mixed-~a" 'directory))
  (define good-repo (build-path base "good"))
  (write-file! (build-path good-repo "js" "ok.bjs") GOOD-JS)
  (init-repo! good-repo)
  (define bad-repo (build-path base "bad"))
  (write-file! (build-path bad-repo "web" "bin" "wake-compile") "MODULES=(x)\n")
  (init-repo! bad-repo)
  (define consumers
    (list (glob-consumer "aagood" good-repo "js" ".bjs")
          `(consumer (name "zzdrift") (repo-env "ZZDRIFT_FIXREPO")
                     (repo-default ,(path->string bad-repo)) (target "js")
                     (enumerators ((enumerator (kind bash-array)
                                    (source "web/bin/wake-compile") (array-name "modules")
                                    (template "web/compiler/{}.bjs")
                                    (shape-markers ("modules=("))))))))
  (with-scratch
   (lambda (scratch)
     (check-exn exn:fail:drift?
                (lambda () (run-consumers consumers scratch #:jobs 4 #:timeout 120)))))
  (delete-directory/files base))

;; --- ROOTS + ORDERING: north resolves store from exact read-only roots --------
;; Exercises the north-specific module roots and the store-before-north
;; scheduler edge at jobs=1 (must not deadlock). Nothing is staged into or
;; written under either consumer tree.
(test-case "module roots: north compiles against store's exact source root"
  (define base (make-temporary-file "c2-stage-~a" 'directory))
  (define store-repo (build-path base "store"))
  (define north-repo (build-path base "north"))
  (write-file! (build-path store-repo "src" "store" "thing.bclj")
               "#lang beagle/clj\n(ns store.thing)\n(defn double [(x Int)] Int (* x 2))\n")
  (make-directory* (build-path store-repo "codegraph" "src"))
  (make-directory* (build-path store-repo "build" "interfaces"))
  (init-repo! store-repo)
  (write-file! (build-path north-repo "src" "north" "main.bclj")
               "#lang beagle/clj\n(ns north.main)\n(require store.thing :as t)\n(defn go [] Int (t/double 21))\n")
  (init-repo! north-repo)
  (check-false (directory-exists? (build-path north-repo "web-bjs"))
               "CLI/MCP-only North fixture has no retired web source tree")
  ;; north spec must be named "north" to trigger staging; its current source
  ;; contract is exclusively src/north .bclj modules.
  (define north-spec
    `(consumer (name "north") (repo-env "NORTH_FIXREPO")
               (repo-default ,(path->string north-repo)) (target "clj")
               (enumerators ((enumerator (kind glob) (source #f) (root "src/north")
                              (ext ".bclj") (recursive #t) (skip-basenames ())
                              (skip-suffixes ()) (skip-prefixes ()) (shape-markers ()))))))
  (define store-spec (glob-consumer "store" store-repo "src/store" ".bclj"))
  (with-scratch
   (lambda (scratch)
     ;; order [north store] with jobs=1 forces the dependency wait to resolve
     (define results (run-consumers (list north-spec store-spec) scratch
                                    #:jobs 1 #:timeout 180))
     (check-equal? (run-result-status (result-named results "store")) "pass")
     (check-equal? (run-result-status (result-named results "north")) "pass"
                   "north's (require store.thing) resolved via the Store root")
     (check-true (run-result-byteclean? (result-named results "north")))
     (check-true (run-result-byteclean? (result-named results "store")))))
  (delete-directory/files base))

(test-case "module roots: Store compiles through its three owned source roots"
  (define base (make-temporary-file "c2-store-roots-~a" 'directory))
  (define repo (build-path base "store"))
  (write-file! (build-path repo "src" "store" "core.bclj")
               "#lang beagle/clj\n(ns store.core)\n(defn value [] Int 20)\n")
  (write-file! (build-path repo "codegraph" "src" "codegraph" "helper.bclj")
               (string-append
                "#lang beagle/clj\n(ns codegraph.helper)\n"
                "(require store.core :as core)\n"
                "(defn value [] Int (core/value))\n"))
  (write-file! (build-path repo "build" "interfaces" "store" "iface.bclj")
               "#lang beagle/clj\n(ns store.iface)\n(defn value [] Int 22)\n")
  (write-file! (build-path repo "src" "store" "main.bclj")
               (string-append
                "#lang beagle/clj\n(ns store.main)\n"
                "(require codegraph.helper :as helper)\n"
                "(require store.iface :as iface)\n"
                "(defn value [] Int (+ (helper/value) (iface/value)))\n"))
  (init-repo! repo)
  (define store-spec
    `(consumer (name "store") (repo-env "STORE_FIXREPO")
               (repo-default ,(path->string repo)) (target "clj")
               (enumerators
                ((enumerator (kind glob) (source #f) (root "src")
                             (ext ".bclj") (recursive #t) (skip-basenames ())
                             (skip-suffixes ()) (skip-prefixes ()) (shape-markers ()))
                 (enumerator (kind glob) (source #f) (root "codegraph/src")
                             (ext ".bclj") (recursive #t) (skip-basenames ())
                             (skip-suffixes ()) (skip-prefixes ()) (shape-markers ()))
                 (enumerator (kind glob) (source #f) (root "build/interfaces")
                             (ext ".bclj") (recursive #t) (skip-basenames ())
                             (skip-suffixes ()) (skip-prefixes ()) (shape-markers ()))))))
  (define consumers (list store-spec))
  (with-scratch
   (lambda (scratch)
     (define results (run-consumers consumers scratch #:jobs 1 #:timeout 120))
     (define r (result-named results "store"))
     (check-equal? (run-result-status r) "pass")
     (check-equal? (run-result-count r) 4)
     (check-true (run-result-byteclean? r))
     (check-equal? (run-result-diagnostics r) '())))
  (delete-directory/files base))

(test-case "target overrides: Store compiles independent Core outputs under the job bound"
  (define base (make-temporary-file "c2-store-core-~a" 'directory))
  (define repo (build-path base "store"))
  (write-file! (build-path repo "src" "store" "base.bgl")
               "#lang beagle\n(ns store.base)\n(defn value [] Int 40)\n")
  (write-file! (build-path repo "src" "store" "use.bgl")
               (string-append
                "#lang beagle\n(ns store.use)\n"
                "(require store.base :as base)\n"
                "(defn value [] Int (+ (base/value) 2))\n"))
  ;; The Store runner always supplies all three owned roots, just as its hosted
  ;; build does; only src contains files in this focused Core fixture.
  (make-directory* (build-path repo "codegraph" "src"))
  (make-directory* (build-path repo "build" "interfaces"))
  (write-file! (build-path repo "build" "generated-targets.d" "00.tsv")
               (string-append
                "# kind\tsource\tdestination\n"
                "beagle-core\tsrc/store/base.bgl\tout/store/base.clj\n"
                "beagle-core\tsrc/store/use.bgl\tout/store/use.clj\n"))
  (init-repo! repo)
  (define store-spec
    `(consumer (name "store") (repo-env "STORE_FIXREPO")
               (repo-default ,(path->string repo)) (target "clj")
               (enumerators
                ((enumerator (kind tsv-manifest) (source #f)
                             (manifest-root "build/generated-targets.d")
                             (manifest-ext ".tsv")
                             (include-kinds ("beagle-core"))
                             (target-overrides (("beagle-core" . "clj")))
                             (shape-markers ()))))))
  (with-scratch
   (lambda (scratch)
     (define results (run-consumers (list store-spec) scratch
                                    #:jobs 2 #:timeout 120))
     (define r (result-named results "store"))
     (check-equal? (run-result-status r) "pass")
     (check-equal? (run-result-count r) 2)
     (check-true (run-result-byteclean? r))
     (check-equal? (run-result-diagnostics r) '())))
  (delete-directory/files base))
