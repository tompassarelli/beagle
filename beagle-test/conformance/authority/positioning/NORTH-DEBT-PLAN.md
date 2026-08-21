# North debt plan — post-Beagle Store rename

Survey date: 2026-08-18. Scope is the tracked `north` main checkout at
`3d77d9de` ("Seal Store selector in MCP lifetime fixture"). This is a
static, read-only survey. The North daemon is down pending the new engine
release, so no command was run against its coordinator, persistence, or
installed wrapper. Every item that needs a live-data census or a wrapper/daemon
round trip is explicitly release-gated below.

## Bottom line

The old engine *selection names* are already gone: no tracked source matches
`NORTH_FRAM_SELECTION`, `NORTH_FRAMRPC_OUT`, `FRAM_HOME`, `FRAM_BIN`,
`FRAM_OUT`, `FRAM_LOG`, `FRAM_THREADS`, `FRAM_SPACE_ID`, `framrpc.env`,
`north-fram`, `fram-mcp`, `branch-core`, `fram-engine`, or
`framrpc-client`. Do not recreate a rename wave for those names.

This is not yet clean. There are 13 independently deliverable seams: one
high-risk Store-selection split, three command/dead-surface removals, two
historical-data compatibility readers, five routing/harness compatibility
surfaces, and two vocabulary/documentation cleanups. `FRAMRPC` and `FRAMLOG`
are retained protocol and storage-format names, not former-engine selectors;
they are excluded unless a line is using them to describe the old product.

## Sequence and release boundary

1. Land the static command, vocabulary, and documentation deletions first.
2. With the new engine release selected, prove one canonical Store selection
   through the installed CLI, MCP, session hooks, and a managed child before
   changing selection fallbacks.
3. Query the live coordination data for the historical shapes named below.
   Delete a reader only when its count is zero; migrate the exact remaining
   rows in the same worker seam if it is nonzero.
4. Run North's nearest affected checks after each seam. The usual SDK gate is
   `bun run check && bun run test` from `north:sdk`; the daemon-dependent
   checks wait for the new engine release.

## One-worker seams

