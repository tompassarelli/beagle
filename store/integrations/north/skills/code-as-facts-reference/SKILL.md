---
name: code-as-facts-reference
description: >-
  Detailed graph-edit verbs, lossless projection commands, relational program
  reads, Datalog entry points, and scope limits for code-as-facts. Load when
  code-as-facts-distilled routes here or the user explicitly requests details.
---

# Code as facts reference

"Facts" uses the view-level sense from `store:docs/ontology.md`: selected live
triples constitute the program. The kernel stores recursive Triples and
assertion occurrences; it has no stored `Fact` type.

## Graph-edit verbs

The engine is `store:resolve.clj`; the Store MCP exposes these operations:

| Intent | Tool | Engine behavior |
|---|---|---|
| add or replace a top-level definition | `mcp__store__add-def` | `upsert-form`; appends or replaces its wrapper edge |
| replace a function body | `mcp__store__set-body` | replaces the live body-slot assertion |
| rename a definition | `mcp__store__rename-def` | scope-correct through `refers_to` |
| insert after an anchor | `mcp__store__insert-after` | ordered placement |
| insert before a named definition | `mcp__store__insert-before` | ordered wrapper edge with candidate compilation |
| delete a definition | engine `delete`; no MCP verb yet | refuses orphaned references |

An edit payload is an EDN datum such as
`(defn add-two [x Int] Int (base (+ x 2)))`, not a splice. The server entry is
`store:bin/beagle-store-mcp`; the executable authoring contract is
`beagle:bin/test/code-as-facts/authoring-verbs.sh`.

## Lossless round trip

```text
.bclj --emit-edn--> lossless AST facts --resolve.clj VERB--> edited facts
      <--render-- regenerated .bclj, gated by recompilation <--
```

Grounding commands:

```sh
racket beagle:beagle-lib/private/facts-roundtrip.rkt --emit-edn file.bclj > a.edn
bb -cp store:out store:resolve.clj set-body name scope body.edn a.edn
racket beagle:beagle-lib/private/facts-roundtrip.rkt --render "$RESOLVE_OUT/resolved-file.edn"
```

The in-band marker is regenerated immediately after the
`(define-target clj)` header. Adoption is explicit per file; see
`beagle:bin/test/code-as-facts/README.md`, "Capability vs adoption".

## Relational program reads

Prefer the sealed-session named reads:

1. `read_definition {name, file}` returns one `semanticIdentity` and source
   anchor at a pinned logical version.
2. `find_references {semanticIdentity, direction}` returns direct resolved
   inbound or outbound sites.
3. `trace_impact {semanticIdentity, direction, maxDepth}` returns transitive
   paths with depths.

Use `occurrence_history` for definitions and resolved sites in snapshot source
order. It is not cross-version edit history. `inspect_program` batches already
identified requests against one logical version and preserves each tag/outcome.

Corpus entry points:

```sh
store:bin/beagle-store-code-on DIR --space-id ID
bb -cp store:out store:out/callgraph.clj DIR/.store/corpus.facts
bb -cp store:out store:out/resolve.clj callgraph file.edn …
```

`beagle-facts` covers Beagle ASTs only. Its compact query projection drops
types and parameters; `facts-roundtrip.rkt --emit-edn` is the lossless truth
projection. `store:codegraph/` is opt-in and should be opened only for its
relational reports. The broader loop vocabulary is in
`beagle:docs/authoring-loops.md`.
