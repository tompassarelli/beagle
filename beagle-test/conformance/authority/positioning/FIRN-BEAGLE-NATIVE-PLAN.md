# Firn: Beagle-native shell-deprecation plan

## Position

Firn's configuration source is already Beagle: every `#lang beagle/nix` (`.bnix`)
file compiles to its adjacent generated `.nix`.  The command graph is mostly
Racket (`nixos-config:scripts/firn.rkt` and `scripts/firn-cmds/*.rkt`), with a
small native-Beagle program already present.  Shell still owns the process
boundary: discovery, cache publication, schema/cache transactions, Nix process
launches, a Git hook, and the agent guard.

Do not treat “no shell remains” as a sufficient outcome.  The rebuild pipeline
switches the running system and is launch-critical.  A replacement ships only
when it removes a duplicated semantic implementation or makes a load-bearing
invariant more explicit; a wrapper translated line-for-line into Beagle is not
an improvement.

Surveyed repositories: `nixos-config` (implementation), `beagle` (compiler and
native runtime), and `north` (no Firn implementation; it supplies the shared
agent environment).  No Firn shell implementation was found in North.

## What is already native

| Surface | State | Evidence |
| --- | --- | --- |
| Configuration authoring and Nix emission | Live Beagle/Nix compiler surface | `nixos-config:AGENTS.md:19-31`; `beagle:beagle-lib/private/build-all.rkt:351-417` |
| Tag-resolution kernel and native executable | Live for the two- and three-token `firn tag resolve` forms | `nixos-config:native/tag_resolve.bgl:1`; `native/tag_resolve_native.bgl:370-391`; `flake.bnix:61-89`; generated launcher `dotfiles/bin/firn:13-19` |
| Flake-input resolver | Native implementation and tests exist, but it is not packaged or routed | `nixos-config:native/flake_input_native.bgl:1-168`; `native/flake_input_native.test.sh:1` |
| Module/host inventory and authoring commands | Native implementations and tests exist, but they are not packaged or routed | `nixos-config:native/inventory_native.bgl:1`; `native/authoring_native.bgl:1`; their `*_native.test.sh` files |
| Top-level native Firn binary | Help-text prototype only; non-help arguments return 64 | `nixos-config:native/firn.bgl:1-373`; packaged as `firn-native` at `flake.bnix:68-75` |
| Full CLI and rebuild orchestration | Still Racket, not shell and not native Beagle | `nixos-config:scripts/firn.rkt:29-70`; `scripts/firn-cmds/rebuild.rkt:324-477` |

The important implication is that the next migration is not a greenfield
rewrite.  It must route and prove the native seams that already exist before
attempting the launch-critical pipeline.

## Shell inventory

“Production shell” below means a script invoked by the Firn CLI, a build/rebuild
path, a configured hook, CI, or the installed command.  The function anchors
name every shell function in that production scope.  Test-only shell harnesses
are listed after the table; they are verification fixtures, not replacement
targets.

