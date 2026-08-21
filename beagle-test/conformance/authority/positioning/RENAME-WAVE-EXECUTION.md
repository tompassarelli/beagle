+++
id = "store-cli-rename-wave-execution"
title = "Execute branch-core to store and Fram CLI to beagle store"
shape = "project"
life = "done"
updated_at = "2026-08-17T20:26:55+08:00"
owners = ["codex:/root"]
depends_on = []

[[lane]]
repo = "beagle"
worktree = "~/code/beagle/worktrees/store-rename"
branch = "store-rename"
owner = "codex:/root"
state = "landed and reaped at e55dbf48617aa71d85da9383b9cb2ac7230456bd"

[[lane]]
repo = "north"
worktree = "~/code/north/worktrees/store-rename"
branch = "store-rename"
owner = "codex:/root"
state = "landed and reaped at 3d77d9de961d19e5b328a7e7665817c7cea434df"
+++

# RENAME WAVE EXECUTION

RENAME-PREP-DONE

## Execution outcome

RENAME-WAVE-DONE. Beagle landed first at
`e55dbf48617aa71d85da9383b9cb2ac7230456bd`; North then landed at
`3d77d9de961d19e5b328a7e7665817c7cea434df`, pinned to that exact Beagle
producer. Both local main refs and origin/main refs agree, and both
`store-rename` worktrees and branches were reaped.

