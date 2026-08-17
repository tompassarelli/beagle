# Value-Semantics Ownership & Type-Driven Representation Selection

**Status:** JavaScript implementation and research note.
**Scope:** Primarily the JS backend. Cross-target value semantics is a design
goal; the current differential harness covers the Clojure oracle and JavaScript.
Query current targets with `bin/beagle langs` rather than copying a count that
will drift.

---

## 0. TL;DR

Squint and Cherry prove the conventional choice is **small JS bundle XOR faithful
Clojure value-semantics** (working `=` on maps, value-keyed sets/maps). They must
choose globally because they are *untyped*.

Beagle's design uses types to select a native representation only where it can
prove the value never needs value identity. The intended result is faithful
value semantics without an always-on persistent runtime. Whether that reaches
another implementation's bundle size is a measurement, not a product claim.

A downstream compiler is a useful measurement case: its compiler and generated
applications should be measured separately so an implementation detail in the
compiler does not silently become a generated-application dependency.

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

## 3. Prior art that informs the strategy

**Squint vs Cherry — the same decision, made twice by the ClojureScript core team
(Michiel Borkent / borkdude).**

- **Squint** — native JS data structures (plain objects/arrays, keywords→strings,
  copy-on-write spread).
  [README](https://github.com/squint-cljs/squint) ·
  [porting blog](https://blog.michielborkent.nl/porting-cljs-project-to-squint.html)
- **Cherry** — vendored `cljs.core` persistent structures with a runtime that is
  not readily removed by ES-module tree shaking.
  [porting blog](https://blog.michielborkent.nl/porting-cljs-project-to-squint.html) ·
  [DCD 2022 slides](https://speakerdeck.com/borkdude/clojurescript-reimagined-dutch-clojure-days-2022)
**Library landscape:** existing persistent-data libraries illustrate the trade-off
between value semantics, bundle boundaries, and dependency ownership. Beagle keeps
the representation layer in-tree so the compiler owns the relevant contract.

TC39 Records & Tuples was withdrawn; it does not provide a platform-level
value-`===` solution
([#394](https://github.com/tc39/proposal-record-tuple/issues/394),
[Igalia summary](https://blogs.igalia.com/compilers/2025/05/20/summary-of-the-april-2025-tc39-plenary/)).
The successor Composites remains a proposal,
([notes](https://github.com/tc39/notes/blob/main/meetings/2025-11/november-19.md)).
so neither is an implementation dependency.

---

## 4. Research assertion

> The Squint-vs-Cherry tradeoff — small bundle **XOR** faithful Clojure semantics —
> constrains untyped implementations differently. Beagle can use type
> information to preserve value semantics while retaining native
> representations where they are proved equivalent. Bundle-size results remain
> empirical.

---

## 5. Downstream measurement case

A downstream compiler is a useful corpus for this work. Measure the compiler's
persistent-runtime residual separately from the JavaScript it generates; a
compiler implementation detail must not silently become a generated-application
dependency. The two measurements test different contracts and neither implies
the other.

---

## 6. Stance inversion

Faithful value identity — `=`, `hash`, sets/maps-keyed-by-value — is the
contract this design assigns to Beagle's typed IR. Each backend needs evidence
before it can claim conformance.

Native JS objects / copy-on-write spread / `===` stop being the default you patch and
become **an optimization the checker earns**: emit the cheap native representation
exactly where it can prove the value never reaches a value-identity position; emit the
faithful representation everywhere else. The design keeps semantics fixed and
makes representation cheaper only where it is proved safe.

The representation layer stays in-tree so the compiler owns its semantics and
bundle boundary.

---

## 7. Type-driven representation selection

This design draws on representation-selection techniques used by MLton, GHC,
and Rust (`repr`), applied to Clojure value semantics on a JavaScript host.

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

Representation polymorphism with coercion remains the main research area. It
is nontrivial but well-trodden in the ML/GHC literature.

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

## 9. The cross-target conformance harness

- **Shape.** A corpus of small Beagle programs, each computing values / exercising `=`,
  `hash`, set-membership, and map-by-value-key. Compile each runnable target and assert
  results agree against the Clojure oracle. The current harness covers Clojure and
  JavaScript; `bin/beagle langs` reports the targets still needing runners.
- **Current JS scope.** Compound equality, hashing, deduplication, set
  membership, immutability, and compound-key maps are covered. A target needs a
  runner in this suite before it can claim conformance.

---

## 10. Bundle measurement roadmap

- **Configs.** This design, a native-only comparison, and an external baseline.
- **Metrics, on a representative `.bjs` corpus.** (i) conformance pass-rate (§9);
  (ii) shipped persistent-runtime bytes after tree-shaking.
- **Corpus.** Measure a downstream compiler and its generated application
  separately, as described in §5.
- **Interpretation.** A substantial persistent residual identifies values the
  analysis cannot yet represent natively. The result should guide analysis work,
  not be inferred in advance.

---

## 11. Evidence discipline

The correctness contract needs conformance evidence; performance promotion
needs profiling evidence. A corpus can expose gaps, but does not replace either
kind of evidence.

---

## 12. Thesis framing

Value semantics belong to the language contract rather than an accidental host
representation. The current JavaScript evidence is narrower than cross-target
conformance and should be described that way.

---

## 13. Implementation status

The JavaScript backend has structural equality and hashing, representation-aware
helpers, and persistent handling for compound keys. Remaining work includes
coercion at flow boundaries, profile-guided promotion for hot mutation, broader
conformance coverage, and bundle measurement.

---

## 14. Open questions / risks

- **Interop lift cost.** FFI objects used as keys must be lifted to persistent — how
  often, how expensive?
- **Analysis strength.** How large a fraction of values can be *proven* native-safe?
  Directly determines the bundle win (the §10 null branch).
- **Generated-code runtime.** A downstream generator can have its own value
  helpers; test that contract separately from the compiler's runtime.
- **Other backends.** Their conformance is unknown until a runner exists.
- **No author-facing knob.** Representation remains a compiler decision from
  types rather than a runtime flag.

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
- Implementation: `beagle-lib/private/emit-js.rkt`,
  `beagle-lib/private/js-capabilities.rkt`, and `beagle-lib/lib/beagle/core.js`.
