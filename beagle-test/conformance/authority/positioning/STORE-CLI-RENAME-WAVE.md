# Beagle Store CLI rename wave

## Decision

The canonical human surface is **`beagle store <verb>`**. Do not create
`bstore`, do not retain `fram`, and do not install an alias or forwarding shim.
Automation-only entrypoints use the explicit `beagle-store-*` prefix.

This is one break-forward consumer wave. The Beagle producer commit may land
first because current consumers are pinned, but North, nixos-config,
Greywrought, and Gjoa are one cutover set: prepare and verify all of them before
re-pointing a live consumer.

The inventory was read at these main-checkout revisions:

- Beagle `424704d388021be9dd9e3e238c284ec0497876e6`.
- North `8f2483b0ed1753c8d56f9244f43bf807083699bc`.
- nixos-config `c41ea9c2cfb41bafa890dced3710abe4cbb6d4fe`.
- Greywrought `fb1f19e70104d872103ffc3ef775919b1a9bc3f6`.
- Gjoa `ee5cb2481b6d605f57569222494f7b01ceb1eecd`.

## Why `beagle store`, not `bstore`

`bin/beagle` is already the one authoritative command dispatcher and help
surface (`beagle:bin/beagle:26-83`, dispatch at `:89-215`). Its existing
commands are mostly direct verbs (`check`, `build`, `langs`, `doctor`), while
its help groups related capabilities by entity. The absorbed engine is the
first capability large enough to need its own entity node. `store` gives it a
stable noun and keeps its verbs together without polluting the root command
set:

```text
beagle store tell SUBJECT SLOT VALUE
beagle store retract SUBJECT SLOT VALUE
beagle store show SUBJECT
beagle store query EDN
beagle store scan T1|_ T2|_ T3|_
beagle store occurrences
beagle store version|status|validate
beagle store doctor --deep
beagle store backup create|verify ...
beagle store code on|off|status ...
beagle store up [--restart]          # checkout/development only
beagle store serve ...               # direct foreground operation
```

The dispatcher should own help, argument routing, and the public exit-status
contract. The current split between `branch-core/bin/fram` and
`branch-core/bin/fram-fast.clj` is visible at `beagle:branch-core/bin/fram:6-74`
and `beagle:branch-core/bin/fram-fast.clj:198-255`; fold it behind the `store`
node rather than preserving a second top-level CLI.

`bstore` is rejected because it creates a second brand, a second help root, an
unexplained abbreviation, and another executable every consumer must locate.
It also contradicts the repository's existing rule that specialist developer
tools use descriptive `bin/beagle-*` names (`beagle:bin/beagle:81-82`). Stable
executables remain appropriate for non-human process boundaries, so systemd
may execute `beagle-store-server` and MCP clients may execute
`beagle-store-mcp`; those are not alternative user CLIs.

## Exact new names

### Public, packaged, and helper executables

| Current | Replacement | Public role |
|---|---|---|
| `fram` | no file; `beagle store ...` | only human CLI |
| `fram-backup` | `beagle-store-backup` | packaged operator helper; also `beagle store backup` |
| `fram-server` | `beagle-store-server` | foreground service launcher; also `beagle store serve` |
| `fram-server-native` | `beagle-store-server-native` | sealed native artifact |
| `fram-mcp` | `beagle-store-mcp` | generic store MCP server |
| `fram-up` | `beagle-store-up` | checkout supervisor; also `beagle store up` |
| `fram-selfcheck` | `beagle-store-doctor` | deep store doctor |
| `fram-selfcheck-probe.clj` | `beagle-store-doctor-probe.clj` | private doctor probe |
| `fram-fast.clj` | `beagle-store-cli.clj` | private CLI implementation |
| `fram-native-build` | `beagle-store-native-build` | native artifact builder |
| `fram-cloudflare-native-image` | `beagle-store-cloudflare-native-image` | Cloudflare native image builder |
| `fram-code-on` | `beagle-store-code-on` | deep graph-authoring helper; routed as `store code on` |
| `fram-code-off` | `beagle-store-code-off` | deep graph-authoring helper; routed as `store code off` |
| `fram-code-status` | `beagle-store-code-status` | deep graph-authoring helper; routed as `store code status` |
| `fram-code-wire` | `beagle-store-code-wire` | private wiring helper |
| `fram-code-wire-toml.py` | `beagle-store-code-wire-toml.py` | private TOML helper |
| `fram-coherence-doctor` | `beagle-store-coherence-doctor` | deep developer check |
| `fram-defcheck` | `beagle-store-defcheck` | deep developer check |
| `fram-defcheck-server.rkt` | `beagle-store-defcheck-server.rkt` | private warm checker |
| `fram-edit-verifier` | `beagle-store-edit-verifier` | private verifier adapter |
| `fram-graph-edit-runtime` | `beagle-store-graph-edit-runtime` | sealed graph-edit runtime |
| `fram-graph-ops-report` | `beagle-store-graph-ops-report` | graph operations report |
| `fram-ingest-code` | `beagle-store-ingest-code` | graph-authoring ingest helper |
| `fram-promote` | `beagle-store-promote` | store release promoter |
| `fram-render-code-native` | `beagle-store-render-code-native` | native renderer helper |
| `_fram-resolver` | `_beagle-store-resolver` | private resolver helper |

The current filename authorities are
`beagle:branch-core/bin/fram:1`, `fram-backup:1`,
`fram-cloudflare-native-image:1`, `fram-code-off:1`, `fram-code-on:1`,
`fram-code-status:1`, `fram-code-wire:1`, `fram-code-wire-toml.py:1`,
`fram-coherence-doctor:1`, `fram-defcheck:1`,
`fram-defcheck-server.rkt:1`, `fram-edit-verifier:1`, `fram-fast.clj:1`,
`fram-graph-edit-runtime:1`, `fram-graph-ops-report:1`,
`fram-ingest-code:1`, `fram-mcp:1`, `fram-native-build:1`,
`fram-promote:1`, `fram-render-code-native:1`, `fram-selfcheck:1`,
`fram-selfcheck-probe.clj:1`, `fram-server:1`, and `fram-up:1`; the two
outside `branch-core/bin` are `beagle:native-core/bin/fram-native-demo:1` and
`beagle:bin/_fram-resolver:1`.

