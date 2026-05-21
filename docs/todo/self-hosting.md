---
status: active
priority: 1
---

# Self-hosting: beagle compiles itself

Core compiler is ~12K lines: parse.rkt (1872), check.rkt (2558),
emit-js.rkt (1562), emit-py.rkt (1098), emit-nix.rkt (1069),
emit-rkt.rkt (983), emit-clj.rkt (765), lint.rkt (743),
macros.rkt (484), ast.rkt (437), types.rkt (393).

## Pipeline

Racket handles parse + type-check. Beagle-written components (compiled to
JS via Node) produce target source from JSON AST.

```
source.bgl → bin/beagle-ast → JSON AST → node emit-{target}.mjs → target source
```

## Done — emitters + lint (52%)

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
- [x] Unified build script (`self-host/build.sh`) — 13 checks, all pass
- [x] Pipeline scripts: beagle-self-emit, beagle-self-emit-clj, -py, -nix, -rkt

## Next — internal logic (remaining 48%)

- [ ] macros.bjs (484 lines) — macro expansion engine
- [ ] types.bjs (393 lines) — type AST, parser, compatibility checker
- [ ] ast.bjs (437 lines) — AST struct definitions as JS classes

## Hardest — parser + type checker

- [ ] parse.bjs (1872 lines) — source → AST, macro expansion, module resolution
- [ ] check.bjs (2558 lines) — type inference, flow narrowing, exhaustive match

These are deeply Racket-specific (syntax objects, reader macros, module system).

## Coverage

| component | lines | status |
|-----------|-------|--------|
| emit-js.rkt | 1562 | done |
| emit-clj.rkt | 765 | done |
| emit-py.rkt | 1098 | done |
| emit-nix.rkt | 1069 | done |
| emit-rkt.rkt | 983 | done |
| lint.rkt | 743 | done |
| **done** | **6220** | **~52%** |
| macros.rkt | 484 | next |
| types.rkt | 393 | next |
| ast.rkt | 437 | next |
| parse.rkt | 1872 | hard |
| check.rkt | 2558 | hard |
