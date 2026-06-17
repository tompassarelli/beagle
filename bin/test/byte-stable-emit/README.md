# Byte-stable emit — move 2

`datum->pretty` (in `beagle-lib/private/claims-roundtrip.rkt`) renders a parsed
Beagle program (or one reconstructed from claims) back to source. It is the
deterministic, local, comment-preserving formatter that lets the graph be
canonical and text be a regenerable lowering — the precondition for the
claim-canonical flip (move 3).

## The contract (what `run.sh` gates)

1. **Idempotent fixed-point** — `pretty(parse(pretty(x))) == pretty(x)`, byte-identical.
   Follows from purity (output depends only on the datum + width) + the round-trip.
2. **Round-trip preserving** — pretty text re-reads to the IDENTICAL datum.
3. **Locality** — a one-token change yields a small, local diff (each element owns
   its line when a form breaks). This is the property determinism does NOT give for
   free.
4. **Comment-preserving** — leading/trailing/file comments survive the
   claims→source render (`render-edn` uses `datum->pretty`, keeping Turtle #6
   placement).

`run.sh` proves all four: fixed-point + round-trip over the in-repo fixture corpus
(racket-only, no fram/bb), a locality receipt (one-token change → single-line
diff), and comment preservation + rendered-text round-trip. It also fails on any
**skipped/unparseable** file — a skip is not a pass.

## Idiomatic indentation

Form signatures stay on the opening line; only the body breaks (indented). The
`head-keep` table (derived from a discovery pass over `parse.rkt` + the corpus)
keeps: `defn` name+params+`:- ret`; `let`/`if`/`when` heads; `def`/`defonce`
bindings; `fn` params+`:- ret`; `defrecord` name+fields; threading inits;
`do`/`try`/`cond` standalone. So a body edit is a local diff.

## Known limitations (honest)

- **Width-boundary reflow is inherent.** A one-token change that pushes a form from
  inline (fits in 80 cols) to broken reflows that whole form (each element to its
  own line) — an O(arity)-line diff for a one-token change. Every width-based
  formatter (prettier, gofmt, cljfmt, black) has this; round-trip still holds. The
  locality guarantee is for edits that don't cross the width boundary — the common
  case. Not a gate failure.
- **A pathologically long signature line** (e.g. a many-binding `let`) stays one
  line rather than breaking per-pair. Cosmetic; the diff is still local.
- **Comment capture gaps** (pre-existing in Turtle #6, not introduced here): block
  `#|...|#` comments and comments *inside* a form are not captured; at most one
  comment per line; exact whitespace/alignment is normalized.

## Surfaced + fixed

Adversarial verification found a real round-trip hole: `datum->src` rendered
symbols with bare `symbol->string`, so a symbol containing whitespace/delimiters/
backslash, or the empty symbol (constructible via `|...|` or `\`), did NOT
round-trip (`|foo bar|` → two symbols; `\\` → unreadable; `||` → vanished value).
Fixed: `symbol->src` backslash-escapes unsafe chars per the reader's actual
convention (`|...|` is a literal run with no internal escaping; `\X` escapes
outside bars), empty → `||`. Logged in `docs/text-as-source-latent-bugs.md`.

## Flagged (separate, not move 2)

`#?(...)` reader-conditionals parse via `reader-impl.rkt` but `read-beagle-syntax`
(parse.rkt's readtable) rejects them — a reader divergence. `.bgl` files declaring
`#lang beagle/rkt` are rejected (invalid target). These are reader/corpus gaps for
their owners, not emit bugs.

## Run

```
bin/test/byte-stable-emit/run.sh
```