The nested flake becomes a Beagle Store package, not a residual Fram package:

- `pname = "beagle-store"`; libexec/share roots become `libexec/beagle/store`
  and `share/beagle/store` (`beagle:branch-core/flake.nix:102`, `:142-162`,
  `:395-411`).
- Root Beagle exports `packages.<system>.store` and makes it available alongside
  the compiler package. The nested flake's current `packages.fram`,
  `fram-graph-edit-runtime`, and `apps.fram*` authorities are
  `beagle:branch-core/flake.nix:561-590` and `:596-620`.
- Nix apps become `store`, `store-server`, `store-mcp`, and
  `store-graph-edit-runtime`; `default` remains the Beagle compiler at the root,
  not the store.
- Release archives and READY receipts become `beagle-store-*`; old immutable
  Fram releases remain untouched for rollback.

### MCP and units

| Current | Replacement |
|---|---|
| MCP key `fram` | MCP key `beagle-store` |
| command `fram-mcp` | `beagle-store-mcp` |
| `north-fram.service` | `north-store.service` |
| `north-fram-launch` | `north-store-launch` |
| `north-fram-publish-runtime` | `north-store-publish-runtime` |
| `north-fram.runtime` | `north-store.runtime` |
| `north-framrpc-runtime/v1` | `north-store-runtime/v1` |
| `north-fram-release/v1` | `north-store-release/v1` |
| `greywrought-fram.service` | `greywrought-store.service` |
| `greywrought-fram-health.service` | `greywrought-store-health.service` |
| `greywrought-fram-health.timer` | `greywrought-store-health.timer` |
| `greywrought-fram-health` | `greywrought-store-health` |

Use `beagle-store` rather than bare `store` for MCP because MCP server names
share a global client namespace. Use `north-store` and `greywrought-store` for
units because the owner already supplies the missing context.

### Runtime configuration names

Rename the complete component environment family, without reading old names:

```text
FRAM_HOME                    -> BEAGLE_STORE_HOME
FRAM_BIN                     -> BEAGLE_STORE_BIN
FRAM_OUT                     -> BEAGLE_STORE_OUT
FRAM_LOG                     -> BEAGLE_STORE_LOG
FRAM_THREADS                 -> BEAGLE_STORE_THREADS
FRAM_TELEMETRY_LOG           -> BEAGLE_STORE_TELEMETRY_LOG
FRAM_SPACE_ID                -> BEAGLE_STORE_SPACE_ID
FRAM_SERVER_PORT             -> BEAGLE_STORE_SERVER_PORT
FRAM_SERVER_*                -> BEAGLE_STORE_SERVER_*
FRAM_NATIVE_*                -> BEAGLE_STORE_NATIVE_*
FRAM_CLIENT_*                -> BEAGLE_STORE_CLIENT_*
FRAM_GRAPH_* / FRAM_CODE_*   -> BEAGLE_STORE_GRAPH_* / BEAGLE_STORE_CODE_*
NORTH_FRAMRPC_OUT            -> NORTH_STORE_OUT
NORTH_FRAM_SELECTION         -> NORTH_STORE_SELECTION
```

The North selector becomes
`~/.local/state/north/beagle-store.env`; its attestation directory becomes
`~/.local/state/north/store-runtime/`. Do not read `framrpc.env` as fallback.
The old selector belongs only to the old system generation.

## Namespace ruling

Rename source namespaces too. `fram.*` becomes `beagle.store.*`; the bare
implementation namespace `framrpc` becomes `beagle.store.rpc`. Move the source
and generated paths in the same commit:

```text
branch-core/src/fram/...       -> branch-core/src/beagle/store/...
branch-core/src/framrpc.bclj   -> branch-core/src/beagle/store/rpc.bclj
branch-core/out/fram/...       -> branch-core/out/beagle/store/...
branch-core/out/framrpc.clj    -> branch-core/out/beagle/store/rpc.clj
```

Leaving `fram.*` would preserve the hidden second product boundary. North's
current build has to synthesize `src/fram`, put a separate Fram `out` on its
runtime classpath, and teach Beagle to resolve that namespace
(`north:build.sh:4-16`, `:23`). That is exactly the seam the absorption should
remove. The wave already rebuilds every generated output and every consumer,
so postponing the namespace move would buy no compatibility while guaranteeing
a second coordinated break later.

This ruling does **not** rename durable format identities. Keep FRAMRPC v2 wire
bytes, FRAMLOG/v1 magic, `.framlog` files, and persisted `:fram/*` keys byte
identical. They are versioned data contracts, not source namespaces or command
aliases. Rename their owning package/API to
`@tompassarelli/beagle-store-rpc` / `storeClient`, but continue to describe the
wire protocol as FRAMRPC where byte identity matters. This boundary makes a
whole-wave rollback possible without translating or copying live data. A total
FRAMLOG/FRAMRPC lexical and storage migration would be a separate, explicitly
authorized data-format change.

The source namespace declarations to move are all of the following:

- `beagle:branch-core/src/defcheck_gate.bclj:8` — `fram.defcheck`.
- `beagle:branch-core/src/fram/authority.bclj:3` — `fram.authority`.
- `beagle:branch-core/src/fram/branch.bclj:4` — `fram.branch`.
- `beagle:branch-core/src/fram/claims.bclj:16` — `fram.claims`.
- `beagle:branch-core/src/fram/datalog.bgl:4` — `fram.datalog`.
- `beagle:branch-core/src/fram/export.bclj:2` — `fram.export`.
- `beagle:branch-core/src/fram/fold.bclj:4` — `fram.fold`.
- `beagle:branch-core/src/fram/import.bclj:2` — `fram.import`.
- `beagle:branch-core/src/fram/kernel.bgl:4` — `fram.kernel`.
- `beagle:branch-core/src/fram/kernel_classify.bgl:3` —
  `fram.kernel-classify`.