| Shell surface and function anchors | What it does | Blast radius if wrong | Native seam / disposition |
| --- | --- | --- | --- |
| `nixos-config:scripts/firn-build:1-187`; `cleanup_runtime_root:53-56`, `firn_cli:58-62`; embedded Python stripper `134-183` | Resolves the attested Beagle/Racket runtime; runs tag and flake-input resolution; discovers stale `.bnix`; invokes `beagle-build-all`; strips Firn-only attributes; removes obsolete generated `enabled-tags.nix`. | **Critical.** Wrong discovery or emission writes stale/invalid generated Nix; tag/flake-input order changes the evaluated system; a wrong cleanup can damage temporary runtime state. | **Migrate, split into seams 1–2.** Move membership/emit policy and authoring-metadata omission into Beagle; retain only a minimal process adapter until the native command owns the whole transaction. |
| `nixos-config:scripts/firn-build-bin:1-289`; `cleanup_publish_temps:58-62`, `trace_now_ms:64-67`, `trace_revision_start:69-76`, `trace_revision_end:78-86`; generates the installed launcher at `166-284` (whose functions are reproduced at `dotfiles/bin/firn:26-93`) | Compiles the Racket CLI under Beagle's pinned Racket into an immutable, source-keyed cache; atomically publishes the launcher; retries on moving source; emits telemetry. | **High.** A mixed Racket/Beagle runtime can make all Firn commands fail; a non-atomic launcher or stale cache breaks every operator command. | **Do not translate now (seam 7, deferred).** It disappears only when the complete CLI is native. Replacing this cache publisher while Racket remains adds a second runtime mechanism with no quality gain. |
| Generated installed launcher `nixos-config:dotfiles/bin/firn:1-139`; `trace_now_ms:26-29`, `trace_start:31-37`, `trace_end:39-45`, `rebuild_invocation:51-57`, `open_trace_run:59-74`, `exec_runtime:80-93` | Starts rebuild telemetry, dispatches native tag resolution, attestates source/Racket cache identity, self-builds a missing runtime, then `exec`s the Racket CLI. Source owner is `firn-build-bin`, not this generated copy. | **High.** A bad dispatch can bypass the tag resolver or run mismatched bytecode; telemetry regressions impair post-rebuild diagnosis. | **Do not migrate separately (seam 7).** Preserve exact `tag resolve` routing while native commands are added one at a time; delete this launcher only with the Racket CLI, never before. |
| `nixos-config:scripts/firn-source-hash:1-34` (no shell functions) | Produces the source identity used by `firn-build-bin` and the generated launcher to select an immutable Racket runtime. | **High.** A collision, omitted source, or unstable input can run stale bytecode or repeatedly rebuild the CLI. | **Keep with seam 7.** Its inputs and output must become part of the native CLI artifact identity; do not make an independent language port while the Racket cache still consumes it. |
| `nixos-config:scripts/firn-extract-schema:1-126`; `cleanup:66-70`; embedded Python JSON validation `86-109` | Evaluates NixOS/Darwin/Home-Manager option schemas through Beagle, verifies input fingerprint stability, and atomically publishes schema and validation-policy cache files. | **High.** A mismatched schema validates configurations against the wrong Nix inputs and can conceal a build failure. | **Migrate only as part of schema authority (seam 3).** The extraction engine is already Beagle-owned (`beagle:bin/beagle-extract-schema`). A native Firn transaction has value only if it makes the fingerprint-plus-publish contract single-sourced. |
| `nixos-config:scripts/firn-schema-input-fingerprint:1-131` (no shell functions) | Hashes the relevant lock/tool/config inputs used to decide whether a schema cache is current. | **High.** A false cache hit gives validators stale schema; a false miss causes needless extraction. | **Migrate with seam 3.** Put the algorithm next to the Beagle schema extractor; retain byte-for-byte fixture vectors before replacing the shell entry point. |
| `nixos-config:scripts/firn-validate:1-200`; `schema_cache_is_current:49-97`, `darwin_schema_cache_is_current:99-147` | Validates cache provenance, then runs the Beagle validator over Firn's selected `.bnix` sources. | **High.** It is the standard pre-rebuild gate; an omission or stale-cache acceptance permits invalid source into the snapshot. | **Migrate with seam 3.** Validation semantics already belong to Beagle. Keep the command’s source-selection and stale-cache refusals identical until a native subcommand is parity-proven. |
| `nixos-config:scripts/firn-lint-nix:1-110`; `hash_lines:37-46`, `write_stamp:60-71` | Parallel, content-addressed `nix-instantiate --parse-only` checking of generated Nix. | **Medium/high.** It catches emitter syntax faults before expensive evaluation; a wrong cache can suppress a parse failure. | **Reject migration for now.** This is a thin, parallel Nix parser adapter. Native reimplementation adds process/cache risk but no semantic quality beyond the upstream parser. Keep it as the controlled Nix boundary. |
| `nixos-config:scripts/firn-verify:1-62` (no shell functions) | Fast Beagle-validation oracle for repair tools; optional slow rung runs build, Nix syntax lint, then build-only Nix verification. | **High as a gate adapter.** A false success lets automated repair claim validation it did not perform. | **Retain as a shell composition adapter.** Its value is selecting existing gates, not implementing a new domain. Revisit only if Beagle owns the complete repair-gate protocol. |
| `nixos-config:scripts/firn-rebuild-impact:1-169`; `extract_name:78-84` | Runs `nix build --dry-run`, parses its plan, and presents expected local builds/fetches and known-expensive packages. | **Medium.** Wrong output misinforms the operator, but does not switch or mutate the system. | **Reject native migration.** It is presentation over volatile upstream Nix diagnostics; a native parser would be more brittle without a quality gain. |
| `nixos-config:dotfiles/bin/firn-prewarm:1-330`; `say:21`, `git_clean:25-33`, `looks_like_firn_repo:35-37`, `container_main:39-62`, `resolve_repo:67-76`, `warm_key:78-83`, `snapshot_uri:85-95`, `local_host:97-102`, `target_attr:104-116`, `cmdline_of:118-123`, `rebuild_running:128-142`, `is_prewarm_pid:144-152`, `supersede:155-165`, `release_pidfile:167-173`, `prewarm:175-221`, `spawn_detached:223-230`, `ref_hook_content:235-255`, `ours:257-259`, `install_hook:261-287`, `usage:289-300` | Installs a reference-transaction Git hook and low-priority, detached Nix evaluation prewarm; deduplicates/supersedes current work. | **Medium.** Errors waste CPU or make rebuilds cold; the hook is intentionally fail-open and must never block Git. Unsafe PID handling could affect an unrelated process. | **Defer (seam 8).** A typed native implementation could improve process identity and atomic state, but only after Beagle’s native host layer demonstrably covers detached execution, locking, safe signal handling, and Git-hook stdin. No launch-critical quality gain today. |
| `nixos-config:scripts/firn-pin-staleness:1-244`; `usage:9-17`, `verify_url:72-87`, `report_hand_pin:89-100` | CI/reporting audit of external action, pre-commit, fixed-output, Codeberg, and lock pins using `curl`, `git`, `jq`, and `awk`. | **Low for the machine; medium for supply-chain reporting.** Incorrect reporting can miss a stale pin or create noisy failures. | **Reject.** It is an intentionally networked policy report, not a Firn runtime seam; native migration does not make the remote assertion more reliable. |
| `nixos-config:scripts/firn-license-check:1-40`; `fail:6-9`, `check_hash:11-16` | CI checksum and README license consistency check. | **Low.** Only licensing hygiene reporting is affected. | **Reject.** A 40-line deterministic shell check has no runtime coupling or native-quality benefit. |
| `nixos-config:modules/north-profile/firn/hooks/firn-guard.sh:1-176`; `capture_hook_stdin:25-41`; embedded Python decisions `52-163` | Injects Firn rules on first relevant edit and denies raw system-switch commands/wholesale upgrades, while keeping `firn rebuild` allowed. It is projected to Codex and the agent switchboard at `modules/codex/default.bnix:63-64`, `dotfiles/agents/hooks.d/firn-guard.json:1-19`, and `dotfiles/codex/hooks.json:46-61`. | **Critical policy boundary.** A false allow enables an unsanctioned system switch; a false deny blocks normal agent work. It must drain hook stdin and fail open on malformed/oversized input. | **Reject replacement now.** Hook hosts invoke an executable shell command and require a universally available, very fast fail-open shim. A native binary would add deployment/availability risk while leaving the host adapter. Keep the shell shim; separately consider moving only pure JSON policy after a measured contract test. |

