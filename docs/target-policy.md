# Target policy

The canonical source-profile and materializer registry is
`beagle-lib/private/targets.rkt`. Every inventory in the repository — the
`bin/beagle` usage line, `share/targets.sh`, `bin/beagle-doctor`, and every doc
span wrapped in a `<!-- beagle:langs … -->` marker — is a derived view of it,
refilled by `bin/beagle doc-fill`. `beagle-test/tests/docfill.rkt` fails the
build when a derived view has drifted, so adding or removing a profile is one
edit plus one fill.

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

Hosted targets produce replaceable materializations of the checked AST; Native
materializers consume its frozen native-program projection. Neither introduces
another program identity. A content digest identifies an input or output; it
does not confer trust, authority, or permission to execute.

Bare `#lang beagle` on `.bgl` names the experimental Native Core profile and
always lowers to a frozen native program. `.bgl` never means target-neutral or
"no target selected"; only the resulting native program is backend-neutral.
Hosted profiles use their explicit language paths and extensions, such as
`#lang beagle/clj` on `.bclj`.
