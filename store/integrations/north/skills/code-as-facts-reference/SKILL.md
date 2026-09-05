---
name: code-as-facts-reference
description: >-
  Full notes on graph-native authoring, lossless projection, named relational reads, and scope limits.
---

# Code as facts: full notes

## Two projections, two uses

“Facts” here means the selected live triples constituting a program view.
The kernel stores recursive Triples and assertion occurrences, not a separate
stored Fact type. A compact query projection can omit details useful only to
rendering; an editing projection cannot. Never feed a lossy analysis graph
back into source generation.

The `store:` paths below refer to the embedded `beagle:store/` source.
Repository-qualified paths in command sketches are locators: resolve them to
real checkout paths before execution. Read the Beagle pinned-Racket procedure
before any direct Racket command; do not select an ambient runtime.

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
"$RACKET" beagle:beagle-lib/private/facts-roundtrip.rkt --emit-edn file.bclj > a.edn
bb -cp store:out store:resolve.clj set-body name scope body.edn a.edn
"$RACKET" beagle:beagle-lib/private/facts-roundtrip.rkt --render "$RESOLVE_OUT/resolved-file.edn"
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


## Adoption and failure boundary

Availability of graph operations is capability, not per-file adoption.
Registry membership or a genuine leading marker selects graph-native editing.
A quoted marker in a body is not adoption. Removing adoption to evade a failing
channel changes source authority and requires an explicit decision.

If a verb is unavailable or candidate compilation fails, preserve the original
graph/source and report the missing boundary. A text splice or lossy projection
does not repair it. Relational answers should cite the pinned logical version
and resolved semantic identity, not merely a matching name.
