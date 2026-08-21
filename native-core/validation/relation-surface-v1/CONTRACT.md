# Relation-centered surface v1 validation contract

This is a validation-local, non-default source-profile experiment. It does not
register `#lang beagle/rel`, modify the production reader, or change bare
`#lang beagle`. The tracked `.brel` files are source projections consumed by a
typed Native Beagle translator. Generated Lisp/Core exists only in driver
scratch space.

## One admitted semantic shape

The v1 grammar is deliberately closed:

```text
source   := "(" INT PLUS INT ")" EQUALS INT EOF
PLUS     := "+" | "plus"
EQUALS   := "=" | "equals"
INT      := a canonical signed 64-bit decimal integer
```

Whitespace, comments, and line layout are reader trivia. The existing
`beagle.datum-reader` supplies bounded structural events; because it currently
classifies decimal atoms as symbols, the translator validates every decimal
lexeme itself.

Both of these source projections:

```text
(2 + 5) = 7

(
  2
  plus
  5
)
equals
7
```

lower deterministically to the ordinary checked Core expression:

```clojure
(= (+ 2 5) 7)
```

Equality therefore has ordinary eager Boolean semantics in this experiment.
No relation, proposition, constraint, variable, mode, or search node survives
to Beagle checking or Native lowering.

## Semantic boundaries

| Surface category | v1 decision |
| --- | --- |
| expression | Ordinary evaluation through existing typed Core. |
| proposition | Future preserved semantic content; not implemented here. |
| query | Future explicit open-relational profile; not implemented here. |
| assertion | Separate Store admission; never implied by translation. |

Open `?x`, `query`, `solve`, `assert`, `fact`, `law`, `rule`, `goal`, malformed
integers (including overflow), and every unsupported shape are hard rejections.
A rejection writes neither generated Core nor a receipt. This fixture contacts
no Store, creates no world, asserts no proposition, and requests no effect
beyond bounded local file reads and scratch-file writes through `host.fs`.

## Identity and authority

`SourceProjectionV1` keeps the logical source path and exact raw source bytes.
Its source-content identity covers the raw bytes; its projection identity
covers both path and raw bytes. The semantic identity covers the canonical
ordinary Core expression, while the canonical-module identity covers the
generated module bytes.

Consequently, different paths, layout, and operator spellings can have distinct
projection identities while sharing byte-identical generated Core and equal
semantic/module identities. Reading the same projection twice must produce
byte-identical Core and receipt bytes. Files are first-class inputs in this
prototype even though durable semantic identity is intentionally independent
of their layout and path.

## Current gaps this does not design away

Beagle's Lisp compiler AST, compiler fact projections, and Store Terms remain
separate current surfaces. This experiment records that boundary; it does not
pretend Store triples are compiler expressions or that derivation is Store
assertion.

The language reader protocol can produce an accepted `ReaderProductV1`, but
the production `parse-program` path cannot yet consume that product directly.
This validation therefore uses `beagle.datum-reader` events in its typed local
translator, writes canonical Core only to scratch, and re-enters the existing
compiler at its ordinary source parser. That `ReaderProduct -> parse-program`
seam remains an integration gap, not a capability claimed by this prototype.
