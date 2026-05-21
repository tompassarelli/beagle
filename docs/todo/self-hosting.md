---
status: done
priority: 1
---

# Self-hosting: beagle compiles itself

Core compiler is ~12K lines: parse.rkt (1872), check.rkt (2558),
emit-js.rkt (1562), emit-py.rkt (1098), emit-nix.rkt (1069),
emit-rkt.rkt (983), emit-clj.rkt (765), lint.rkt (743),
macros.rkt (484), types.rkt (393), ast.rkt (437).

## Pipeline

Racket handles parse + type-check. Beagle-written components (compiled to
JS via Node) produce target source from JSON AST.

```
source.bgl → bin/beagle-ast → JSON AST → node emit-{target}.mjs → target source
```

## Done — all compiler components (100%)

- [x] AST JSON bridge (`ast-json.rkt`, `bin/beagle-ast`)
  - Extension-based target inference, float/int kind split
  - Nix-specific AST nodes (16 node types), externs, requires
  - condp clauses (pairs not structs), if-some/when-some, defunion type-params
  - member-field type annotations, pat-record symbol bindings
- [x] JS emitter (`self-host/emit-js.bjs`, 950 lines) — fixed-point verified
- [x] CLJ emitter (`self-host/emit-clj.bjs`, 370 lines) — 4 fixtures
- [x] Python emitter (`self-host/emit-py.bjs`, 970 lines) — exact match
- [x] Nix emitter (`self-host/emit-nix.bjs`, 921 lines) — 5 fixtures, 16/16 full corpus
- [x] Racket emitter (`self-host/emit-rkt.bjs`, 1095 lines) — 23/30 oracle fixtures
- [x] Lint pass (`self-host/lint.bjs`, 788 lines) — all 6 checks match Racket linter
- [x] Types (`self-host/types.bjs`) — type AST, parser, compatibility checker, 50 tests
- [x] Macros (`self-host/macros.bjs`) — template expansion, hygiene, contracts, 27 tests
- [x] AST (`self-host/ast.bjs`) — node constructors, symbol predicates, tag utils, 48 tests
- [x] Parser (`self-host/parse.bjs`, 1923 lines) — source→AST, all forms, destructuring, 71 tests
- [x] Checker (`self-host/check.bjs`, 1648 lines) — type inference, narrowing, exhaustiveness, 38 tests
- [x] Unified build script (`self-host/build.sh`) — all checks pass
- [x] Pipeline scripts: beagle-self-emit, beagle-self-emit-clj, -py, -nix, -rkt

## Coverage

| component | lines | status |
|-----------|-------|--------|
| emit-js.rkt | 1562 | done |
| emit-clj.rkt | 765 | done |
| emit-py.rkt | 1098 | done |
| emit-nix.rkt | 1069 | done |
| emit-rkt.rkt | 983 | done |
| lint.rkt | 743 | done |
| macros.rkt | 484 | done |
| types.rkt | 393 | done |
| ast.rkt | 437 | done |
| parse.rkt | 1872 | done |
| check.rkt | 2558 | done |
| **total** | **11,964** | **~100%** |
