#lang racket/base

;; Zig backend golden snapshots (thread 20260612232001, brief §7.1).
;;
;; Each fixtures/zig-golden/NN-name.bgl compiles (target injected) and
;; must match its committed NN-name.zig snapshot byte-for-byte — any
;; diff is a deliberate, reviewed change. Re-bless after a reviewed
;; emitter change with:
;;
;;   BEAGLE_ZIG_BLESS=1 raco test beagle-test/tests/emit-zig.rkt
;;
;; Additionally every snapshot must COMPILE: when `zig` is on PATH the
;; suite runs `zig build-obj -fno-emit-bin` over each snapshot (with the
;; kernel prelude copied alongside), so snapshots can't rot into
;; non-Zig. Without zig the compile check is skipped (snapshot
;; comparison still runs).
;;
;; Also here: pointed-rejection cases — out-of-table IR must error with
;; "not yet supported by zig backend", never silently approximate.

(require rackunit
         racket/file
         racket/path
         racket/string
         racket/system
         beagle/private/parse
         beagle/private/check
         beagle/private/emit)

(define fixtures-dir
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (build-path dir "fixtures" "zig-golden")))

(define kernel-rt
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (simplify-path (build-path dir 'up 'up "kernel" "src" "beagle_rt.zig"))))

(define bless? (and (getenv "BEAGLE_ZIG_BLESS") #t))

(define (compile-zig-src src-path)
  (define stxs (read-beagle-syntax src-path))
  (define forms (cons (datum->syntax #f '(define-target zig)) stxs))
  (define prog (parse-program forms #:source-path src-path))
  (type-check! prog)
  (emit-program prog))

(define (compile-zig-forms . datums)
  (define forms (map (lambda (d) (datum->syntax #f d))
                     (cons '(define-target zig) datums)))
  (define prog (parse-program forms))
  (type-check! prog)
  (emit-program prog))

(define (compile-zig-string src)
  ;; through the REAL beagle reader (brackets/braces), via a temp file.
  (define f (make-temporary-file "zigsrc~a.bgl"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file f #:exists 'replace (lambda (p) (display src p)))
      (compile-zig-src f))
    (lambda () (delete-file f))))

(define ZIG (find-executable-path "zig"))
(unless ZIG
  (displayln "note: zig not on PATH — snapshot compile checks skipped"))

(define (zig-compiles? zig-src name)
  (define dir (make-temporary-file "zigck~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (copy-file kernel-rt (build-path dir "beagle_rt.zig"))
      (define f (build-path dir (format "~a.zig" name)))
      (call-with-output-file f (lambda (p) (display zig-src p)))
      (define out (open-output-string))
      (define ok
        (parameterize ([current-output-port out]
                       [current-error-port out]
                       [current-directory dir])
          (system* ZIG "build-obj" "-fno-emit-bin" (path->string f))))
      (unless ok
        (eprintf "zig compile check failed for ~a:\n~a\n" name
                 (get-output-string out)))
      ok)
    (lambda () (delete-directory/files dir))))

(define fixture-files
  (sort (for/list ([f (in-list (directory-list fixtures-dir))]
                   #:when (regexp-match? #rx"\\.bgl$" (path->string f)))
          (path->string f))
        string<?))

(for ([bgl (in-list fixture-files)])
  (define name (regexp-replace #rx"\\.bgl$" bgl ""))
  (define snap-path (build-path fixtures-dir (string-append name ".zig")))
  (define emitted (compile-zig-src (build-path fixtures-dir bgl)))
  (when bless?
    (call-with-output-file snap-path #:exists 'replace
      (lambda (p) (display emitted p))))
  (test-case (format "golden: ~a matches snapshot" name)
    (check-true (file-exists? snap-path)
                (format "missing snapshot ~a (run with BEAGLE_ZIG_BLESS=1)" name))
    (check-equal? emitted (file->string snap-path)))
  (when ZIG
    (test-case (format "golden: ~a compiles as zig" name)
      (check-true (zig-compiles? emitted name)))))

;; --- determinism: same input → byte-identical output --------------------------

(test-case "emission is deterministic"
  (define f (build-path fixtures-dir "07-loop-recur.bgl"))
  (check-equal? (compile-zig-src f) (compile-zig-src f)))

;; --- pointed rejections (out-of-table IR) --------------------------------------

(define-syntax-rule (check-unsupported name rx form ...)
  (test-case name
    (check-exn (lambda (e)
                 (and (exn:fail? e)
                      (regexp-match? #rx"not yet supported by zig backend" (exn-message e))
                      (regexp-match? rx (exn-message e))))
               (lambda () (compile-zig-forms form ...)))))

(check-unsupported "zig rejects untyped def pointedly"
  #rx"untyped def"
  '(def x 42))

(check-unsupported "zig rejects defn without return annotation"
  #rx"return annotation"
  '(defn f [x :- Int] x))

(define-syntax-rule (check-unsupported/src name rx src)
  (test-case name
    (check-exn (lambda (e)
                 (and (exn:fail? e)
                      (regexp-match? #rx"not yet supported by zig backend" (exn-message e))
                      (regexp-match? rx (exn-message e))))
               (lambda () (compile-zig-string src)))))

(check-unsupported/src "zig rejects map literals pointedly"
  #rx"map literal"
  "(ns g)\n(defn f [x :- Int] :- Int (do {:a x} x))")

(check-unsupported/src "zig rejects multi-arity defn"
  #rx"multi-arity"
  "(ns g)\n(defn f ([a :- Int] :- Int a) ([a :- Int b :- Int] :- Int (+ a b)))")

(check-unsupported "zig rejects variable shift amounts"
  #rx"shift"
  '(defn f [x :- Int n :- Int] :- Int (bit-shift-left x n)))

(check-unsupported "zig rejects / pointing at quot"
  #rx"quot"
  '(defn f [a :- Int b :- Int] :- Int (/ a b)))

(check-unsupported/src "zig rejects general qualified calls"
  #rx"qualified"
  "(ns g)\n(require clojure.string :as str)\n(defn f [s :- String] :- String (str/trim s))")

;; --- Phase 2: world-escape check + promote ------------------------------------

(define-syntax-rule (check-escape name rx src)
  (test-case name
    (check-exn (lambda (e)
                 (and (exn:fail? e)
                      (regexp-match? #rx"world-state type" (exn-message e))
                      (regexp-match? rx (exn-message e))))
               (lambda () (compile-zig-string src)))))

(check-escape "escape: World with a Vec field is rejected at compile time"
  #rx"tick-lifetime field log"
  "(ns g)\n(defrecord World [score :- Int log :- (Vec Int)])\n(defn world-tick [ctx :- Ctx w :- World] :- World (->World (:score w) (:log w)))")

(check-escape "escape: String fields are slices too"
  #rx"strings are slices"
  "(ns g)\n(defrecord World [name :- String])\n(defn world-tick [ctx :- Ctx w :- World] :- World w)")

(check-escape "escape: nested record smuggling a slice is caught"
  #rx"tick-lifetime field xs"
  "(ns g)\n(defrecord Bag [xs :- (Vec Int)])\n(defrecord World [bag :- Bag])\n(defn tick-step [ctx :- Ctx w :- World] :- World w)")

(test-case "value-level promote is the world-tick artifact; systems promote via SoA"
  (define out (compile-zig-string
               "(ns g)\n(defrecord S [v :- Int])\n(defn tick-step [ctx :- Ctx s :- S] :- S s)"))
  (check-false (regexp-match? #rx"pub fn promote\\(" out))
  (check-true (regexp-match? #rx"pub fn tickStepPromoteAll" out)))

;; --- engine layer (script→engine crossing) -------------------------------------

(define ENGINE-SRC
  (string-append
   "(ns g)\n"
   "(defrecord MindIn [x :- Int belief :- Int])\n"
   "(defrecord Obs [sig :- Int])\n"
   "(defrecord StepOut [x :- Int belief :- Int act :- Int])\n"
   "(defn tick-step [ctx :- Ctx m :- MindIn obs :- Obs max-x :- Int] :- StepOut\n"
   "  (->StepOut (+ (:x m) (:sig obs)) (:belief m) 0))"))

(test-case "engine: SoA buffers generated for entity and output records"
  (define out (compile-zig-string ENGINE-SRC))
  (check-true (regexp-match? #rx"pub const MindInSoA = struct" out))
  (check-true (regexp-match? #rx"pub const StepOutSoA = struct" out)))

(test-case "engine: per-system range loop — record params per-entity, scalars broadcast"
  (define out (compile-zig-string ENGINE-SRC))
  (check-true (regexp-match?
               #rx"pub fn tickStepAllRange.tick: std.mem.Allocator, seed: u64, tick_no: u64, in: \\*const MindInSoA, obs: \\[\\]const Obs, max_x: i64, out: \\*StepOutSoA, lo: usize, hi: usize."
               out)))

(test-case "engine: counter-rng policy with a name-derived lane"
  (define out (compile-zig-string ENGINE-SRC))
  (check-true (regexp-match? #rx"rt.Splitmix64.init.rt.mix64.seed" out))
  (check-true (regexp-match? #rx"Lane 0x[0-9A-F]+ derives from the system name" out)))

(test-case "engine: promotion copies world-lifetime fields, transients stay behind"
  (define out (compile-zig-string ENGINE-SRC))
  (check-true (regexp-match? #rx"pub fn tickStepPromoteAll" out))
  (check-true (regexp-match? #rx"@memcpy.next.x.0..n., out.x.0..n.." out))
  (check-true (regexp-match? #rx"@memcpy.next.belief" out))
  (check-false (regexp-match? #rx"next.act" out)))

(define TWO-SYSTEM-SRC
  (string-append
   "(ns g)\n"
   "(defrecord MindIn [x :- Int alarm :- Int])\n"
   "(defrecord MindOut [x :- Int alarm :- Int act :- Int])\n"
   "(defrecord WolfIn [x :- Int energy :- Int])\n"
   "(defrecord WolfOut [x :- Int energy :- Int howl :- Int])\n"
   "(defn mind-step [ctx :- Ctx m :- MindIn] :- MindOut\n"
   "  (->MindOut (:x m) (:alarm m) 0))\n"
   "(defn wolf-step [ctx :- Ctx w :- WolfIn] :- WolfOut\n"
   "  (->WolfOut (:x w) (:energy w) 0))"))

(test-case "engine: two systems — two archetypes, each with stores + loop + promote"
  (define out (compile-zig-string TWO-SYSTEM-SRC))
  (check-true (regexp-match? #rx"pub const MindInSoA = struct" out))
  (check-true (regexp-match? #rx"pub const WolfInSoA = struct" out))
  (check-true (regexp-match? #rx"pub fn mindStepAllRange" out))
  (check-true (regexp-match? #rx"pub fn wolfStepAllRange" out))
  (check-true (regexp-match? #rx"pub fn mindStepPromoteAll" out))
  (check-true (regexp-match? #rx"pub fn wolfStepPromoteAll" out)))

(test-case "engine: per-system rng lanes are distinct"
  (define out (compile-zig-string TWO-SYSTEM-SRC))
  (define lanes (regexp-match* #rx"\\+% 0x([0-9A-F]+)\\)\\)\\)" out #:match-select cadr))
  (check-equal? 2 (length lanes))
  (check-false (equal? (car lanes) (cadr lanes))))

(when ZIG
  (test-case "engine: two-system generated layer compiles as zig"
    (check-true (zig-compiles? (compile-zig-string TWO-SYSTEM-SRC) "two-systems"))))

(test-case "literal-only branches get an @as anchor (zig comptime_int trap)"
  ;; In a binding position, (if c 1 0) is two comptime_int branches under
  ;; runtime control flow — zig rejects it unless one branch is anchored.
  (define out (compile-zig-string
               "(ns g)\n(defn f [x :- Int] :- Int (let [v (if (> x 0) 1 0)] v))"))
  (check-true (regexp-match? #rx"@as.i64, 1." out)))

(when ZIG
  (test-case "literal-branch if compiles in binding position"
    (check-true (zig-compiles?
                 (compile-zig-string
                  "(ns g)\n(defn f [x :- Int] :- Int (let [v (if (> x 0) 1 0)] v))")
                 "literal-if-binding"))))

(test-case "engine: a -step fn without Ctx first is an ordinary function"
  (define out (compile-zig-string
               "(ns g)\n(defn two-step [a :- Int b :- Int] :- Int (+ a b))"))
  (check-false (regexp-match? #rx"AllRange" out))
  (check-true (regexp-match? #rx"pub fn twoStep" out)))

(test-case "engine: entity = output dedups to a single SoA struct"
  (define out (compile-zig-string
               "(ns g)\n(defrecord S [v :- Int])\n(defn tick-step [ctx :- Ctx s :- S] :- S s)"))
  (check-equal? 1 (length (regexp-match* #rx"pub const SSoA = struct" out))))

(test-case "engine: world-tick alone gets promote but no engine layer"
  (define out (compile-zig-string
               "(ns g)\n(defrecord World [score :- Int])\n(defn world-tick [ctx :- Ctx w :- World] :- World w)"))
  (check-true (regexp-match? #rx"pub fn promote" out))
  (check-false (regexp-match? #rx"tickAllRange" out)))

(when ZIG
  (test-case "engine: generated engine layer compiles as zig"
    (check-true (zig-compiles? (compile-zig-string ENGINE-SRC) "engine-layer"))))

(check-unsupported/src "engine: param 1 must be the entity record"
  #rx"tick-step param 1"
  "(ns g)\n(defrecord S [v :- Int])\n(defn tick-step [ctx :- Ctx n :- Int] :- S (->S n))")

(check-unsupported/src "engine: entity fields must be scalar for the commit memcpy"
  #rx"engine entity record with non-scalar field"
  (string-append
   "(ns g)\n(defrecord Inner [v :- Int])\n"
   "(defrecord E [inner :- Inner])\n(defrecord O [v :- Int])\n"
   "(defn tick-step [ctx :- Ctx e :- E] :- O (->O (:v (:inner e))))"))

(check-unsupported/src "engine: param names can't collide with engine bindings"
  #rx"seed collides with a generated engine binding"
  "(ns g)\n(defrecord S [v :- Int])\n(defn tick-step [ctx :- Ctx s :- S seed :- Int] :- S s)")

(check-unsupported/src "engine: name-matched promotion fields must agree on type"
  #rx"share a name but not a type"
  (string-append
   "(ns g)\n(defrecord E [x :- Int])\n(defrecord O [x :- Float])\n"
   "(defn tick-step [ctx :- Ctx e :- E] :- O (->O 1.0))"))

