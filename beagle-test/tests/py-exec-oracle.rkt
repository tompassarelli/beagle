#lang racket/base

;; Execution oracle for Python fixtures: compile each .bpy via beagle-build,
;; then exercise the emitted Python with a known driver. Catches semantic
;; bugs (NameError, AttributeError, wrong value) that `ast.parse` cannot —
;; e.g. the slashed-name bug where `(math/sqrt x)` was emitting valid-but-
;; wrong Python `math/sqrt(x)` (division, NameError at runtime).
;;
;; Per-fixture: emit to a temp dir, then run a small Python driver that
;; imports the emitted module + calls functions + prints expected output.
;; Compare stdout to the expected string.

(require rackunit
         racket/string
         racket/port
         racket/system
         racket/runtime-path
         racket/file)

(define-runtime-path fixtures-dir "fixtures")
(define-runtime-path beagle-build "../../bin/beagle-build")

(define tmp-dir (make-temporary-file "beagle-py-oracle-~a" 'directory))

(define (emit-and-run name driver-code)
  (define src (build-path fixtures-dir (string-append name ".bpy")))
  (define out (build-path tmp-dir (string-append name ".py")))
  ;; Beagle's emit produces snake_case module names; the driver imports
  ;; from the file stem directly.
  (define module-name (string-replace name "-" "_"))
  (parameterize ([current-output-port (open-output-string)]
                 [current-error-port  (open-output-string)])
    (system* (path->string beagle-build) (path->string src) (path->string out)))
  ;; Make sure the module file exists (rename if beagle wrote snake-case)
  (define snake-out (build-path tmp-dir (string-append module-name ".py")))
  (when (and (file-exists? out) (not (file-exists? snake-out)))
    (copy-file out snake-out #t))
  (define full-script
    (string-append
     "import sys\n"
     (format "sys.path.insert(0, '~a')\n" (path->string tmp-dir))
     (format "from ~a import *\n" module-name)
     driver-code))
  (define out-port (open-output-string))
  (define err-port (open-output-string))
  (define ok?
    (parameterize ([current-output-port out-port]
                   [current-error-port  err-port])
      (system* "/run/current-system/sw/bin/python3" "-c" full-script)))
  (values ok? (get-output-string out-port) (get-output-string err-port)))

(test-case "py-string-methods — runtime behavior matches"
  (define-values (ok? out err)
    (emit-and-run "py-string-methods" #<<PY
print(shout('hello'))
print(whisper('WORLD'))
print(trim_edges('  hi  '))
print(words('one two three'))
print(join_with_dash(['a', 'b', 'c']))
print(swap_vowels('banana'))
print(starts_with_hi_p('hi there'))
print(count_spaces('a b c'))
PY
    ))
  (check-true ok? err)
  (check-equal? out "HELLO\nworld\nhi\n['one', 'two', 'three']\na-b-c\nb@n@n@\nTrue\n2\n"))

(test-case "py-list-dict-set — runtime behavior matches"
  (define-values (ok? out err)
    (emit-and-run "py-list-dict-set" #<<PY
xs = [1, 2, 3]
append_one(xs, 4)
print(xs)
print(pop_last(xs))
print(dict_get_default({'a': 5}, 'a'))
print(dict_get_default({'a': 5}, 'missing'))
print(len_of([1, 2, 3, 4]))
print(sum_of([1, 2, 3, 4]))
print(sorted_of([3, 1, 2]))
PY
    ))
  (check-true ok? err)
  (check-equal? out "[1, 2, 3, 4]\n4\n5\n0\n4\n10\n[1, 2, 3]\n"))

(test-case "py-classes — defrecord dataclass roundtrip"
  (define-values (ok? out err)
    (emit-and-run "py-classes" #<<PY
a = Account('Alice', 100.0)
b = deposit(a, 50.0)
c = withdraw(b, 30.0)
print(account_holder(c))
print(account_balance(c))
t = Transaction('A', 'B', 25.0)
print(describe_txn(t))
PY
    ))
  (check-true ok? err)
  (check-equal? out "Alice\n120.0\nA -> B: 25.0\n"))

(test-case "py-comprehensions — list comprehension emit runs"
  (define-values (ok? out err)
    (emit-and-run "py-comprehensions" #<<PY
print(squares([1, 2, 3, 4]))
print(keep_evens([1, 2, 3, 4, 5, 6]))
print(count_to(5))
print(count_from_to(2, 5))
print(doubled_sum([1, 2, 3]))
PY
    ))
  (check-true ok? err)
  (check-equal? out "[1, 4, 9, 16]\n[2, 4, 6]\n[0, 1, 2, 3, 4]\n[2, 3, 4]\n12\n"))

(test-case "py-exceptions — deferror hierarchy + try/except"
  (define-values (ok? out err)
    (emit-and-run "py-exceptions" #<<PY
# defunion-style class hierarchy
print(issubclass(Overflow, DomainError))
print(issubclass(BadInput, DomainError))
# try/except short-circuits
print(safe_divide(10, 2))
print(safe_divide(10, 0))
print(safe_int_parse('42'))
print(safe_int_parse('not a number'))
PY
    ))
  (check-true ok? err)
  (check-equal? out "True\nTrue\n5.0\n0\n42\n-1\n"))

(test-case "py-stdlib-modules — slashed-name → dotted Python runs"
  (define-values (ok? out err)
    (emit-and-run "py-stdlib-modules" #<<PY
# Confirms math.pi, math.sqrt etc. actually run — would have caught
# the original `math/sqrt(n)` slashed-name bug instantly.
print(round(pi_times(2.0), 4))
print(sqrt_of(16.0))
print(floor_of(3.7))
print(ceil_of(3.2))
print(to_json([1, 2, 3]))
print(from_json('[1, 2, 3]'))
PY
    ))
  (check-true ok? err)
  (check-equal? out "6.2832\n4.0\n3\n4\n[1, 2, 3]\n[1, 2, 3]\n"))

(test-case "py-match — match/case + defunion ADT"
  (define-values (ok? out err)
    (emit-and-run "py-match" #<<PY
print(area(Circle(2.0)))
print(area(Square(3.0)))
print(area(Rect(2.0, 4.0)))
print(classify(0))
print(classify(2))
print(classify(99))
print(describe(Circle(1.0)))
print(describe(Rect(1.0, 2.0)))
PY
    ))
  (check-true ok? err)
  (check-equal? out "12.56636\n9.0\n8.0\nzero\ntwo\nmany\nround\nrectangular\n"))
