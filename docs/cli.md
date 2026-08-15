# The CLI and the authoring loop

`bin/beagle help` is the source of truth for this list; it is generated from the
live command table, and this page will lag it. Deeper dev tools stay as
`bin/beagle-*` (blame, specfix, trace, cascade, oracle, proptest, muttest,
dtrace, smap).

Static reference docs are intentionally thin while the surface moves — the
compiler is the reference, fronted by one CLI.

## Authoring

```sh
beagle syntax FILE          # parse check (+ --ledger, --repair --emit-patch)
beagle check [PATH...]      # type-check without emitting (--profile N)
beagle validate [FILE...]   # parse + check + schema validation
beagle build [--target T] PATH [OUT]  # explicit hosted source emission
beagle build --materializer c17|qbe|wasm --out DIR [--abi lp64|wasm32]
             [--entry NS/NAME]... PATH.bgl...
                                      # frozen native program + one projection;
                                      #  wasm is the C17/WASI bootstrap and
                                      #  requires --abi wasm32
beagle fix [--dry-run] [PATH...]                # high-confidence auto-fixes
beagle repair DIR VERIFY    # evidence-ranked repair (--emit-patch / --auto)
beagle doctor [--deep]      # is the authoring loop online and working?
```

Beagle source is strictly checked. `--profile 0` stops after parsing for
diagnostic workflows; it does not change source semantics or produce a checked
program.

## Query — the compiler is the source of truth

```sh
beagle sig FN PATH...       # typed signature
beagle fields RECORD PATH   # record fields, types, accessors
beagle callers FN PATH...   # call sites
beagle provides FILE        # exports
beagle impact FN PATH...    # change-impact
beagle expand FILE          # macro-expanded source
beagle ast FILE             # canonical, versioned checked-program JSON;
                            #  parses + strict-checks without execution;
                            #  sourceId is repo-relative; sourceSha256 binds
                            #  source bytes and projectionSha256 binds the AST;
                            #  schema v4 retains structural namespace imports
beagle explain CODE         # diagnostic explanation (E001, …)
beagle explain-type FILE    # inferred types as a view
beagle facts-roundtrip MODE FILE   # program-lossless source↔fact projection
                                   #  (reader-datum identity, not byte identity)
beagle langs [--json] [--view V]   # target table (names, table, extensions,
                                   #  domains, pipeline)
beagle doc-fill [--check]   # refill every doc span the table owns; --check
                            #  exits 3 on drift
```

## Project and loop

```sh
beagle init [--hooks] [--target T] [DIR]  # bootstrap a project (+ repair hooks)
beagle daemon start|status|stop           # watch + cache type results
beagle promote [REV]        # promote clean checkout HEAD, restart its daemon
beagle test [--active-only] # run the test tiers
beagle rejection-stats DIR  # diagnostics by cause-class
beagle lsp | beagle repl    # LSP server / typed REPL
```

## The authoring loop

A watch daemon, an on-edit syntax/type hook, and machine-applicable fixes are
where the type signal becomes applied edits. `beagle doctor` health-checks the
whole path end to end. `beagle init --hooks` wires the same loop into a project's
`.claude/` configuration, and is idempotent on an already-initialized repo.

## Build output paths

Bare `#lang beagle` on `.bgl` is Native Core, never a target-neutral or
unselected source profile. Its build always publishes
`module.native-program`, `module.native-program.sha256`, `source.facts`, and
`report.txt`; `--materializer c17` adds `module_0.h`/`module_0.c`, while
`--materializer qbe` adds `module_0.ssa`. `--materializer wasm --abi wasm32`
adds `module_0.wasm`, its SHA-256 digest, `module_0.wasm.seams`, and two reports:
`wasm-report.txt` contains the deterministic bootstrap/tool-identity contract;
`wasm-audit.txt` records environment-specific resolved compiler, linker, and
runtime paths. With no `--entry`, the reactor is classified as a non-executable
projection and exports only `_initialize` and `memory`. No materializer is
implicit, and hosted `.bclj` is not accepted by the Core build path.

### Wasm executable entries (wasm-entry-abi v1)

