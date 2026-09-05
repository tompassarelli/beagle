---
name: code-as-facts-distilled
description: >-
  Edit explicitly graph-upstream Beagle files or answer relational code questions from projected ASTs. Use normal text tools for ordinary source and literal lookup.
---

# Code as facts

Choose graph-native editing or relational analysis; they use different
projections and do not imply each other.

## Editing

A file is graph-upstream when its absolute path is registered in
`$GRAPH_UPSTREAM_REGISTRY` (default `~/.config/store/graph-upstream-files`)
or its leading comment block carries `;; @upstream:graph`.

Use the session's graph-authoring `mcp__store__*` verbs, never text edits.
They modify lossless AST facts and commit after regeneration/recompilation.
If the channel is missing, stop that edit. De-adoption needs an explicit
decision removing both applicable markers; it is not a workaround.

## Analysis

Use named reads or Datalog for identity, resolved references, and transitive
impact. Use source tools for literals, bodies, comments, and layout.
The compact query projection is lossy and cannot authorize graph edits.

Keep the public Store data MCP catalog to `tell`, `retract`, `show`, `ask`,
and `validate`; program inspection/authoring are separate session tools.
For verbs, named reads, round trips, and limits, resolve
`agents path code-as-facts-reference`.
