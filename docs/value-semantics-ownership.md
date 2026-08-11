# Value-Semantics Ownership & Type-Driven Representation Selection

**Status:** JS P1–P3 implemented; implementation record and remaining research.
2026-06-21, refreshed 2026-08-11.
**Scope:** Primarily the JS backend. The invariant spans every language target; the
current differential harness covers the Clojure oracle and JavaScript. Query current
targets with `bin/beagle langs` rather than copying a count that goes stale.
**Load-bearing consumer:** Wake (`.wake → Beagle/JS`) — see [§5](#5-the-load-bearing-case-wake-the-downstream-consumer).
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

**Why this is load-bearing, not academic:** Wake's compiler is Beagle/JS and turns
`.wake` declarations into direct-DOM JavaScript and FRAM plans. Wake deliberately is
not a browser framework, so an always-on persistent runtime would tax a live downstream
compiler and its generated applications. Type erasure is how Beagle keeps faithful
semantics without imposing that tax ([§5](#5-the-load-bearing-case-wake-the-downstream-consumer)).

This is **thesis-driven, not demand-driven** — so it is *not* gated on a corpus
([§11](#11-why-this-is-thesis-driven-not-demand-gated)).

---

## 1. Current state (verified)

Facts from the tree as of this writing (anchors, not prose-to-be-trusted):

- **`=` is structural value equality.** `emit-js.rkt` routes compound or uncertain
  operands through `core.js` `equiv`; only pairs proven scalar use native `===`.
  `identical?` deliberately remains reference identity.
- **Immutability (no mutation) is already done** by copy-on-write: `conj → [...a, x]`,
  `assoc → ({...o, k:v})`, `update → {...m,[k]:f(m[k])}`, `dissoc`/`merge` likewise
  (`emit-js.rkt`).
- **The owned runtime is split by need.** `beagle-lib/lib/beagle/core.js` supplies
  structural `equiv`/`hash` and representation-polymorphic reads. Native-only programs
  import the lite helpers; HAMT-aware variants are selected only when required.
- **Compound keys and value sets use persistent structures.** The emitter keeps
  provably scalar-keyed maps and sets native, and routes compound or uncertain key
  positions through `beagle-lib/lib/beagle/hamt.js`.
- **The differential and representation-soundness gates are active.** Clojure is the
  oracle for JavaScript value behavior, while an independent structural oracle checks
  that native sites are not falsely promoted and compound-key sites are not missed.

**Implication:** value identity is owned by Beagle's JS backend today. Remaining work
is stronger analysis, additional target coverage, and measuring the downstream bundle
residual rather than repairing a missing semantic foundation.

---

## 2. The two problems (do not conflate them)

| | **A. Value equality** | **B. Structural sharing + compound keys** |
|---|---|---|
| Original symptom | `(= {:a 1} {:a 1})` was false; sets/dedup of equal maps were wrong | Native objects cannot use compound values as keys; copy-on-write is O(n) |
| Bites | Any comparison of compound values | Compound-key use immediately; hot-loop mutation at scale |
| Current JS status | Structural `equiv`/`hash`, native representation retained | HAMT for correctness-required sites; perf promotion remains research |
| Needs persistent structures? | **No** | Only the compound-key/value-set slice does (see §7b) |

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

## 5. The load-bearing case: Wake (the downstream consumer)

This is the strongest external motivation, and it converts the persistent-layer
approach from "nice" to **load-bearing**.

**Wake is downstream of this exact decision.** Wake's compiler modules are `.bjs` and
compile `.wake` declarations into one checked application graph, then project that
graph as direct-DOM JavaScript and a FRAM plan. The compiler therefore executes with
Beagle's structural `equiv`/`hash` semantics and type-selected native or persistent
representations. Generated applications are emitted artifacts rather than Beagle
programs themselves; that distinction belongs in every measurement.

**Wake's direct-DOM constraint is incompatible with always-on persistence.** Wake is
deliberately not a browser framework. Its applications use ordinary JavaScript and DOM
nodes, and custom panes receive the narrow `window.wake` integration seam. The Cherry
approach to correct value semantics — shipping a persistent runtime unconditionally —
would add a framework-sized floor to a compiler whose purpose is to project only the
application graph it checked. Therefore:

> **Type-driven representation selection ([§7](#7-type-driven-representation-selection))
> is the correctness fix compatible with Wake's architecture.** Native where provable;
> persistent only where a compiler module genuinely needs it. The generated app must
> not inherit a Beagle runtime merely because its generator is written in Beagle.

**Wake is a strong corpus for the bundle win.** Its compiler graph is composed mostly
of records, vectors, and string/keyword-keyed metadata maps. The generated local store
uses scalar integer `eid` keys; the FRAM connector keeps an ephemeral browser cache
while durable identity and storage semantics stay behind the Wake gateway. Those are
the values the [§7b](#7b-what-the-analysis-computes) analysis should prove
**native-safe**. A compound-key site should pay for persistence locally, not set the
bundle floor for every compiler module or generated app.

**There are two falsifiers, not one.** Compile the current Wake compiler under the
representation analysis and measure its persistent residual. Then compile a canonical
`.wake` application and verify that its emitted JavaScript gains no implicit Beagle
runtime. The first checks Beagle's downstream bundle; the second protects Wake's output
contract. Neither result should be inferred from the other.

**The FRAM boundary remains separate.** Wake emits application schema and a closed
gateway surface; FRAM owns recursive terms, occurrences, history, Datalog, and durable
storage. Value-representation selection in Beagle must not turn Wake into a storage
engine or move FRAM semantics into generated JavaScript.

**Strategic consequence — the JS surface stays owned.** `.bjs` plus faithful value
semantics gives Wake Clojure value behavior, native-JS bundle size, and Beagle-owned
diagnostics. Wake's live compiler corpus is the forcing function that makes that
consolidation measurable.

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
  `hash`, set-membership, and map-by-value-key. Compile each runnable target and assert
  results agree against the Clojure oracle. The current harness covers Clojure and
  JavaScript; `bin/beagle langs` reports the targets still needing runners.
- **Today it passes on JavaScript.** Compound equality, hashing, deduplication, set
  membership, immutability, and compound-key maps are asserted green. A target joins
  the claim only when its runner is wired into this differential suite.
- That one green suite **is** the owned-value-resolution demonstration: target-invariant
  value semantics, measured and falsifiable. It also converts "JS `=` is broken" from a
  one-off patch into "every backend conforms to one owned semantics."

---

## 10. The bundle-vs-Cherry experiment

- **Configs.** (A) semantics-guaranteed (this design); (B) Squint-style native-only;
  plus **Cherry as external baseline**.
- **Metrics, on a representative `.bjs` corpus.** (i) conformance pass-rate (§9);
  (ii) shipped persistent-runtime bytes after tree-shaking.
- **Wake as the headline corpus.** Compile the registered Wake `.bjs` compiler modules
  under config A and measure their persistent residual. Hypothesis: **near zero** for
  the current scalar-keyed graph and emitter code; a non-zero residual localizes the
  first compiler value that genuinely needs persistence. Separately compile
  `wiki.wake`, `crm-v2.wake`, `todo.wake`, and `tracker.wake`, then verify their emitted
  application JavaScript. That second check protects Wake's own generated `equiv`/`hash`
  runtime and must not be counted as Beagle-emitted runtime
  ([§5](#5-the-load-bearing-case-wake-the-downstream-consumer)).
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
foundational, not because a `.bjs` file asked. Wake
([§5](#5-the-load-bearing-case-wake-the-downstream-consumer)) makes this concrete: a
registered compiler corpus already exercises the JS target, while the invariant must
hold beyond whatever shapes that corpus happens to contain today.

(The §7b *perf* promotion is the one genuinely demand-driven sub-part — gate that on
profiling. The *correctness* invariant and harness are not gated.)

---

## 12. Thesis framing: owned resolution, second axis

Owned resolution has so far been about **names** — Beagle owns what a reference points
to; the target can't (see fram `docs/ADDRESSING_THESIS.md`). This is the **second
axis: Beagle owns what a value *is and means*, identically across Clojure, JavaScript,
and Nix — the target can't.** Same founding assertion ("graph-as-truth requires owned
resolution requires a language"), applied to value semantics instead of identity — and
unlike name-resolution, this one is *immediately demonstrable* via §9.

**The stacked move (why Wake and this are one thesis, not two).** Wake resolves an
application's schema, UI projection, and closed data boundary at compile time, then
emits direct-DOM JavaScript and a FRAM plan. This work resolves value representation
while Beagle compiles Wake's `.bjs` compiler. Same move, different layer, **stacked**:
Wake on top of Beagle. The artifact boundary remains explicit: Beagle selects the
compiler's representation; Wake owns the separate value runtime it writes into an
application. One assertion — *resolve at compile time what others resolve at runtime,
emit minimal code you own* — demonstrated at both layers without conflating them.

**Discipline (so the dissertation doesn't eat the talk):** the *talk-sized* assertion is
"owned value-resolution: identical semantics across every target, proven by one
differential suite." The *research-program-sized* assertion is the full
representation-selection-beats-Cherry result. Lead with the former; the latter is the
field behind it.

---

## 13. Implementation sequence (foundation-first)

1. **P1 — Invariant + falsifier (shipped).** Canonical IR value-identity ([§8](#8-canonical-value-identity-in-the-ir))
   + cross-target conformance harness ([§9](#9-the-cross-target-conformance-harness-the-falsifier)).
   Establishes the owned definition and measures Clojure/JavaScript divergence. Other
   targets join the claim when their runners land.
2. **P2 — JS conformance (shipped).** Type-directed `equiv` + structural `hash` in `core.js`,
   wired to `=`/`not=`/`contains?`/`distinct`/set-membership (scalar args → native ops;
   compound → `equiv`). This closed the native-value correctness gap and directly
   corrected Wake's compiler execution semantics
   ([§5](#5-the-load-bearing-case-wake-the-downstream-consumer)); it does not silently
   replace Wake's generated-code runtime.
3. **P3 — Representation selection + own persistent layer (shipped).** The §7b correctness
   analysis + a tree-shakeable HAMT (Beagle-owned; `hamt_plus`/Immutable.js as
   *reference*, not dependency) for the compound-key residual. Compound-key tests are
   green. The §10 Wake bundle experiment remains to be run.
4. **P4 — Research (remaining).** Coherence/coercion across flow boundaries ([§7c](#7c-the-coherence--coercion-discipline-the-hard-part));
   perf-driven promotion for hot-loop mutation; generalize and strengthen the analysis.

---

## 14. Open questions / risks

- **Interop lift cost.** FFI objects used as keys must be lifted to persistent — how
  often, how expensive?
- **Analysis strength.** How large a fraction of values can be *proven* native-safe?
  Directly determines the bundle win (the §10 null branch).
- **Wake has a separate generated-code value runtime.** The current generator emits
  its own `equiv`/`hash` helpers and uses `equiv` for local and FRAM browser-store change
  gates. Beagle P2 corrects the `.bjs` compiler, not those emitted helpers. Differentially
  test the two definitions or establish an explicit shared emission boundary; do not
  assume they remain aligned
  ([§5](#5-the-load-bearing-case-wake-the-downstream-consumer)).
- **Other backends' current conformance.** Does Nix attrset `==` already
  conform, or need work? The harness will tell.
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
- Wake: `wake:README.md`, `wake:claude.md`, `wake:web/compiler/codegen.bjs`, and
  `wake:web/demo/wiki.wake` (`.wake → checked graph → direct-DOM JS | FRAM plan`).
- Thesis: fram `docs/ADDRESSING_THESIS.md` (owned resolution, first axis).
