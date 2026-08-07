#lang racket/base

;; `beagle ts-externs` maps TypeScript declarations to typed beagle wrappers.
;; The mapping must degrade to Any rather than guess, and the emitted module must
;; itself parse and type-check.

(require rackunit
         racket/runtime-path
         racket/list
         racket/string
         racket/file
         racket/port
         beagle/private/ts-externs
         beagle/private/parse
         beagle/private/check)

(define-runtime-path fixtures-dir "fixtures/ts-externs")

(test-case "primitives map, everything richer degrades to Any"
  (check-equal? (ts-type->beagle "number") "Float")
  (check-equal? (ts-type->beagle "string") "String")
  (check-equal? (ts-type->beagle "boolean") "Bool")
  (check-equal? (ts-type->beagle "void") "Nil")
  (check-equal? (ts-type->beagle "number[]") "(Vec Float)")
  (check-equal? (ts-type->beagle "Array<string>") "(Vec String)")
  (check-equal? (ts-type->beagle "Promise<number>") "(Promise Float)")
  ;; A nullable primitive keeps its payload type; beagle has no optionality.
  (check-equal? (ts-type->beagle "number | null") "Float")
  (check-equal? (ts-type->beagle "(Color | Texture) | null") "Any")
  (check-equal? (ts-type->beagle "Object3D") "Any")
  (check-equal? (ts-type->beagle "{ a: number }") "Any")
  (check-equal? (ts-type->beagle "(x: number) => void") "Any")
  (check-equal? (ts-type->beagle "this") "Any"))

(define (class-named name)
  (define-values (classes _reexports)
    (parse-declarations (build-path fixtures-dir "shapes.d.ts")))
  (findf (lambda (c) (string=? (ts-class-name c) name)) classes))

(test-case "a class declaration parses through generics, JSDoc, and modifiers"
  (define box (class-named "Box"))
  (check-true (ts-class? box))
  (check-equal? (ts-class-base box) "Thing")
  ;; The JSDoc mentions `class Decoy {`: comments must be stripped before the scan.
  (check-false (class-named "Decoy"))
  (define names (map ts-member-name (ts-class-members box)))
  (check-not-false (member "scale" names) "overloaded method is present")
  (check-false (member "hidden" names) "a private member is dropped"))

(test-case "export default class parses; type-only re-export edges are marked"
  (define-values (classes _re) (parse-declarations (build-path fixtures-dir "ghost.d.ts")))
  (define ghost (findf (lambda (c) (string=? (ts-class-name c) "Ghost")) classes))
  (check-true (ts-class? ghost))
  (check-not-false (member "fade" (map ts-member-name (ts-class-members ghost))))
  (define-values (_cs reexports) (parse-declarations (build-path fixtures-dir "index.d.ts")))
  (check-equal? reexports
                '(("./shapes.js" . #f) ("./other.js" . #f) ("./ghost.js" . #t))))

(test-case "generated module parses and type-checks"
  (define out (make-temporary-file "beagle-ts-externs-~a.bjs"))
  (dynamic-wind
    void
    (lambda ()
      (parameterize ([current-output-port (open-output-nowhere)])
        (run-ts-externs (list (path->string (build-path fixtures-dir "index.d.ts"))
                              "--module" "shapes"
                              "--ns" "shapes.api"
                              "--out" (path->string out))))
      (define text (file->string out))
      ;; Both re-export forms are followed, so a class declared in another file
      ;; and named in the barrel is included.
      (check-regexp-match #rx"make-thing" text)
      ;; Optional params become clauses of one multi-arity defn, not suffixed names.
      (check-regexp-match #rx"defn make-box\n" text)
      (check-false (regexp-match? #rx"make-box-2" text))
      ;; A variadic signature becomes a rest param forwarded with js/spread.
      (check-regexp-match #rx"box-add \\[self: Any & children: Any\\]" text)
      (check-regexp-match #rx"js/spread children" text)
      ;; A primitive property gets a reader and a writer; a non-primitive gets neither.
      (check-regexp-match #rx"defn box-width \\[self: Any\\] -> Float" text)
      (check-regexp-match #rx"defn set-box-width!" text)
      (check-false (regexp-match? #rx"defn box-nested" text))
      ;; A readonly property gets a reader only.
      (check-regexp-match #rx"defn box-is-box" text)
      (check-false (regexp-match? #rx"set-box-is-box!" text))
      ;; A type-only re-export keeps its instance wrappers but nothing that
      ;; names the class at runtime: no import, no constructor, no statics.
      (check-regexp-match #rx"defn ghost-fade" text)
      (check-regexp-match #rx"defn ghost-opacity" text)
      (check-regexp-match #rx"defn set-ghost-opacity!" text)
      (check-false (regexp-match? #rx"make-ghost" text))
      (check-false (regexp-match? #rx"ghost-conjure" text))
      (let ([refer (string-split (cadr (regexp-match #rx":refer \\[([^]]*)\\]" text)))])
        (check-not-false (member "Box" refer))
        (check-not-false (member "Thing" refer))
        (check-false (member "Ghost" refer)))
      (check-not-exn
       (lambda () (type-check! (parse-program (read-beagle-syntax out) #:source-path out)))))
    (lambda () (delete-file out))))
