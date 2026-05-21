# E22: Cross-target macro verification — results

**Date:** 2026-05-21

## Finding

Proc macro expansions emit correctly to all 6 targets. The same
`defconst-set` macro, unchanged, compiles and runs identically on
Clojure, JavaScript, Python, and Typed Racket. Nix and ClojureScript
compile successfully (Nix partial runtime, CLJS compile-only).

Proc macros are a language feature, not a Clojure feature.

## Results

| Target | Compiles | Runs | Output correct | Notes |
|--------|:--------:|:----:|:--------------:|-------|
| Clojure (`beagle`) | Y | Y | Y | Babashka |
| ClojureScript (`beagle/cljs`) | Y | — | — | No local runtime |
| JavaScript (`beagle/js`) | Y | Y | Y | Node |
| Nix (`beagle/nix`) | Y | partial | partial | Lazy eval; only last trace visible |
| Python (`beagle/py`) | Y | Y | Y | Python 3 |
| Typed Racket (`beagle/rkt`) | Y | Y | Y | `raco make` oracle passed |

Expected output (identical across Clojure, JS, Python, Typed Racket):
```
200
404
ff0000
ok: 200
error: 500
unknown: missing
blue: 0000ff
```

## Bugs found and fixed

The experiment surfaced two bugs in how `cond`/`else` clauses are
handled, both pre-existing but only triggered by macro-generated code:

1. **Parser: grouped cond clauses from macros.** `parse-cond-clauses`
   only recognized bracketed clauses or flat test/body pairs. Macro
   output produces grouped bare-list clauses `((test) (body))` without
   bracket tags. Fixed by detecting grouped clauses in `parse.rkt`.

2. **Emitters: `else` vs `:else` in cond.** The parser produces the
   symbol `else` for cond catch-all clauses, but the Clojure, JS, and
   Python emitters only checked for `':else` (keyword-style). Fixed in
   `emit-clj.rkt` (→ `:else`), `emit-js.rkt`, and `emit-py.rkt`.
   Nix and Typed Racket already handled `'else` correctly.

## Macro used

`defconst-set` generates per-entry constant functions + a cond-based
lookup function. Uses only portable forms: `defn`, `cond`, `str`, `=`.

```
(defconst-set http-status
  ((ok : Int 200)
   (not-found : Int 404)
   (error : Int 500)))
```

Expands to 4 forms per invocation (3 constants + 1 lookup).

## Practical implication

Proc macros work across all primary targets with zero target-specific
code. Macro authors don't need to think about which target the code
will emit to — the typed AST contract ensures the expansion produces
valid forms, and each target's emitter handles them independently.
