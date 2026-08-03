---
name: beagle-authoring
description: >-
  Use WHENEVER writing, editing, or debugging Beagle source in ANY project —
  files with a beagle extension (any `.b*` — the live set is `beagle langs
  --view extensions`), files starting with `#lang beagle`, or
  anything under ~/code/beagle. Establishes the authoring loop is online and
  functionally working BEFORE coding; the compiler is the loop's oracle and
  the source of truth, never a static cheat sheet. NOT for relational queries
  over a Beagle tree — that's codegraph.
---

# Beagle authoring

Beagle is a typed authoring IR — **Clojure plus types**, compiled `parse →
check → emit` to <!-- beagle:langs names -->Clojure, JavaScript, Nix, Odin, Zig, and TypeScript<!-- /beagle:langs -->. The reason to author in Beagle
at all is the **authoring loop**: pointed, structured errors and machine-applicable
repairs fed back fast. If that loop is offline or silently degraded, you are
writing Beagle blind. So the loop comes first.

## 0. Handshake — run this BEFORE writing any Beagle

```
beagle doctor --deep
```

- **"Authoring loop: ok"** → proceed.
- **"Authoring loop: DEGRADED" (exit 1)** → the feedback you'd rely on is not
  trustworthy. Do **not** start coding on silent green. Fix it:
  - daemon down → `beagle doctor --revive`  (or `beagle daemon start --watch .`)
  - no per-edit hook in this project → `beagle init --hooks` to scaffold the
    portable PostToolUse syntax/type-check hook, then re-run the doctor.
  - re-run `beagle doctor --deep` until green.

`beagle doctor` is a **functional** check, not a liveness check: it round-trips
known-bad **and** known-good inputs through syntax / type-check / suggestion→patch,
so it catches a checker stuck "always-pass" or "always-fail" — exactly the silent
degradation a process-exists check misses.

## 0.5 Source channel — text by default

Use ordinary Edit/Write for new and existing Beagle source. Do not run
`fram-code-on`, require a flip level, or interrupt bounded work with an upstream
migration choice unless the human explicitly asks to adopt graph authoring.

Graph authoring remains an optional per-file channel. A file is graph-upstream
only when its path is explicitly registered in
`~/.config/fram/graph-upstream-files` or its leading comment block contains
`;; @upstream:graph`. For those deliberately adopted files, use the
**code-as-facts** skill
(`fram:integrations/north/skills/code-as-facts/SKILL.md`) and its graph-edit
verbs until the file is unadopted. Coordinator availability never blocks
ordinary text authoring elsewhere.

## 1. Heartbeat — keep it alive while coding

- The **PostToolUse hook** (installed by `beagle init --hooks`) is the only
  *harness-enforced* feedback — it fires on every Edit/Write. **Trust its
  output.** Fix syntax errors before type errors. Never hand-count parens —
  `beagle syntax` already counted them.
- If feedback ever goes **silent** mid-session, the loop degraded — re-run
  `beagle doctor --revive --quiet`.

> Reliability note: a skill (this file) and CLAUDE.md are *model-discretion* —
> they can be forgotten. The **hook** is the deterministic layer. The handshake
> above exists to bootstrap that deterministic layer when you start.

## 2. The compiler is the source of truth — never trust a static list

There is **no** static reference for the **form set, type list, or stdlib** —
the surface churns daily; any cheat sheet of it is stale within a day. To learn
the *current* surface, **query the compiler**:

| question | tool |
|---|---|
| does this file parse? where? | `beagle syntax FILE` (`--ledger`, `--repair --emit-patch`) |
| does this file type-check? | `beagle check --agent FILE` |
| signature of X? | `beagle sig X FILE...` |
| fields of record R? | `beagle fields R FILE...` |
| who calls X? | `beagle callers X FILE...` |
| what does FILE export? | `beagle provides FILE` |
| which targets exist, for what? | `beagle langs` (`--view domains`, `--json`) |
| change-impact of X? | `beagle impact X FILE...` |
| macro expansion? | `beagle expand FILE` |
| run tests | `beagle test` (active tier; per-suite env opts into gated suites) |
| compile | `beagle build FILE [OUT]` |
| is the authoring loop healthy? | `beagle doctor [--deep]` |
| auto-repair | `beagle repair --emit-patch` (also `beagle-trace`, `beagle-blame`, `beagle-cascade`, `beagle-specfix`) |

