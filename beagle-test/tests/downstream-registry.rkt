#lang racket/base
;; Gate C1 red/green: the downstream consumer registry derives each consumer's
;; membership from its OWN enumerator, records sorted-relpath count + SHA-256,
;; and FAILS CLOSED (exn:fail:drift) when an enumerator's shape changes.
;;
;; GREEN uses hermetic fixture repos for the extraction logic plus the live
;; registry when all five consumer repos are checked out. RED mutates fixture
;; enumerator shapes and asserts the drift guard trips.
(require rackunit
         racket/file
         racket/list
         racket/string
         racket/path
         racket/port
         "../../contrib/downstream/registry.rkt")

;; --- helpers -----------------------------------------------------------------
(define (sha256 s)
  (define-values (proc out in err)
    (subprocess #f #f #f (find-executable-path "sha256sum")))
  (write-string s in) (close-output-port in)
  (define line (read-line out))
  (close-input-port out) (close-input-port err)
  (subprocess-wait proc)
  (car (string-split line)))

(define (write-file! path content)
  (make-directory* (path-only path))
  (call-with-output-file path #:exists 'replace
    (lambda (o) (write-string content o))))

;; Build a throwaway repo dir and hand back its absolute path.
(define (with-fixture-repo proc)
  (define dir (make-temporary-directory))
  (dynamic-wind void
                (lambda () (proc dir))
                (lambda () (delete-directory/files dir))))

(define (consumer-spec name repo enumerators)
  `(consumer (name ,name) (repo-default ,(path->string repo))
             (target "test") (enumerators ,enumerators)))

;; ============================================================================
;; GREEN — hermetic extraction of each enumerator family
;; ============================================================================
(test-case "bash-array extraction derives the declared module set"
  (with-fixture-repo
   (lambda (repo)
     (write-file! (build-path repo "web" "bin" "wake-compile")
                  "modules=(alpha beta gamma)\n")
     (for ([m '("alpha" "beta" "gamma")])
       (write-file! (build-path repo "web" "compiler" (string-append m ".bjs")) ";;\n"))
     (define r (derive-consumer
                (consumer-spec "wake-fix" repo
                               '((enumerator (kind bash-array)
                                             (source "web/bin/wake-compile")
                                             (array-name "modules")
                                             (template "web/compiler/{}.bjs")
                                             (shape-markers ("modules=(")))))))
     (check-equal? (consumer-result-count r) 3)
     (check-equal? (consumer-result-relpaths r)
                   '("web/compiler/alpha.bjs" "web/compiler/beta.bjs" "web/compiler/gamma.bjs"))
     ;; count + SHA-256 are recorded over the SORTED relpaths (the bar).
     (check-equal? (consumer-result-sha256 r)
                   (sha256 (string-join (consumer-result-relpaths r) "\n"))))))

(test-case "bash-for-list extraction derives the loop module set"
  (with-fixture-repo
   (lambda (repo)
     (write-file! (build-path repo "build.sh")
                  "for m in types store kernel; do build $m.bclj; done\n")
     (for ([m '("types" "store" "kernel")])
       (write-file! (build-path repo "src" "fram" (string-append m ".bclj")) ";;\n"))
     (define r (derive-consumer
                (consumer-spec "fram-fix" repo
                               '((enumerator (kind bash-for-list)
                                             (source "build.sh")
                                             (loop-var "m")
                                             (template "src/fram/{}.bclj")
                                             (shape-markers ("for m in")))))))
     (check-equal? (consumer-result-count r) 3)
     (check-equal? (consumer-result-relpaths r)
                   '("src/fram/kernel.bclj" "src/fram/store.bclj" "src/fram/types.bclj")))))

(test-case "glob extraction walks the root and applies skips"
  (with-fixture-repo
   (lambda (repo)
     (for ([f '("a.bjs" "macros.bjs" "sub/b.bjs" "test/c.bjs" "d.test.bjs")])
       (write-file! (build-path repo "root" f) ";;\n"))
     (define r (derive-consumer
                (consumer-spec "glob-fix" repo
                               '((enumerator (kind glob) (source #f)
                                             (root "root") (ext ".bjs") (recursive #t)
                                             (skip-basenames ("macros.bjs"))
                                             (skip-suffixes (".test.bjs"))
                                             (skip-prefixes ("test/"))
                                             (shape-markers ()))))))
     ;; macros.bjs, test/c.bjs, d.test.bjs skipped; a.bjs + sub/b.bjs kept.
     (check-equal? (consumer-result-relpaths r) '("root/a.bjs" "root/sub/b.bjs")))))

;; --- find-exclude fixture harness --------------------------------------------
;; A hermetic nixos-config-shaped repo: firn-build (emit) + firn-validate
;; (validate) enumerator sources carrying their real shape markers, plus a
;; .bnix set spanning membership + every excluded class.
(define firn-build-src
  (string-append
   "find . -name '*.bnix' -not -path './result*' -not -path './.direnv/*' -print0\n"
   "  ./scripts/*) continue ;;\n"
   "  ./tests/*) continue ;;\n"
   "  ./docs/fixtures/*) continue ;;\n"
   "  */enabled-tags.bnix) continue ;;\n"))
(define firn-validate-src
  "find . -type f -name '*.bnix' -not -path './tests/fixtures/*' -not -path './result/*'\n")

(define (std-firn-tree! repo)
  (write-file! (build-path repo "scripts" "firn-build") firn-build-src)
  (write-file! (build-path repo "scripts" "firn-validate") firn-validate-src)
  (for ([f '("a.bnix" "nested/b.bnix" "tests/fixtures/bad.bnix"
             "hosts/x/enabled-tags.bnix" "docs/fixtures/ex.bnix" "result/r.bnix")])
    (write-file! (build-path repo f) "{}\n")))

(define standard-classified
  '((exclude (relpath "tests/fixtures/bad.bnix")     (class negative-fixture))
    (exclude (relpath "hosts/x/enabled-tags.bnix")   (class resolver-input))
    (exclude (relpath "docs/fixtures/ex.bnix")       (class doc-fixture))))

(define (firn-enum classified)
  `(enumerator (kind find-exclude)
               (source "scripts/firn-build")
               (ext ".bnix")
               (find-not-paths ("result" ".direnv"))
               (exclude-relpath-prefixes ("scripts/" "tests/" "docs/fixtures/"))
               (exclude-basenames ("enabled-tags.bnix"))
               (shape-markers ("find . -name '*.bnix' -not -path './result*'"
                               "./scripts/*) continue"
                               "./tests/*) continue"
                               "./docs/fixtures/*) continue"
                               "*/enabled-tags.bnix) continue"))
               (validate-source "scripts/firn-validate")
               (validate-shape-markers ("find . -type f -name '*.bnix'"
                                        "-not -path './tests/fixtures/*'"))
               (validate-negative-prefixes ("tests/fixtures/"))
               (classified-excludes ,classified)))

(define (derive-firn repo classified)
  (derive-consumer (consumer-spec "firn-fix" repo (list (firn-enum classified)))))

(test-case "find-exclude: membership = firn-build emit set; excludes classified"
  (with-fixture-repo
   (lambda (repo)
     (std-firn-tree! repo)
     (define r (derive-firn repo standard-classified))
     ;; membership is firn-build's emit set (broad excludes applied); result/
     ;; pruned as find-not-paths noise.
     (check-equal? (consumer-result-relpaths r) '("a.bnix" "nested/b.bnix"))
     (check-equal? (consumer-result-count r) 2)
     ;; every non-membership .bnix is explicitly classified.
     (check-equal? (sort (map car (consumer-result-excluded r)) string<?)
                   '("docs/fixtures/ex.bnix" "hosts/x/enabled-tags.bnix"
                     "tests/fixtures/bad.bnix"))
     (check-equal? (cdr (assoc "tests/fixtures/bad.bnix" (consumer-result-excluded r)))
                   'negative-fixture)
     (check-equal? (cdr (assoc "hosts/x/enabled-tags.bnix" (consumer-result-excluded r)))
                   'resolver-input)
     (check-equal? (cdr (assoc "docs/fixtures/ex.bnix" (consumer-result-excluded r)))
                   'doc-fixture))))

(test-case "find-exclude: membership ∪ excluded accounts for every discovered .bnix"
  (with-fixture-repo
   (lambda (repo)
     (std-firn-tree! repo)
     (define r (derive-firn repo standard-classified))
     (define accounted
       (sort (append (consumer-result-relpaths r)
                     (map car (consumer-result-excluded r)))
             string<?))
     ;; result/r.bnix is the only unaccounted file — VCS/build noise both firn
     ;; scripts prune. Everything else is membership or an explicit exclude.
     (check-equal? accounted
                   '("a.bnix" "docs/fixtures/ex.bnix" "hosts/x/enabled-tags.bnix"
                     "nested/b.bnix" "tests/fixtures/bad.bnix")))))

;; ---- fail-closed accounting: the silent-membership-gap the gate closes ------
(test-case "drift: an unclassified excluded .bnix (silent-membership gap) fails closed"
  (with-fixture-repo
   (lambda (repo)
     (std-firn-tree! repo)
     ;; a future good source dropped under a formerly-broad excluded prefix
     (write-file! (build-path repo "scripts" "newtool.bnix") "{}\n")
     (check-exn exn:fail:drift? (lambda () (derive-firn repo standard-classified))))))

(test-case "drift: planting under every formerly-broad prefix fails closed"
  (for ([p '("scripts/z.bnix" "tests/t.bnix" "docs/fixtures/x.bnix")])
    (with-fixture-repo
     (lambda (repo)
       (std-firn-tree! repo)
       (write-file! (build-path repo p) "{}\n")
       (check-exn exn:fail:drift?
                  (lambda () (derive-firn repo standard-classified))
                  (format "planted ~a must trip drift, not vanish" p))))))

(test-case "drift: a new negative fixture must be classified (no silent add)"
  (with-fixture-repo
   (lambda (repo)
     (std-firn-tree! repo)
     (write-file! (build-path repo "tests" "fixtures" "extra.bnix") "{}\n")
     (check-exn exn:fail:drift? (lambda () (derive-firn repo standard-classified))))))

(test-case "resolution: classifying a planted file restores green membership"
  (with-fixture-repo
   (lambda (repo)
     (std-firn-tree! repo)
     (write-file! (build-path repo "tests" "fixtures" "extra.bnix") "{}\n")
     (define r (derive-firn repo
                            (cons '(exclude (relpath "tests/fixtures/extra.bnix")
                                            (class negative-fixture))
                                  standard-classified)))
     (check-equal? (consumer-result-count r) 2)
     (check-true (and (assoc "tests/fixtures/extra.bnix" (consumer-result-excluded r)) #t)))))

(test-case "drift: a stale classification (file gone) fails closed"
  (with-fixture-repo
   (lambda (repo)
     (std-firn-tree! repo)
     (check-exn exn:fail:drift?
                (lambda () (derive-firn repo
                                        (cons '(exclude (relpath "tests/fixtures/ghost.bnix")
                                                        (class negative-fixture))
                                              standard-classified)))))))

(test-case "drift: negative-fixture class on a firn-validated file fails closed"
  (with-fixture-repo
   (lambda (repo)
     (std-firn-tree! repo)
     ;; enabled-tags is validated by firn-validate -> it is not a negative fixture
     (check-exn exn:fail:drift?
                (lambda () (derive-firn repo
                  '((exclude (relpath "tests/fixtures/bad.bnix")   (class negative-fixture))
                    (exclude (relpath "hosts/x/enabled-tags.bnix") (class negative-fixture))
                    (exclude (relpath "docs/fixtures/ex.bnix")     (class doc-fixture)))))))))

(test-case "drift: resolver-input class on a tests/fixtures file fails closed"
  (with-fixture-repo
   (lambda (repo)
     (std-firn-tree! repo)
     (check-exn exn:fail:drift?
                (lambda () (derive-firn repo
                  '((exclude (relpath "tests/fixtures/bad.bnix")   (class resolver-input))
                    (exclude (relpath "hosts/x/enabled-tags.bnix") (class resolver-input))
                    (exclude (relpath "docs/fixtures/ex.bnix")     (class doc-fixture)))))))))

(test-case "drift: firn-validate shape change fails closed"
  (with-fixture-repo
   (lambda (repo)
     (std-firn-tree! repo)
     (write-file! (build-path repo "scripts" "firn-validate") "find . -name '*.bnix'\n")
     (check-exn exn:fail:drift? (lambda () (derive-firn repo standard-classified))))))

;; ============================================================================
;; RED — enumerator shape drift fails closed
;; ============================================================================
(test-case "bash-array drift: renamed array trips the guard"
  (with-fixture-repo
   (lambda (repo)
     (write-file! (build-path repo "web" "bin" "wake-compile")
                  "MODULES=(alpha beta)\n") ; shape marker `modules=(` gone
     (check-exn exn:fail:drift?
                (lambda () (derive-consumer
                            (consumer-spec "wake-drift" repo
                                           '((enumerator (kind bash-array)
                                                         (source "web/bin/wake-compile")
                                                         (array-name "modules")
                                                         (template "web/compiler/{}.bjs")
                                                         (shape-markers ("modules=(")))))))))))

(test-case "bash-for-list drift: loop replaced trips the guard"
  (with-fixture-repo
   (lambda (repo)
     (write-file! (build-path repo "build.sh")
                  "while read m; do build $m; done\n") ; no `for m in`
     (check-exn exn:fail:drift?
                (lambda () (derive-consumer
                            (consumer-spec "fram-drift" repo
                                           '((enumerator (kind bash-for-list)
                                                         (source "build.sh")
                                                         (loop-var "m")
                                                         (template "src/fram/{}.bclj")
                                                         (shape-markers ("for m in")))))))))))

(test-case "find-exclude drift: firn-build find/skip shape changed trips the guard"
  (with-fixture-repo
   (lambda (repo)
     (std-firn-tree! repo)
     (write-file! (build-path repo "scripts" "firn-build")
                  "find . -name '*.nix'\n") ; the recorded find + skip markers are gone
     (check-exn exn:fail:drift? (lambda () (derive-firn repo standard-classified))))))

(test-case "glob require-absent drift: a manifest appears trips the guard"
  (with-fixture-repo
   (lambda (repo)
     (write-file! (build-path repo "web-bjs" "src" "a.bjs") ";;\n")
     (write-file! (build-path repo "web-bjs" "build.sh") "modules=(a)\n") ; seam grew a manifest
     (check-exn exn:fail:drift?
                (lambda () (derive-consumer
                            (consumer-spec "north-web-drift" repo
                                           '((enumerator (kind glob) (source #f)
                                                         (root "web-bjs/src") (ext ".bjs")
                                                         (recursive #f)
                                                         (require-absent "web-bjs/build.sh")
                                                         (shape-markers ()))))))))))

(test-case "missing enumerator source trips the guard"
  (with-fixture-repo
   (lambda (repo)
     (make-directory* repo)
     (check-exn exn:fail:drift?
                (lambda () (derive-consumer
                            (consumer-spec "gone" repo
                                           '((enumerator (kind bash-array)
                                                         (source "web/bin/wake-compile")
                                                         (array-name "modules")
                                                         (template "x/{}.bjs")
                                                         (shape-markers ("modules=(")))))))))))

;; ============================================================================
;; GREEN (live) — the shipped registry derives exactly five consumers
;; ============================================================================
(test-case "live registry derives exactly five consumers, deterministically"
  (define consumers (load-consumers))
  (check-equal? (length consumers) 5 "registry names exactly five consumers")
  (check-equal? (sort (map consumer-name consumers) string<?)
                '("fram" "gjoa" "nixos-config" "north" "wake"))
  (cond
    [(andmap (lambda (c) (directory-exists? (consumer-repo-path c))) consumers)
     (define run1 (derive-all))
     (define run2 (derive-all))
     ;; Determinism: same tree in, same count + SHA out.
     (for ([a (in-list run1)] [b (in-list run2)])
       (check-equal? (consumer-result-sha256 a) (consumer-result-sha256 b))
       (check-equal? (consumer-result-count a) (consumer-result-count b)))
     (for ([r (in-list run1)])
       (check-true (> (consumer-result-count r) 0)
                   (format "~a derived a non-empty roster" (consumer-result-name r)))
       (check-equal? (string-length (consumer-result-sha256 r)) 64
                     "SHA-256 is 64 hex chars")
       ;; The recorded SHA is the hash of the recorded sorted relpaths.
       (check-equal? (consumer-result-sha256 r)
                     (sha256 (string-join (consumer-result-relpaths r) "\n")))
       ;; Sorted + unique.
       (check-equal? (consumer-result-relpaths r)
                     (sort (remove-duplicates (consumer-result-relpaths r)) string<?)))
     (define north-result
       (findf (lambda (r) (string=? (consumer-result-name r) "north")) run1))
     (check-true
      (and north-result
           (andmap (lambda (path) (string-prefix? path "src/north/"))
                   (consumer-result-relpaths north-result)))
      "live North membership is exclusively its current src/north build contract")]
    [else
     (printf "~a\n" "(skipping live derivation: not all consumer repos checked out)")]))

(test-case "live nixos-config: every excluded .bnix is classified and disjoint from membership"
  (define nc (findf (lambda (c) (string=? (consumer-name c) "nixos-config"))
                    (load-consumers)))
  (cond
    [(directory-exists? (consumer-repo-path nc))
     ;; derive-consumer fails closed on any unclassified .bnix, so reaching here
     ;; already proves the live tree has no silent-membership gap.
     (define r (derive-consumer nc))
     (check-true (pair? (consumer-result-excluded r))
                 "nixos-config carries explicit classified excludes")
     (for ([p (in-list (consumer-result-excluded r))])
       (check-true (and (memq (cdr p) '(negative-fixture resolver-input doc-fixture)) #t)
                   (format "~a has a known exclude class" (car p))))
     ;; membership and excludes never overlap.
     (for ([p (in-list (consumer-result-excluded r))])
       (check-false (and (member (car p) (consumer-result-relpaths r)) #t)
                    (format "~a is excluded, not in membership" (car p))))]
    [else
     (printf "~a\n" "(skipping live nixos-config: repo not checked out)")]))
