#lang racket/base

;; .bpy fixture coverage. Each fixture exercises a different surface
;; corner of the Python target. We compile the source and assert structural
;; properties of the emitted Python.

(require rackunit
         racket/string
         racket/port
         racket/file
         racket/runtime-path
         beagle/private/parse
         beagle/private/emit
         beagle/lang/reader-impl)

(define-runtime-path fixtures-dir "fixtures")

(define (compile-bpy-file path)
  (define src (file->string path))
  (define lines (string-split src "\n"))
  (define body-lines
    (filter (lambda (l) (not (string-prefix? l "#lang"))) lines))
  (define body (string-append "(define-target py)\n"
                              (string-join body-lines "\n")))
  (define stxs
    (with-input-from-string body
      (lambda ()
        (let loop ([acc '()])
          (define d (beagle-read-syntax (path->string path) (current-input-port)))
          (if (eof-object? d) (reverse acc) (loop (cons d acc)))))))
  (define prog (parse-program stxs))
  (string-trim (emit-program prog)))

(define (py-fixture name)
  (compile-bpy-file (build-path fixtures-dir name)))

;; --- string methods --------------------------------------------------------

(test-case "py-string-methods fixture"
  (define out (py-fixture "py-string-methods.bpy"))
  (check-true (string-contains? out "s.upper()"))
  (check-true (string-contains? out "s.lower()"))
  (check-true (string-contains? out "s.strip()"))
  (check-true (string-contains? out "s.split(\" \")"))
  (check-true (string-contains? out "\"-\".join(parts)"))
  (check-true (string-contains? out "s.replace(\"a\", \"@\")"))
  (check-true (string-contains? out "s.startswith(\"hi\")"))
  (check-true (string-contains? out "s.endswith(\"!\")"))
  (check-true (string-contains? out "s.count(\" \")")))

;; --- list / dict / set methods ---------------------------------------------

(test-case "py-list-dict-set fixture"
  (define out (py-fixture "py-list-dict-set.bpy"))
  (check-true (string-contains? out "xs.append(x)"))
  (check-true (string-contains? out "xs.extend(ys)"))
  (check-true (string-contains? out "xs.pop()"))
  (check-true (string-contains? out "d.keys()"))
  (check-true (string-contains? out "d.values()"))
  (check-true (string-contains? out "d.get(k, 0)"))
  (check-true (string-contains? out "a.union(b)"))
  (check-true (string-contains? out "a.intersection(b)"))
  (check-true (string-contains? out "len(xs)"))
  (check-true (string-contains? out "max(xs)"))
  (check-true (string-contains? out "min(xs)"))
  (check-true (string-contains? out "sum(xs)"))
  (check-true (string-contains? out "sorted(xs)"))
  (check-true (string-contains? out "reversed(xs)")))

;; --- classes (defrecord → dataclass) ---------------------------------------

(test-case "py-classes fixture — defrecord emits frozen dataclass"
  (define out (py-fixture "py-classes.bpy"))
  (check-true (string-contains? out "from dataclasses import dataclass"))
  (check-true (string-contains? out "@dataclass(frozen=True)"))
  (check-true (string-contains? out "class Account:"))
  (check-true (string-contains? out "holder: object"))
  (check-true (string-contains? out "balance: object"))
  (check-true (string-contains? out "class Transaction:"))
  ;; record accessor functions
  (check-true (string-contains? out "def account_holder(r):"))
  (check-true (string-contains? out "return r.holder"))
  ;; constructor call
  (check-true (string-contains? out "Account(account_holder(a)")))

;; --- comprehensions --------------------------------------------------------

(test-case "py-comprehensions fixture — for → list comprehension"
  (define out (py-fixture "py-comprehensions.bpy"))
  (check-true (string-contains? out "[(x * x) for x in xs]"))
  (check-true (string-contains? out "for x in xs if "))
  ;; nested for
  (check-true (string-contains? out "for x in xs for y in ys"))
  ;; range
  (check-true (string-contains? out "range(n)"))
  (check-true (string-contains? out "range(a, b)")))

;; --- exceptions / deferror / try-catch -------------------------------------

(test-case "py-exceptions fixture — deferror → class hierarchy, try/except"
  (define out (py-fixture "py-exceptions.bpy"))
  (check-true (string-contains? out "class DomainError(Exception):"))
  (check-true (string-contains? out "class Overflow(DomainError):"))
  (check-true (string-contains? out "class Underflow(DomainError):"))
  (check-true (string-contains? out "class BadInput(DomainError):"))
  (check-true (string-contains? out "try:"))
  (check-true (string-contains? out "except ZeroDivisionError as e:"))
  (check-true (string-contains? out "except ValueError as e:")))

;; --- stdlib modules (math, json) — slashed names → dotted ------------------

(test-case "py-stdlib-modules fixture — slashed-name → dotted Python"
  (define out (py-fixture "py-stdlib-modules.bpy"))
  ;; math/sqrt → math.sqrt (not math/sqrt, which would be invalid Python)
  (check-true (string-contains? out "math.pi"))
  (check-true (string-contains? out "math.sqrt(n)"))
  (check-true (string-contains? out "math.floor(n)"))
  (check-true (string-contains? out "math.ceil(n)"))
  (check-false (string-contains? out "math/sqrt"))
  (check-true (string-contains? out "json.dumps(obj"))
  (check-true (string-contains? out "json.loads(s)"))
  (check-false (string-contains? out "json/loads")))

;; --- match / defunion / cond -----------------------------------------------

(test-case "py-match fixture — defunion → ADT, match → match/case"
  (define out (py-fixture "py-match.bpy"))
  (check-true (string-contains? out "class Shape:"))
  (check-true (string-contains? out "class Circle(Shape):"))
  (check-true (string-contains? out "class Square(Shape):"))
  (check-true (string-contains? out "class Rect(Shape):"))
  (check-true (string-contains? out "match s:"))
  (check-true (string-contains? out "case Circle(r):"))
  (check-true (string-contains? out "case Rect(w, h):"))
  ;; cond → if/elif/else
  (check-true (string-contains? out "if (n == 0):"))
  (check-true (string-contains? out "elif (n == 1):"))
  (check-true (string-contains? out "else:")))

;; --- basic / record / loop / try (existing fixture) ------------------------

(test-case "pytest fixture — basic forms still emit"
  (define out (py-fixture "pytest.bpy"))
  (check-true (string-contains? out "class Point:"))
  (check-true (string-contains? out "def distance(p):"))
  (check-true (string-contains? out "def classify(n):"))
  (check-true (string-contains? out "def factorial(n):"))
  ;; loop/recur → while loop or recursion
  (check-true (or (string-contains? out "while ")
                  (string-contains? out "return factorial")))
  ;; try/catch
  (check-true (string-contains? out "try:"))
  (check-true (string-contains? out "except Exception as e:")))