For forms/types/stdlib themselves, **read the source** — never restate it:
`parse.rkt` (forms), `types.rkt` (types), `stdlib-*.rkt` (externs),
`targets.rkt` (the canonical target table; `extensions.rkt` derives ext→target
from it). The authoritative living anchor is
**`beagle:CLAUDE.md`** — read it when you start Beagle work in a session;
if the surface looks different than you expect, `git log` it.

> To *query* a Beagle codebase relationally (scope-correct callers, transitive
> blast radius / leverage, the call graph) rather than write it, see the
> **codegraph** skill — it projects the source into recursive triples in Fram's
> store (Chartroom) and answers with Datalog over the live view, which beats
> grep/bare-symbol on exactly the relational questions text search can't compute.

## 3. Stable operating model (this does not churn)

- **Beagle is Clojure + types, nothing else.** Every divergence from Clojure
  must be load-bearing for the type system or a backend, or it gets removed.
- **Surface lock:** typed Clojure with inline postfix `NAME: TYPE` / `-> RET`
  annotations only — `(def x: T v)`, `(defn f [p: T] -> R body)`,
  `(defonce …)`, `(defrecord N [field: T])`. Interiors are inferred. Always
  write the canonical spelling; during the current dual-accept cut legacy `:-`
  still parses with a warning, and only a `:`-marked RETURN is hard-rejected
  (pointing at `-> RET`).
- **Boundary-vector layout:** zero/one logical parameter or typed field stays
  inline with its owner; 2+ put `[` on the following line exactly two columns
  past the owning form's opening parenthesis, then one aligned logical entry
  start per line, with exactly one space between `]` and any `-> RET`.
  Typed bindings, destructures, and `& rest` each count as one entry. This
  covers function/method/macro vectors and typed record/union/error fields, not
  data vectors or let-style value bindings.
- **Zero external users → hard removal.** When a form/keyword is wrong, REMOVE
  it (pointed error naming the replacement) — never deprecate or alias.
- **Prefix where meaning diverges from Clojure:** `nix/assert`, `nix/with`,
  `nix/with-cfg` (bare `assert`/`with`/`with-cfg` are rejected). Bare names are
  reserved for forms that behave as their Clojure namesake.
- **Apply-and-report.** The spec is generative: run a form through the three
  rules (Clojure+types / load-bearing divergence / idiomatic-per-target) and one
  answer falls out. Fix the code and report what was measured — don't surface
  option menus for questions the spec already settles.

<!-- beagle:langs extensions -->
| extension | target |
|---|---|
| `.bclj` | `clj` (`#lang beagle`) |
| `.bjs` | `js` (`#lang beagle/js`) |
| `.bnix` | `nix` (`#lang beagle/nix`) |
| `.bodin` | `odin` (`#lang beagle/odin`) |
| `.bzig` | `zig` (`#lang beagle/zig`) |
| `.bsc` | `scriptc` (`#lang beagle/scriptc`) |
| `.bgl` | target-neutral — declare with `#lang beagle/<target>` or `(define-target …)` |
| `.rkt` | legacy — no extension/header validation |
<!-- /beagle:langs -->

Which target to reach for:

