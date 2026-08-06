# Target policy

Targets are removed, not deprecated, when they stop earning their place.
Reviving one means re-wiring the emitter and proving it against a real consumer,
not flipping a switch. There is no back-compat shim and no deprecation window.

The canonical source-profile and materializer registry is
`beagle-lib/private/targets.rkt`. Every inventory in the repository — the
`bin/beagle` usage line, `share/targets.sh`, `bin/beagle-doctor`, and every doc
span wrapped in a `<!-- beagle:langs … -->` marker — is a derived view of it,
refilled by `bin/beagle doc-fill`. `beagle-test/tests/docfill.rkt` fails the
build when a derived view has drifted, so adding or removing a profile is one
edit plus one fill.

## Removed targets

| target | removed | reason | tag |
|---|---|---|---|
| SQL | 2026-06-28 | unused, rotting | `sql-archive-2026-06-28` |
| ClojureScript | 2026-07-04 | zero users, redundant against the native JS target | `cljs-final` |

The tags exist in the repository, so the removed emitters remain readable at
those points in history.

## What is not a target

`facts` is the compact, lossy projection of the parsed AST into CNF analysis
facts, represented as three-slot vectors (`bin/beagle-facts`, implemented by
`beagle-lib/private/emit-facts.rkt`). It is a query surface, not an authoring
language. It has no `#lang`, no source extension, and no idiom, and is carried
separately in `targets.rkt`'s `PROJECTIONS` list precisely so views can mention
it without it drifting back into "seven targets".

`beagle facts-roundtrip` is the verbose, program-lossless source↔fact projection
used by code-as-facts; "lossless" means reader-datum identity, not byte
identity. The two projections share the fact layer, not a fidelity contract, so
no single sentence describes both.

Bare `#lang beagle` on `.bgl` names the Native Core profile and always lowers
to a frozen Native World. `.bgl` never means target-neutral or "no target
selected"; only the resulting Native World is backend-neutral. Hosted profiles
use their explicit language paths and extensions, such as `#lang beagle/clj`
on `.bclj`. Only `.rkt` remains legacy and exempt from extension/header
validation.