- `beagle:branch-core/src/fram/log_codec.bgl:3` — `fram.log-codec`.
- `beagle:branch-core/src/fram/main.bclj:2` — `fram.main`.
- `beagle:branch-core/src/fram/native_dispatch.bgl:3` —
  `fram.native-dispatch`.
- `beagle:branch-core/src/fram/native_lease_ops.bgl:3` —
  `fram.native-lease-ops`.
- `beagle:branch-core/src/fram/native_query_ops.bgl:3` —
  `fram.native-query-ops`.
- `beagle:branch-core/src/fram/native_server.bgl:3` — `fram.native-server`.
- `beagle:branch-core/src/fram/native_wire_codec.bgl:3` —
  `fram.native-wire-codec`.
- `beagle:branch-core/src/fram/provider_host.bclj:5` —
  `fram.provider-host`.
- `beagle:branch-core/src/fram/query.bgl:4` — `fram.query`.
- `beagle:branch-core/src/fram/rotation.bgl:19` — `fram.rotation`.
- `beagle:branch-core/src/fram/rpc_limits.bgl:3` — `fram.rpc-limits`.
- `beagle:branch-core/src/fram/rt_core.bgl:7` — `fram.rt-core`.
- `beagle:branch-core/src/fram/schema.bgl:33` — `fram.schema`.
- `beagle:branch-core/src/fram/slots.bgl:5` — `fram.slots`.
- `beagle:branch-core/src/fram/snapshot_codec.bgl:5` —
  `fram.snapshot-codec`.
- `beagle:branch-core/src/fram/store.bgl:3` — `fram.store`.
- `beagle:branch-core/src/fram/text_index.bgl:3` — `fram.text-index`.
- `beagle:branch-core/src/fram/text_search.bgl:4` — `fram.text-search`.
- `beagle:branch-core/src/fram/tools.bclj:3` — `fram.tools`.
- `beagle:branch-core/src/fram/txn.bgl:8` — `fram.txn`.
- `beagle:branch-core/src/fram/types.bgl:5` — `fram.types`.
- `beagle:branch-core/src/framrpc.bclj:4` — `framrpc`.
- `beagle:branch-core/codegraph/src/roundtrip_fram.bclj:12` —
  `roundtrip-fram`; rename it `roundtrip-beagle-store` with matching filename.

## Rename-bearing inventory

This inventory names every distinct live name/contract and every test cluster
that asserts it. Repeated prose occurrences inside the same file are not
duplicated. Protocol-only FRAMRPC/FRAMLOG occurrences are intentionally listed
as retained, not silently swept into the CLI rename.

### Beagle

The current CLI surface is declared twice: shell usage and routing at
`beagle:branch-core/bin/fram:6-43`, then the Beagle fallback namespace and help
at `beagle:branch-core/src/fram/main.bclj:1-7`. The public data dispatcher and
its user-visible `fram` diagnostics are
`beagle:branch-core/bin/fram-fast.clj:157-167`, `:198-239`, and `:241-255`.
The MCP entrypoint is `beagle:branch-core/bin/fram-mcp:1-14`; the server and
checkout supervisor are `beagle:branch-core/bin/fram-server:1-24` and
`beagle:branch-core/bin/fram-up:1-16`.

Generated-source authority is
`beagle:branch-core/build.sh:2-9`, `:36-64`, and `:66-102`. The manifest carries
every old source/output path at
`beagle:branch-core/build/generated-targets.d/00-current.tsv:2-56` and
`beagle:branch-core/build/generated-targets.d/20-provider-host.tsv:2`.

Other Beagle-owned rename surfaces are:

- Root absorption description: `beagle:README.md:325-328`.
- Standalone-mirror workflow: `beagle:.github/workflows/fram-lockstep.yml:1-57`.
  Replace it with an in-repository `store-integration` gate; do not continue to
  checkout the historical Fram repository.
- Resolver/callgraph defaults:
  `beagle:bin/_fram-resolver:2-24` and `beagle:bin/beagle-callgraph:3`,
  `:17-39`.
- Downstream registry and dependency scheduler:
  `beagle:contrib/downstream/runner.rkt:14-16`, `:73-100`, `:214-215`, and
  `beagle:contrib/downstream/consumers.rktd:81-83`.
- Native validation pin route:
  `beagle:native-core/validation/fram-checkout.sh:5-29`; after absorption it
  selects the current Beagle pin's `branch-core`, not a Fram pin.
- Native slices with hard-coded source namespaces/paths:
  `beagle:native-core/validation/slice-types/run.sh:5-23`,
  `slice-types/pipeline.bclj:193-209`, `:345-366`,
  `slice-types-full/drive.sh:2-51`, `slice-store/drive.sh:2-70`,
  `slice-vec/drive.sh:2-77`, `slice-bodies/drive.sh:2-101`,
  `slice-kernel-capability/drive.sh:7-9`,
  `slice-kernel-capability/host_capability_slice.bclj:60`,
  `slice-main-capability/main_fixture.bgl:3-8`, and
  `slice-main-capability/drive.sh:90-157`.
- Native analysis vocabulary:
  `beagle:native-core/analysis/epoch/affordance.clj:1268-1272`,
  `:1400-1403`, and `:1877-1882`.
- Bun package identity and repository pointer:
  `beagle:branch-core/clients/bun/package.json:2-4`, `:8-30`, `:38-41`, and
  `beagle:branch-core/clients/bun/README.md:1-18`, `:30-52`, `:178`.
- Native ABI/artifact names:
  `beagle:branch-core/native/fram.h:1`,
  `native/fram_embed.c:1`, `native/fram_wasm_host.c:1`, and the generated
  `fram-server-native` assertions in
  `beagle:branch-core/tests/fram_native_build_cache_smoke.sh:647-705`.

