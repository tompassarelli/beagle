#lang racket/base

(require rackunit
         racket/file
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         beagle/private/check
         beagle/private/emit
         beagle/private/parse)

(define-runtime-path receiver-fixture "fixtures/i1-receiver-semantics.bjs")
(define-runtime-path non-js-fixture "fixtures/i1-this-as-non-js.bclj")

(define bun-path
  (or (find-executable-path "bun")
      (error 'i1-receiver-semantics
             "bun is required for the focused receiver-semantics contract")))

(define (checked-program path)
  (define program
    (parse-program (read-beagle-syntax path) #:source-path (path->string path)))
  (type-check! program)
  program)

(define (run-emitted emitted)
  (define script-path
    (make-temporary-file "beagle-i1-receiver-~a.mjs"))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file script-path #:exists 'truncate
       (lambda (out)
         (display emitted out)
         (display #<<JS

const marker = {};
if (capture_this.call(marker) !== marker) throw new Error("this-as");

const receiver = {identity() { return this; }};
if (call_identity(receiver) !== receiver) throw new Error("direct receiver");
const detached = extract_identity(receiver);
if (detached() !== undefined) throw new Error("detached receiver");

let receiverEvaluations = 0;
const leaf = {value() {
  if (this !== leaf) throw new Error("leaf receiver");
  return 7;
}};
const root = {child() {
  if (this !== root) throw new Error("root receiver");
  return leaf;
}};
const result = chained_once(() => {
  receiverEvaluations += 1;
  return root;
});
if (result !== 7 || receiverEvaluations !== 1) throw new Error("chained receiver");

const typedLeaf = {value() { return 11; }};
const typedRoot = {child() { return typedLeaf; }};
if (typed_chain(typedRoot) !== 11) throw new Error("typed chain");
console.log("i1 receiver semantics: PASS");
JS
                  out)))
     (define output (open-output-string))
     (define errors (open-output-string))
     (define code
       (parameterize ([current-output-port output]
                      [current-error-port errors])
         (system*/exit-code bun-path (path->string script-path))))
     (values code (get-output-string output) (get-output-string errors)))
   (lambda ()
     (delete-file script-path))))

(test-case "direct and chained member calls preserve receiver semantics"
  (define program (checked-program receiver-fixture))
  (define typed-chain
    (for/first ([form (in-list (program-forms program))]
                #:when (and (defn-form? form)
                            (eq? (defn-form-name form) 'typed-chain)))
      form))
  (define outer-call (car (defn-form-body typed-chain)))
  (check-pred jst-call? outer-call)
  (check-pred jst-call? (jst-call-receiver outer-call))
  (define emitted (emit-program program))
  (define-values (code output errors) (run-emitted emitted))
  (check-equal? code 0 errors)
  (check-equal? output "i1 receiver semantics: PASS\n"))

(test-case "this-as is scoped to the JavaScript target"
  (define result
    (with-handlers ([exn:fail? values])
      (checked-program non-js-fixture)
      #f))
  (check-pred exn:fail? result)
  (check-regexp-match #rx"this-as.*JavaScript target" (exn-message result)))
