# beagle — todo

## Next

- **Source mapping (comprehensive).** Goal: 99% automated source-mapping
  so Clojure runtime errors point back at originating beagle source.
  Current state: per-form source locations exist for compile-time errors.
  Remaining: emit `.clj.map` or inline `^{:line N}` metadata so runtime
  stacktraces map back to `.rkt` source.
- **`deftype` / `extend-type`.** Protocol implementation on types.
  `defprotocol` exists; need the other side.
- **Atom/swap!/reset!.** Basic concurrency primitives. Common in real
  Clojure apps.
- **Threading macros `->`, `->>`.** Could be user-defined macros, but
  they're universal enough to consider built-in.
- **More stdlib typing.** Only ~110 of 1000+ Clojure functions typed.
  Priority: high-use functions that would catch real bugs.
- **Sequential destructuring.** `[a b & rest]` in let/fn/defn.
  Map destructuring (`{:keys}`) is done; vector destructuring is the
  other half.

## Someday

Speculative; no commitment.

- **LSP / editor integration.** Type-aware completion, jump-to-def, etc.
- **Typed REPL.** Connect to a live Clojure socket-repl, evaluate
  beagle forms with full type checking before sending.

## Done

- All core forms (def, defn, fn, let, if, cond, when, do, call, vector, quote)
- try/catch/finally, doseq, case, constructor calls (ClassName.)
- defprotocol, defmulti/defmethod
- Keyword-as-function (`(:key map)`) with record field type inference
- Map literals (`{}`), set literals (`#{}`), import (Java classes)
- Map destructuring (`{:keys [a b c]}`, `{:keys [a b c] :as m}`) in params and let
- Meta: ns, define-mode, require, declare-extern, define-macro, import, unsafe
- Types: primitives, function types (incl. variadic), parametric, union, polymorphic (forall), Any
- Macros: safe (gensym-hygienic) / unsafe with &rest and splice
- Custom reader preserving `[]`/`()`, intercepting `{}`/`#{}`
- Stdlib extern catalog (~110 functions)
- bin/beagle-build, bin/beagle-build-all, bin/beagle-expand
- 258-test suite
- experiments/ benchmark framework (40 tasks × 3 variants, gen-prompts + score + verify-behavior)
- Head-to-head benchmark (8 programs, beagle vs raw Clojure, 16/16 pass)
- Refactoring experiment (overhead-pct cascade, 2/2 pass)
- Bug detection experiment (5 injected bugs, 2/2 pass)
- loop/recur, for (with :when), sort-by language forms
- Wrapped let-binding form: `(let [(name : Type) value ...] ...)`
- Lint pass: untyped def/defn, return-type missing, unsafe escape, shadow, unused extern
- Empirical benchmark: 88 responses, 5 real bugs caught + fixed, 100% behavior pass
- Structured error output (BEAGLE_ERROR_FORMAT=json, hints, beagle-check)
- docs/findings.md empirical log
- Form catalog (docs/forms.md)
- Flow-sensitive type narrowing in if/cond/when
- Cross-file type import via (require module) / (require module :as alias)
- Polymorphic stdlib (map, filter, identity etc.)
- raco beagle build|check|expand subcommands
- Per-statement source locations for compile-time errors
- Hygienic macros (gensym-based for safe macros)
