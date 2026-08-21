+++
id = "beagle-cone-receipt-spike"
title = "Cone receipt spike"
shape = "task"
life = "inactive"
updated_at = "2026-08-17T21:06:00+08:00"
owners = ["codex:/root"]
depends_on = []
assigned_to = "codex:/root"
delegated_by = "operator"
+++

## Outcome

The killer gate is answerable today at the compiler semantic-unit seam. The
native program cache does not yet consume that answer for reuse.

## Receipt

Lane and compiler commit: `beagle` at
`4f9c6f874157e3e7746e7e5f47c8748260511f25`.

New fixture: `cone.a/value` is called directly by `cone.b/consume`.
Every build used `bin/beagle build --materializer c17 --entry cone.b/consume`
and returned `result PASS`.

`source.facts` emitted this dependency in every version:

```text
read    cone.b/consume    cone.a/value
```

| Version | `cone.a/value` semantic SHA-256 | `cone.b/consume` semantic SHA-256 | Receipt |
| --- | --- | --- | --- |
| baseline | `a106c467…0c24e7` | `83cf662c…bdff4d` | baseline |
| body edit, same signature | `9ea1388d…352f12` | `83cf662c…bdff4d` | invalidate A; **skip B** |
| signature edit | `877e9160…8f0607` | `e722bdbb…e730b5` | invalidate A and B |

Actual delta output:

```text
body-edit       invalidated     cone.a/value
body-edit       skipped         cone.b/consume
signature-edit  invalidated     cone.a/value
signature-edit  invalidated     cone.b/consume
```

The existing compiler unit-reuse gate also passed against the observed corpus:

```text
branch-compile-corpus: unit reuse PASS 9/9, 8/9, 7/9 exact reuse
branch-compile-corpus: singleton PASS 0/1/2 compiled units, 3 attach-body,
3 lower-ready-function, deterministic repetition
```

This proves the selected payload reuse cone, including the body versus
signature distinction. The observed four-module corpus independently reported:

```text
private-implementation  corpus.foundation/private-offset
public-interface         corpus.feature/score-value,corpus.foundation/adjust
```

## Native-cache boundary

`branch-core/bin/fram-native-build` currently computes one
`program_closure_hash` in `write_program_input_manifest`; its manifest contains
every logical source path and every source content digest. Therefore either A
edit changes the whole native-program key and produces a cache miss/rebuild.
It has no per-unit payload key or dependency-context reuse decision, so it
cannot presently state that B was physically skipped.

The exact implementation seam for native reuse is
`branch-core/bin/fram-native-build:write_program_input_manifest` and its
single `$program_cache/$program_closure_hash` lookup. Feed the compiler's
semantic-unit content digests plus direct-read/interface-context receipt into a
unit cache there, then assemble the already-existing unit-reuse result. Keep
the whole-program key as the final assembly/artifact key.

## Verification notes

- `beagle doctor --revive --quiet` followed by `beagle doctor --deep` reported
  `Authoring loop: ok`.
- The focused `branch-compile-corpus/run.sh --observe` completed and generated
  the source-fact receipts above.
- Its `--check` form stopped before unit reuse because the tracked whole-build
  snapshot drifted in bundle/source-fact and frozen-program digests. The direct
  unit-reuse gate above passed against those current observed builds.
- The general build result cache logged `BYPASS untrusted-compiler` during the
  direct fixture builds; no claim here treats that cache as evidence of a
  physical B skip.

## Current state

Committed as `018cf2806df1b1d6e039fae8e0a1b56e15b00011`. No landing was
performed; after these findings were extracted, the worktree and branch were
reaped.
