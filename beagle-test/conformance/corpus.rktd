;; Beagle conformance corpus — the executable-spec manifest (see README.md).
;;
;; Row: (id path kind option ...)
;;   id    — stable case id; the ratchet (known-divergences-<target>.edn) keys on it.
;;   path  — repo-relative source file; target derived from extension
;;           (.bjs -> js, .bclj -> clj, .bnix -> nix, .bsc -> scriptc).
;;   kind  — emit   : golden = emitted output (expected/<target>/<id>.<ext>)
;;           reject : source must FAIL check; golden = diagnostic text
;;                    (expected/<target>/<id>.diag)
;;           static : emit + the emitted output compiles 100% statically on the
;;                    target (scriptc), over MORE THAN ZERO statements
;;           native : static + the native executable's stdout/stderr/exit equal
;;                    the oracle runtime's (node) on the same emitted source
;;           module : a multi-file row — #:modules names the siblings; goldens
;;                    live in expected/<target>/<id>/, and the entry then runs
;;                    the static + native dimensions
;;   option — #:modules (path ...)  additional sources of a module row
;;            #:diag-requires REGEX / #:diag-forbids REGEX  (reject rows) the
;;              POINTEDNESS contract: what a user-facing diagnostic must and
;;              must not say. Without it a reject row with a bad message is a
;;              silent pass — the rejection is "correct" and nothing ratchets.
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

 ;; --- scriptc --------------------------------------------------------
 ;; ScriptC compiles ordinary TypeScript to a native binary with no JS engine,
 ;; so a scriptc row certifies three things a golden diff cannot: the emitted
 ;; .ts type-checks under ScriptC's real tsc, it compiles 100% STATICALLY over
 ;; a non-zero statement count, and the native executable behaves exactly like
 ;; Node. Tooling: $BEAGLE_SCRIPTC (or `scriptc` on PATH) + clang + node; when
 ;; absent those dimensions report UNENFORCED, never pass.
 ;;
 ;; Green rows — the JS-family core that already survives all three dimensions.
 ("sc-defn-arith"      "beagle-test/conformance/corpus/scriptc/sc-defn-arith.bsc"      native)
 ("sc-if-cond-do-let"  "beagle-test/conformance/corpus/scriptc/sc-if-cond-do-let.bsc"  native)
 ("sc-loop-recur"      "beagle-test/conformance/corpus/scriptc/sc-loop-recur.bsc"      native)
 ("sc-nil-boundary"    "beagle-test/conformance/corpus/scriptc/sc-nil-boundary.bsc"    native)
 ("sc-float-boundary"  "beagle-test/conformance/corpus/scriptc/sc-float-boundary.bsc"  native)
 ("sc-count-vec"       "beagle-test/conformance/corpus/scriptc/sc-count-vec.bsc"       native)
 ;;
 ;; Ratcheted rows — every one is a CURRENT PRODUCT GAP, declared at the
 ;; behavior beagle owes rather than at today's behavior, and classified in
 ;; known-divergences-scriptc.edn. Each entry goes STALE (and must be deleted,
 ;; with the golden regenerated) the moment the gap closes.
 ("sc-str-concat"      "beagle-test/conformance/corpus/scriptc/sc-str-concat.bsc"      static)
 ("sc-inner-fn"        "beagle-test/conformance/corpus/scriptc/sc-inner-fn.bsc"        static)
 ("sc-extern"          "beagle-test/conformance/corpus/scriptc/sc-extern.bsc"          static)
 ("sc-fixed-width-reject" "beagle-test/conformance/corpus/scriptc/sc-fixed-width-reject.bsc" static)
 ("sc-await-reject"    "beagle-test/conformance/corpus/scriptc/sc-await-reject.bsc"    native)
 ("sc-record"          "beagle-test/conformance/corpus/scriptc/sc-record.bsc"          native)
 ("sc-map-set-literal" "beagle-test/conformance/corpus/scriptc/sc-map-set-literal.bsc" native)
 ("sc-comment-neutral" "beagle-test/conformance/corpus/scriptc/sc-comment-neutral.bsc" emit)
 ("sc-target-case"     "beagle-test/conformance/corpus/scriptc/sc-target-case.bsc"     emit)
 ("sc-module-two-file" "beagle-test/conformance/corpus/scriptc/sc-module-two-file.bsc" module
  #:modules ("beagle-test/conformance/corpus/scriptc/sc-module-two-file-lib.bsc"))
 ;; Reject rows carrying a pointedness contract: they DO reject today, but the
 ;; message is not user-facing, so the contract keeps the gap firing.
 ("sc-missing-return-annot" "beagle-test/conformance/corpus/scriptc/sc-missing-return-annot.bsc" reject
  #:diag-requires "->"
  #:diag-forbids "type-prim|boundary type #f")
 ("sc-untyped-def"     "beagle-test/conformance/corpus/scriptc/sc-untyped-def.bsc"     reject
  #:diag-requires "\\bdef\\b"
  #:diag-forbids "def-form|record-form|type-prim|type-app")
)
