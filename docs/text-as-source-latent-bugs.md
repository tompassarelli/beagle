# Latent bugs surfaced by moving off text-as-source

A running ledger. The thesis behind graph-native repair is that **text-as-source
isn't neutral** — it doesn't just make analysis slower, it *silently corrupts and
conceals*. Each entry below is a real correctness bug that existed for some time,
invisible, and became visible only when a layer moved from text/`Any` to structured
claims. "Migrating off text *found* these" is the receipt that the boat deserved to
burn.

The bar for an entry: a genuine wrong-answer or data-loss bug (not a style nit),
that the text/`Any` layer was *hiding*, surfaced as a side effect of a migration.

---

## 1. `schema/value-id` returned a masked `nil`
**Surfaced by:** typing Fram's engine in Beagle (replacing `:- Any` with real types).
**The bug:** `value-id` is genuinely `Int?` (can return `nil`), but under `:- Any`
the checker looked at nothing, so callers indexed with the result unguarded. `Any`
was masking a real nullability bug.
**Why text/`Any` hid it:** `Any` opts *out* of checking — the wrong value was as
unchecked as untyped Clojure. Expressing the real type (`Int?`) forced the guard.
**Fix:** nil-guarded before the index lookups; the type is now `Int?`.

## 2. `beagle-cascade` bare-name blast radius merged across modules
**Surfaced by:** moving cascade's call graph from regex-over-text to the Fram
`calls` claim graph (move 1, tool 1).
**The bug:** the regex call graph keyed callers by **bare function name**, so a
`helper` defined in two modules merged into one node. Changing `mod_a/helper` was
reported as breaking callers of `mod_b/helper` — a function never touched. Wrong
blast radius, every time there was a name collision, silently.
**Why text hid it:** text doesn't know what calls what; a bare-symbol match *cannot*
distinguish the two `helper`s, so the wrong answer looked like a normal answer.
**Fix:** scope-correct call graph (a call binds the defn in its own module).
Gated: `bin/test/cascade-graph`.

## 3. `beagle-repair` deduped distinct suspicions into one
**Surfaced by:** moving semantic suspicions from regex-scraped prose to structured
records (move 1, tool 2).
**The bug:** `beagle-repair` deduplicated repairs by `file:line`, but semantic
suspicions carry no line (`?`), so **every suspicion in a module collapsed to one** —
a module with two suspicious functions reported only one. The code's own comment
*predicted* this ("distinct fixes that share a file:line still collapse").
**Why text hid it:** the prose-`SUSPECT` regex was *also* silently dropping any
suspicion on a function whose name it couldn't parse (e.g. `total=`), so two
suspicions almost never survived to collide — the drop bug masked the dedup bug.
A bug hidden behind a bug, both in the text layer.
**Fix:** structured records survive verbatim; no-line entries dedup by function.
Gated: `bin/test/repair-semantic`.

## 4. `datum->src` silently corrupted exotic symbols (round-trip hole)
**Surfaced by:** building the byte-stable emit gate (move 2) + adversarial
verification of it.
**The bug:** the source renderer rendered every symbol with bare `symbol->string`,
never re-applying the reader's escaping. So a symbol whose name contains
whitespace/delimiters/backslash, or the empty symbol (both constructible —
`|foo bar|`, `\\`, `||`), did NOT round-trip: `|foo bar|` re-read as TWO symbols,
`\\` (a one-backslash symbol) rendered to unreadable text, `||` (empty symbol)
rendered to nothing so the value vanished.
**Why text hid it:** no real `.bclj` uses such symbols (109 source files + 98
fixtures all round-trip), so the renderer looked correct for years. Only an
adversarial probe constructing the pathological symbols exposed that the text
serialization was lossy for an entire class of values.
**Fix:** `symbol->src` backslash-escapes unsafe chars per the reader's actual
convention (`|...|` is a literal run with no internal escaping; `\X` escapes
outside bars), with the empty symbol rendered `||`. Gated: `bin/test/byte-stable-emit`
+ the `--pretty-gate` skip detector (an unparseable file now fails the gate instead
of silently not-counting — a second blind spot the same probe found).

---

**Pattern:** four independent migrations, four concealed correctness bugs — and in
case 3 one bug was *masking* another, in case 4 the corruption hid behind "no real
input triggers it." The text/`Any` representation was not a neutral serialization —
it was actively hiding wrong answers. That is evidence for the thesis, not
incidental cleanup.