Beagle's committed producer passed the authoring doctor, Store build, packaged
server smoke, hosted MCP suite (19/19), standalone Store flake check, and the
single full active suite (2407/2407; the current tree contains one more
assertion than the package's earlier 2406 expectation). The scoped producer
denylist was empty.

North's committed consumer passed the generated-source build, sandboxed CI
required-bars test, SDK check, canonical sandboxed SDK suite, and arena seed
test. The SDK result was 162 files, 1774 pass, 16 coded capability skips, 0
failures, and 13039 expectations. The package's branch/path guard and old
Beagle-pin guard were empty. The known nixos-config `flake.lock` dirt was not
modified. Existing Beagle rollback/compiler pins were retained because this
wave demonstrated no new local pin consumer.

This is the mechanical cutover package for the instant the campaign-integration
commit is available. It supersedes the execution portions of
beagle:beagle-test/conformance/authority/positioning/STORE-CLI-RENAME-WAVE.md after a
read-only preflight against the current trees.

No repository was edited for this preflight. The only intended mutation is this
handoff file.

## Current evidence

The revisions read were:

| tree | revision | current state relevant to this wave |
|---|---|---|
| Beagle | e51504195dada9d45037abca8cd4b8a02a5f9e6a | W1-W4 campaign is integrated; the checked-in engine is still branch-core/, fram.*, and bin/fram. Beagle main is a bare Git repository with its checked-out tree exposed; git status is unavailable there, so the Git index/tree and files were read without mutation. |
| North | c1f188158ff691ea3fa75f028e73d3a97fc45a04 | North migration to Beagle branch-core is already landed. It still uses the old path, executable, environment, unit, and SDK names. |
| nixos-config | c7a7dc3cc6b5947aecacb2bafb2a7723b1d1a6bf | The main checkout has pre-existing WIP in flake.lock; preserve it and do not use the primary checkout for the landing. |
| Greywrought | a5cee1eef0f9c6beec40539a7d6f095f4a9d52c2 | Still has the Fram runtime, package, deployment, unit, and backup names. |
| Gjoa | d4df04bd82d4a330fa8dbd0026eab893a8f25234 | Beagle pin and six Fram wording/comment references remain. No Store runtime is present. |
| Fram legacy checkout | f622abdc590bc768519157786ca3ee9620ec16ea | Still contains the standalone Fram product and release surface. It is a rollback/archive asset, not a file set to edit in this wave. |
| Wake compiler consumer | current tree read-only | Its Beagle pin is a compiler consumer. Its FramAuthority and fram plan vocabulary are Wake contracts, not evidence of a Beagle Store runtime dependency. Do not lexical-sweep them in this wave. |

The current Beagle pin sidecar at
/home/tom/code/beagle/pins/4aaf833c1edd27f155fbb744dfbbfa8ba9f1b55d.pin
names Greywrought, Gjoa, nixos-config, Wake, and the legacy Fram checkout.
The old plan's 4c05adc3... and b4f30814... pin statements are stale. A new
hash-named pin is required after the producer lands; never repoint a live pin.

## Naming ruling to execute

The latest ruling is:

~~~
directory:   branch-core/ -> store/
human CLI:   beagle store <verb>
namespaces:  fram.* / framrpc -> store.* / store.rpc
~~~

branch, segment, and slot remain where they describe actual store mechanics.
FRAMRPC, FRAMLOG, their versioned bytes, .framlog durable files, and persisted
:fram/* keys remain protocol/data identities. They are not aliases for the
removed CLI.

## Full path map

Apply the following as one producer rename, then sweep all tracked references.
Every path is inside the named repository unless it is explicitly absolute.

### Beagle producer paths

| current | replacement/action |
|---|---|
| branch-core/ | store/ |
| store/src/fram/ | store/src/store/ |
| store/src/framrpc.bclj | store/src/store/rpc.bclj |
| store/out/fram/ | store/out/store/ |
| store/out/framrpc.clj | store/out/store/rpc.clj |
| store/native/src/fram/ | store/native/src/store/ |
| store/codegraph/src/roundtrip_fram.bclj | store/codegraph/src/roundtrip_store.bclj |
| store/integrations/north/skills/fram-modeling/ | store/integrations/north/skills/beagle-store-modeling/ |
| bin/_fram-resolver | bin/_beagle-store-resolver |
| native-core/bin/fram-native-demo | native-core/bin/beagle-store-native-demo |
| native-core/validation/fram-checkout.sh | native-core/validation/store-checkout.sh |
| native-core/validation/fram.ref | native-core/validation/store.ref |
| store/native/fram.h | store/native/store.h |
| store/native/fram_embed.c | store/native/store_embed.c |
| store/native/fram_wasm_host.c | store/native/store_wasm_host.c |
| libfram.a/libfram.so | libbeagle_store.a/libbeagle_store.so |
| store/clients/bun/framrpc.{mjs,d.ts} | store/clients/bun/store-rpc.{mjs,d.ts} |
| store/clients/bun/framrpc-core.{mjs,d.ts} | store/clients/bun/store-rpc-core.{mjs,d.ts} |
| store/tests/<product-fram-test> | store/tests/<product-store-test>; protocol-only framlog_*, framref_*, and framrpc_* fixtures may retain protocol filenames |

The path map applies recursively to all references in Beagle workflows,
release scripts, package metadata, generated manifests, native slices,
documentation, tests, and store/ internal helpers. Do not hand-edit generated
store/out; regenerate it from the renamed source tree.

### Namespace map

~~~
fram.authority              -> store.authority
fram.branch                 -> store.branch
fram.claims                 -> store.claims
fram.datalog                -> store.datalog
fram.export                 -> store.export
fram.fold                   -> store.fold
fram.import                 -> store.import
fram.kernel                 -> store.kernel
fram.kernel-classify        -> store.kernel-classify
fram.log-codec              -> store.log-codec
fram.main                   -> store.main
fram.native-dispatch        -> store.native-dispatch
fram.native-lease-ops       -> store.native-lease-ops
fram.native-query-ops       -> store.native-query-ops
fram.native-server          -> store.native-server
fram.native-wire-codec      -> store.native-wire-codec
fram.provider-host          -> store.provider-host
fram.query                  -> store.query
fram.rotation               -> store.rotation
fram.rpc-limits             -> store.rpc-limits
fram.rt                     -> store.rt
fram.rt-core                -> store.rt-core
fram.schema                 -> store.schema
fram.slots                  -> store.slots
fram.snapshot-codec         -> store.snapshot-codec
fram.store                  -> store.store
fram.text-index             -> store.text-index
fram.text-search            -> store.text-search
fram.tools                  -> store.tools
fram.txn                    -> store.txn
fram.types                  -> store.types
framrpc                     -> store.rpc
roundtrip-fram              -> roundtrip-store
~~~

Do not use the old plan's beagle.store.* namespace target; EXEC-67 ruled
store.* after that plan was written.

### CLI and executable map

bin/beagle becomes the only human dispatcher. There is no bstore, no bin/fram
compatibility file, and no forwarding shim.

| current | replacement/action |
|---|---|
| fram | delete; invoke as beagle store ... |
| fram-fast.clj | beagle-store-cli.clj (private store dispatcher) |
| fram-backup | beagle-store-backup |
| fram-server | beagle-store-server |
| fram-server-native | beagle-store-server-native |
| fram-mcp | beagle-store-mcp |
| fram-up | beagle-store-up |
| fram-selfcheck | beagle-store-doctor |
| fram-selfcheck-probe.clj | beagle-store-doctor-probe.clj |
| fram-native-build | beagle-store-native-build |
| fram-cloudflare-native-image | beagle-store-cloudflare-native-image |
| fram-code-on/off/status | beagle-store-code-on/off/status |
| fram-code-wire | beagle-store-code-wire |
| fram-code-wire-toml.py | beagle-store-code-wire-toml.py |
| fram-coherence-doctor | beagle-store-coherence-doctor |
| fram-defcheck | beagle-store-defcheck |
| fram-defcheck-server.rkt | beagle-store-defcheck-server.rkt |
| fram-edit-verifier | beagle-store-edit-verifier |
| fram-graph-edit-runtime | beagle-store-graph-edit-runtime |
| fram-graph-ops-report | beagle-store-graph-ops-report |
| fram-ingest-code | beagle-store-ingest-code |
| fram-promote | beagle-store-promote |
| fram-render-code-native | beagle-store-render-code-native |

The public forms are:

~~~
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
beagle store up [--restart]
beagle store serve ...
~~~

The packaged non-human entrypoints are beagle-store-server and
beagle-store-mcp. MCP key fram becomes beagle-store. Unit names become
north-store.service, greywrought-store.service, and corresponding
*-health/*-health.timer names. Runtime record and receipt names become:

~~~
north-fram-launch           -> north-store-launch
north-fram-publish-runtime -> north-store-publish-runtime
north-fram.runtime          -> north-store.runtime
north-framrpc-runtime/v1    -> north-store-runtime/v1
north-fram-release/v1       -> north-store-release/v1
greywrought-fram-health     -> greywrought-store-health
~~~

## Environment map

Rename every component-owned FRAM_* binding, local, test fixture, wrapper,
receipt field, and diagnostic to BEAGLE_STORE_*. The family rule covers the
current tree's larger W4-era surface than the old plan's shorter list.

~~~
FRAM_HOME                         -> BEAGLE_STORE_HOME
FRAM_BIN                          -> BEAGLE_STORE_BIN
FRAM_OUT                          -> BEAGLE_STORE_OUT
FRAM_LOG                          -> BEAGLE_STORE_LOG
FRAM_THREADS                      -> BEAGLE_STORE_THREADS
FRAM_TELEMETRY_LOG                -> BEAGLE_STORE_TELEMETRY_LOG
FRAM_SPACE_ID                     -> BEAGLE_STORE_SPACE_ID
FRAM_BIND                         -> BEAGLE_STORE_BIND
FRAM_PORT                         -> BEAGLE_STORE_PORT
FRAM_PATH                         -> BEAGLE_STORE_PATH
FRAM_SOURCE / FRAM_SOURCE_ROOT    -> BEAGLE_STORE_SOURCE / BEAGLE_STORE_SOURCE_ROOT
FRAM_TREE / FRAM_REVISION         -> BEAGLE_STORE_TREE / BEAGLE_STORE_REVISION
FRAM_SERVER_*                     -> BEAGLE_STORE_SERVER_*
FRAM_NATIVE_*                     -> BEAGLE_STORE_NATIVE_*
FRAM_CLIENT_*                     -> BEAGLE_STORE_CLIENT_*
FRAM_GRAPH_*                      -> BEAGLE_STORE_GRAPH_*
FRAM_CODE_*                       -> BEAGLE_STORE_CODE_*
FRAM_RUNTIME_*                    -> BEAGLE_STORE_RUNTIME_*
FRAM_TEST_*                       -> BEAGLE_STORE_TEST_*
FRAM_GRAAL_* / FRAM_WASI_*        -> BEAGLE_STORE_GRAAL_* / BEAGLE_STORE_WASI_*
FRAM_DO_* / FRAM_CF_*             -> BEAGLE_STORE_DO_* / BEAGLE_STORE_CF_*
FRAM_* test/build helper families -> BEAGLE_STORE_* test/build helper families

NORTH_FRAM_SELECTION              -> NORTH_STORE_SELECTION
NORTH_FRAMRPC_OUT                 -> NORTH_STORE_OUT
~~~

NORTH_FRAMRPC_HOST,
NORTH_FRAMRPC_READ_TIMEOUT_MS, and NORTH_FRAMRPC_LISTENER_POLL_MS remain
transport settings because they name the retained FRAMRPC protocol, not the
Store component. FRAMRPC_* and FRAMLOG_* protocol constants likewise remain.
FRAM_LOG is component-owned and does rename to BEAGLE_STORE_LOG even though
its value remains an existing .framlog file.

North's selector and attestation locations become:

~~~
~/.local/state/north/framrpc.env       -> ~/.local/state/north/beagle-store.env
~/.local/state/north/framrpc-runtime/ -> ~/.local/state/north/store-runtime/
~~~

There is no read fallback for the old selector.

## Consumer sweep

### North: already on branch-core, now swept to store

North's producer path is already Beagle branch-core. The following non-test
files must change in the same North landing:

~~~
.github/workflows/ci.yml, README.md, flake.nix, build.sh,
bin/arena-seed, bin/north, bin/north-on-spawn, bin/north-on-tooluse,
bin/tests/arena-seed-test.sh, bin/tests/ci-required-bars-test.sh,
bin/tests/north-on-tooluse-stress-test.sh, cli/dashboard-cli.clj,
docs/building-and-testing.md, profiles/tom/docs/north.md,
sdk/test/codex-app-server.test.ts, sdk/test/mcp-dispatch-contract.test.ts,
sdk/test/mcp-driver-lifetime-integration.test.ts, sdk/test/run-ledger.test.ts,
tests/generated_output_test.sh
~~~

Also sweep the North component/API surface: bin/north forwarding from
$FRAM_BIN/fram to beagle store, all bin/fram-server starts to
beagle-store-server, cli/framrpc-client.clj to cli/store-rpc-client.clj,
north.framrpc-client to north.store-rpc-client, sdk/src/fram-engine.ts to
sdk/src/beagle-store.ts, sdk/src/framrpc-client.ts to
sdk/src/store-rpc-client.ts, sdk/src/framrpc-codec.ts to
sdk/src/store-rpc-codec.ts, and every import/test fixture that names those
files. Keep FRAMRPC golden bytes and protocol assertions.

The exact North test files that currently embed branch-core paths are below.
The listed line numbers are current-tree anchors; all are same-landing edits.

~~~
cli/tests/acquire-claim-integration-test.clj:15
cli/tests/agent-identity-publication-integration-test.clj:13,15
cli/tests/concern-cli-validation-test.clj:13
cli/tests/concern-offline-reconcile-integration-test.clj:15
cli/tests/concern-offline-spool-integration-test.clj:19
cli/tests/context-replacement-test.clj:15
cli/tests/coord-assert-after-read-integration-test.clj:13,15
cli/tests/delivery-evidence-contention-integration-test.clj:20,24
cli/tests/directed-attention-integration-test.clj:14
cli/tests/framrpc-client-test.clj:15
cli/tests/json-children-indexed-test.clj:23
cli/tests/json-search-test.clj:15
cli/tests/json-show-indexed-test.clj:22
cli/tests/learning-assignment-integration-test.clj:12
cli/tests/learning-compare-test.clj:14
cli/tests/linear-reservation-integration-test.clj:13,15
cli/tests/live-feed-integration-test.clj:16,324
cli/tests/live-msg-admission-integration-test.clj:17
cli/tests/maintenance-large-corpus-test.clj:14,18
cli/tests/maintenance-task-lifecycle-test.clj:17
cli/tests/message-audience-integration-test.clj:15,23
cli/tests/message-routing-test.clj:11
cli/tests/native-listener-liveness-integration-test.clj:16
cli/tests/north-listen-reconnect-test.clj:14
cli/tests/orchestration-root-cwd-test.clj:11
cli/tests/peer-command-integration-test.clj:14,18
cli/tests/pending-pagination-integration-test.clj:16,18
cli/tests/presence-online-integration-test.clj:17,20
cli/tests/read-projection-churn-oracle.clj:84,99
cli/tests/run-fact-publication-integration-test.clj:12,14
cli/tests/spend-breaker-test.clj:13,21,23
cli/tests/spend-cli-test.clj:19,21
cli/tests/subscription-policy-test.clj:13
cli/tests/worktree-allocation-integration-test.clj:15,17
cli/tests/worktree-janitor-integration-test.clj:16,20

sdk/test/codex-app-server.test.ts:909
sdk/test/mcp-dispatch-contract.test.ts:887
sdk/test/mcp-driver-lifetime-integration.test.ts:28
sdk/test/run-ledger.test.ts:230

bin/tests/arena-seed-test.sh:5
bin/tests/ci-required-bars-test.sh:118,121-124
bin/tests/north-on-tooluse-stress-test.sh:10

tests/generated_output_test.sh:5,11
tests/board_active_test.clj:11
tests/capture_test.clj:7
tests/schema_test.clj:8
tests/validate_process_test.clj:19
~~~

The North CI source currently pins Beagle
db33a4e70718dc9a1b1cff57e33128ad44b6bcb9; the final North landing must point
to the new post-rename producer object, not db33... and not an independent
Fram checkout.

### Other current consumer surfaces

Sweep these repositories in parallel after the producer commit is known, each
in its own worktree:

~~~
nixos-config:
  modules/north-fram/{default.bnix,default.nix,north-fram-launch,
    north-fram-publish-runtime}
  hosts/whiterabbit/configuration.bnix, hosts/whiterabbit/configuration.nix
  dotfiles/{bin/fram,bin/north,bin/north-mcp,bin/concern}
  dotfiles/codex/config.toml
  modules/claude/{default.bnix,default.nix}
  scripts/{claude-mcp-register.sh,claude-mcp-register.test.sh,
    agent-config-check.sh,agent-config-check.test.sh}
  config/hardcoded-repo-paths.tsv
  dotfiles/bin/{agents,agents.test.sh}
  .github/workflows/build.yml, flake.bnix, flake.nix, flake.lock

greywrought:
  deploy/linux/{beagle-toolchain.env,fram.env.example,fram-health.sh,
    framlog-identity.mjs,backup-capture.sh,build-release.sh,release-switch.sh,
    README.md}
  deploy/linux/systemd/{greywrought-fram.service,
    greywrought-fram-health.service,greywrought-fram-health.timer,
    greywrought-authority.service,greywrought-authority-backup.service,
    greywrought-authority-health.service,greywrought-origin-health.service}
  package.json, bun.lock, vendor/{framrpc-PROVENANCE.md,framrpc-LICENSE-MIT,
    tompassarelli-framrpc-0.2.0.tgz}
  tools/{fram-authority-ontology.mjs,fram-authority-runtime.mjs}
  tests/{fram-authority-ontology.test.mjs,fram-authority-runtime.test.mjs,
    native-fram-restart.test.mjs,framrpc-vendor.test.mjs,
    support/fake-fram-authority.mjs}
  all imports and product wording in authority, packaging, runtime-health,
  release-switch, and backup tests

gjoa:
  configs/beagle.ref, src/gjoa/browser/components/gjoa/beagle/core.js,
  docs/stewardship/churn.md, tools/projector/claims.bjs,
  tools/projector/reflector.bjs, tools/sovereignty/egress-scan.bjs
~~~

Greywrought's FRAMLOG magic, .framlog authoritative file, and golden FRAMRPC
bytes remain unchanged. Its /opt/fram release layout becomes /opt/beagle-store;
its component environment becomes BEAGLE_STORE_*.

Gjoa has no Store runtime cutover: advance its Beagle pin and re-vendor only
when the new producer is the selected compiler/runtime object.

The current Beagle pin sidecar also names Wake and /home/tom/code/fram/main.
Wake only consumes Beagle compiler/runtime artifacts; do not rename Wake's
domain-level FramAuthority, framPlan, or .fram.json contracts here. The
standalone Fram checkout is retained as a rollback/archive asset. Do not edit
it or retire its pin until its consumer record is explicitly resolved.

## Plan-step invalidations

These are explicit corrections to the old plan, not optional improvements.

| old plan step/assertion | current-tree result | execution disposition |
|---|---|---|
| Inventory revisions Beagle 424704d3, North 8f2483b0, nixos-config c41ea9c, Grey fb1f19e, Gjoa ee5cb248 | All are stale. Current revisions are recorded above. | Replace every old revision and use exact post-rename commit objects. |
| Beagle standalone-mirror workflow .github/workflows/fram-lockstep.yml | Path is absent from current Beagle. | Do not rename or replace a nonexistent file. Sweep live .github/workflows/test.yml, native.yml, and release.yml instead. |
| Namespace target beagle.store.* / beagle.store.rpc | Superseded by the later ruling store.* / store.rpc. | Use store.*; the old target is invalid. |
| North step 1: replace separate Fram checkout and src/fram symlink | North c1f18815 already consumes Beagle branch-core; no src/fram symlink exists. | Mark complete and do not recreate it. Rename the already-landed branch-core path and update its pin. |
| North step 2: point build/CI at branch-core | Already landed, but pinned to old Beagle db33... | Replace with store/ and the new producer object; retain the migration's test coverage. |
| North test inventory from the old plan | Current North has the expanded list above, including JSON, reconnect, lifecycle, top-level, and SDK fixtures. | Use the current list, not the old subset. |
| Old pin rollback paragraph naming 4c05adc3 and b4f30814 | Current sidecar is 4aaf833c... and names Wake plus legacy Fram. | Recompute pin consumers after all landings; never apply old pin IDs mechanically. |
| “No standalone Fram consumers post-adoption” | Current 4aaf...pin still names /home/tom/code/fram/main; live legacy assets exist. | Keep the old pin until that record is explicitly resolved. This is a retirement prerequisite, not a rename alias. |
| Beagle step “rename every fram test” | Protocol fixture names and bytes intentionally remain FRAMRPC, FRAMLOG, framref, and framlog. | Rename product/API assertions; retain protocol identities under the allowlist. |
| Old final acceptance “no old name anywhere” | Wake domain contracts and retained durable formats are legitimate non-Store names. | Apply the scoped denylist, not a blind global fram grep. |
| “One heavy build/suite at a time” | Not a plan correctness issue, but it conflicts with current fleet rules for independent seams. | Use one producer gate and parallel independent consumer gates; serialize shared live cutover and resource-bound gates. |

## Mechanical landing order

1. Create one Beagle lane from e5150419 and perform the path, namespace,
   executable, package, generated-output, workflow, native, client, and test
   rename. Add beagle store dispatch/help before touching consumer lanes.
2. Run the producer gate and final producer denylist. Commit it. Record the
   exact full object ID; create a new detached Beagle pin and sidecar for real
   consumers. Do not mutate 4aaf... in place.
3. Create North, nixos-config, Greywrought, and Gjoa lanes from their exact
   current revisions. Wake is a compiler-pin-only lane if its pin is advanced;
   Fram is not an edit lane. Update the Store consumers to the producer object.
4. Run each local gate below against the exact producer object. No remote CI
   verdict blocks a landing; it is asynchronous confirmation. Do not switch
   nixos-config or deploy Greywrought during preparation.
5. Land consumer commits in dependency order: Gjoa, Greywrought, nixos-config,
   then North. Re-run the committed nixos no-link build after landing. The
   pre-existing nixos WIP must be isolated before that lane is created.
6. At the bounded cutover window: quiesce Greywrought writes, stop the old
   North unit, land prepared North, run sanctioned firn rebuild from committed
   nixos-config, then install/start new Greywrought units. There is no
   mixed-name compatibility state.
7. Run canaries, retain old pins/releases/generations through bounded soak, and
   only then reconcile/retire old pins using explicit consumer proof.

## Gates

All gates run from lanes, against committed trees, with bounded supervisors.
No gate below edits a main checkout.

### Beagle producer gate

~~~sh
bin/beagle doctor --deep
bin/beagle test --active-only
(cd store && ./build.sh)
(cd store && tests/run_hosted_test.sh 240s bash tests/package_server_smoke.sh)
(cd store && tests/run_hosted_test.sh 240s bb -cp out tests/mcp_test.clj)
nix flake check ./store
~~~

The gate must prove beagle store help, data verbs, doctor, backup, the
beagle-store-mcp catalog, renamed Bun client, existing FRAMRPC golden frames,
an existing FRAMLOG fixture, and regenerated output/package manifests.

### North consumer gate

~~~sh
./build.sh
bin/test-suite --sandbox-home -- bash bin/tests/ci-required-bars-test.sh
(cd sdk && bun run check && bun run test)
bash bin/tests/arena-seed-test.sh
~~~

Run North integration tests with BEAGLE_STORE_TEST_CHECKOUT and
BEAGLE_STORE_OUT, not FRAM_TEST_CHECKOUT/FRAM_OUT. Assert generic North engine
verbs invoke beagle store, service fixtures invoke beagle-store-server,
north status validates north-store.runtime, and no tracked file names
branch-core, north-fram.service, or fram-mcp.

### nixos-config consumer gate

~~~sh
./scripts/firn-build
./scripts/firn-validate
native/tag_resolve_native.test.sh
modules/codex/default.test.sh
scripts/claude-mcp-register.test.sh
scripts/agent-config-check.test.sh
nix build .#nixosConfigurations.whiterabbit.config.system.build.toplevel --no-link
~~~

Inspect the built generation. It must contain beagle-store-mcp and
north-store.service, contain no fram-mcp or north-fram.service, use the new
Beagle input, and preserve pre-existing WIP rather than overwriting it.

### Greywrought gate

~~~sh
bun run build
bun run test
bun test tests/store-rpc-vendor.test.mjs \
  tests/authority-packaging.test.mjs tests/runtime-health.test.mjs \
  tests/build-release.test.mjs tests/release-switch.test.mjs
~~~

Require the new package/provenance identity, release marker, unit ExecStartPre,
native READY receipt, matching Beagle commit, and a read-only open/validate of a
copy of the current FRAMLOG.

### Gjoa and compiler-pin-only gate

~~~sh
bun run check
bun run preflight
~~~

Gate M must prove the new full Beagle object ID and the vendored runtime header
must record it. Wake's existing compiler gates remain authoritative for its
compiler pin; no Wake Store runtime gate is invented.

## End-state grep guards

Run these after each producer/consumer landing and again over final tracked
trees. Nonempty output is a failure unless it matches the explicit
protocol/data allowlist.

### Beagle path and product denylist

~~~sh
set -eu
test -z "$(git ls-files | rg '(^|/)(branch-core|fram|fram-[^/]*|_fram[^/]*)(/|$)' || true)"
! git grep -n -I -E \
  '(^|[^[:alnum:]_])(fram-server|fram-mcp|fram-up|fram-backup|fram-fast|fram-native-build|fram-graph-edit-runtime|fram-code-(on|off|status|wire)|fram-selfcheck|fram-defcheck|fram-edit-verifier|fram-promote|fram-render-code-native|fram-ingest-code)([^[:alnum:]_]|$)|packages\.fram|apps\.fram|mcp_servers\.fram|fram\.(authority|branch|claims|datalog|export|fold|import|kernel|query|schema|store|tools|txn|types)|FRAM_(HOME|BIN|OUT|LOG|THREADS|TELEMETRY_LOG|SPACE_ID|SERVER_|NATIVE_|CLIENT_|GRAPH_|CODE_)|NORTH_FRAM_SELECTION|NORTH_FRAMRPC_OUT|@tompassarelli/framrpc' -- .
~~~

The path guard runs from the Beagle producer lane after the branch-core move.
Retained FRAMRPC, FRAMLOG, .framlog, framref, and persisted :fram/* identities
are allowed and must not be converted.

### North branch/path guard

~~~sh
set -eu
! git grep -n -I -E \
  'branch-core|/branch-core|north-fram|fram-mcp|\$FRAM_BIN/fram|/bin/fram-server|framrpc\.env|NORTH_FRAM_SELECTION|NORTH_FRAMRPC_OUT|FRAM_(HOME|BIN|OUT|LOG|THREADS|TELEMETRY_LOG|SPACE_ID|SERVER_)' -- .
test ! -e sdk/src/fram-engine.ts
test ! -e sdk/src/framrpc-client.ts
test ! -e sdk/src/framrpc-codec.ts
~~~

Retained FRAMRPC protocol symbols and golden-frame bytes are not failures; old
component paths, commands, selector names, and env bindings are.

### Consumer command/unit/package guard

~~~sh
for repo in north nixos-config greywrought gjoa; do
  root="/home/tom/code/$repo/main"
  ! rg -n -I --hidden --glob '!.git/**' --glob '!node_modules/**' \
    'branch-core|fram-mcp|fram-server|north-fram|greywrought-fram|mcp_servers\.fram|@tompassarelli/framrpc|FRAM_HOME|FRAM_BIN|FRAM_OUT|FRAM_LOG|FRAM_THREADS|FRAM_TELEMETRY_LOG|FRAM_SPACE_ID|NORTH_FRAM_SELECTION|NORTH_FRAMRPC_OUT' "$root"
done
~~~

Use scoped allowlists for Wake's FramAuthority/framPlan and protocol magic; do
not claim zero lexical fram across unrelated products.

## Live cutover canaries

Only after all local gates and guards pass:

~~~text
systemctl --user is-active north-store.service
beagle store status
beagle store validate
beagle-store-mcp: initialize -> tools/list -> one read-only show/ask
north status and one reversible fact write/read/retract
systemctl is-active greywrought-store.service
greywrought-store-health identity-bound status
Greywrought /readyz plus one admitted operation and one backup dry verification
~~~

Each canary has one bounded supervisor. A timeout or ambiguous mutation stops
the cutover; do not blindly retry a write.

## Rollback and pin retirement

Rollback is the whole consumer set in reverse order: stop new Store writers,
restore the previous Greywrought release/unit set, revert North and
nixos-config with new commits, restore the old selector and MCP declaration,
and leave Beagle main advanced. FRAMRPC and FRAMLOG require no translation.

Do not delete the old 4aaf... pin while its sidecar still names Wake or the
legacy Fram checkout. Do not edit /home/tom/code/fram/main as part of this
wave. After every real consumer has moved or been explicitly retired, add the
required exact consumer-main records and use pin-retire only after its proof
passes.

## Completion condition

The wave is complete only when:

1. beagle store is the sole human Store CLI and no old executable shim exists.
2. branch-core/, product-owned fram paths/namespaces, old component envs, old
   unit/MCP/package names, and old North consumer paths are absent from scoped
   tracked trees.
3. FRAMRPC/FRAMLOG bytes and persisted keys remain unchanged and are covered by
   compatibility tests.
4. Beagle, North, nixos-config, Greywrought, and Gjoa local gates pass on exact
   commits, with Wake handled only as a compiler-pin consumer if advanced.
5. Live canaries pass and old rollback assets remain until bounded soak is
   accepted.

RENAME-PREP-DONE
