---
name: code-as-facts
description: >-
  Use for CODE AS A FACT GRAPH, two faculties. (1) EDITING a Beagle source file
  whose UPSTREAM is the fact GRAPH — one listed in the graph-upstream registry
  or whose leading comment block carries `;; @upstream:graph`. Its text is a
  regenerable view of the Fram fact graph: author by GRAPH EDIT via the
  mcp__fram__* tools, never Edit/Write/MultiEdit (a PreToolUse guard refuses
  text edits). (2) ASKING relational questions about a Beagle tree —
  scope-correct "who calls THIS x", transitive blast radius, the real call
  graph — as Datalog over the projected AST instead of grep. NOT for editing
  ordinary text-upstream Beagle files, non-Beagle repos, or a single-file /
  plain-string lookup (grep wins there).
---

# Code as facts — the graph is both the editing surface and the query surface

"Facts" here is the view-level sense (fram:docs/ontology.md): the selected live
triples constitute the current program. The kernel stores recursive Triples and
assertion occurrences; nothing stored is a `Fact` type.

One substrate, two faculties: §0–§3 are the **write** side (authoring a
graph-upstream file), §4 is the **read** side (relational code-intelligence over
a Beagle tree). Either one may be why you are here.

Most Beagle files are text-canonical: you Edit/Write the text and the compiler
reads it. A **graph-upstream** file is the inverse (the move-3 flip): its source
of truth is the **Fram fact graph**, and the on-disk `.bclj` is a *regenerated
downstream view* — like a file that a formatter owns. Editing such a file as text
desyncs the graph from the bytes, so the deterministic **PreToolUse guard refuses
Edit/Write/MultiEdit** on it. This skill is the model half: for these files you
author by **graph edit**.

## 0. Is this file graph-upstream? (when this skill applies)

A file is graph-upstream iff EITHER:
- its absolute path is listed in `$GRAPH_UPSTREAM_REGISTRY`
  (default `~/.config/fram/graph-upstream-files`) — the authoritative marker, OR
- its **leading comment block** contains the sentinel `;; @upstream:graph`
  (the in-band, travels-with-the-file marker; it survives the lossless round-trip,
  landing just after the regenerated `(define-target clj)` header).

If neither holds, this skill does NOT apply — use the **beagle-authoring** skill
and ordinary Edit/Write. Adoption is explicit and per-file for both new and
existing source; there is no blanket "all .bclj" rule. The honest line: code
*can* be graph-upstream — see `beagle:bin/test/code-as-facts/README.md`
"Capability vs adoption".

## 1. The graph-edit verbs (use these instead of Edit/Write)

The authoring engine is `fram:resolve.clj` (modes
`upsert-form` / `set-body` / `rename` / `delete`), exposed AI-facing over the fram
MCP server. Each is a genuine fact operation on the lossless AST projection,
**recompile-gated and fail-closed** — an edit that the engine refuses, or that
does not recompile, writes no tree.

| Intent | Tool | Notes |
|---|---|---|
| Add a new top-level def | `mcp__fram__add-def` | `upsert-form` with a new name; appends a wrapper `fN` edge |
| Replace a def by name | `mcp__fram__add-def` | `upsert-form` with an existing name; withdraws its live wrapper `fN` assertion, then asserts the replacement edge |
| Replace a defn's body | `mcp__fram__set-body` | withdraws the live body-slot `fN` assertion(s), then asserts the newly minted body at the first body slot |
| Rename a def | `mcp__fram__rename-def` | O(1), scope-correct via `refers_to`, shadow-safe |
| Insert a form after an anchor | `mcp__fram__insert-after` | ordered placement |
| Insert any valid top-level form before a named def | `mcp__fram__insert-before` | ordered wrapper edge; candidate compilation must pass |
| Delete a def | _(engine verb `delete` exists; MCP tool not yet exposed)_ | fail-closed on orphaned references |

The new form/body is **structured data you emit** (an EDN datum, the structured
edit spec — e.g. `(defn add-two [(x Int)] Int (base (+ x 2)))`), not a text
splice. It is minted into the same Fram store as `kind`/`v`/`fN` facts, and any
reference in it resolves via the same lexical walk — so it is scope-correct for
free (a later rename of a callee propagates into the code you just authored).

> If the guard denies and the `mcp__fram__*` verbs are somehow absent, surface
> the gap — never fall back to text Edit on a guarded file. (Server entry:
> `fram:bin/fram-mcp`.)

## 2. The loop (what each verb does under the hood)

```
.bclj  --emit-edn-->  lossless AST facts  --(resolve.clj <verb>)-->  edited facts
       <--render-- (byte-stable regenerated .bclj, recompile-gated) <--
```