| # | Finding and anchors | Remedy | Size / release condition |
|---|---|---|---|
| 1 | **Store selection is split across three authorities.** The packaged wrappers source one host file (`north:flake.nix:505`, `539`, `618`, `624`, `661`); the CLI requires only `BEAGLE_STORE_HOME` (`north:bin/north:141-146`); the SDK silently defaults to `~/.local/state/north/store-runtime/active/current` (`north:sdk/src/beagle-store.ts:4-29`), while session hooks default to `~/code/beagle/main/store` (`north:bin/north-on-spawn:10-17`, `north:bin/north-on-tooluse:10-17`). SDK children inherit that fallback at many launch sites, e.g. `north:sdk/src/worktree.ts:165-179`. This is the old env/selection seam in a new spelling. | Define one sealed Store-selection contract and one resolver. Make CLI, MCP, hooks, SDK children, and the package obtain the same home/bin/out from it; remove checkout defaults and independent `active/current` fallback. Missing selection must fail before work is launched. Add one matrix test covering explicit selection, installed selection, and absent selection. | **L, 1 worker, 1–2 days. Blocked on the new engine release** because acceptance must exercise the installed selector and live daemon. |
| 2 | **Retired Fram product vocabulary remains in live runtime comments and labels.** `north:bin/north:8`, `141`, `197`, `339`; `north:bin/north-runtime:29-30`; `north:bin/arena-seed:30`; `north:docs/operating-manual.md:174`; and the former-repository link in `north:README.md:13-15`. `fram_out` is especially misleading because it is populated from `BEAGLE_STORE_OUT`. | Rename local variables, comments, diagnostics, and product-facing prose to “Beagle Store.” Keep only FRAMRPC/FRAMLOG where they name the still-canonical protocol/log format. Update the product link only after confirming the engine release’s canonical public URL. | **S, 1 worker, 1–2 hours.** Static; link target confirmation is release-gated. |
| 3 | **Retired CLI aliases are still live.** `untell`, `board`, and `plate` are advertised by `north:cli/surface.edn:33-38`, routed in `north:bin/north:235`, `268`, `283`, `327-337`, `545-576`, and exposed through MCP at `north:bin/north-mcp:226`, `1081-1082`. `request`, `fork`, and `req` remain registered at `north:cli/surface.edn:128-130` and routed at `north:bin/north:453-456`. | Delete the aliases from the surface registry, Bash dispatch, MCP alias map, generated help, and alias-specific tests. Preserve only `retract`, `threads`, `delegate`/`spawn`, and their documented current forms. Do not leave renamed-command error stubs. | **M, 1 worker, 0.5 day.** Static. |
| 4 | **`north handoff` is a tombstone, not a command.** It is retained as `:legacy` (`north:cli/surface.edn:172-173`) and as an error-only route (`north:bin/north:407-410`). Generated help consequently advertises it. | Delete the registry entry, dispatch arm, generated help rows, and its tests. `north failover` remains the only recovery command. | **S, 1 worker, 1–2 hours.** Static. |
| 5 | **`north set` is an explicitly legacy, unsafe writer that the wrapper still forwards.** It is advertised at `north:cli/surface.edn:199-200` and `north:share/help/topic-store.txt:13`; the default engine passthrough accepts it at `north:bin/north:625-626`. | Remove it from the registry and make the wrapper reject `set` rather than passing it to `beagle store`. Delete the legacy help and tests. The supported coordinated write surface is `north tell`/`north retract`. | **S, 1 worker, 1–2 hours.** Static. |
| 6 | **The public `delivery attest` command is deliberately nonfunctional scaffolding.** It is shown as unavailable (`north:cli/surface.edn:131-133`) and always throws after validation (`north:sdk/src/delivery-attest.ts:21-29`), reached via `north:bin/north:419-422`. | Delete this public command, its generated help, module, and tests unless an isolated verifier is being delivered in the same change. Do not retain a permanently failing feature advertisement. | **S, 1 worker, 1–2 hours.** Static. |
| 7 | **Claude harness-state fallback is still a live compatibility reader.** `north:cli/harness-state.clj:30-51` reads `NORTH_LEGACY_HARNESS_STATE` / `~/.claude/my-config.state`; writes seed canonical state from it (`175-195`). A separate Bash fast path duplicates the fallback (`north:bin/north:92-121`, especially `97`). Documentation still declares it (`north:docs/harness-architecture.md:118-127`). | After a live census confirms no supported installation depends on the old file, delete the old env var and file fallback from Clojure and Bash, remove migration tests/docs, and use only `NORTH_HARNESS_STATE` / `~/.local/state/north/harness.conf`. | **M, 1 worker, 0.5 day. Release-gated**: census installed state before removal. |
| 8 | **Historical outcome-only lane/run readers remain.** `north:cli/terminal-projection.clj:1-7`, `557-593` accepts a terminal with only `outcome`; the mirrored SDK projection does the same at `north:sdk/src/terminal-projection.ts:148-195`. The writer also keeps the old `outcome == process_outcome` alias (`north:cli/agent-fact-internal.clj:25-36`, `420-421`). | Query for terminal/run subjects without `process_outcome`. If none exist, remove outcome-only parsing, legacy writer alias, affected predicates, and fixtures. If rows exist, migrate those exact rows to the manifest-backed terminal shape first, then remove both readers together. | **L, 1 worker, 1 day. Blocked on the new engine release** because the required corpus census and migration are daemon-backed. |
| 9 | **Legacy missing pin evidence is accepted by executable bootstraps.** `north:sdk/src/routing-economics.ts:382-405`, `472-482`; the spawn and dispatch CLIs grant the bypass at `north:sdk/src/spawn.ts:392-425`, `2076-2082` and `north:sdk/src/dispatch.ts:217`, `1382-1393`, `1536-1540`. This makes inherited pre-evidence selector envelopes a second routing contract. | Remove `allowLegacyMissingPinEvidence`, `legacy-missing`, and both bootstrap grants. Require typed pin evidence for every explicit provider/account/model selector. Update launch adapters and tests in the same patch. | **M, 1 worker, 0.5–1 day. Release-gated**: prove current engine-launched children always carry the receipt first. |
| 10 | **Routing metadata has parallel compatibility fields instead of one request.** Spawn admits `role`, `tier`, `effort`, and `posture` alongside `routingMetadata` (`north:sdk/src/spawn.ts:223-250`, `291-295`, `404-416`); harness accepts `role`, `posture`, and `effort` (`north:sdk/src/harness.ts:1870-1887`); `AGENT_EFFORT` aliases `AGENT_REASONING` (`north:sdk/src/routing-admission.ts:38-49`). | Make `routingMetadata` the sole managed request and `AGENT_REASONING` its sole environment representation. Remove equality-only fields, aliases, docs, fixtures, and call sites together. | **L, 1 worker, 1–2 days.** The public managed-envelope contract changes; validate all current launcher adapters before landing. |
| 11 | **The orchestration machine schema knowingly retains pre-rename “preset” vocabulary.** `north:orchestration/README.md:185-194` and `north:orchestration/doctrine.md:16-22` say so explicitly. The wire types/parser retain `kind: "preset"` and `nearestPreset` (`north:sdk/src/routing-metadata.ts:38-82`, `144-185`); MCP, CLI, generated contracts, and docs consume it (`north:bin/north-mcp:349`, `753-860`; `north:cli/agents-cli.clj:1112`, `1344-1451`). | Choose the canonical current composition vocabulary, migrate every generated contract and in-tree consumer in one atomic schema change, then delete `preset`/`nearestPreset` compatibility keys and wording. Do not keep dual JSON shapes. | **L, 1 worker, 1–2 days.** No daemon required for structural work; run the orchestration validator and SDK suite. |
| 12 | **Provider-routing compatibility projections duplicate canonical target data.** `north:sdk/src/providers/types.ts:143-165` retains provider pressures/weights and automated observations as compatibility projections; `north:sdk/src/resource-policy.ts:638-650` constructs them. `RoutingDecision` also publishes duplicate `requested`/`requestedProvider` and `reason`/`selectionReason` fields (`north:sdk/src/providers/types.ts:455-477`, `north:sdk/src/provider-routing.ts:1175-1181`). | Census all in-tree consumers; migrate them to target-scoped fields and canonical names, then delete the projections and duplicate response properties. Preserve a single target-level routing result. | **L, 1 worker, 1–2 days.** Static call-site migration; verify provider routing tests. |
| 13 | **Provider-specific authoring kill-switch vocabulary is still accepted.** `north:cli/harness-dial.clj:63-70` reads `CLAUDE_NO_AUTHORING_HOOKS` after the canonical `AGENT_NO_AUTHORING_HOOKS`; its comment records a prior mis-selection incident. | Remove the `CLAUDE_` alias once every projected hook and provider adapter exports the generic variable. Update the harness dial matrix and profile documentation together. | **S, 1 worker, 1–2 hours.** Static, but verify projected hook inputs after the engine/system release. |

## Deliberate non-findings

- `FRAMRPC` and `FRAMLOG` are still the actual Store protocol and log-format
  vocabulary. Renaming them as if they were former-engine selectors would
  create a new compatibility seam.
- Generated `out/`, `share/help/`, and `*.doc.edn` files are tracked current
  artifacts with declared generators. There is no static evidence that they
  are stale; regenerate only in a seam that changes their source.
- The unavailable delivery verifier is a real, bounded limitation, not an
  engine outage diagnosis. It is listed because exposing a command that can
  only fail is dead public surface.

## Verification record

Static searches covered former engine selector names, former runtime filenames,
explicit `legacy`/`compatibility` branches, CLI registry-to-dispatch paths, and
Store selector consumers. North main was clean before the survey. No daemon,
MCP, or coordinator command was invoked because the daemon is down pending the
new engine release.

NORTH-DEBT-DONE — 13 findings: 1 Store-selection split; 3 retired/dead CLI
surfaces; 2 historical-state readers; 5 routing/harness compatibility seams; 2
vocabulary/documentation seams. No old Fram selector variables or old runtime
filenames remain in tracked North source.
