#lang racket/base

(require rackunit
         racket/file
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         setup/collects
         beagle/lang/reader-impl
         beagle/private/check
         beagle/private/emit
         beagle/private/parse
         beagle/private/types)

(define-runtime-path fixture-path "fixtures/js-protocol-dispatch.bjs")
(define-runtime-path core-js-path "../../beagle-lib/lib/beagle/core.js")

(define BUN-PATH (find-executable-path "bun"))
(define BEAGLE-CORE-JS
  (path->string (collection-file-path "lib/beagle/core.js" "beagle")))

(define (read-forms source path)
  (parameterize ([current-readtable beagle-readtable])
    (define input (open-input-string source))
    (port-count-lines! input)
    (let loop ([forms '()])
      (define form (read-syntax path input))
      (if (eof-object? form)
          (reverse forms)
          (loop (cons form forms))))))

(define (checked-program source path)
  (define prog (parse-program (read-forms source path) #:source-path path))
  (define type-table (make-hasheq))
  (parameterize ([current-check-profile 2]
                 [current-type-table type-table])
    (type-check! prog))
  (register-program-type-table! prog type-table)
  prog)

(define (check-error-message source)
  (define result
    (with-handlers ([exn:fail? values])
      (checked-program
       (string-append "(ns fixtures.invalid-protocol)\n"
                      "(define-target js)\n"
                      source)
       'invalid-protocol.bjs)
      #f))
  (check-pred exn:fail? result)
  (if (exn:fail? result) (exn-message result) ""))

(define (run-js js)
  (define js-path (make-temporary-file "beagle-protocol-~a.js"))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file js-path #:exists 'truncate
       (lambda (out) (display js out)))
     (define output (open-output-string))
     (define errors (open-output-string))
     (define code
       (parameterize ([current-output-port output]
                      [current-error-port errors])
         (system*/exit-code BUN-PATH (path->string js-path))))
     (values code (get-output-string output) (get-output-string errors)))
   (lambda () (delete-file js-path))))

(define (run-emitted emitted)
  (run-js
   (string-append
    (string-replace emitted "from 'beagle/core.js'"
                    (format "from '~a'" BEAGLE-CORE-JS))
    "\nconsole.log(render_label());\n"
    "console.log(render_counter());\n"
    "console.log(scale_counter());\n")))

(test-case "runtime protocol registry is immutable and keyed by protocol/type identity"
  (define runtime-source (file->string core-js-path))
  (check-false
   (regexp-match? #rx"Object[.](defineProperty|setPrototypeOf)|[.]prototype[ \t]*="
                  runtime-source))
  (when BUN-PATH
    (define methods
      (string-append
       "const labelMethods = {render: self => self.text};\n"
       "const registry = protocol_registry([\n"
       "  ['fixtures/Renderable', 'fixtures/Label', labelMethods],\n"
       "  ['fixtures/Renderable', 'fixtures/Counter', {render: self => String(self.value)}],\n"
       "  ['fixtures/Scalable', 'fixtures/Counter', {scale: (self, factor) => self.value * factor}]\n"
       "]);\n"
       "labelMethods.render = () => 'mutated';\n"
       "if (!Object.isFrozen(registry)) throw new Error('mutable registry');\n"
       "const label = Object.freeze({_tag: 'Label', text: 'typed'});\n"
       "const counter = Object.freeze({_tag: 'Counter', value: 7});\n"
       "console.log(protocol_dispatch(registry, 'fixtures/Renderable', 'fixtures/Label', 'render', label));\n"
       "console.log(protocol_dispatch(registry, 'fixtures/Renderable', 'fixtures/Counter', 'render', counter));\n"
       "console.log(protocol_dispatch(registry, 'fixtures/Scalable', 'fixtures/Counter', 'scale', counter, 6));\n"))
    (define-values (code output errors)
      (run-js
       (format "import {protocol_registry, protocol_dispatch} from '~a';\n~a"
               BEAGLE-CORE-JS methods)))
    (check-equal? code 0 errors)
    (check-equal? output "typed\n7\n42\n")))

(test-case "typed protocol dispatch is immutable and keyed by protocol/type identity"
  (define source
    (string-append
     "(define-target js)\n"
     (string-join
      (filter (lambda (line) (not (string-prefix? line "#lang")))
              (string-split (file->string fixture-path) "\n"))
      "\n")))
  (define emitted (emit-program (checked-program source fixture-path)))
  (check-false (regexp-match? #rx"\\.prototype|Object\\.(defineProperty|setPrototypeOf)"
                              emitted))
  (when BUN-PATH
    (define-values (code output errors) (run-emitted emitted))
    (check-equal? code 0 errors)
    (check-equal? output "typed\n7\n42\n")))

(test-case "protocol method implementations are type checked"
  (define message
    (check-error-message
     (string-append
      "(defprotocol Renderable (render [self Any] String))\n"
      "(extend-type String Renderable\n"
      "  (render [self String] Int 1))\n")))
  (check-regexp-match #rx"return type|expected String|Int" message))

(test-case "extend-type rejects a missing protocol implementation"
  (define message
    (check-error-message
     (string-append
      "(defprotocol Sized\n"
      "  (width [self Any] Int)\n"
      "  (height [self Any] Int))\n"
      "(extend-type String Sized\n"
      "  (width [self String] Int 1))\n")))
  (check-regexp-match #rx"missing implementation for height" message))