The CLI form the MCP tools wrap (for grounding / manual runs):

```sh
# project the module to lossless AST-facts EDN
racket beagle:beagle-lib/private/facts-roundtrip.rkt --emit-edn <file.bclj> > a.edn
# apply the graph edit (writes the rendered projection to $RESOLVE_OUT)
bb -cp fram:out fram:resolve.clj set-body <name> <scope> <body.edn> a.edn
# regenerate byte-stable text + recompile-gate (committed only if it builds)
racket beagle:beagle-lib/private/facts-roundtrip.rkt --render "$RESOLVE_OUT/resolved-<file>.edn"
```

The CI gate that proves all of this is GREEN:
`beagle:bin/test/code-as-facts/authoring-verbs.sh`.

## 3. If you genuinely must edit text

Adoption is reversible and deliberate. To edit a graph-upstream file as text you
must first **de-adopt** it (remove its path from `$GRAPH_UPSTREAM_REGISTRY` and
drop the `;; @upstream:graph` sentinel). That is a workflow decision, not a
per-edit escape hatch — make it explicitly, then the guard allows text edits again.

## 4. Relational code queries — the blast-zone faculty

The same graph, read instead of written: project a Beagle tree's AST into Fram
and *derive* the answer with Datalog. Reach for it when the question is
**relational** — who calls *this* `red` when two modules each define one,
dependents, transitive blast radius, the call graph — and consult it BEFORE
proposing a change. Grep and one-hop `beagle callers` are scope-blind (they
merge the two `red`s; the graph knows lexical binding, text match doesn't) and
structurally cannot compute a transitive closure.

```
*.bclj/.bjs/.bnix ──beagle-facts──▶ [subj "pred" obj] ──fold──▶ Fram store ──Datalog──▶ callers / blast radius
   (AST, any #lang)                  EDN triples                (interned graph)      (transitive closure)
```

Current entry points:

```sh
# turn the stack on for a project dir — also writes <dir>/.fram/corpus.facts
fram:bin/fram-code-on <dir> --space-id <id>
# who-calls + transitive blast radius over that corpus (JSON: defns/edges/blast)
bb -cp fram:out fram:out/callgraph.clj <dir>/.fram/corpus.facts
# no corpus, straight off lossless AST EDN: the engine resolver's callgraph mode
bb -cp fram:out fram:out/resolve.clj callgraph <file.edn> …
```

In a graph session, use the named program reads on the sealed session MCP before
inventing Datalog:

1. `read_definition {name, file}` resolves the natural selector to one exact
   `semanticIdentity` and structural source anchor at a pinned logical version.
2. `find_references {semanticIdentity, direction}` returns direct resolved
   inbound/outbound call sites for that identity.
3. `trace_impact {semanticIdentity, direction, maxDepth}` follows the transitive
   blast path with a depth on every result.

Use `occurrence_history` for the definition and its resolved reference sites in
snapshot source order. It is not cross-version edit history. When the identities
are already known, `inspect_program` batches an ordered vector of these requests;
every child keeps its tag and outcome and runs against the same logical version.

This is a strict division of labor, not a claim that graphs replace source text:
use text search for literal strings, and read the rendered source for exact bodies,
comments, and local formatting. Use the named graph reads for identity, scope,
relationships, and transitive impact.

The public Fram MCP data edge (`fram:bin/fram-mcp`) remains exactly `tell` /
`retract` / `show` / `ask` / `validate`; `ask` is available for genuinely ad-hoc
typed recursive queries. Program inspection and graph authoring are session tools,
not additions to that closed public catalog.

Honest scope:

- **Beagle source only.** `beagle:bin/beagle-facts` reflects `.bclj`/`.bjs`/`.bnix`
  ASTs (ignoring each file's `#lang`). This is not a general multi-language indexer.
- **Two projections, two jobs.** The *query* projection (`beagle-facts`) is compact
  and good for leverage but lossy (drops types/params); the *truth* projection
  (`facts-roundtrip.rkt --emit-edn`, §2) round-trips the program losslessly and is
  what the edit verbs ride. Query projection for code-intelligence, truth
  projection for graph-native edits/rename.
- **`fram:codegraph/` is an opt-in analysis surface.** Prefer the entry points
  above unless its relational reports are required.
- Do not spin any of this up for "find the string `foo`" or a single-file read.

The bet, shared with North: a flat text-and-grep view rots and cannot compute
relational questions; the graph is always current and answers them for free.

The family: Beagle text edits → beagle-authoring · graph-upstream files and
relational code queries (edit channel + blast zone) → code-as-facts · building
apps on the engine → fram-modeling. Loop vocabulary:
`beagle:docs/authoring-loops.md`.
