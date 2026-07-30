#lang racket/base

(require racket/file
         racket/runtime-path
         racket/string
         rackunit)

(define-runtime-path test-dir ".")
(define root (simplify-path (build-path test-dir ".." "..")))

(define (repo-file path)
  (file->string (build-path root path)))

(define pin-path "contrib/downstream/fram-ci-revision")
(define pin-source (repo-file pin-path))
(define pin (string-trim pin-source))
(define test-workflow (repo-file ".github/workflows/test.yml"))
(define native-workflow (repo-file ".github/workflows/native.yml"))
(define lockstep-workflow (repo-file ".github/workflows/fram-lockstep.yml"))

(define (literal-count text needle)
  (length (regexp-match* (regexp (regexp-quote needle)) text)))

(define (release-workflow-valid? workflow)
  (and
   (= (literal-count workflow "repository: tompassarelli/fram") 1)
   (= (literal-count workflow pin-path) 1)
   (= (literal-count workflow "id: fram-revision") 1)
   (= (literal-count workflow
                     "ref: ${{ steps.fram-revision.outputs.revision }}")
      1)
   (= (literal-count workflow pin) 0)
   (null? (regexp-match* #px"\\b[0-9a-f]{40}\\b" workflow))))

(test-case "Fram compatibility revision is one canonical commit"
  (check-regexp-match #px"^[0-9a-f]{40}\n$" pin-source)
  (for ([workflow (in-list (list test-workflow native-workflow))])
    (check-true (release-workflow-valid? workflow))))

(test-case "release workflows reject a second divergent Fram checkout"
  (define divergent-checkout
    (string-append
     "\n      - uses: actions/checkout@v5\n"
     "        with:\n"
     "          repository: tompassarelli/fram\n"
     "          ref: 1111111111111111111111111111111111111111\n"))
  (for ([workflow (in-list (list test-workflow native-workflow))])
    (check-false
     (release-workflow-valid? (string-append workflow divergent-checkout)))))

(test-case "moving Fram main is isolated to a non-release lockstep workflow"
  (check-regexp-match #px"(?m:^  workflow_dispatch:$)" lockstep-workflow)
  (check-regexp-match #px"(?m:^  schedule:$)" lockstep-workflow)
  (check-false (regexp-match? #px"(?m:^  (push|pull_request):)" lockstep-workflow))
  (check-equal? (literal-count lockstep-workflow pin-path) 0)
  (check-equal? (literal-count lockstep-workflow "ref:") 0)
  (check-equal?
   (literal-count lockstep-workflow "repository: tompassarelli/fram")
   1))
