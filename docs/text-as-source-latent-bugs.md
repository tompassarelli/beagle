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
>
> **Same class in the JS backend — FIXED (found by adversarial verification):** the
> determinism skeptic auditing the clj fix found `emit-js.rkt` carried a *module-level*
> `(define match-counter (box 0))` that was **never reset per program**. Within one
> build the file set is sorted and the counter is process-deterministic, so a single
> invocation was byte-stable — but the box LEAKED across programs: the second
> match-using module in one process started at `_match_1`, not `_match_0`, so a
> module's `.js` depended on what was built *before* it. Fixed identically: `match-counter`
> is now a `make-parameter` box, reset fresh in `js-emit-program`. Gated by the js leg of
> `bin/test/build-reproducible` (two match modules in one invocation; each must reset to
> `_match_0`). Same bug in two backends; the adversarial "find ANY other source of
> nondeterminism" prompt is what surfaced the second.

> **Scope-correctness holes in graph-native RENAME — FIXED (adversarial verification).**
> Distinct from the migration findings above (those were *text* hiding bugs); these were
> bugs in the *graph engine itself*, found by adversarially stress-testing the headline
> claim "graph-native rename is scope-correct, unlike sed." Both **recompiled clean** —
> the most dangerous failure mode (a silent meaning change a green build endorses):
> 1. **Typed paren-param `(x :- T)` not collected as a binding.** `collect-bind-syms`
>    handled bare/`[..]`/`{..}` params but not the legal paren form, so a param `(red :- Int)`
>    was invisible to the resolver; a body use of `red` then resolved to a same-named
>    top-level def and was wrongly renamed with it. Fix: collect the symbols before `:-`
>    in a paren list (and resolve its inner type too, so type-renames still cascade).
> 2. **No no-capture invariant.** The collision guard only checked def-vs-def, so
>    `rename src→dst` where `dst` is a param/let-local was *accepted*, rewriting a
>    reference into a name captured by the local: `(+ dst src)` → `(+ dst dst)`,
>    `(* sum total)` → `(* sum sum)`. Fix: a scope-precise `capture-refs` walk (reuses
>    the resolver's exact frame construction) refuses the rename if any reference to the
>    renamed def has `new` bound by an enclosing local — checked across all files, since a
>    `:refer`'d bare reference lives in a consumer module. Both gated by
>    `bin/test/code-as-claims/rename.sh §5`. The lesson mirrors the thesis: scope-correctness
>    is a *property to be verified adversarially*, not assumed because the graph "knows scope."
>
> **The lesson, quantified — adversarial sweep #2 found SEVENTEEN more.** A second,
> deeper sweep (8 skeptics, one per scope hazard) over the same engine surfaced **17
> real silent-miscompiles** (recompiled-but-wrong), 0 false-positives, in two clusters:
> (A) `:or` destructuring defaults were never walked (a default referencing a def left
> dangling) and `let`/`loop`/`for` bindings were resolved in the OUTER scope although
> they are SEQUENTIAL, so an earlier sibling never shadowed a later value — both a
> missed rename and a *missed capture* the no-capture invariant should have caught; and
> (B) a bare symbol naming a type was never a reference, so constructor calls
> `(Point ..)`, `defunion` variants, cross-module types, and single-colon `:`
> annotations all failed to track a type rename (and made `delete` false-report "safe"
> on code that then dangled). Fixing the cross-module case exposed an *eighteenth*: bare
> `(require m :refer […])` was never parsed (only bare `:as` was), so refer-imported
> references silently neither resolved nor renamed. All fixed + gated
> (`rename.sh §6-§8`, `delete.sh`). The headline: a graph engine is not scope-correct
> *because* it is a graph — it is scope-correct only where it has been adversarially
> proven so. Two sweeps, 2 + 17 concealed wrong-answers in an engine whose whole pitch
> is "correct unlike sed." Verify, don't assume.
>
> **Loop-until-dry — the full run (sweeps 1-11).** The sweeps continued until the
> finder rate fell to a DRY ROUND. Real silent-miscompiles found per sweep:
> **3, 17, 7, 7, 6, 5, 3, 3, 1, 5, 4, 0** (~61 total) — sweep #12 found ZERO across every
> area (defmethod/reify, as-> regression, grand identity) → **CONVERGED**. 0 surviving false-positives. Each
> round probed beagle surface the resolver had never modeled, so this was *completing*
> the resolver for beagle's real surface, not chasing exotica. The categories closed:
> sequential/`:or` bindings; the type family (constructors, `defunion` variants,
> cross-module types, single-colon `:`); the full quasiquote family (reader-`~`,
> explicit `(unquote)`, quoted data) — sweep #4 even caught a *regression sweep #3's own
> fix introduced*, the loop catching itself; the shipped `defrecord`+`defunion` idiom
> (rename was splitting the type); multi-arity `defn`; `->`/`map->` auto-constructors;
> synthesized field accessors `<lower(Record)>-<field>` (local **and** cross-module);
> `match` as a real pattern-binding form; typed `let`/`for` bindings; fully-qualified
> `module-name/Name` refs; `defprotocol` method names; and `letfn` + `extend-type`
> binding scopes. Every fix is CI-gated (`rename.sh §1-§16`, `delete.sh §1-§10`,
> `authoring.sh`) and move-3 identity (datum + recompile) held throughout. The deepest
> lesson, now quantified at ~57: "the graph knows scope" is a *claim to be earned per
> form*, not a property of being a graph — an adversarial loop, run until dry, is how
> you earn it. (Acceptable known-limitations, not bugs: comment prose-word over-rename;
> `:rename` map, which beagle rejects; fused reader `~x` in macro templates, which the
> clj target has no functional consumer for.)
