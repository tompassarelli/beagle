#lang racket/base

(require rackunit
         racket/file
         racket/string
         beagle/private/parse
         beagle/private/signature-format)

(define (with-source source proc)
  (define path (make-temporary-file "beagle-signature-format-~a.bclj"))
  (dynamic-wind
    (lambda ()
      (call-with-output-file path
        (lambda (out) (display source out))
        #:exists 'truncate/replace))
    (lambda () (proc path))
    (lambda () (when (file-exists? path) (delete-file path)))))

(define (formatted source)
  (with-source
   source
   (lambda (path)
     (define edits (signature-layout-edits path))
     (values (apply-signature-layout-edits source edits) edits))))

(test-case "single flat unrefined pair is already canonical"
  (define source "(defn greet [name String] String name)\n")
  (define-values (actual edits) (formatted source))
  (check-equal? actual source)
  (check-equal? edits '()))

(test-case "short declare-extern batch stays inline with one shared type"
  (define source "(declare-extern [window document] Any)\n")
  (define-values (actual edits) (formatted source))
  (check-equal? actual source)
  (check-equal? edits '()))

(test-case "long declare-extern batch uses pairwise rows and one shared type"
  (define source
    (string-append
     "(declare-extern [globalThis process TextDecoder Error String Number Set "
     "Intl setInterval clearInterval] Any)\n"))
  (define-values (actual edits) (formatted source))
  (check-equal?
   actual
   (string-append
    "(declare-extern\n"
    "  [globalThis process\n"
    "   TextDecoder Error\n"
    "   String Number\n"
    "   Set Intl\n"
    "   setInterval clearInterval] Any)\n"))
  (check-equal? (length edits) 1)
  (check-equal? (length (regexp-match* #rx"Any" actual)) 1))

(test-case "odd declare-extern batch keeps the closing vector and type together"
  (define source
    (string-append
     "(declare-extern [first-very-long-host-name second-very-long-host-name "
     "third-very-long-host-name] (Fn [String] Any))\n"))
  (define-values (actual edits) (formatted source))
  (check-equal?
   actual
   (string-append
    "(declare-extern\n"
    "  [first-very-long-host-name second-very-long-host-name\n"
    "   third-very-long-host-name] (Fn [String] Any))\n"))
  (check-equal? (length edits) 1))

(test-case "declare-extern write reaches the canonical fixed point"
  (define source
    (string-append
     "(declare-extern [globalThis process TextDecoder Error String Number Set "
     "Intl setInterval clearInterval] Any)\n"))
  (with-source
   source
   (lambda (path)
     (check-equal? (format-signature-files 'check (list path)) 3)
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-equal? (format-signature-files 'check (list path)) 0))))

(test-case "declare-extern comments make a noncanonical rewrite diagnostic-only"
  (define source
    (string-append
     "(declare-extern [globalThis process ; runtime roots\n"
     " TextDecoder Error String Number Set Intl setInterval clearInterval] Any)\n"))
  (with-source
   source
   (lambda (path)
     (define edits (signature-layout-edits path))
     (check-equal? (length edits) 1)
     (check-false (layout-edit-safe? (car edits)))
     (check-equal? (layout-edit-refusal (car edits)) 'comment-reach)
     (check-equal? (format-signature-files 'write (list path)) 2)
     (check-equal? (file->string path) source))))

(test-case "CST spacing normalizes signatures, member calls, and property access"
  (define source
    (string-append
     "(defn bridge-sample []  String\n"
     "  (do\n"
     "    (.push kept  segment)\n"
     "    (.-env process )))\n"))
  (with-source
   source
   (lambda (path)
     (check-equal? (format-signature-files 'check (list path)) 3)
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-equal?
      (file->string path)
      (string-append
       "(defn bridge-sample [] String\n"
       "  (do\n"
       "    (.push kept segment)\n"
       "    (.-env process)))\n"))
     (check-equal? (format-signature-files 'check (list path)) 0))))

(test-case "CST spacing preserves strings, comments, and vertical layout"
  (define source
    (string-append
     "(defn bridge-sample [] String\n"
     "  (do\n"
     "    (str \"two  spaces )\"  value )\n"
     "    ; keep  comment spacing )\n"
     "    (.push kept  segment)))\n"))
  (with-source
   source
   (lambda (path)
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-equal?
      (file->string path)
      (string-append
       "(defn bridge-sample [] String\n"
       "  (do\n"
       "    (str \"two  spaces )\" value)\n"
       "    ; keep  comment spacing )\n"
       "    (.push kept segment)))\n"))
     (check-equal? (format-signature-files 'check (list path)) 0))))

(test-case "legacy grouped pair canonicalizes inline"
  (define-values (actual edits)
    (formatted "(defn greet [(name String)] String name)\n"))
  (check-equal? actual "(defn greet [name String] String name)\n")
  (check-equal? (length edits) 1))

(test-case "pair count alone expands a defn signature"
  (define-values (actual edits)
    (formatted "(defn add [x Int y Int] Int (+ x y))\n"))
  (check-equal?
   actual
   (string-append
    "(defn add\n"
    "  [x Int\n"
    "   y Int] Int\n"
    "  (+ x y))\n"))
  (check-equal? (length edits) 1))

(test-case "single refinement stays inline"
  (define source
    "(defn positive [x (Int where (> _ 0))] Int x)\n")
  (define-values (actual edits) (formatted source))
  (check-equal? actual source)
  (check-equal? edits '()))

(test-case "legacy constraints refuse command-wide writes"
  (define blocked "(defn positive [(x Int positive?)] Int x)\n")
  (define rewritable "(defn add [(x Int) (y Int)] Int (+ x y))\n")
  (with-source
   blocked
   (lambda (blocked-path)
     (with-source
      rewritable
      (lambda (rewritable-path)
        (define edits (signature-layout-edits blocked-path))
        (check-equal? (length edits) 1)
        (check-equal? (layout-edit-refusal (car edits))
                      'refinement-not-implemented)
        (check-equal?
         (format-signature-files 'check (list blocked-path rewritable-path)) 3)
        (check-equal?
         (format-signature-files 'write (list blocked-path rewritable-path)) 2)
        (check-equal? (file->string blocked-path) blocked)
        (check-equal? (file->string rewritable-path) rewritable))))))

(test-case "signature where clause remains after its return line"
  (define-values (actual edits)
    (formatted
     "(defn bounded [lo Int hi Int] Bool (where (<= lo hi)) true)\n"))
  (check-equal?
   actual
   (string-append
    "(defn bounded\n"
    "  [lo Int\n"
    "   hi Int] Bool\n"
    "  (where (<= lo hi))\n"
    "  true)\n"))
  (check-equal? (length edits) 1))

(test-case "variadic marker and pair stay one logical row"
  (define-values (actual edits)
    (formatted
     "(defn collect [(first Int) & (more (Vec Int))] Int first)\n"))
  (check-equal?
   actual
   (string-append
    "(defn collect\n"
    "  [first Int\n"
    "   & more (Vec Int)] Int\n"
    "  first)\n"))
  (check-equal? (length edits) 1))

(test-case "fn keeps its return after the expanded vector"
  (define-values (actual edits)
    (formatted "(fn [x Int y Int] Int (+ x y))\n"))
  (check-equal?
   actual
   (string-append
    "(fn\n"
    "  [x Int\n"
    "   y Int] Int\n"
    "  (+ x y))\n"))
  (check-equal? (length edits) 1))

(test-case "defrecord shares the pair break law"
  (define-values (actual edits)
    (formatted "(defrecord Point [(x Float) (y Float)])\n"))
  (check-equal?
   actual
   (string-append
    "(defrecord Point\n"
    "  [x Float\n"
    "   y Float])\n"))
  (check-equal? (length edits) 1))

(test-case "one local binding triple stays inline"
  (define source "(let [x Int 1] x)\n")
  (define-values (actual edits) (formatted source))
  (check-equal? actual source)
  (check-equal? edits '()))

(test-case "let and loop break one complete triple per line"
  (for ([source+expected
         (in-list
          (list
           (cons "(let [x Int 1 y Int 2] (+ x y))\n"
                 (string-append
                  "(let [x Int 1\n"
                  "      y Int 2]\n"
                  "  (+ x y))\n"))
           (cons "(loop [x Int 1 y Int 2] (+ x y))\n"
                 (string-append
                  "(loop [x Int 1\n"
                  "       y Int 2]\n"
                  "  (+ x y))\n"))))])
    (define-values (actual edits) (formatted (car source+expected)))
    (check-equal? actual (cdr source+expected))
    (check-equal? (length edits) 1)))

(test-case "nested binding rewrites converge without overlapping edits"
  (define source
    (string-append
     "(let [f (Fn [Int Int] Int) (fn [x Int y Int] Int (+ x y)) "
     "z Int 2] (f z z))\n"))
  (with-source
   source
   (lambda (path)
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-equal? (format-signature-files 'check (list path)) 0)
     (check-equal?
      (file->string path)
      (string-append
       "(let [f (Fn [Int Int] Int) (fn\n"
       "                             [x Int\n"
       "                              y Int] Int\n"
       "                             (+ x y))\n"
       "      z Int 2]\n"
       "  (f z z))\n")))))

(test-case "legacy local pairs preserve nested initializer layout"
  (define source
    "(let [f (fn [x Int y Int] Int (+ x y)) z 2] (f z z))\n")
  (with-source
   source
   (lambda (path)
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-equal? (format-signature-files 'check (list path)) 0)
     (check-equal?
      (file->string path)
      (string-append
       "(let [f (fn\n"
       "          [x Int\n"
       "           y Int] Int\n"
       "          (+ x y))\n"
       "      z 2]\n"
       "  (f z z))\n")))))

(test-case "qualified flat local type is not a legacy refinement"
  (define source
    (string-append
     "(let [a terrain/TerrainBatch (filterv first? xs) "
     "b (Vec Any) (filterv second? xs)] a)\n"))
  (with-source
   source
   (lambda (path)
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-equal? (format-signature-files 'check (list path)) 0)
     (check-equal?
      (file->string path)
      (string-append
       "(let [a terrain/TerrainBatch (filterv first? xs)\n"
       "      b (Vec Any) (filterv second? xs)]\n"
       "  a)\n")))))

(test-case "qualified optional local type keeps its complete initializer"
  (define source
    (string-append
     "(let [full history/AuthenticatedHistory? (loaded-history full-result) "
     "prefix history/AuthenticatedHistory? (loaded-history prefix-result)] full)\n"))
  (with-source
   source
   (lambda (path)
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-equal? (format-signature-files 'check (list path)) 0)
     (check-equal?
      (file->string path)
      (string-append
       "(let [full history/AuthenticatedHistory? (loaded-history full-result)\n"
       "      prefix history/AuthenticatedHistory? (loaded-history prefix-result)]\n"
       "  full)\n")))))

(test-case "compound qualified flat local types are not legacy refinements"
  (for ([type-text
         (in-list
          '("(U terrain/DigRequest Nil)"
            "(JsMap String logout/LogoutState)"
            "(Atom sim/World)"
            "(Vec character/Character)"))])
    (define source
      (format
       "(let [a ~a (filterv first? xs) b (Vec Any) (filterv second? xs)] a)\n"
       type-text))
    (with-source
     source
     (lambda (path)
       (check-equal? (format-signature-files 'write (list path)) 0)
       (check-equal? (format-signature-files 'check (list path)) 0)
       (check-equal?
        (file->string path)
        (string-append
         (format "(let [a ~a (filterv first? xs)\n" type-text)
         "      b (Vec Any) (filterv second? xs)]\n"
         "  a)\n"))))))

(test-case "width never changes a single-pair signature"
  (define name (make-string 120 #\f))
  (define source (format "(defn ~a [x Int] Int x)\n" name))
  (define-values (actual edits) (formatted source))
  (check-equal? actual source)
  (check-equal? edits '()))

(test-case "ordinary and macro vectors are not typed-signature rewrites"
  (define source
    (string-append
     "(def data [x y z])\n"
     "(defmacro pair [x y] `[~x ~y])\n"))
  (define-values (actual edits) (formatted source))
  (check-equal? actual source)
  (check-equal? edits '()))

(test-case "line-comment reach is preserved by a signature rewrite"
  (define source
    "(defn f ; owner comment\n  [x Int y Int] Int x)\n")
  (with-source
   source
   (lambda (path)
     (define edits (signature-layout-edits path))
     (check-equal? (length edits) 1)
     (check-true (layout-edit-safe? (car edits)))
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-equal?
      (file->string path)
      (string-append
       "(defn f ; owner comment\n"
       "  [x Int\n"
       "   y Int] Int\n"
       "  x)\n"))
     (check-equal? (format-signature-files 'check (list path)) 0))))

(test-case "comments nested in a let initializer survive canonical layout"
  (define source
    (string-append
     "(let [runtime (Map Keyword Any) {:x 1\n"
     "                                ;; keep runtime ownership\n"
     "                                :y 2} value Int 3] value)\n"))
  (with-source
   source
   (lambda (path)
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-true
     (string-contains? (file->string path) ";; keep runtime ownership"))
     (check-equal? (format-signature-files 'check (list path)) 0))))

(test-case "map destructuring is not a legacy refinement"
  (define source
    (string-append
     "(let [{:keys [process-outcome delivery-outcome]} (terminal-state facts) "
     "task (task-of facts)] task)\n"))
  (with-source
   source
   (lambda (path)
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-equal? (format-signature-files 'check (list path)) 0)
     (check-equal?
      (file->string path)
      (string-append
       "(let [{:keys [process-outcome delivery-outcome]} (terminal-state facts)\n"
       "      task (task-of facts)]\n"
       "  task)\n")))))

(test-case "comments between a binding vector and body survive one write"
  (define source
    (string-append
     "(let [provider-axis (provider-target-label facts) composition "
     "(orchestration-provenance facts)]\n"
     "  ;; the visible identity is derived on every read\n"
     "  (str provider-axis composition))\n"))
  (with-source
   source
   (lambda (path)
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-equal? (format-signature-files 'check (list path)) 0)
     (check-equal?
      (file->string path)
      (string-append
       "(let [provider-axis (provider-target-label facts)\n"
       "      composition (orchestration-provenance facts)]\n"
       "  ;; the visible identity is derived on every read\n"
       "  (str provider-axis composition))\n")))))

(test-case "comments between local bindings survive one write"
  (define source
    (string-append
     "(let [first (first-value) _ (when first (use first))\n"
     "      ;; preserve the gate attached to the following binding\n"
     "      second (second-value) third (third-value)] third)\n"))
  (with-source
   source
   (lambda (path)
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-equal? (format-signature-files 'check (list path)) 0)
     (check-equal?
      (file->string path)
      (string-append
       "(let [first (first-value)\n"
       "      _ (when first (use first))\n"
       "      ;; preserve the gate attached to the following binding\n"
       "      second (second-value)\n"
       "      third (third-value)]\n"
       "  third)\n")))))

(test-case "one write reaches the canonical fixed point"
  (define source "(defn add [(x Int) (y Int)] Int (+ x y))\n")
  (with-source
   source
   (lambda (path)
     (check-equal? (format-signature-files 'check (list path)) 3)
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-equal? (format-signature-files 'check (list path)) 0)
     (check-equal?
      (file->string path)
      (string-append
       "(defn add\n"
       "  [x Int\n"
       "   y Int] Int\n"
       "  (+ x y))\n")))))
