# Value-Semantics Ownership & Type-Driven Representation Selection

**Status:** Design / proposal (not yet built). 2026-06-21.
**Scope:** Primarily the JS backend; the invariant and harness span all five targets.
**Load-bearing consumer:** Eddy (`.eddy → Beagle/JS`) — see [§5](#5-the-load-bearing-case-eddy-the-downstream-consumer).
**Thesis hook:** the *second axis* of owned resolution — see [§12](#12-thesis-framing-owned-resolution-second-axis).

---

## 0. TL;DR

Squint and Cherry prove the conventional choice is **small JS bundle XOR faithful
Clojure value-semantics** (working `=` on maps, value-keyed sets/maps). They must
choose globally because they are *untyped*.

Beagle has types, so it does not choose. Make **faithful value-semantics an
invariant guaranteed on every target**, and let the type checker drop in the cheap
**native representation only where it can prove the value never needs value-identity**.
Result: **Cherry's correctness at Squint's bundle size** — the persistent runtime is
tree-shaken away everywhere the types say native suffices. Neither Squint nor Cherry
can do this; the reason Beagle can is the entire reason its type system exists.

**Why this is load-bearing, not academic:** Eddy — `.eddy → Beagle/JS → direct-DOM JS`
— is *downstream of this surface*. Its zero-runtime promise ("no framework runtime,
zero dependencies") is incompatible with shipping a persistent runtime always-on, so
type-erasure is the **only** way Eddy can be both correct and dependency-free
([§5](#5-the-load-bearing-case-eddy-the-downstream-consumer)).

This is **thesis-driven, not demand-driven** — so it is *not* gated on a corpus
([§11](#11-why-this-is-thesis-driven-not-demand-gated)).

---

## 1. Current state (verified)

Facts from the tree as of this writing (anchors, not prose-to-be-trusted):

- **`=` is reference identity, not value equality.** `emit-js.rkt:1267-1269` routes
  `=` through the infix table; `js-capabilities.rkt` `JS-INFIX-OPS` maps `'= → "==="`
  (and `'not= → "!=="`). So `(= {:a 1} {:a 1})` compiles to `({a:1} === {a:1})` ⇒
  **`false`**. This is a live Clojure-semantics bug, independent of the persistence
  question.
- **Immutability (no mutation) is already done** by copy-on-write: `conj → [...a, x]`,
  `assoc → ({...o, k:v})`, `update → {...m,[k]:f(m[k])}`, `dissoc`/`merge` likewise
  (`emit-js.rkt:105-212`). Value *equality* was never wired to match.
- **A runtime module already exists and is owned:** `beagle-lib/lib/beagle/core.js`
  (248 lines, 30+ helpers), imported as `import * as $$bc from 'beagle/core.js'`
  (`emit-js.rkt:639`). Ops route to it via `runtime-call` (`emit-js.rkt:296-418`).
- **A `hash` already ships but is crude:** `core.js:204` is `JSON.stringify(x)`.
  `memoize` keys on `JSON.stringify(args)` too — so there is already an *inconsistent*
  content-keying convention (some ops content-key, `=`/`dedupe`/set-membership use
  `===`).
- **Representations:** keywords → bare strings (`kw->prop`), maps → plain objects,
  vectors → arrays, sets → native `new Set` (so set membership of compound values is
  reference identity — also wrong vs Clojure).

**Implication:** the runtime home, an (inconsistent) hash, and copy-on-write
immutability already exist. What is missing is a single *owned* definition of value
identity and the machinery to render it faithfully and cheaply.

---

## 2. The two problems (do not conflate them)

| | **A. Value equality** | **B. Structural sharing + compound keys** |
|---|---|---|
| Symptom | `(= {:a 1} {:a 1})` → `false`; sets/dedup of equal maps wrong | `assoc` is O(n) copy; maps/vectors can't be map/set *keys* by value |
| Bites | The moment any program compares compound values — **now, latent** | At scale (hot-loop big-map updates) or when compound keys are needed |
| Spec status | **Mandated** ("Beagle is Clojure plus types"; `=` must be Clojure `=`) | Founding-but-narrow; see §7 |
| Fix | Cheap: structural `equiv`/`hash`, **native representation kept** | Heavy: a real keyed/persistent structure |
| Needs persistent structures? | **No** | Only the *compound-key* slice does (see §7b) |

The sharpening that makes the whole design tractable: **native representation + a
correct `equiv` is fully correct for everything except using a compound value as a
map/set key.** JS objects key by string only — no `equiv` can fix that; it genuinely
needs a hash-keyed structure. So the *correctness mandate* for the persistent layer is
exactly the **compound-key reachable set**, which in idiomatic Clojure-on-JS
(string/keyword keys) is small. That smallness is *why* tree-shaking wins (§10).

---

## 3. Prior art that settles the strategy

**Squint vs Cherry — the same decision, made twice by the ClojureScript core team
(Michiel Borkent / borkdude).**

- **Squint** — native JS data structures (plain objects/arrays, keywords→strings,
  copy-on-write spread, ~10KB runtime). *This is what `.bjs` already does.* borkdude
  ships it as the **production-stable** sibling.
  [README](https://github.com/squint-cljs/squint) ·
  [porting blog](https://blog.michielborkent.nl/porting-cljs-project-to-squint.html)
- **Cherry** — vendored `cljs.core` persistent structures = a **~300–350 KB raw /
  ~56 KB gzipped, *un-tree-shakeable* floor** ("not optimizable by ES6 bundlers"),
  marked **experimental, not for production**.
  [porting blog](https://blog.michielborkent.nl/porting-cljs-project-to-squint.html) ·
  [DCD 2022 slides](https://speakerdeck.com/borkdude/clojurescript-reimagined-dutch-clojure-days-2022)
- borkdude's #1 documented native-JS pain was **truthiness** (`0`/`""` falsy in JS) —
  an *untyped* problem Beagle's checker closes statically. The genuinely hard native
  losses he names are exactly **value equality + compound keys**.

**Library landscape (if you ever vendored instead of owned):** Immutable.js is the
only maintained lib with persistent-sharing + value-equality/hashing + compound keys
(v5.1.6, 2026-05; 17.5 KB gz) but is a non-tree-shakeable monolith with a bus-factor
history ([unmaintained 2019–~2024, #1689](https://github.com/immutable-js/immutable-js/issues/1689)).
Mori *is* `cljs.core` extracted — semantically perfect, dead since 2015 (reference
only). immer / @thi.ng/associative each fail a non-negotiable. **Conclusion: own it,
don't vendor** (§6).

**The platform will not rescue you.** TC39 **Records & Tuples was withdrawn 2025-04-14,
repo archived** — engines refused value-`===`
([#394](https://github.com/tc39/proposal-record-tuple/issues/394),
[Igalia summary](https://blogs.igalia.com/compilers/2025/05/20/summary-of-the-april-2025-tc39-plenary/)).
The successor **Composites is Stage 1**, not being pushed for advancement (Nov 2025),
with SpiderMonkey flagging possible unimplementability
([notes](https://github.com/tc39/notes/blob/main/meetings/2025-11/november-19.md)).
"Native + wait for the platform" is a closed door.

---

## 4. The maximal assertion

> The Squint-vs-Cherry tradeoff — small bundle **XOR** faithful Clojure semantics —
> exists only because both are untyped. Beagle, because it has types, **collapses it**:
> faithful value-semantics guaranteed on every target, with the persistent runtime
> tree-shaken to exactly the sites the types can't prove native-safe.
> **Cherry's correctness at Squint's bundle size.**

You do not pick a column of the table. You delete the table.

---

## 5. The load-bearing case: Eddy (the downstream consumer)

This is the strongest external motivation, and it converts the persistent-layer
approach from "nice" to **load-bearing**.

**Eddy is downstream of this exact decision.** Per Eddy's `claude.md`, Eddy is
`.eddy → Beagle/JS compiler → direct-DOM JavaScript`: **every Eddy-generated app *is*
Beagle's JS output.** So Eddy inherits whatever value-semantics the JS target has —
today, including the broken `=`. This document is not choosing whether to build
something Eddy *might* use; it is choosing the semantics of the surface Eddy *already
emits onto*.

**Eddy's zero-runtime thesis is incompatible with always-on persistence.** Eddy's
identity is *"No framework runtime. No virtual DOM. No signal graph. Zero
dependencies. ~490 lines of self-contained JS you own."* The Cherry way of getting
correct value-semantics — ship a ~56 KB persistent runtime, always — would put a
framework-runtime-sized blob into **every** Eddy app, and Eddy's reason to exist
evaporates. Therefore:

> **Type-driven representation selection ([§7](#7-type-driven-representation-selection))
> is the *only* correctness fix compatible with Eddy's thesis.** Native where provable;
> persistent tree-shaken in only where a specific app genuinely needs it. The erasure
> is not an optimization — it is the *precondition* for Eddy being both correct *and*
> zero-runtime. "Own it + erase it" beats "vendor it" not just on principle, but on
> Eddy's product survival.

**Eddy is the best case for the bundle win, not the worst.** Eddy's entities are
string/keyword-keyed maps of scalar fields (see the `.eddy` surface). Those are exactly
the values the [§7b](#7b-what-the-analysis-computes) analysis proves **native-safe** —
so persistence tree-shakes to **~zero** in a typical Eddy app. The §10 residual is
minimized precisely in Eddy's domain. (A complex app using compound keys pays for those
sites; rare here.)

**Where it surfaces in Eddy — RESOLVED by reading the generated code (2026-06-21,
`crm-v2`, the richest demo: FK + derived field + undo).** Eddy compiles *render*
diffing away (direct per-attribute mutation) — untouched. The **state layer** is the
candidate, and the finding is decisive: Eddy's store is **eid-relational**. Entities
live in `new Map()` keyed by integer `eid`; *every* equality in the generated app is
**scalar** (`e.contact === fkEid`, `selectedContact === eid`, `evt.type === 'update'`;
the derived `display-name` is `(str name " @ " company)` over scalar fields); and
`update()` fires `notify()` **unconditionally** — no `if (old === value)` gate. So Eddy
today emits **zero compound `=` and zero compound map-keys**: the `=`-bug is **fully
latent, not a live bug.** Eddy is *insulated* by its eid-relational design.

So P2's value to Eddy is **not a bugfix — it is an enabler.** Two unlocks: (1) **sound
change-gating** — Eddy currently fires `notify`/re-render on every set and recomputes
derived/FK views from scratch (`byContact` filters all entities; O(n) per change);
cheap, correct `=` is the precondition for "skip if the value didn't actually change,"
extended to *compound* field values (scalar attrs could already gate with `===` today —
and don't). (2) **value-keyed derived caches** — memoize `byContact`/`display-name` by
their inputs' *content*. That is Eddy's next reactivity tier, blocked precisely on the
value-semantics this doc owns. Dependency direction is Eddy → Beagle, so it lands with
*no new Eddy work*.

**The deeper convergence (ambition).** Eddy's store *is already fact-shaped*: stable
integer **eid** identity, an append **event log** (`notify({add|update|remove, eid,
attr, old, new})` = supersettable assertions), **undo/redo as a fold over that log**,
and **derived views** over the entities. Eddy independently reinvented a fact store in
emitted JS — and reached for **identity addressing (eid)**, independently corroborating
the addressing thesis (fram `docs/ADDRESSING_THESIS.md`). This is where the *two
customers converge*: value-semantics-ownership (sound `=`/hash/change-detection over the
log) and the fact engine (eid substrate, supersession, Datalog derived-views replacing
hand-rolled `byContact` filters) are the two halves that make Eddy's store rigorous. See
the existing `web/spike/eddy-on-claims/` probe — this work is its value-semantics half.

**Strategic consequence — the CLJS consolidation.** `.bjs` + faithful value-semantics =
*Cherry done right*: ClojureScript semantics, native-JS bundle size, Beagle-owned
diagnostics. It dominates `.bcljs` on every axis except calling an existing CLJS
library. So this work also collapses the JS story to **one owned surface** — `.bjs`
becomes primary; CLJS is demoted to a compatibility shim (kept, not fed). Eddy riding on
`.bjs` is the forcing function that makes that consolidation real.

---

## 6. Stance inversion

Faithful value identity — `=`, `hash`, sets/maps-keyed-by-value — is an **invariant
Beagle owns in the typed IR, and every backend is obligated to render it identically**
([§8](#8-canonical-value-identity-in-the-ir)).

Native JS objects / copy-on-write spread / `===` stop being the default you patch and
become **an optimization the checker earns**: emit the cheap native representation
exactly where it can prove the value never reaches a value-identity position; emit the
faithful representation everywhere else. **Semantics never degrade; only representation
gets cheaper when provably safe.** This is the inversion — persistence is the
guarantee, native is the reward.

And **own it, don't vendor.** Cherry's 56 KB floor is a consequence of *untypedness* —
a monolithic `cljs.core` it cannot erase. Beagle writes its own persistent layer as
independent, tree-shakeable ES exports and erases it per-site. Vendoring a library is
the opposite of owned resolution; you do not rent your value model.

---

## 7. Type-driven representation selection

The actual compiler contribution. Lineage: MLton (monomorphize + flatten/unbox),
GHC (worker/wrapper, unboxing, levity polymorphism), Rust (`repr`). The novelty is
applying representation selection to **Clojure value-semantics on a JS host**, which
untyped compilers (Squint, Cherry, ClojureScript) structurally cannot do.

### 7a. The representation lattice

```
        persistent   (faithful: structural sharing, value-equality, compound keys)
            |          ⊒  (more faithful, more expensive)
          native      (plain JS object/array + equiv/hash helpers)
```

`persistent ⊒ native`. Selection assigns each collection-typed value the **lowest**
(cheapest) representation that is *sound for all of its uses*. Default reward = native;
forced up to persistent only by a use that demands it.

### 7b. What the analysis computes

For each collection-typed binding/result, two questions:

1. **Correctness — value-identity reachability (must-have).** Does the value ever reach
   a position that requires value-identity that native *cannot* provide even with
   `equiv`? The decisive position is **used as a key in a map/set** (JS objects key by
   string; `equiv` cannot help). If **yes → persistent** (correctness). If **no →
   native + equiv is fully correct.** This is a crisp backward reachability/dataflow
   pass over the typed IR.
2. **Performance — hot-path mutation (nice-to-have, secondary).** Is the value updated
   (`assoc`/`conj`/`update`) repeatedly inside a loop over a large collection, where
   O(n) copy dominates? Profile/heuristic-driven; promotes to persistent for
   structural sharing. Not a correctness obligation.

The correctness pass is the one that matters first and is well-defined. Because most
idiomatic maps use string/keyword keys, the compound-key reachable set is small — the
empirical basis for the bundle win.

### 7c. The coherence / coercion discipline (the hard part)

Selection is only sound with a join rule and boundary coercions:

- **Join.** A value flowing into both a native-safe site and a persistent-required site
  takes the **join = persistent** (the safe upper bound). Native only when *all* uses
  are native-safe. Straightforward unification / backward dataflow.
- **Interop boundary.** A plain JS object arriving from FFI that is then used as a key
  must be **lifted** to persistent at the boundary (a real cost to budget).
- **Mixed `=`.** Equality between a native and a persistent representation needs a
  **bridging `equiv`** that compares across representations.

This — representation polymorphism with coercion — is where the genuine research lives.
It is nontrivial but well-trodden in the ML/GHC literature. That is the work; it's the
good kind.

---

## 8. Canonical value-identity in the IR

One owned definition, rendered (not redefined) by each backend:

- **Equality** is Clojure `=`: scalars by value; collections structurally and
  recursively; representation-independent.
- **Hash** is a structural content hash **consistent with `=`** (`a = b ⇒ hash a =
  hash b`), replacing `core.js:204`'s order-/NaN-/`undefined`-fragile `JSON.stringify`.
- **Backends may substitute cheap native ops only where types guarantee equivalence**
  to this definition — e.g. `===` for `Int`/`Bool`/keyword, native `Set` for scalar
  element types. The canonical definition is the source of truth; native ops are
  proven-equivalent shortcuts.

This is value-resolution *owned by the language*, exactly as name-resolution is.

---

## 9. The cross-target conformance harness (the falsifier)

The single artifact that makes the whole assertion testable.

- **Shape.** A corpus of small Beagle programs, each computing values / exercising `=`,
  `hash`, set-membership, and map-by-value-key. Compile each to **all five targets**,
  run, and assert results agree against a reference oracle (the Clojure target is the
  natural oracle, since Clojure `=`/hash are the definition).
- **Today it fails** on JS (`(= {:a 1} {:a 1})` ⇒ `false`). The deliverable is: **it
  passes by construction on every target**, with any per-target divergence surfaced as
  a failing test rather than a silent runtime difference.
- That one green suite **is** the owned-value-resolution demonstration: target-invariant
  value semantics, measured and falsifiable. It also converts "JS `=` is broken" from a
  one-off patch into "every backend conforms to one owned semantics."

---

## 10. The bundle-vs-Cherry experiment

- **Configs.** (A) semantics-guaranteed (this design); (B) Squint-style native-only;
  plus **Cherry as external baseline**.
- **Metrics, on a representative `.bjs` corpus.** (i) conformance pass-rate (§9);
  (ii) shipped persistent-runtime bytes after tree-shaking.
- **Eddy as the headline corpus.** Compile a representative Eddy-generated app
  (`.eddy → Beagle/JS`) under config A and measure its persistent residual. Hypothesis:
  **~zero** — and already *evidence-consistent*: `crm-v2`'s generated code is
  eid-relational, emitting zero compound `=` / compound keys ([§5](#5-the-load-bearing-case-eddy-the-downstream-consumer)),
  so the §7b analysis proves every value native-safe. Eddy is the *existence proof* that
  faithful semantics cost nothing at Eddy's scale. A non-zero residual would localize
  exactly which Eddy feature first forces persistence.
- **Hypotheses.** A passes 100% conformance where B fails on compound values; A's
  persistent residual **≪** Cherry's ~56 KB-gz floor, because types erased it at most
  sites.
- **Honest-null branch.** If A's residual ≈ Cherry's floor, the native-safety analysis
  is too weak (too many values forced persistent) — which *names the exact research
  problem* (strengthen §7b/§7c). Either outcome is a result; record it in
  `experiments/`.

---

## 11. Why this is thesis-driven, not demand-gated

Beagle's Phase-0 telemetry gate applies to **demand-driven** features (value depends on
a corpus exercising them). Faithful, target-invariant value-semantics is **thesis-
driven** — a founding demonstration that types + owned resolution beat both untyped
extremes. Gating it on a corpus is the self-fulfilling deadlock the gate's own scope
clause excludes: *the corpus cannot exercise what isn't built.* Build it because it is
foundational, not because a `.bjs` file asked. (Eddy [§5](#5-the-load-bearing-case-eddy-the-downstream-consumer)
makes this concrete: the consumer that needs it most can't ship the thing that would
let it ask.)

(The §7b *perf* promotion is the one genuinely demand-driven sub-part — gate that on
profiling. The *correctness* invariant and harness are not gated.)

---

## 12. Thesis framing: owned resolution, second axis

Owned resolution has so far been about **names** — Beagle owns what a reference points
to; the target can't (see fram `docs/ADDRESSING_THESIS.md`). This is the **second
axis: Beagle owns what a value *is and means*, identically across Clojure, CLJS, JS,
Nix, Odin — the target can't.** Same founding assertion ("graph-as-truth requires owned
resolution requires a language"), applied to value semantics instead of identity — and
unlike name-resolution, this one is *immediately demonstrable* via §9.

**The stacked move (why Eddy and this are one thesis, not two).** Eddy compiles away the
*framework runtime* — it resolves reactivity at compile time and emits direct mutation.
This work compiles away the *value-semantics runtime* — it resolves representation at
compile time and emits native where provable. Same move, different layer, **stacked**:
Eddy on top of Beagle. React resolves "what changed" at runtime; Eddy resolves it at
compile time. Cherry resolves "what do these values mean" at runtime; Beagle resolves it
at compile time. One assertion — *resolve at compile time what others resolve at runtime,
emit minimal code you own* — demonstrated at two layers, with Eddy as the proof it
composes.

**Discipline (so the dissertation doesn't eat the talk):** the *talk-sized* assertion is
"owned value-resolution: identical semantics across five targets, proven by one
differential suite." The *research-program-sized* assertion is the full
representation-selection-beats-Cherry result. Lead with the former; the latter is the
field behind it.

---

## 13. Phasing (foundation-first)

1. **P1 — Invariant + falsifier.** Canonical IR value-identity ([§8](#8-canonical-value-identity-in-the-ir))
   + cross-target conformance harness ([§9](#9-the-cross-target-conformance-harness-the-falsifier)).
   Establishes the owned definition and measures current divergence across all five
   targets. *This is what to build first — not the JS-only patch.*
2. **P2 — JS conformance.** Type-directed `equiv` + structural `hash` in `core.js`,
   wired to `=`/`not=`/`contains?`/`distinct`/set-membership (scalar args → native ops;
   compound → `equiv`). Closes the correctness gap everywhere **except** compound keys.
   Harness goes green on JS except compound-key tests. **Pays Eddy immediately**
   ([§5](#5-the-load-bearing-case-eddy-the-downstream-consumer)) with no new Eddy work.
3. **P3 — Representation selection + own persistent layer.** The §7b correctness
   analysis + a tree-shakeable HAMT (Beagle-owned; `hamt_plus`/Immutable.js as
   *reference*, not dependency) for the compound-key residual. Compound-key tests go
   green. Run the §10 experiment (Eddy as headline corpus).
4. **P4 — Research.** Coherence/coercion across flow boundaries ([§7c](#7c-the-coherence--coercion-discipline-the-hard-part));
   perf-driven promotion for hot-loop mutation; generalize and strengthen the analysis.

---

## 14. Open questions / risks

- **Interop lift cost.** FFI objects used as keys must be lifted to persistent — how
  often, how expensive?
- **Analysis strength.** How large a fraction of values can be *proven* native-safe?
  Directly determines the bundle win (the §10 null branch).
- **Eddy `=`-payoff is latent, not live (RESOLVED 2026-06-21).** `crm-v2` generated
  code is eid-relational — all equality scalar, integer-keyed `Map`, unconditional
  `notify`. So P2 is an *enabler* for Eddy's change-gating / value-keyed-cache tier (and
  the eddy-on-claims convergence), not a bugfix
  ([§5](#5-the-load-bearing-case-eddy-the-downstream-consumer)). Open: does the *next*
  reactivity tier want to gate on value — i.e. is the enabler demand-real soon?
- **Other backends' current conformance.** Do Nix (attrset `==`) and Odin (struct/array
  `==`) already conform, or need work? The harness will tell.
- **No author-facing knob.** Representation stays a compiler decision from types — never
  a runtime flag (spec: no escape hatches, no two-semantics-under-one-extension).

---

## 15. References

- Squint: <https://github.com/squint-cljs/squint> ·
  borkdude, "Porting a ClojureScript project to Squint":
  <https://blog.michielborkent.nl/porting-cljs-project-to-squint.html>
- Cherry: <https://github.com/squint-cljs/cherry> ·
  "ClojureScript Reimagined" (DCD 2022):
  <https://speakerdeck.com/borkdude/clojurescript-reimagined-dutch-clojure-days-2022>
- Immutable.js maintenance history (#1689):
  <https://github.com/immutable-js/immutable-js/issues/1689>
- Mori: <https://github.com/swannodette/mori>
- TC39 Records & Tuples withdrawal (#394):
  <https://github.com/tc39/proposal-record-tuple/issues/394> ·
  Igalia April-2025 plenary:
  <https://blogs.igalia.com/compilers/2025/05/20/summary-of-the-april-2025-tc39-plenary/>
- TC39 Composites: <https://github.com/tc39/proposal-composites> ·
  Nov-2025 notes: <https://github.com/tc39/notes/blob/main/meetings/2025-11/november-19.md>
- Internal anchors: `beagle-lib/private/emit-js.rkt` (`:1267` infix `=`, `:296-418`
  runtime calls, `:639` import), `beagle-lib/private/js-capabilities.rkt`
  (`JS-INFIX-OPS`), `beagle-lib/lib/beagle/core.js` (`:204` `hash`).
- Eddy: `/home/tom/code/eddy/README.md`, `/home/tom/code/eddy/claude.md`
  (`.eddy → Beagle/JS → direct-DOM JS`; zero-runtime thesis).
- Thesis: fram `docs/ADDRESSING_THESIS.md` (owned resolution, first axis).
