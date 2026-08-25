---
name: code-as-facts-distilled
description: >-
  Use for CODE AS A FACT GRAPH, two faculties. (1) EDITING a Beagle source file
  whose UPSTREAM is the fact GRAPH — one listed in the graph-upstream registry
  or whose leading comment block carries `;; @upstream:graph`. Its text is a
  regenerable view of the Beagle Store fact graph: author by GRAPH EDIT via the
  mcp__store__* tools, never Edit/Write/MultiEdit (a PreToolUse guard refuses
  text edits). (2) ASKING relational questions about a Beagle tree —
  scope-correct "who calls THIS x", transitive blast radius, the real call
  graph — as Datalog over the projected AST instead of grep. NOT for editing
  ordinary text-upstream Beagle files, non-Beagle repos, or a single-file /
  plain-string lookup (grep wins there).
---

# Code as facts

First decide the faculty: graph-native editing or relational code analysis.

For editing, graph-upstream means its absolute path is in
`$GRAPH_UPSTREAM_REGISTRY` (default `~/.config/store/graph-upstream-files`) or
its leading comment block has `;; @upstream:graph`. Otherwise edit normally.

Never text-edit graph-upstream source. Use `mcp__store__*` verbs, which apply
structured EDN to lossless AST facts and commit only after regeneration and
recompilation. If unavailable, stop and report the missing channel. De-adoption
is an explicit decision removing both applicable markers, not an escape hatch.

For relational analysis, use projected ASTs and named reads or Datalog for
identity, references, and transitive impact. Use text/source for literals,
bodies, comments, and layout; skip the graph for a plain lookup.

Keep the public Store MCP data catalog closed to `tell`, `retract`, `show`,
`ask`, and `validate`; program inspection and graph authoring remain session
tools. Query projection is lossy analysis data; only the lossless round-trip
projection may carry graph-native edits.

For verb tables, projection commands, named read sequences, examples, limits,
and entry points, resolve and read `agents path code-as-facts-reference`.