The tests that assert an operator or artifact name, and therefore must be
renamed rather than retained, are:

- `beagle:branch-core/tests/README.md:9-10`;
  `bun_backup_test.mjs:7-71`; `bun_framrpc_client_test.mjs:71`;
  `cloudflare_json_response_test.clj:130`;
  `cloudflare_runtime_closure_test.clj:10-52`;
  `cloudflare_wasm_release_artifact_test.sh:26-91`.
- `beagle:branch-core/tests/code_edit_min_smoke.clj:20`;
  `code_editpath_defect_test.clj:57`; `code_write_def_test.clj:22`;
  `edit_verifier_adapter_test.clj:23`;
  `fixtures/slow_server_wrapper.sh:2-11`.
- `beagle:branch-core/tests/fram_backup_restore_test.sh:7-149`;
  `fram_code_wire_test.sh:3-265`; `fram_do_client_smoke.sh:36-47`;
  `fram_fast_exit_status_test.sh:41`; `fram_mcp.clj:292-333`;
  `fram_native_build_cache_smoke.sh:5-1173`;
  `fram_promotion_test.clj:43-108`; `fram_query_native_closure_test.sh:15-45`;
  `fram_snapshot_boot_test.sh:10-47`; `fram_up_readiness_test.sh:5-163`;
  `fram_wasm_embed_smoke.sh:8`.
- `beagle:branch-core/tests/graph_control_mcp_e2e_test.clj:81-166`;
  `graph_ops_report_test.sh:45`; `graph_ops_telemetry_smoke_test.clj:14`;
  `hosted_test_process_reaping_test.sh:51-84`; `mcp_test.clj:55-174`;
  `mcp_warm_graph_edit_regression_test.clj:34-160`.
- `beagle:branch-core/tests/native_code_commit_gate_test.clj:81-91`;
  `native_code_reader_test.clj:74`; `native_release_artifact_test.sh:30-171`;
  `native_rpc_boundary_ratchet_test.clj:60-104`;
  `package_graph_edit_runtime_smoke.sh:14-192`;
  `package_server_smoke.sh:20-254`; `projection_lifecycle_test.clj:154`;
  `selfcheck_deep_test.sh:2-35`; `store_defcheck_test.clj:5-102`.

Protocol-named tests such as `framlog_*`, `framref_codec_test.clj`, and
`framrpc_*` continue to test the retained wire/log contract, but their product
wording and package imports change. Their filename authorities are
`beagle:branch-core/tests/framlog_chain_boot_test.clj:1`,
`framlog_deflate_test.clj:1`, `framlog_fork_test.clj:1`,
`framlog_torn_sweep_test.clj:1`, `framref_codec_test.clj:1`,
`fram_rpc_v2_test.clj:1`, `framrpc_latency_convoy_test.clj:1`,
`framrpc_transport_test.mjs:1`, and `framrpc_write_conc_test.clj:1`.

### North

North currently treats Fram as a second checkout and runtime. The dependency
pin and CI checkout are `north:flake.nix:12-20` and
`north:.github/workflows/ci.yml:53-109`; replace `fram-test-source` with the
exact Beagle producer commit and bind tests to its `branch-core` store tree.
Remove the separate `tompassarelli/fram` checkout.

The primary runtime and CLI surfaces are:

- Source-link build seam: `north:build.sh:4-16`, `:23`.
- Environment/classpath selection: `north:bin/north:124-165`.
- Store readiness and unit attestation:
  `north:bin/north:302-328`.
- Generic read/write forwarding to the old executable:
  `north:bin/north:538-563`, `:585-635`.
- North's user-visible engine description:
  `north:src/north/main.bclj:1378-1391` and generated
  `north:out/north/main.clj:781`.
- Runtime attestation format and field authority:
  `north:cli/runtime-attestation.clj:9-22`, `:296-298`, `:432-465`, and
  `:491-532`.
- Unit consumers in dashboards/diagnostics:
  `north:cli/dashboard-cli.clj:507`,
  `dashboard-collectors.clj:279`, `dashboard-render.clj:168`, and
  `hotspots-cli.clj:72-83`.
- SDK component boundary:
  `north:sdk/src/fram-engine.ts:6-96`; rename the file to
  `beagle-store.ts`, its `FRAM_*` exports to `BEAGLE_STORE_*`, and every import
  in `children.ts:28`, `coordination.ts:11`, `death.ts:20`,
  `delivery-evidence.ts:8`, `dispatch-driver.ts:7`, `failover.ts:23`,
  `harness.ts:57`, `identity.ts:27`,
  `integrations/linear/north-state.ts:19`, `learning-assignment-writer.ts:7`,
  `orchestration-graph-source.ts:21`, `orchestration-policy-pin.ts:7`,
  `run-ledger.ts:7`, `shadow-reviewer-note.ts:7`, `spend-guard.ts:8`,
  `telemetry.ts:7`, `terminal-notification.ts:10`, `watchdog.ts:32`, and
  `worktree.ts:36`.
- Runtime-manifest component key `fram`:
  `north:sdk/src/runtime-manifest.ts:8`, with schema tests at
  `north:sdk/test/runtime-manifest.test.ts:41-49`, `:88-95`, `:187`.
- The only literal Fram MCP executable fixture in North:
  `north:sdk/test/codex-app-server.test.ts:908-909`.

North's `north.framrpc-client`, `framrpc-client.ts`, and `framrpc-codec.ts`
files are developer-facing names and become `north.store-rpc-client`,
`store-rpc-client.ts`, and `store-rpc-codec.ts`, while their golden frames stay
FRAMRPC v2. Authorities are `north:cli/framrpc-client.clj:2-4`,
`north:sdk/src/framrpc-client.ts:1-15`, and
`north:sdk/src/framrpc-codec.ts:1-49`. Their import/test fanout is named at
`north:cli/coord.clj:8-13`, `bars-cli.clj:27-67`,
`agent-fact-internal.clj:973-978`,
`cli/tests/framrpc-client-test.clj:4-22`,
`sdk/test/fixtures/framrpc-golden-frames.gen.clj:2-6`,
`sdk/test/framrpc-codec.test.ts:1-26`,
`sdk/test/mcp-driver-lifetime-integration.test.ts:18-19`, and
`sdk/test/run-ledger.test.ts:6-7`.

