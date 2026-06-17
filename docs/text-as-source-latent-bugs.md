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

## 5. Comment subtree orphaned through the Fram store (float node ids)
**Surfaced by:** the move-3 canonical loop's *through-a-real-Fram-store* leg
(move-2 was in-memory and could not see it).
**The bug:** `max-id` (which allocates comment/segment node ids beyond the
structural ids) considered leaf VALUES via `(integer? (caddr t))`, and Racket's
`integer?` is **#t for integer-valued floats** (`2.0`, `16.0`). A float literal in
the source therefore poisoned the allocation, emitting comment node ids as FLOATS
(`192.0`). The Fram-store loader's node-ref test was `(integer? o)` — false for
`192.0` — so it interned each comment ref as a VALUE, orphaning the whole comment
subtree; after the store re-minted ids, root-finding picked a wrong node and
reconstruction crashed (`cljs-interop.bcljs`, `gatepolicy.bclj`).
**Why it hid:** files whose comment ids happened to be plain integers round-tripped
fine; only a source with a float literal + comments through a *real store* exposed it.
**Fix:** `max-id` considers only subjects (real node ids) via `exact-integer?`;
the loader treats any bare number as a node-ref (leaf values are quoted strings in
the EDN); `edn-root` prefers the structural wrapper over hash order. (Same probe also
found `emit-edn` crashing on `.bnix` top-level brace-maps where `syntax-span`=#f —
fixed with a guard.) Gated: `bin/test/code-as-claims`.

---

**Pattern:** five independent migrations, five concealed correctness bugs — bugs
masking bugs (case 3), corruption hiding behind "no real input triggers it" (cases
4, 5), and a whole class invisible until exercised *through the engine* (case 5).
The text/`Any` representation was not a neutral serialization — it was actively
hiding wrong answers. That is evidence for the thesis, not incidental cleanup.

> **Adjacent finding — FIXED (a build-reproducibility bug):** the move-3
> recompile-identity gate revealed that `beagle build` was **not byte-reproducible**
> for `match` — its temp was `(format "match__~a" (random 99999))`, so the *same*
> source produced different `.clj` each build. Fixed in `emit-clj.rkt`: the temp is
> now a deterministic per-program counter (`match__0`, `match__1`, … — parameterized
> fresh in `clj-emit-program`, the emit-odin pattern), so the same source compiles
> byte-identically every build. Gated by `bin/test/build-reproducible`. Not a
> claims-loop loss (the loop was always datum-faithful), but it makes the committed
> `out/` and the recompile gate robust without relying on the build-nondeterminism guard.
