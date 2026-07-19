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

(test-case "find-exclude extraction drops find-not-paths + excludes"
  (with-fixture-repo
   (lambda (repo)
     (write-file! (build-path repo "scripts" "firn-build")
                  "find . -name '*.bnix' -not -path './result*' enabled-tags.bnix\n")
     (for ([f '("a.bnix" "hosts/x/enabled-tags.bnix" "scripts/z.bnix"
                "tests/t.bnix" "nested/b.bnix" "result/r.bnix")])
       (write-file! (build-path repo f) "{}\n")) ; result/ pruned by walk
     (define r (derive-consumer
                (consumer-spec "firn-fix" repo
                               '((enumerator (kind find-exclude)
                                             (source "scripts/firn-build")
                                             (ext ".bnix")
                                             (find-not-paths ("result" ".direnv"))
                                             (exclude-relpath-prefixes ("scripts/" "tests/"))
                                             (exclude-basenames ("enabled-tags.bnix"))
                                             (shape-markers ("-name '*.bnix' -not -path './result*'")))))))
     (check-equal? (consumer-result-relpaths r) '("a.bnix" "nested/b.bnix")))))

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

(test-case "find-exclude drift: find line changed trips the guard"
  (with-fixture-repo
   (lambda (repo)
     (write-file! (build-path repo "scripts" "firn-build")
                  "find . -name '*.nix'\n") ; the recorded find marker is gone
     (check-exn exn:fail:drift?
                (lambda () (derive-consumer
                            (consumer-spec "firn-drift" repo
                                           '((enumerator (kind find-exclude)
                                                         (source "scripts/firn-build")
                                                         (ext ".bnix")
                                                         (find-not-paths ("result"))
                                                         (exclude-relpath-prefixes ())
                                                         (exclude-basenames ())
                                                         (shape-markers ("-name '*.bnix' -not -path './result*'")))))))))))

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
                     (sort (remove-duplicates (consumer-result-relpaths r)) string<?)))]
    [else
     (printf "~a\n" "(skipping live derivation: not all consumer repos checked out)")]))
