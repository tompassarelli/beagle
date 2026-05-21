---
status: active
priority: 1
---

# Self-hosting: beagle compiles itself

Target: 25%+ of core compiler lines emitted by beagle-written emitters.

Core compiler is ~12K lines: parse.rkt (1872), check.rkt (2558),
emit-js.rkt (1562), emit-py.rkt (1098), emit-nix.rkt (1069),
emit-rkt.rkt (983), emit-clj.rkt (765), lint.rkt (743),
macros.rkt (484), ast.rkt (437), types.rkt (393).

## Pipeline

Racket handles parse + type-check. Beagle-written emitters (compiled to
JS via Node) produce the final target source from JSON AST.

```
source.bgl → bin/beagle-ast → JSON AST → node emit-{target}.mjs → target source
```

## Done

- [x] AST JSON bridge (`ast-json.rkt`, `bin/beagle-ast`)
  - Extension-based target inference in `read-beagle-syntax`
  - Fixed: case-clause body (single expr, not list), if-let then/else (single expr),
    pat-record bindings (symbol list, not pairs), defunion/deferror member-fields
- [x] JS emitter (`self-host/emit-js.bjs`, ~950 lines)
  - Passes hello-js.bjs match test (vs Racket emitter)
  - Fixed-point reached (gen2 = gen1)
- [x] CLJ emitter (`self-host/emit-clj.bjs`, ~370 lines)
  - Passes mathlib.bclj, shapes.bclj, result.bclj, kitchen-sink.bclj
  - `bin/beagle-self-emit-clj` pipeline script
  - defunion/deferror member-fields emission
- [x] Python emitter (`self-host/emit-py.bjs`, ~970 lines)
  - Passes pytest.bpy (exact match vs Racket emitter)
  - `bin/beagle-self-emit-py` pipeline script
  - Indentation tracking, dataclass records, match/case, list comprehensions,
    loop/recur → while True, try/except, ~40 core call translations
- [x] Unified build script (`self-host/build.sh`)
  - Builds + verifies all three emitters (6 checks, all pass)

## Stretch

- [ ] Nix emitter (`self-host/emit-nix.bjs`)
- [ ] Racket emitter (`self-host/emit-rkt.bjs`)
- [ ] Lint pass (`self-host/lint.bjs`)

## Coverage

| component | lines | status |
|-----------|-------|--------|
| emit-js.rkt | 1562 | done (emit-js.bjs, 950 lines) |
| emit-clj.rkt | 765 | done (emit-clj.bjs, 370 lines) |
| emit-py.rkt | 1098 | done (emit-py.bjs, 970 lines) |
| **subtotal** | **3425** | **~28% of 12K** |
