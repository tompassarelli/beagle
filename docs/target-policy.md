# Target policy

Targets are removed, not deprecated, when they stop earning their place.
Reviving one means re-wiring the emitter and proving it against a real consumer,
not flipping a switch. There is no back-compat shim and no deprecation window.

The canonical target list is `beagle-lib/private/targets.rkt`. Every target
enumeration in the repository — the `bin/beagle` usage line, `share/targets.sh`,
`bin/beagle-doctor`'s emitter inventory, the cheatsheet preamble, and every doc
span wrapped in a `<!-- beagle:langs … -->` marker — is a derived view of it,
refilled by `bin/beagle doc-fill`. `beagle-test/tests/docfill.rkt` fails the
build when a derived view has drifted, so adding or removing a target is one
edit plus one fill.

## Removed targets

| target | removed | reason | tag |
|---|---|---|---|
| SQL | 2026-06-28 | unused, rotting | `sql-archive-2026-06-28` |
| ClojureScript | 2026-07-04 | zero users, redundant against the native JS target | `cljs-final` |

Both tags exist in the repository, so the removed emitters remain readable at
those points in history.

## What is not a target

`facts` is a lossless CNF fact-triple projection of the same AST
(`beagle-lib/private/emit-facts.rkt`, exercised by `bin/beagle
facts-roundtrip`). It has no `#lang`, no source extension, and no idiom; it is a
query surface, not a language you author against. It is carried separately in
`targets.rkt`'s `PROJECTIONS` list precisely so views can mention it without it
drifting back into "seven targets".

Beyond the target set, two source extensions name no target:
`.bgl` (target-neutral — declare with `#lang beagle/<target>` or `(define-target
…)`) and `.rkt` (legacy — no extension or header validation).
