# Code as canonical claims — move 3

Proves the **flip is real**: a Beagle program can live as canonical claims and lose
nothing. The loop:

```
.bclj --import--> lossless claims --(through a real Fram store)--> claims --export--> .bclj'
```

- **import** = `claims-roundtrip --emit-edn` (the lossless datum-level projection,
  comments included — *not* the lossy query projection the call graph uses).
- **the canonical store** = a real Fram store (`through-fram.clj`, mirroring
  chartroom's `roundtrip_fram`): claims loaded in, re-extracted out, entity ids
  re-minted by the engine.
- **export** = byte-stable `datum->pretty` (`--render`, move 2).

## The two proofs (`run.sh`, over `fram/src`)

1. **Datum-identical through the Fram store** — the program reconstructs
   datum-identically after a round-trip through a real Fram store (not just an
   in-memory map). 11/11.
2. **Recompile-identity (modulo srcloc)** — `beagle build` of the regenerated tree
   is **byte-identical** to `beagle build` of the original, after stripping
   `^{:line N :file "..."}` srcloc metadata. So the emitted *program* is identical;
   claims-canonical loses nothing for the compiler.

### Why "modulo srcloc"

`beagle` bakes `^{:line N :file "..."}` debug pointers into the `.clj`. Those
necessarily reflect the source text's **layout and location**, not the program —
and `datum->pretty` reformats to its canonical style, so the regenerated source has
different line numbers (and a different path). In the *flipped* world the canonical
text **is** the regenerated text, so those srclocs correctly point at it. Stripping
them and getting byte-identity proves the actual emitted code is the same. This is
honest, not a dodge: srclocs are debug metadata, and two semantically-identical
sources with different formatting *must* differ only there.

## Capability vs adoption (the honest line)

This proves code **can** be claim-canonical (the capability + the loop + the gate).
It does **not** convert a live repo's source to *be* the Fram log — that's an
adoption decision (and a workflow change), deliberately not made here.

Note: regenerated source is **0/11 byte-identical** to the hand-formatted original —
`datum->pretty` imposes its canonical style, so a first flip reformats the tree
(like adopting gofmt/prettier). Expected; the program is unchanged (recompile-identical).

## Run

```
CODE_AS_CLAIMS_CORPUS=~/code/fram/src FRAM_OUT=~/code/fram/out bin/test/code-as-claims/run.sh
```

Needs racket (`claims-roundtrip`, `beagle-build-all`) + bb + fram's `out/` classpath.
Gated in CI over the checked-out `fram/src`.
