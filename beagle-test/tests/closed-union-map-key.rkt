#lang racket/base

(require rackunit
         racket/file
         racket/path
         racket/system
         beagle/private/check
         beagle/private/emit
         beagle/private/parse)

(define tests-dir
  (let-values ([(dir _name _dir?) (split-path (syntax-source #'here))])
    dir))

(define fixture
  (build-path tests-dir
              "fixtures"
              "zig-closed-union-map-key"
              "closed-union-map-key.bgl"))

(define kernel-rt
  (simplify-path
   (build-path tests-dir 'up 'up "beagle-lib" "zig" "beagle_rt.zig")))

(define (zig-program . datums)
  (parse-program
   (map (lambda (datum) (datum->syntax #f datum))
        (cons '(define-target zig) datums))))

(test-case "closed Dyn Map keys require every alternative to be hashable"
  (check-not-exn
   (lambda ()
     (type-check!
      (zig-program
       '(define-mode strict)
       '(defn lookup [entries :- (Map (Dyn String Int) Int)] :- Bool
          (contains? entries "key"))))))
  (check-exn
   #rx"\\(Dyn String Regex\\) does not support clojure-value equality and clojure-hash"
   (lambda ()
     (type-check!
      (zig-program
       '(define-mode strict)
       '(defn lookup [entries :- (Map (Dyn String Regex) Int)] :- Bool
          (contains? entries "key")))))))

(test-case "closed Dyn values behave as logical keys in emitted Zig"
  (define zig (find-executable-path "zig"))
  (check-not-false zig "zig executable is required for this behavior fixture")
  (define stxs (read-beagle-syntax fixture))
  (define prog
    (parse-program
     (cons (datum->syntax #f '(define-target zig)) stxs)
     #:source-path fixture))
  (type-check! prog)
  (define emitted (emit-program prog))
  (define dir (make-temporary-file "closed-union-map-key~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (copy-file kernel-rt (build-path dir "beagle_rt.zig"))
      (define source (build-path dir "closed-union-map-key.zig"))
      (call-with-output-file
       source
       (lambda (out)
         (display emitted out)
         (display
          #<<ZIG

test "closed Dyn values behave as logical map keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rng = rt.Splitmix64.init(1);
    var ctx = rt.Ctx{ .tick = arena.allocator(), .rng = &rng };
    try std.testing.expectEqual(@as(i64, 2), exercise(&ctx));
}
ZIG
          out)))
      (define output (open-output-string))
      (define ok?
        (parameterize ([current-directory dir]
                       [current-output-port output]
                       [current-error-port output])
          (system* zig "test" (path->string source))))
      (check-true ok? (get-output-string output)))
    (lambda () (delete-directory/files dir))))
