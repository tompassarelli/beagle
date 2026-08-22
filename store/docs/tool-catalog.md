# Public tool catalog

This document fixes the current source-head MCP data surface at exactly five public data verbs and separates it from native and sealed controls.

| Tool | Contract |
|---|---|
| `tell` | assert one Triple |
| `retract` | retract one exact Triple |
| `show` | return live Triples whose `t1` matches |
| `ask` | run one validated structured query |
| `validate` | report structural integrity |

The advertised list is closed. Missing arguments and unknown names fail. Dispatch accepts only the names above. Graph-authoring verbs belong to a separate sealed control service.

These are Store data capabilities, not a Model-planning or external-effect API.
They record and query assertions; they do not turn desired state into observed
state, execute a plan, or grant trust because content or hashes match.

## Value boundary

The kernel accepts recursive typed [Terms](glossary.md#semantic-kernel), but current MCP writes intentionally expose String `subject`, `predicate`, and `object`; show takes one subject String; ask's advertised constant schema covers Strings and numbers. This edge limitation is not a second kernel model.

Use the official Bun Store RPC client, native CLI, or tagged Cloudflare JSON API for recursive Triples, Keywords, Bools, or Instants. Undocumented permissive decoding is not a compatibility promise.

## Ask and other clients

`ask` accepts the JSON equivalent of the [structured query](query-reference.md), lowers it to a typed plan, and sends Store RPC. It is not a string query language.

The zero-dependency Bun client is the builder/application transport. It exposes
all thirteen Store RPC v2 (wire version 2.0) data operations, recursive Terms, atomic
batches, expected and served versions, snapshot-pinned paging, occurrence
replay, validation, and leases without copying or reinterpreting the codec.
The separately named native `rpc/checkpoint` operator is deliberately absent
from that application client surface.

`bin/beagle store` also offers scan, occurrences, version, status, and local migration/projection/admin commands. Those are native or local utilities, not additional MCP tools.

[`../tests/mcp_test.clj`](../tests/mcp_test.clj) gates this catalog; [`../tests/native_rpc_boundary_ratchet_test.clj`](../tests/native_rpc_boundary_ratchet_test.clj) separately gates Store RPC.
