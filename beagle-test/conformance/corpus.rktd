;; Beagle conformance corpus — the executable-spec manifest (see README.md).
;;
;; Row: (id path kind)
;;   id    — stable case id; the ratchet (known-divergences-<target>.edn) keys on it.
;;   path  — repo-relative source file; target derived from extension
;;           (.bjs -> js, .bclj -> clj, .bnix -> nix).
;;   kind  — emit   : golden = emitted output (expected/<target>/<id>.<ext>)
;;           reject : source must FAIL check; golden = diagnostic text
;;                    (expected/<target>/<id>.diag)
;;
;; The initial emit corpus is the standalone beagle-test fixtures; rows added
;; for conformance only live under beagle-test/conformance/corpus/.
;; Adding a row is deliberate (authored data, jolt-style): add it here, then
;; `bin/beagle-certify --regen` to source its golden from the oracle.

(
 ;; --- js -------------------------------------------------------------
 ("hello-js"           "beagle-test/tests/fixtures/hello-js.bjs"           emit)
 ("js-array-methods"   "beagle-test/tests/fixtures/js-array-methods.bjs"   emit)
 ("js-arrow-object"    "beagle-test/tests/fixtures/js-arrow-object.bjs"    emit)
 ("js-object-statics"  "beagle-test/tests/fixtures/js-object-statics.bjs"  emit)
 ("js-promises"        "beagle-test/tests/fixtures/js-promises.bjs"        emit)
 ("js-stdlib-statics"  "beagle-test/tests/fixtures/js-stdlib-statics.bjs"  emit)
 ("js-unary"           "beagle-test/tests/fixtures/js-unary.bjs"           emit)
 ("jsquote-demo"       "beagle-test/tests/fixtures/jsquote-demo.bjs"       emit)
 ("macrolib"           "beagle-test/tests/fixtures/macrolib.bjs"           emit)
 ;; js-reserved-word-param: emit MANGLES strict-mode reserved words (`private`
 ;; -> `private$`), so this now emits valid ESM (@019f21fe-b4df, fixed).
 ("js-reserved-word-param" "beagle-test/conformance/corpus/js-reserved-word-param.bjs" emit)
 ;; js-set-on-get: check now REJECTS set! on a non-place target (`(get m k)`)
 ;; on value targets — reject row, golden is the diagnostic (@019f21fe-b4df).
 ("js-set-on-get"          "beagle-test/conformance/corpus/js-set-on-get.bjs"          reject)

 ;; --- clj ------------------------------------------------------------
 ("mathlib"            "beagle-test/tests/fixtures/mathlib.bclj"           emit)
 ("shapes"             "beagle-test/tests/fixtures/shapes.bclj"            emit)
 ("result"             "beagle-test/tests/fixtures/result.bclj"            emit)
 ("kitchen-sink"       "beagle-test/tests/fixtures/kitchen-sink.bclj"      emit)
 ("reject-type-mismatch" "beagle-test/conformance/corpus/reject-type-mismatch.bclj" reject)
 ;; char-literal: named (\tab \space …), plain (\z \0), let-binding and predicate
 ;; positions. Regression row for the oracle reader/emitter char-literal bug
 ;; (was: \tab → bare symbol `tab`; fixed: reader now produces Racket char? values).
 ("charlit"             "beagle-test/conformance/corpus/charlit.bclj"            emit)

 ;; --- nix ------------------------------------------------------------
 ("nix-builtins"       "beagle-test/tests/fixtures/nix-builtins.bnix"      emit)
 ("nix-derivation"     "beagle-test/tests/fixtures/nix-derivation.bnix"    emit)
 ("nix-flake"          "beagle-test/tests/fixtures/nix-flake.bnix"         emit)
 ;; A dotted name whose root is bound nowhere (not a formal/let/nix-with) is a
 ;; free variable — reject row, golden is the E021 diagnostic (@019f221f-8f10).
 ("nix-free-dotted"    "beagle-test/conformance/corpus/nix-free-dotted.bnix" reject)
 ("nix-interp-ms"      "beagle-test/tests/fixtures/nix-interp-ms.bnix"     emit)
 ("nix-kmod"           "beagle-test/tests/fixtures/nix-kmod.bnix"          emit)
 ("nix-let-cond"       "beagle-test/tests/fixtures/nix-let-cond.bnix"      emit)
 ("nix-macro"          "beagle-test/tests/fixtures/nix-macro.bnix"         emit)
 ("nix-mkdefault"      "beagle-test/tests/fixtures/nix-mkdefault.bnix"     emit)
 ("nix-nested-mkif"    "beagle-test/tests/fixtures/nix-nested-mkif.bnix"   emit)
 ("nix-options"        "beagle-test/tests/fixtures/nix-options.bnix"       emit)
 ("nix-overlay"        "beagle-test/tests/fixtures/nix-overlay.bnix"       emit)
 ("nix-rec-assert"     "beagle-test/tests/fixtures/nix-rec-assert.bnix"    emit)
 ("nix-simple-pkg"     "beagle-test/tests/fixtures/nix-simple-pkg.bnix"    emit)
 ("nix-tilde-ms"       "beagle-test/tests/fixtures/nix-tilde-ms.bnix"      emit)
 ("nix-with-cfg"       "beagle-test/tests/fixtures/nix-with-cfg.bnix"      emit)
)
