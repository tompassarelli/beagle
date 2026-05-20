# Multi-target guide

## Available targets

| Target | Extension | `#lang` header | Runtime |
|--------|-----------|----------------|---------|
| Clojure | `.bclj` | `#lang beagle/clj` | JVM |
| ClojureScript | `.bcljs` | `#lang beagle/cljs` | JS (browser/Node) |
| JavaScript | `.bjs` | `#lang beagle/js` | Node/browser |
| Nix | `.bnix` | `#lang beagle/nix` | Nix evaluator |
| SQL | `.bsql` | `#lang beagle/sql` | Database |
| Python | `.bpy` | `#lang beagle/py` | Plumbed, no emitter |

## File extension determines target

The file extension is the source of truth. A `.bjs` file compiles to JavaScript.
Extension/`#lang` mismatch is a hard error.

## Target-specific forms

| Form | Targets | Notes |
|------|---------|-------|
| `await` | js, cljs | Async point; function auto-marked async |
| `js-quote` | js | Raw JS string literal |
| `doto` | clj, cljs | Mutate object, return original |
| `with-open` | clj | Java resource management |
| `inh` | nix | Nix inherit |
| `fn-set` | nix | Nix function with attrset arg |
| `rec-att` | nix | Nix recursive attrset |
| `deftable` | sql | Declare table schema |
| `select/insert/update/delete` | sql | Type-checked SQL queries |

## Stdlib per target

- Portable: 269 entries (available in all targets)
- Clojure: 352 entries (Java interop, Clojure collections)
- ClojureScript: 75 entries (browser/Node APIs)
- JavaScript: 38 entries (Math, JSON, Promise, fetch, timers)
- Nix: 120 entries (builtins.*, lib.*, lib.types.*)
- SQL: 43 entries (aggregates, window functions, operators)

## Cross-target code

To share logic across targets, extract pure functions into separate modules.
Each target file imports the shared module. Target-specific code stays in
target-specific files.