### Test-only shell inventory

These scripts exercise the production seams and should remain free to use shell
fixtures even if the implementation becomes native: `scripts/firn-build.test.sh`,
`scripts/firn-build-bin.test.sh`, `scripts/firn-schema-input-fingerprint.test.sh`,
`scripts/firn-source-hash.test.sh`, `scripts/firn-validate.test.sh`,
`dotfiles/bin/firn-prewarm.test.sh`, and
`modules/north-profile/firn/hooks/firn-guard.test.sh`.  The native acceptance
harnesses are `native/authoring_native.test.sh`, `native/flake_input_native.test.sh`,
`native/inventory_native.test.sh`, `native/tag_resolve_native.test.sh`, and
`native/window_marks_native.test.sh`.

They are not production shell implementation and should not be counted as
shell-deprecation seams.  They are the rollback evidence for a migration.

## Migration map and ordering

The work order is deliberately safety-first.  Each numbered row is one
independently shippable, one-worker seam; do not combine it with a neighboring
row.  “Build-only verify” means the existing host target:
`nix build .#nixosConfigurations.whiterabbit.config.system.build.toplevel --no-link`.

| Order / one-worker seam | Replacement seam and completion condition | Required verification | Rollback |
| --- | --- | --- | --- |
| 1. Native tag resolver completion | Keep the existing native executable as the sole implementation of `firn tag resolve`; expand its contract only after exact parity with the Racket resolver, including `all+emit`, host resolution, generated file bytes, and errors. Current dispatch is at `dotfiles/bin/firn:13-19`. | `native/tag_resolve_native.test.sh`; `scripts/firn-build.test.sh`; `firn repo build`; `firn repo validate`; build-only verify. | Restore the Racket dispatch branch in the generated launcher and retain Racket resolver source until parity is proven in the landed commit. |
| 2. Native flake-input activation | Package `native/flake_input_native.bgl` beside `firn-tag-resolve`, route exactly `firn flake-input resolve emit`, and compare the resulting `flake.bnix` bytes and failures with `scripts/firn-cmds/flake-inputs-resolve.rkt`. | `native/flake_input_native.test.sh`; focused Racket/native golden cases; `firn repo build`; `firn repo validate`; build-only verify. | Remove only the routing/package edge; the Racket command remains authoritative until equivalence is demonstrated. |
| 3. Make Beagle own source membership and emitted metadata | Replace `firn-build`’s `find`/case rules and Python post-stripper with compiler-owned Firn/Nix target semantics: declared membership, explicit excluded classes, and emitter omission of `tags`, `tags-opt-in`, `tag-overrides`, and `flake-inputs`. Beagle already has downstream-registry checking for Firn membership (`beagle:contrib/downstream/registry.rkt:268-348`). | Golden generated `.nix` comparison for the full tree; `scripts/firn-build.test.sh`; Beagle downstream registry test; `firn repo build`; `firn repo validate`; build-only verify. | Revert the compiler target and retain the shell transaction. Never hand-edit generated `.nix`; rollback is a source revert followed by `firn repo build`. |
| 4. Native schema-cache transaction | Consolidate fingerprint calculation, schema extraction, JSON/policy validation, and atomic publish behind one Beagle-owned command. Preserve NixOS, Darwin, and Home-Manager targets and the before/after fingerprint refusal. | Existing `scripts/firn-schema-input-fingerprint.test.sh` and `scripts/firn-validate.test.sh`, extended with native parity fixtures; `firn repo build`; `firn repo validate`; build-only verify. | Re-route `schema extract`, `upgrade`, `doctor`, and `validate` to the shell transaction; cache files are derived and can be regenerated. |
| 5. Native inventory and authoring routing | Package and route the already-tested `inventory_native` and `authoring_native` commands one command group at a time. Do not route `secret show/edit` until its `sops` process and TTY contract is separately designed. | Corresponding native tests; CLI output/error golden cases; `firn repo build`; `firn repo validate`; build-only verify. | Remove the route and use the Racket command modules, which remain until the native group is accepted. |
| 6. Native top-level CLI only after command coverage | Replace the help-only `native/firn.bgl:371-373` with dispatch only when every selected command group is native or deliberately delegated through a stable boundary. This is where `firn-build-bin` and the generated Racket launcher can actually disappear. | Command-graph parity corpus; all routed native tests; `scripts/firn-build-bin.test.sh` until its deletion is justified; `firn repo build`; `firn repo validate`; build-only verify. | Keep the generated launcher as the selectable entry point until the native binary has passed a full command corpus. A single environment switch must restore it. |
| 7. Rebuild pipeline assessment, not an automatic port | The rebuild orchestrator is Racket (`scripts/firn-cmds/rebuild.rkt`), not shell. Port only a pure planning/telemetry subkernel first, then prove snapshot URI, preflight, validation, activation, and generation-tag behavior. Do not port the live switch merely to meet a language target. | Existing rebuild telemetry tests plus a hermetic snapshot/preflight corpus; then `firn repo build`; `firn repo validate`; build-only verify. No automatic live switch is a migration test. | Keep Racket as the activation authority. Any native failure before switch falls back to the last verified Racket path; after a switch, use `firn rollback` / boot-menu rollback. |
| 8. Prewarm assessment | Port only if native host APIs can prove safe process identity, advisory locking, bounded detached execution, and non-blocking Git-hook behavior. Otherwise retain the tested shell implementation. | `dotfiles/bin/firn-prewarm.test.sh`; `firn repo build`; `firn repo validate`; build-only verify. | Remove the Git hook route or point it back at the shell prewarmer; failure remains advisory and must not interrupt Git. |