Tests that start the old `bin/fram-server` are the integration cluster at:

- `north:bin/tests/arena-seed-test.sh:28`.
- `north:cli/tests/acquire-claim-integration-test.clj:76`;
  `agent-identity-publication-integration-test.clj:14`, `:130`;
  `concern-attention-seam-test.clj:84`; `concern-cli-validation-test.clj:53`;
  `concern-offline-reconcile-integration-test.clj:59`;
  `concern-offline-spool-integration-test.clj:419`;
  `concern-terminal-cas-test.clj:73`; `context-replacement-test.clj:49`;
  `coord-assert-after-read-integration-test.clj:14`, `:48`;
  `delivery-evidence-contention-integration-test.clj:21`, `:74`;
  `directed-attention-integration-test.clj:121`;
  `learning-assignment-integration-test.clj:109`;
  `linear-reservation-integration-test.clj:14`, `:139`;
  `live-feed-integration-test.clj:307`; `live-msg-admission-integration-test.clj:205`;
  `maintenance-large-corpus-test.clj:17`, `:122`;
  `message-audience-integration-test.clj:22`, `:128`;
  `native-listener-liveness-integration-test.clj:180`;
  `peer-command-integration-test.clj:17`, `:85`;
  `pending-pagination-integration-test.clj:17`, `:184`;
  `presence-online-integration-test.clj:19`, `:57`;
  `read-projection-churn-oracle.clj:98-99`, `:228`;
  `run-fact-publication-integration-test.clj:13`, `:173`;
  `spend-breaker-test.clj:22`, `:60`; `spend-cli-test.clj:20`, `:57`;
  `subscription-policy-test.clj:40`;
  `worktree-allocation-integration-test.clj:16`, `:130`; and
  `worktree-janitor-integration-test.clj:19`, `:247`.

The `FRAM_*` test environment mirrors those production authorities rather than
forming additional contracts. Its central CI bindings are
`north:.github/workflows/ci.yml:71-78`, `:131-152`, `:178-225`, and `:272-276`;
the SDK's hermetic boundary is
`north:sdk/test/support/hermetic-preload.ts:107-113`.

### nixos-config

The system module is wholly Fram-named:

- `nixos-config:modules/north-fram/default.bnix:5-64` is the source authority.
  Rename the directory to `modules/north-store`, the option to
  `myConfig.modules.north-store.enable`, and the unit/helper/selector/record
  names exactly as specified above.
- `nixos-config:modules/north-fram/north-fram-launch:1-28` and
  `north-fram-publish-runtime:1-58` become the two `north-store-*` helpers.
- `nixos-config:modules/north-fram/default.nix:6-38` is generated output; do
  not edit it. Regenerate it from the renamed `.bnix` source.
- The host enable is
  `nixos-config:hosts/whiterabbit/configuration.bnix:57-59`; its generated mirror
  is `configuration.nix:57`.

MCP/config surfaces are:

- Codex key, executable, and env:
  `nixos-config:dotfiles/codex/config.toml:56-63`.
- The explicitly requested assertion:
  `nixos-config:modules/codex/default.test.sh:133-142`.
- Claude's checkout binding:
  `nixos-config:modules/claude/default.bnix:15-18`, `:105-127`; generated
  `default.nix:16`.
- Registration source and tests:
  `nixos-config:scripts/claude-mcp-register.sh:4`, `:21-32`, `:73-93`,
  `:138-147`; `claude-mcp-register.test.sh:12-23`, `:45-60`, `:132-163`,
  `:193-196`.
- Static/live config checks:
  `nixos-config:scripts/agent-config-check.sh:226-254`, `:712`, `:769-795`,
  `:1248-1288`, `:1499-1584`, `:1632-1699`; mirrored assertions in
  `agent-config-check.test.sh:119-151`, `:329`, `:782-829`, `:1084-1099`, and
  `:1229-1231`.

Other nixos-config operator/build references are:

- Live wrapper `nixos-config:dotfiles/bin/fram:1-4`: delete it; the installed
  Beagle command owns `beagle store`.
- North/concern wrappers sourcing the selector:
  `nixos-config:dotfiles/bin/north:3-4`, `north-mcp:3`, and `concern:3`.
- Switchboard skill paths:
  `nixos-config:dotfiles/bin/agents:43`, `:774-775` and tests
  `dotfiles/bin/agents.test.sh:152`, `:976-1038`. Rename `fram-modeling` to
  `beagle-store-modeling` and resolve it from the Beagle repository.
- Hard-coded checkout inventories:
  `nixos-config:config/hardcoded-repo-paths.tsv:18-19`, `:32-42`, `:50`, `:93`;
  `dotfiles/bin/hardcoded-repo-path-check:19`, `:70-73`; and
  `scripts/tests/hardcoded-repo-path-check.sh:53`.
- CI's obsolete standalone Fram override:
  `nixos-config:.github/workflows/build.yml:23-43`; remove it after the store is
  supplied by the Beagle input.
- Current Beagle input pin:
  `nixos-config:flake.bnix:20-22` (generated `flake.nix:36-38`). Advance it to
  the producer commit and regenerate `flake.lock`.
- Firn-native consumes that exact input for both executables. The specifically
  requested tag-resolve inputs are
  `nixos-config:flake.bnix:65-89` (generated `flake.nix:362-368`). The store
  rename does not add a tag-resolve source dependency, but the Beagle pin bump
  must rebuild `firn-tag-resolve`, and the `north-fram` to `north-store`
  directory/option rename must be reflected by a fresh `firn tag resolve`.
- Example flake-input text still names Fram at
  `nixos-config:scripts/firn-cmds/diff.rkt:192-193`; update the fixture to a
  Beagle Store example.