Each repeated `--entry NS/NAME` names one public, parameterless `Int` source
function. The build proves each entry's qualified source definition, unique
lowered function, and generated C symbol are one chain, then exports it as

```
beagle_wasm_entry_v1__<ns>__<name> : () -> i64
```

where `<ns>` and `<name>` replace every byte outside `[A-Za-z0-9]` with `_`.
Two entries that flatten to one export name, duplicate entries, and any other
callable shape are refused by qualified name. During the build every entry is
invoked under Wasmtime in its own fresh instance and its i64 result is
recorded in `wasm-report.txt` (`wasm-entry-result NS/NAME R`).

Entries whose lowered form takes the generated resource parameters
(`native_arena *arena`, `const native_capability *capability` — the same four
shapes `beagle native-exe` links) are served by an adapter-owned instance
state surface: one arena over 16 MiB of static linear-memory storage and one
constant nonzero capability, both constructed while the host runs the exported
`_initialize` (reactor convention: the host must call `_initialize` exactly
once before any entry; skipping it makes the first allocation trap). The arena
lives for the whole instance, allocations accumulate monotonically across
entry calls, exhaustion traps, and the adapter itself never resets it. Builds
with at least one resource-bearing entry additionally export
`beagle_wasm_arena_reset_v1 : () -> i64`, which resets the arena under
explicit host control — invalidating every Buffer allocated so far — and
returns the arena capacity. A module-level `def` is lowered per use site, so
each entry call reconstructs the state it names inside the arena; persistence
across calls is the arena's, not the def's.

The module keeps the zero-import contract (`wasm-import-count 0` in the
report), so `WebAssembly.instantiate(module, {})` works in any browser or JS
runtime; call `instance.exports._initialize()` once, then entries in any
order. The entry list, each entry's lowered resource shape, and the export
policy (`entries-v1`) are receipt-covered in `wasm.receipt`, and the complete
generated adapter (`wasm.adapter.c`) is a receipt input, so the runtime
contract below is bound to the artifact identity.

### Wasm runtime io (v1)

Every executable build publishes a runtime byte channel in each direction,
still with zero imports; all exported functions below are `(i64...) -> i64`.

**Bytes in — `env-records-v1`.** The host environment of a zero-import
reactor is an exported mailbox, never an OS environment:
`beagle_wasm_env_base_v1()` returns its linear-memory address and
`beagle_wasm_env_capacity_v1()` its capacity (65536 bytes). The host writes
consecutive records `[u32le name-length][u32le value-length][name bytes]
[value bytes]`; a zero name-length, exhausted capacity, or truncated record
ends the sequence, and the first matching name wins. `System/getenv` inside
the program reads exactly this region, so per-tick commands are fed by
rewriting the mailbox between entry calls (`parse-double` turns command text
into `Float`). A name that is absent reads as `nil`.

**Bytes out — `registration-order-v1`.** Builds with a resource-bearing
entry export the live Buffer registrations of the instance arena, index 0
oldest, in allocation order (deterministic for a deterministic program):
`beagle_wasm_buffer_count_v1()`, and per index
`beagle_wasm_buffer_address_v1(i)` / `beagle_wasm_buffer_length_v1(i)` /
`beagle_wasm_buffer_stride_v1(i)` (each answers -1 for an out-of-range
index; an empty Buffer's address is 0). The host reads element bytes
directly out of the exported `memory` at `address + index * stride`.
`beagle_wasm_arena_reset_v1()` empties the registration view along with the
arena, and an identical call sequence after a reset reproduces identical
addresses. Scalar results also flow out through each entry's i64 return
(`float-to-bits` publishes a `Float` result losslessly).

One semantic caveat governs interactive use: module-level `def` state is
lowered per use site, so state does not flow between two entry calls through
a `def` — each call reconstructs what it names inside the arena. An
interactive host therefore treats the module as a deterministic step
function: write command records, call an entry, read Buffers/result back,
reset the arena, repeat.

Without an explicit `OUT` argument, `beagle build` writes to
`${BEAGLE_OUT:-<beagle-checkout>/.beagle-out}/<ns-path>.<ext>` — that is the
*beagle* checkout, not your project directory. Pass an output path, or set
`BEAGLE_OUT`, when you want the artifact next to your source.
