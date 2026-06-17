# Structured semantic suspicions — the proof

`beagle-repair` merges evidence from several diagnostic sources into a ranked
repair queue. The semantic-suspicion source (`blame.rkt`) walks the real AST and
produces a fully structured `(struct suspicion (function-name rule op location
confidence message))` — then **threw it away**: `format-suspicion` collapsed it to
a prose line `SUSPECT [conf]: message`, and `beagle-repair` regex-scraped the
function name back out of the message prefix.

## Why it had to change

The scrape regex was `SUSPECT \[([0-9.]+)\]: ([\w?!<>*+\-/]+): (.+)`. The function
name group stops at the first character outside its class. A **valid** Beagle name
like `total=` (Clojure/Beagle allow `=` in identifiers) makes the regex match
`total`, fail on `=`, and **drop the entire suspicion silently** — a real bug
report on a real function, gone, with no error. The structured fields were right
there at the source and got flattened to text one step before they were needed.

## The fix

`blame.rkt` emits each suspicion as a structured JSON record
(`beagle-semantic-json: {…}`) when `BEAGLE_SEMANTIC_JSON=1`; `beagle-repair` sets
that flag and consumes the record directly — `function`, `op`, `context`,
`confidence`, `reason` — no prose round-trip, no re-derivation. The human prose
warning is unchanged when the flag is unset (default).

Fixing this surfaced a **latent dedup bug**: `beagle-repair` deduplicated repairs
by `file:line`, but semantic suspicions have no line (`?`), so every suspicion in a
module collapsed to one. (The old code knew — its comment predicted it; the regex
drop just hid it by never letting two survive.) Entries with no concrete line now
dedup by function instead.

## The fixture

`corpus/acct.bclj` defines two functions that both trip the "name implies
aggregation — subtraction is suspicious" rule: `grand-total` (regex-parseable) and
`total=` (valid name the regex drops).

## The receipt (same fixture, two engines)

```
REGEX (pre-migration, scrapes the prose SUSPECT line) captured:
    grand-total
STRUCTURED (consumes blame.rkt JSON records) captured:
    grand-total
    total=
```

The regex engine silently dropped a real suspicion on a validly-named function;
the structured path kept it.

## Run it

```
bin/test/repair-semantic/run.sh    # asserts total= survives; prints the receipt
```

Needs racket + bb (the build/check + oracle phases). The structured-capture
assertions gate in CI; the side-by-side receipt renders when the pre-migration
`beagle-repair` is reachable in git.

## Scope

This is the second repair tool moved off text-scraping onto structured data (after
`beagle-cascade` → the Fram call graph). The semantic source now passes structured
records end to end. The remaining regex scrapes in `beagle-repair` are the
specfix/blame **runtime-oracle** outputs (value-level ratio hints, not flattened
AST analysis) — a different shape, tracked separately. The type checker is
untouched.