The window-mark files that use a generic `:frame` field and Framework laptop
modules are false positives and are not part of this wave.

### Greywrought

Greywrought has two independent pins that must converge on the same producer
commit:

- Compiler/runtime pin `greywrought:deploy/linux/beagle-toolchain.env:1`, read
  and enforced by `deploy/linux/build-release.sh:24-49` and
  `release-switch.sh:76-92`.
- Vendored client `greywrought:package.json:26` plus
  `vendor/framrpc-PROVENANCE.md:1-20`. Replace the package with
  `@tompassarelli/beagle-store-rpc`, packed from
  `beagle:branch-core/clients/bun` at that same Beagle commit; rename the
  tarball, provenance, license carrier, package import sites, and lock entry.

The deploy cutover surfaces are:

- `greywrought:deploy/linux/fram.env.example:1-8` -> `store.env.example` with
  `BEAGLE_STORE_*` bindings.
- `greywrought:deploy/linux/fram-health.sh:4-19` -> `store-health.sh` using
  `/opt/beagle-store/current/bin/beagle` with `store status`, or the packaged
  `beagle-store-cli` helper if the release deliberately omits the compiler CLI.
- `greywrought:deploy/linux/framlog-identity.mjs:38-200` ->
  `store-log-identity.mjs`; it continues to validate FRAMLOG/v1 bytes.
- Release file lists:
  `greywrought:deploy/linux/build-release.sh:214-215` and
  `release-switch.sh:51-52`.
- Runtime directories, release layout, and operator procedure:
  `greywrought:deploy/linux/README.md:26-28`, `:66-73`, `:149-168`,
  `:364-449`, `:541-589`, and `:605-626`.
- Unit dependency graph:
  `greywrought:deploy/linux/systemd/greywrought-fram.service:2-52`,
  `greywrought-fram-health.service:2-16`,
  `greywrought-fram-health.timer:2-8`,
  `greywrought-authority.service:4-14`,
  `greywrought-authority-backup.service:2-4`,
  `greywrought-authority-health.service:13`, and
  `greywrought-origin-health.service:13`.
- Backup configuration and capture:
  `greywrought:deploy/linux/backup.env.example:1` and
  `backup-capture.sh:22-55`, `:79-110`, `:148-165`.
- OpenTofu descriptions/outputs:
  `greywrought:deploy/opentofu/README.md:5-20`, `:142-146` and
  `outputs.tf:29-34`, `:66`.

Rename component-facing Greywrought files
`tools/fram-authority-ontology.mjs`, `tools/fram-authority-runtime.mjs`,
`tests/fram-authority-ontology.test.mjs`,
`tests/fram-authority-runtime.test.mjs`, `tests/native-fram-restart.test.mjs`,
and `tests/support/fake-fram-authority.mjs` to `store-*` equivalents. Their
import fanout begins at:

- `greywrought:tools/authority-checkpoint.mjs:19`,
  `authority-coordinator.mjs:5`, `authority-domain.mjs:5`,
  `authority-game-adapter.mjs:10`, `authority-terrain-service.mjs:11`,
  `authority-terrain.mjs:24`, `authority-host.mjs:542`,
  `world-checkpoint-v1-v2-migration.mjs:15`, and `zone-supervisor.mjs:2`.
- `greywrought:tests/authority-checkpoint.test.mjs:18`,
  `authority-domain.test.mjs:12`, `authority-game-adapter.test.mjs:19`,
  `authority-terrain-service.test.mjs:21`, `authority-terrain.test.mjs:19`,
  `world-checkpoint-v1-v2-migration.test.mjs:16`, and
  `zone-supervisor.test.mjs:9`.

The remaining product-word references are all in the following tracked files
and must become Beagle Store wording/variables in the same Greywrought commit:

- `greywrought:README.md:21`, `:124`, `:234-243`;
  `src/server/main.bjs:2524`; `src/server/terrain.bjs:127`.
- `greywrought:tools/authority-health-contract.mjs:108-119`;
  `authority-host.mjs:8-184`, `:519-648`, `:1079-1466`;
  `content-addressed-store.mjs:729`; `native-replay-harness.mjs:145`.
- `greywrought:tests/authority-backup.test.mjs:17-228`;
  `authority-candidate.test.mjs:680`; `authority-coordinator.test.mjs:329`;
  `authority-health.test.mjs:19`; `authority-host.test.mjs:31-764`;
  `authority-http.test.mjs:171`; `authority-packaging.test.mjs:607-830`;
  `authority-websocket.test.mjs:629`; `build-release.test.mjs:67`;
  `fixtures/zone-child.mjs:10`; `opentofu-packaging.test.mjs:133`;
  `release-switch.test.mjs:47`; `runtime-health.test.mjs:16-116`;
  `terrain-authority.test.mjs:63`; and `zone-supervisor.test.mjs:78-104`.

`tests/framrpc-vendor.test.mjs:5-40` is renamed to
`store-rpc-vendor.test.mjs` and proves the new package/provenance. FRAMRPC
golden bytes remain unchanged.

Keep the live state file and its FRAMLOG magic unchanged during this wave. A
new service may continue to point `BEAGLE_STORE_LOG` at the existing canonical
file. Rename `/opt/fram` to `/opt/beagle-store` for immutable release artifacts,
but do not move the authoritative log merely to improve a pathname.

### Gjoa

Gjoa has no Fram runtime, executable, MCP, or package consumer. It has one
Beagle pin and six textual Fram references:

- Pin `gjoa:configs/beagle.ref:1-11`, with vendored runtime provenance at
  `gjoa:src/gjoa/browser/components/gjoa/beagle/core.js:1-4`.
- Stale dependency wording `gjoa:docs/stewardship/churn.md:7`, `:109`; it should
  say the Beagle pin includes the Store implementation rather than claiming a
  second Fram dependency.
- Store vocabulary comments `gjoa:tools/projector/claims.bjs:6-7`,
  `tools/projector/reflector.bjs:5`, and
  `tools/sovereignty/egress-scan.bjs:25`.

