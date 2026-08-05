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
beagle build --materializer c17|qbe --out DIR [--entry NS/NAME]... PATH.bgl...
                                      # sealed Native World + one projection
beagle fix [--dry-run] [PATH...]                # high-confidence auto-fixes
beagle repair DIR VERIFY    # evidence-ranked repair (--emit-patch / --auto)
beagle doctor [--deep]      # is the authoring loop online and working?
```

## Query — the compiler is the source of truth

```sh
beagle sig FN PATH...       # typed signature
beagle fields RECORD PATH   # record fields, types, accessors
beagle callers FN PATH...   # call sites
beagle provides FILE        # exports
beagle impact FN PATH...    # change-impact
beagle expand FILE          # macro-expanded source
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
`module.native-world`, `module.native-world.sha256`, `source.facts`, and
`report.txt`; `--materializer c17` adds `module_0.h`/`module_0.c`, while
`--materializer qbe` adds `module_0.ssa`. No materializer is implicit, and
hosted `.bclj` is not accepted by the Core build path.

Without an explicit `OUT` argument, `beagle build` writes to
`${BEAGLE_OUT:-<beagle-checkout>/.beagle-out}/<ns-path>.<ext>` — that is the
*beagle* checkout, not your project directory. Pass an output path, or set
`BEAGLE_OUT`, when you want the artifact next to your source.
