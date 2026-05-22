---
status: active
priority: 1
---

# Self-hosting: beagle compiles itself

## Current status

**Reimplementation: complete.** All ~12K lines of the Racket compiler
have been rewritten in beagle/js (11 components, 400+ tests).

**Bootstrap closure: proven.** The Bun-only compile path (`bin/beagle-bun`)
produces byte-identical output to the Racket path for all 12 compiler
components. Racket remains as a differential oracle, not in the compile loop.

### Trusted path

```
source.bgl → Bun reader/parser/checker/emitter → target source
```

## Proof ladder (bootstrap closure)

- [x] P0: Reader output matches Racket reader on compiler corpus (12/12)
- [x] P1: Parser output matches Racket-backed parser output (12/12)
- [x] P2: Checker accepts the compiler corpus (12/12)
- [x] P3: Emitter produces byte-identical target output (12/12)
- [x] P4: Bun compiler compiles one component whose output runs
- [x] P5: Bun compiler compiles the JS emitter
- [x] P6: JS emitter fixed-point holds under the Bun path (byte-identical)

## Done — reimplementation (all compiler components)

- [x] AST JSON bridge (`ast-json.rkt`, `bin/beagle-ast`)
- [x] JS emitter (`self-host/emit-js.bjs`, 950 lines) — fixed-point verified
- [x] CLJ emitter (`self-host/emit-clj.bjs`, 370 lines) — 4 fixtures
- [x] Python emitter (`self-host/emit-py.bjs`, 970 lines) — exact match
- [x] Nix emitter (`self-host/emit-nix.bjs`, 921 lines) — 5 fixtures, 16/16 full corpus
- [x] Racket emitter (`self-host/emit-rkt.bjs`, 1095 lines) — 23/30 oracle fixtures
- [x] Lint pass (`self-host/lint.bjs`, 788 lines) — all 6 checks match Racket linter
- [x] Types (`self-host/types.bjs`) — type AST, parser, compatibility checker, 50 tests
- [x] Macros (`self-host/macros.bjs`) — template expansion, hygiene, contracts, 27 tests
- [x] AST (`self-host/ast.bjs`) — node constructors, symbol predicates, tag utils, 48 tests
- [x] Parser (`self-host/parse.bjs`, 1923 lines) — all forms, destructuring, 71 tests
- [x] Checker (`self-host/check.bjs`, 1648 lines) — inference, narrowing, exhaustiveness, 38 tests
- [x] Reader (`self-host/reader.bjs`) — s-expression reader, 50 tests
- [x] Stdlib types exported as JSON (`self-host/dist/stdlib-types.json`)
- [x] Compiler bundle script (`self-host/bundle-compiler.sh`)
- [x] `bin/beagle-bun` — standalone compiler entry point
- [x] Unified build script (`self-host/build.sh`) — 18/18 checks pass
- [x] Pipeline scripts: beagle-self-emit, beagle-self-emit-clj, -py, -nix, -rkt

## Bootstrap infrastructure

- [x] `self-host/reader.bjs` — s-expression reader (replaces Racket reader)
- [x] `self-host/export-stdlib.rkt` — one-time Racket→JSON stdlib export
- [x] `self-host/bundle-compiler.sh` — builds standalone compiler.cjs
- [x] `bin/beagle-bun` — Racket-free compile path
- [x] `self-host/verify-bootstrap.sh` — differential check: Bun path vs Racket path (P0–P6)
- [ ] Oracle CI integration — raco make cross-check on Bun compiler output

## Coverage

| component | lines | status |
|-----------|-------|--------|
| emit-js.rkt | 1562 | reimplemented |
| emit-clj.rkt | 765 | reimplemented |
| emit-py.rkt | 1098 | reimplemented |
| emit-nix.rkt | 1069 | reimplemented |
| emit-rkt.rkt | 983 | reimplemented |
| lint.rkt | 743 | reimplemented |
| macros.rkt | 484 | reimplemented |
| types.rkt | 393 | reimplemented |
| ast.rkt | 437 | reimplemented |
| parse.rkt | 1872 | reimplemented |
| check.rkt | 2558 | reimplemented |
| **total** | **11,964** | **reimplemented, bootstrap-closed** |