Advance `configs/beagle.ref` to the new producer commit so the old shared pin
can eventually retire, re-vendor `core.js`, and update these comments. There is
no Gjoa runtime cutover.

## One-wave landing and cutover

All implementation work happens in per-repository worktrees. Prepare each
commit without touching any `main/` checkout. The order below is dependency
order, not permission for partial deployment.

### 1. Land the Beagle producer

1. Add `store` to `bin/beagle` help and dispatch. Make the root dispatcher call
   the renamed private store CLI.
2. Rename every executable in the table, source namespace/path, generated
   output path, Nix package/app, Bun package/API, native artifact name, workflow,
   and test authority. Delete the old names; do not leave wrapper files.
3. Preserve FRAMRPC/FRAMLOG byte contracts and prove the renamed server/client
   still consume existing golden frames and logs.
4. Regenerate `branch-core/out`, package metadata, and any generated manifests.
5. Run the Beagle checks below, commit, `safe-push --to main`, and fast-forward
   Beagle main.
6. Create a new detached full-object-ID pin and sidecar naming nixos-config,
   North, Greywrought, and Gjoa as actual consumers. Do not mutate an existing
   pin.

Existing consumers remain healthy because they still point at old immutable
Beagle/Fram revisions. The historical standalone Fram mirror is no longer an
upstream producer for this wave.

### 2. Prepare and verify North

1. Point build and CI at the new Beagle commit's `branch-core` store, then
   replace the `src/fram` symlink seam with the real `beagle.store.*` module
   root. Rename source/client/runtime-manifest surfaces and regenerate `out`.
2. Route generic North engine verbs through `beagle store`; route service
   execution through `beagle-store-server`.
3. Rename env, selector, runtime record, unit strings, dashboard/hotspot
   readers, SDK exports/imports, and tests. Keep FRAMRPC golden bytes.
4. Commit the verified North lane, but do not land it while the old
   `north-fram.service` is serving. North main is launch-critical.

### 3. Prepare and verify nixos-config

1. Advance the Beagle input in `flake.bnix`, regenerate `flake.nix` and
   `flake.lock`, and remove the obsolete standalone Fram CI override.
2. Rename `modules/north-fram` to `modules/north-store`, update the host option,
   install the Beagle Store package explicitly, and regenerate the sibling
   `.nix`. The new unit executes the immutable package's
   `beagle-store-server`, not `~/code/fram/main`.
3. Rename the selector/env contract, MCP key and executable, Claude/Codex
   registration, switchboard skill source, hard-coded-path inventories, status
   output, and their tests. Delete `dotfiles/bin/fram`.
4. Run `firn tag resolve` after the module-directory rename, then regenerate and
   validate. Build the whiterabbit closure without switching it. Commit the
   verified lane; landing and activation wait for the cutover window.

### 4. Prepare and verify Greywrought

1. Advance `GW_BEAGLE_COMMIT` to the same producer commit.
2. Pack `@tompassarelli/beagle-store-rpc` from that commit, replace the vendor
   tarball/provenance/license name and lock entry, and change all imports/API
   names.
3. Rename component modules, env variables, scripts, unit files, release paths,
   health/backup wiring, docs, and tests. Keep the existing authoritative log
   path and bytes.
4. Build a complete immutable `/opt/beagle-store/releases/<id>` candidate and
   its native artifact. Commit the verified lane, but do not deploy it yet.

### 5. Prepare and verify Gjoa

Advance `configs/beagle.ref`, re-vendor the Beagle runtime, update the six text
references, verify, and commit. This lane can land before the live cutover
because Gjoa has no store runtime.

### 6. Land consumers and cut over live state

1. Land and fast-forward Gjoa and Greywrought. Greywrought main landing does
   not deploy the prepared release.
2. Land and fast-forward nixos-config. Re-run the exact committed no-link build;
   do not switch yet.
3. Announce the bounded maintenance window. Quiesce Greywrought writes and stop
   `north-fram.service`; confirm both old writers have released their FRAMLOG
   locks. This is the only availability gap.
4. Land and fast-forward the prepared North commit while its old service is
   stopped.
5. Run `firn rebuild` from the committed nixos-config main. The new generation
   removes `north-fram.service`, installs and starts `north-store.service`, and
   publishes the new selector/MCP configuration in one system switch.
6. Deploy the prepared Greywrought release, install the renamed units together,
   daemon-reload, enable/start `greywrought-store.service`, then start the
   authority and health timer.
7. Run the cutover canaries. Do not retire old pins, system generations, or
   Greywrought releases until the canaries and a bounded soak pass.

There is no supported mixed state: new North with the old selector, new MCP key
with `fram-mcp`, new Greywrought with the old package API, or new unit names with
old helper paths is a failed cutover, not a compatibility case.

## Verification gates

Run at most one heavy build/suite on the machine at a time and run heavy work at
`nice 19`. Every check is against the exact commit intended to land.

### Beagle

From the Beagle lane:

```sh
bin/beagle doctor --deep
(cd branch-core && ./build.sh)
bin/beagle test --active-only
(cd branch-core && tests/run_hosted_test.sh 240s bash tests/package_server_smoke.sh)
(cd branch-core && tests/run_hosted_test.sh 240s bb -cp out tests/mcp_test.clj)
(cd branch-core && tests/run_hosted_test.sh 240s bash tests/native_release_artifact_test.sh)
nix flake check ./branch-core
```

Also require:

- `beagle store help`, data verbs, `doctor --deep`, and `backup --help` render
  only the new command spelling.
- `beagle-store-mcp` returns the same five-tool catalog.
- The renamed Bun client and server pass the existing FRAMRPC golden-frame
  tests and open an existing FRAMLOG/v1 fixture.
- A tracked-tree denylist search finds no removed binary names, `fram.*` source
  namespace declarations, `src/fram`, `out/fram`, `packages.fram`, or
  `apps.fram`. FRAMRPC/FRAMLOG/persisted-key occurrences are the explicit
  allowlist.