## Explicit non-migrations

Keep `firn-lint-nix`, `firn-verify`, `firn-rebuild-impact`,
`firn-pin-staleness`, `firn-license-check`, and the shell boundary of
`firn-guard` as shell adapters.  Their meaningful work is an external Nix,
network, CI, or hook-host contract.  A Beagle-native rewrite would duplicate
that contract while retaining a launcher/process boundary, increasing risk
without a demonstrated quality gain.

Likewise, do not separately rewrite `firn-build-bin` or the generated `firn`
launcher.  They are temporary Racket-runtime infrastructure and should vanish
as a consequence of a complete native CLI, not be replaced by another cache
publisher.

## Sizing and handoff

- 8 one-worker seams total: 5 implementation candidates (orders 1–5), 1
  conditional CLI consolidation (6), and 2 assessment/defer seams (7–8).
- 4 native command seams are already materially implemented: tag resolve is
  live; flake-input, inventory, and authoring are source/test-ready but not yet
  packaged/routed.
- 6 production shell adapters are explicitly retained/rejected, plus the
  build-bin/launcher pair deferred until the CLI is native.
- The critical path is orders 1–4.  It never changes the live system switch
  until the build, schema, and validation contracts have local parity evidence.

FIRN-PLAN-DONE — 14 production shell scripts inventoried; 8 one-worker seams (5 implementation candidates, 1 conditional consolidation, 2 deferred assessments); 6 adapters rejected for lack of quality gain.