<!-- beagle:langs domains -->
- **Clojure** (`clj`, `.bclj`) — JVM and babashka Clojure: application code, tooling, and beagle's own self-hosted compiler.
- **JavaScript** (`js`, `.bjs`) — Browser, Node, and Bun JavaScript: anything that ships to a JS runtime.
- **Nix** (`nix`, `.bnix`) — Nix expressions type-checked against the NixOS option schema: system and package configuration.
- **Odin** (`odin`, `.bodin`) — Native Odin for graphics and systems work against wgpu and SDL3.
- **Zig** (`zig`, `.bzig`) — Native Zig for standalone linked executables and low-level systems code.
- **TypeScript** (`scriptc`, `.bsc`) — A narrow TypeScript boundary over the JS lowering: typed exports for TypeScript consumers (experimental; primitive-typed defn only).
<!-- /beagle:langs -->

(Both tables are filled by `bin/beagle doc-fill` from
`beagle-lib/private/targets.rkt`, the canonical table `extensions.rkt` itself
derives from. Query it live with `beagle langs`.)

### Native systems strategy

The generated target inventory above records available materializers, not the
strategic destination for the Fram/Beagle native program. System-layer Fram
engine/store/coord primitives and Beagle machinery target the target-neutral
**Beagle Native Core** profile: target-independent typed/effect/region/layout/
control/capability/ABI semantics. Their authoritative lowered program is an
immutable **Native World**. Fram stays entirely Beagle; greenfield work stays
graph-upstream. Materializers are disposable projections: restricted C11 for
bootstrap/reference/sanitizers, QBE as the first direct-native and
anti-C-capture check, Wasm/WASI for capability sandboxing, and
LLVM/Cranelift/direct codegen only when measurement justifies them. Coverage
means 30/39 archived core modules lower into a validated Native World, never
"30 modules that print Zig."

The former system-layer **bzig** default is suspended; Zig is not a strategic
native destination. This is an institutional-fit policy, not a technical-defect
claim. Zig commits `0f5dcae`, `cf87612`, `2fcb72d`, and `9f37f7d` are frozen
as compatibility implementation, rollback, and differential oracle at the
closed 13-operation/12-oracle boundary; only narrowly justified
oracle-maintenance fixes may touch them. No Rust rewrite, handwritten-C domain
logic, or C3/Odin/Idris retarget. "Turtle" names only the turtles-all-the-way-down
architectural thesis, never a code identifier, row/log type, or compiler-phase
label. The amendment's provenance lives on North thread
`019fbd6c-7e2b-7e21-aa2a-57b581004f37`.

## 4. `Any` is opting OUT of the type system — don't reach for it (POLICY)

`Any` = unchecked; an `Any`-heavy `.bclj` gains nothing over `.clj`.

**Policy — whenever you write or edit Beagle:**
- **Express the real type first.** Define the record/shape — what a `Claim`, a
  `Tenant`, a `Request`, a node is. A typed `(defrecord …)` or a concrete
  `(Vec String)` / `(Map …)` / `[A -> B]` is the line where the checker catches a
  wrong value. `Any` is not that line.
- **`Any` is a justified exception, never a default.** If you write `: Any`, you
  must be able to say *why* this value is genuinely un-typeable here. "It was
  faster" / "the data's a bit dynamic" is not a why.
- **The smell test:** if your `.bclj` is `Any`-heavy, you've gained nothing over
  Clojure. Stop. Either write the real type, or leave the code in `.clj` honestly
  (don't ship `Any`-Beagle that masquerades as a typed core).
- **When Beagle genuinely can't express the shape without `Any`, that's a GAP-LIST
  finding** — write it down ("Beagle can't express X") so it feeds the language's
  growth, instead of silently absorbing it as `Any`. The gap list is a deliverable.

**The falsifiable probe:** replace the `Any` with a real type and run
`beagle check`. It compiles → safety gained. Beagle fights you → a real,
recordable gap. Either outcome beats shipping `Any`. ("Does interop compile?" is
the *wrong* probe — that passes trivially. "Can I even *say* this type, or am I
forced back to `Any`?" is the real one.)

---

The family: Beagle text edits → beagle-authoring · graph-upstream files
(graph edit channel) → code-as-facts · relational code queries
(blast zone / who-calls) → codegraph · building apps on the engine →
fram-modeling. Loop vocabulary: `beagle:docs/authoring-loops.md`.