### North

From the North lane, bound to the exact new Beagle Store tree:

```sh
./build.sh
FRAM_TEST_CHECKOUT="$BEAGLE_STORE_HOME/branch-core" \
  bin/test-suite --sandbox-home -- bb -cp "out:$BEAGLE_STORE_OUT" \
  cli/tests/framrpc-client-test.clj
(cd sdk && bun run check && bun run test)
bash bin/tests/arena-seed-test.sh
```

Rename the test env before landing; the spelling above describes the current
harness and must become `BEAGLE_STORE_TEST_CHECKOUT`. Native CI on the exact
North commit is the landing confirmation. Assert that `north show/tell/retract`
invokes the new route, `north status` validates `north-store.runtime`, and no
tracked file names `north-fram.service`, `$FRAM_BIN/fram`, or the old
runtime-manifest component.

### nixos-config

From the nixos-config lane:

```sh
./scripts/firn-build
./scripts/firn-validate
native/tag_resolve_native.test.sh
modules/codex/default.test.sh
scripts/claude-mcp-register.test.sh
scripts/agent-config-check.test.sh
nix build .#nixosConfigurations.whiterabbit.config.system.build.toplevel --no-link
```

Inspect the built generation, not the ambient host: it must contain
`beagle-store-mcp` and `north-store.service`, contain no `fram-mcp` or
`north-fram.service`, and point the Firn native binaries at the exact new Beagle
input.

### Greywrought

From the Greywrought lane:

```sh
bun run build
bun run test
bun test tests/store-rpc-vendor.test.mjs \
  tests/authority-packaging.test.mjs tests/runtime-health.test.mjs \
  tests/build-release.test.mjs tests/release-switch.test.mjs
```

Require the release marker, unit `ExecStartPre`, native READY receipt, vendored
package provenance, and `GW_BEAGLE_COMMIT` to name the same Beagle commit.
Before deployment, prove the new server opens a read-only copy of the current
FRAMLOG and reports the expected SpaceId/version.

### Gjoa

```sh
bun run check
bun run preflight
```

Gate M must prove the new full Beagle object ID and the vendored `core.js`
header must record it.

### Live cutover canaries

```text
systemctl --user is-active north-store.service
beagle store status
beagle store validate
beagle-store-mcp: initialize -> tools/list -> one read-only show/ask
north status and one reversible North fact write/read/retract
systemctl is-active greywrought-store.service
greywrought-store-health identity-bound status
Greywrought /readyz plus one admitted operation and one backup dry verification
```

Each canary has one bounded supervisor. A timeout or ambiguous write stops the
lane; do not retry a mutation blindly.

## Rollback

Rollback is the entire consumer set, in reverse dependency order. Never add an
old-name shim and never move a published tag.

1. Stop new Greywrought admission and both new store writers. Confirm their log
   locks are released.
2. Reinstall the prior immutable Greywrought release and its prior unit set;
   point it at the unchanged authoritative FRAMLOG/CAS.
3. Revert the North consumer commit with a new commit (no reset/history
   rewrite), rebuild its committed outputs, and fast-forward main.
4. Revert the nixos-config consumer commit with a new commit, then use the
   sanctioned generation rollback/rebuild so the old selector,
   `north-fram.service`, and old MCP declarations return together.
5. Revert Gjoa/Greywrought pin commits if their normal development must resume
   on the old compiler/API. They have no live store-state effect.
6. Leave Beagle main advanced. Consumers re-point to the previous immutable
   Beagle/Fram pins; do not rewrite Beagle history.

Rollback needs no log conversion because FRAMRPC and FRAMLOG stayed byte
identical. Old pins and releases are recovery assets, not aliases in the new
tree. Retire them only after all declared consumers have moved and the soak is
accepted.

The old Beagle pin
`4c05adc3315888e913b8b34a7cdf799ca808357c` currently names nixos-config and
Gjoa in its sidecar, so both must move before `pin-retire`. The old pin
`b4f3081420a3be73d730802d2f4608d78d0c6cf4` names Greywrought **and** the
standalone `fram:` mirror. Moving Greywrought alone does not
make that pin retireable; keep it until the mirror's consumer record is
separately resolved.

## Final acceptance

The wave is done only when:

1. `beagle store` is the sole human store CLI.
2. No current tracked tree contains an old command, unit, MCP key, source
   namespace declaration, package/API name, or live checkout path from the
   rename denylist.
3. FRAMRPC/FRAMLOG compatibility tests prove the intentionally retained durable
   formats; there is no runtime fallback to an old executable or env name.
4. Every repository's named gate and native CI pass on its exact landed commit.
5. The live North and Greywrought canaries pass against the new binaries and
   the existing durable data.
6. Rollback pins/releases remain intact until the operator accepts the soak.

RENAME-DESIGN-DONE

## Addendum (EXEC, 2026-08-17 ~14:10) — the directory joins the wave's ruling set
Naming triangle to collapse in ONE wave ruling: fram (dying) / branch-core (the
runbook's branch-machine-era name, currently the import directory) / beagle
store (the proposed CLI surface). EXECUTIVE RECOMMENDATION: align surface AND
directory on "store" — CLI `beagle store <verb>`, directory `branch-core/` ->
`store/` in the same coordinated landing (the wave already touches every path
reference, making the git mv nearly free). "branch" survives only where it
names actual branching semantics inside the store (refs, reseal). RULED by EXEC-67 on source-vocabulary evidence (triple 1249 / store 925 / branch 89): directory = store/, CLI = beagle store, namespaces = store.*. No ratification pending.

## Wave landing checklist addition (operator order, 2026-08-17)
DOCS RIDE THE SAME LANDING: README.md (the branch-core pointer row -> store/,
any fram mention -> store), docs/ALLOCATION.md path citations, and store/'s own
README identity line all update in the wave's landing commit — and because
docfill + license-metadata gates now guard the README, the wave's gate run
covers the doc changes automatically. No doc lands stale behind the rename.
