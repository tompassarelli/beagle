#lang racket/base

(require rackunit
         racket/string
         racket/port
         beagle/private/parse
         beagle/private/emit
         beagle/private/types)

(define (mt . xs) (cons MAP-TAG xs))
(define (br . xs) (cons '#%brackets xs))

(define (nix-emit src)
  (define stxs
    (parameterize ([read-square-bracket-with-tag '#%brackets])
      (with-input-from-string src
        (lambda ()
          (let loop ([acc '()])
            (define d (read-syntax 'test))
            (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))
  (define prog
    (with-handlers ([exn:fail? (lambda (e) #f)])
      (parse-program stxs)))
  (and prog
       (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
         (string-trim (emit-program prog)))))

(define (nix-emit-forms . forms)
  (define stxs (map (lambda (f) (datum->syntax #f f)) forms))
  (define prog
    (with-handlers ([exn:fail? (lambda (e) #f)])
      (parse-program stxs)))
  (and prog
       (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
         (string-trim (emit-program prog)))))

;; --- basic forms -----------------------------------------------------------

(test-case "def emits let binding"
  (define out (nix-emit "(define-target nix) (def x : Int 42)"))
  (check-true (string-contains? out "x = 42;"))
  (check-true (string-contains? out "let")))

(test-case "defn emits curried function"
  (define out (nix-emit "(define-target nix) (defn add [(a : Int) (b : Int)] : Int (+ a b))"))
  (check-true (string-contains? out "add = a: b:"))
  (check-true (string-contains? out "a + b")))

(test-case "fn emits lambda"
  (define out (nix-emit "(define-target nix) (def f : Any (fn [(x : Int)] : Int (+ x 1)))"))
  (check-true (string-contains? out "x:"))
  (check-true (string-contains? out "x + 1")))

(test-case "if emits if/then/else"
  (define out (nix-emit "(define-target nix) (if true 1 0)"))
  (check-true (string-contains? out "if true then 1 else 0")))

(test-case "let emits let/in"
  (define out (nix-emit "(define-target nix) (let [x 1 y 2] (+ x y))"))
  (check-true (string-contains? out "let"))
  (check-true (string-contains? out "x = 1;"))
  (check-true (string-contains? out "y = 2;"))
  (check-true (string-contains? out "in"))
  (check-true (string-contains? out "x + y")))

;; --- data structures -------------------------------------------------------

(test-case "vector emits nix list"
  (define out (nix-emit "(define-target nix) [1 2 3]"))
  (check-true (string-contains? out "[ 1 2 3 ]")))

(test-case "long list breaks to multi-line"
  (define out (nix-emit "(define-target nix) [\"local-fs.target\" \"suspend.target\" \"suspend-then-hibernate.target\" \"hibernate.target\"]"))
  (check-true (and out (string-contains? out "[\n")))
  (check-true (and out (string-contains? out "\"local-fs.target\""))))

(test-case "map emits nix attrset"
  (define out (nix-emit-forms '(define-target nix) `(def m : Any ,(mt ':a 1 ':b 2))))
  (check-true (string-contains? out "a = 1;"))
  (check-true (string-contains? out "b = 2;"))
  (check-true (string-contains? out "{")))

(test-case "nested attrset"
  (define inner (mt ':inner 42))
  (define out (nix-emit-forms '(define-target nix) `(def m : Any ,(mt ':outer inner))))
  (check-true (and out (string-contains? out "outer ="))))

;; --- records ---------------------------------------------------------------

(test-case "defrecord emits constructor + accessors"
  (define out (nix-emit "(define-target nix) (defrecord Point [(x : Int) (y : Int)])"))
  (check-true (string-contains? out "mkPoint = x: y:"))
  (check-true (string-contains? out "_tag = \"point\""))
  (check-true (string-contains? out "point-x = r: r.x;"))
  (check-true (string-contains? out "point-y = r: r.y;")))

;; --- nix builtins ----------------------------------------------------------

(test-case "builtins/ calls emit as builtins.*"
  (define out (nix-emit "(define-target nix) (builtins/length [1 2 3])"))
  (check-true (string-contains? out "builtins.length")))

(test-case "lib/ calls emit as lib.*"
  (define out (nix-emit "(define-target nix) (lib/mkIf true {:enable true})"))
  (check-true (string-contains? out "lib.mkIf true")))

;; --- stdlib fns ------------------------------------------------------------

(test-case "map fn emits builtins.map"
  (define out (nix-emit-forms '(define-target nix)
    `(map (fn ,(br '(x : Int)) : Int (+ x 1)) ,(br 1 2 3))))
  (check-true (string-contains? out "builtins.map")))

(test-case "filter fn emits builtins.filter"
  (define out (nix-emit-forms '(define-target nix)
    `(filter (fn ,(br '(x : Int)) : Bool (> x 0)) ,(br 1 -1 2))))
  (check-true (string-contains? out "builtins.filter")))

(test-case "nil? emits null check"
  (define out (nix-emit "(define-target nix) (nil? x)"))
  (check-true (string-contains? out "== null")))

(test-case "count emits builtins.length"
  (define out (nix-emit "(define-target nix) (count [1 2 3])"))
  (check-true (string-contains? out "builtins.length")))

(test-case "merge emits //"
  (define out (nix-emit "(define-target nix) (merge {:a 1} {:b 2})"))
  (check-true (string-contains? out "//")))

(test-case "concat emits ++"
  (define out (nix-emit "(define-target nix) (concat [1] [2])"))
  (check-true (string-contains? out "++")))

;; --- keyword access --------------------------------------------------------

(test-case "keyword access emits field selection"
  (define out (nix-emit "(define-target nix) (:name person)"))
  (check-true (string-contains? out "person.name")))

;; --- dotted option paths ---------------------------------------------------

(test-case "dotted keyword keys become Nix option paths"
  (define out (nix-emit-forms '(define-target nix) `(def m : Any ,(mt ':services.openssh.enable #t))))
  (check-true (string-contains? out "services.openssh.enable = true;")))

;; --- cond ------------------------------------------------------------------

(test-case "cond emits nested if/then/else"
  (define out (nix-emit "(define-target nix) (cond [true 1] [false 2])"))
  (check-true (string-contains? out "if true then 1 else"))
  (check-true (string-contains? out "if false then 2")))

;; --- with (record update) --------------------------------------------------

(test-case "with emits attrset merge"
  (define out (nix-emit "(define-target nix) (defrecord Foo [(a : Int)]) (with (->Foo 1) [:a 2])"))
  (check-true (string-contains? out "//")))

;; --- string ops ------------------------------------------------------------

(test-case "str emits string concatenation"
  (define out (nix-emit "(define-target nix) (str \"hello\" \" \" \"world\")"))
  (check-true (string-contains? out "\"hello\" + \" \" + \"world\"")))

;; --- comparison operators --------------------------------------------------

(test-case "comparison operators"
  (define out (nix-emit "(define-target nix) (< 1 2)"))
  (check-true (string-contains? out "1 < 2"))
  (define out2 (nix-emit "(define-target nix) (= 1 1)"))
  (check-true (string-contains? out2 "1 == 1")))

;; === Nix-specific forms (Nisp parity) ======================================

;; --- Phase 1: Module-writing core ------------------------------------------

(test-case "fn-set emits attrset-pattern lambda"
  (define out (nix-emit "(define-target nix) (fn-set (a b) (+ a b))"))
  (check-true (and out (string-contains? out "{ a, b }:")))
  (check-true (and out (string-contains? out "a + b"))))

(test-case "fn-set with defaults"
  (define out (nix-emit "(define-target nix) (fn-set (a (b 5)) (+ a b))"))
  (check-true (and out (string-contains? out "b ? 5")))
  (check-true (and out (string-contains? out "{ a, b ? 5 }:"))))

(test-case "module emits ... in formals"
  (define out (nix-emit "(define-target nix) (module [config lib pkgs] config)"))
  (check-true (and out (string-contains? out "...")))
  (check-true (and out (string-contains? out "{ config, lib, pkgs, ... }:"))))

(test-case "overlay emits two formals without rest"
  (define out (nix-emit "(define-target nix) (overlay [final prev] {:foo 1})"))
  (check-true (and out (string-contains? out "{ final, prev }:")))
  (check-false (and out (string-contains? out "..."))))

(test-case "inherit emits inherit"
  (define out (nix-emit "(define-target nix) (inherit a b c)"))
  (check-true (and out (string-contains? out "inherit a b c;"))))

(test-case "inherit-from emits inherit (ns)"
  (define out (nix-emit "(define-target nix) (inherit-from pkgs vim git)"))
  (check-true (and out (string-contains? out "inherit (pkgs) vim git;"))))

(test-case "with emits with"
  (define out (nix-emit "(define-target nix) (with lib [1 2 3])"))
  (check-true (and out (string-contains? out "with lib;")))
  (check-true (and out (string-contains? out "[ 1 2 3 ]"))))

(test-case "s emits interpolated string"
  (define out (nix-emit "(define-target nix) (s \"hello \" name \"!\")"))
  (check-true (and out (string-contains? out "\"hello ${name}!\""))))

(test-case "s with only literals"
  (define out (nix-emit "(define-target nix) (s \"hello\" \" world\")"))
  (check-true (and out (string-contains? out "\"hello world\""))))

(test-case "p emits path literal"
  (define out (nix-emit "(define-target nix) (p \"./foo/bar.nix\")"))
  (check-true (and out (string-contains? out "./foo/bar.nix"))))

;; --- Phase 2: Nix semantic essentials --------------------------------------

(test-case "rec-attrs emits recursive attrset"
  (define out (nix-emit "(define-target nix) (rec-attrs x 1 y x)"))
  (check-true (and out (string-contains? out "rec {")))
  (check-true (and out (string-contains? out "x = 1;")))
  (check-true (and out (string-contains? out "y = x;"))))

(test-case "assert emits assert"
  (define out (nix-emit "(define-target nix) (assert true 42)"))
  (check-true (and out (string-contains? out "assert true; 42"))))

(test-case "get-or emits select with or-default"
  (define out (nix-emit "(define-target nix) (get-or config a.b.c \"fallback\")"))
  (check-true (and out (string-contains? out "config.a.b.c or \"fallback\""))))

(test-case "has emits has-attr check"
  (define out (nix-emit "(define-target nix) (has config a.b)"))
  (check-true (and out (string-contains? out "config ? a.b"))))

(test-case "ms emits multiline string"
  (define out (nix-emit "(define-target nix) (ms \"line one\" \"line two\")"))
  (check-true (and out (string-contains? out "''")))
  (check-true (and out (string-contains? out "line one")))
  (check-true (and out (string-contains? out "line two"))))

(test-case "search-path emits search path"
  (define out (nix-emit "(define-target nix) (search-path nixpkgs)"))
  (check-true (and out (string-contains? out "<nixpkgs>"))))

;; --- Phase 3: Operator/convenience parity ----------------------------------

(test-case "pipe-to emits |>"
  (define out (nix-emit "(define-target nix) (pipe-to x f)"))
  (check-true (and out (string-contains? out "x |> f"))))

(test-case "pipe-from emits <|"
  (define out (nix-emit "(define-target nix) (pipe-from f x)"))
  (check-true (and out (string-contains? out "f <| x"))))

(test-case "implies emits logical implication"
  (define out (nix-emit "(define-target nix) (implies a b)"))
  (check-true (and out (string-contains? out "a -> b"))))

;; --- escape hatch removed --------------------------------------------------

(test-case "unsafe-nix is rejected at parse time"
  ;; nix-emit swallows the parse error and returns #f when the program fails.
  (check-false (nix-emit "(def x : Any (unsafe-nix \"hello\"))")))

;; --- qualified calls: / → . --------------------------------------------------

(test-case "pkgs/ call emits as pkgs.fn"
  (define out (nix-emit "(define-target nix) (pkgs/writeScriptBin \"hello\" \"body\")"))
  (check-true (and out (string-contains? out "pkgs.writeScriptBin")))
  (check-false (string-contains? out "pkgs/writeScriptBin")))

(test-case "arbitrary ns/ call emits as ns.fn"
  (define out (nix-emit "(define-target nix) (config/boot.kernelPackages.kernel)"))
  (check-true (and out (string-contains? out "config.boot.kernelPackages.kernel"))))

(test-case "ns/ symbol in non-call position emits as ns.sym"
  (define out (nix-emit "(define-target nix) (def x : Any pkgs/hello)"))
  (check-true (and out (string-contains? out "pkgs.hello")))
  (check-false (string-contains? out "pkgs/hello")))

;; --- not → ! -----------------------------------------------------------------

(test-case "not emits ! prefix operator"
  (define out (nix-emit "(define-target nix) (not true)"))
  (check-true (and out (string-contains? out "!true")))
  (check-false (string-contains? out "not true")))

(test-case "not with complex expr wraps inner in parens"
  (define out (nix-emit "(define-target nix) (not (= x 1))"))
  (check-true (and out (string-contains? out "!(")))
  (check-true (and out (string-contains? out "==")))
  (check-false (string-contains? out "((!")))

;; --- ms + s inline interpolation ---------------------------------------------

(test-case "ms with s inlines interpolation without double-wrapping"
  (define out (nix-emit "(define-target nix) (ms (s \"#!\" pkgs.bash \"/bin/bash\") \"echo hi\")"))
  (check-true (and out (string-contains? out "#!${pkgs.bash}/bin/bash")))
  (check-false (string-contains? out "${\"")))
