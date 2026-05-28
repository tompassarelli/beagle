# beagle — session anchor

A typed authoring IR. **Nix is the live target;** Clj, CLJS, JS, Py,
Rkt, SQL emitters are parked under `beagle-lib/private/dormant/` and
reactivate with `BEAGLE_ALL_TARGETS=1`. Pipeline:
`parse → check → emit`, all at Racket expand-time inside our custom
`#%module-begin`.

There is **no static reference documentation** for the form set, types,
or stdlib. The surface churns; static docs go stale within a day. The
compiler is the source of truth — query it.

## Tool-first reflexes

Use these before reading source or guessing. Each one is a dynamic
answer to a question a static doc would otherwise try to encode.

| question | tool |
|---|---|
| does this file parse? where? | `bin/beagle-syntax FILE` (`--ledger`, `--repair --emit-patch`) |
| does this file type-check? | `bin/beagle-op-check FILE` (or `bin/beagle-check FILE` for legacy pipeline) |
| what's the signature of X? | `bin/beagle-sig X FILE...` |
| what fields does record R have? | `bin/beagle-fields R FILE...` |
| who calls X? | `bin/beagle-callers X FILE...` |
| what does FILE export? | `bin/beagle-provides FILE` |
| change-impact for X? | `bin/beagle-impact X FILE...` |
| show macro expansion | `bin/beagle-expand FILE` |
| run tests | `bin/beagle-test` (Nix-tier default) |
| compile this | `bin/beagle-op-compile FILE` |

When stuck after ordinary checks: `bin/beagle-repair --emit-patch`,
`bin/beagle-trace --focus FN`, `bin/beagle-cascade --from-failures`,
`bin/beagle-blame`, `bin/beagle-specfix`.

For the form set, read `beagle-lib/private/parse.rkt`. For the typed
externs, read `beagle-lib/private/stdlib-nix.rkt` and `stdlib-portable.rkt`.

## Session start

1. Confirm daemon: `bin/beagle-daemon status`. Start with
   `bin/beagle-daemon start --watch .` if absent — the PostToolUse
   hook auto-starts it on first edit but confirming up front avoids
   cold-start delay.

## Agent loop

1. Trust hook output. Fix syntax errors before type errors. Never
   count parens by hand — `bin/beagle-syntax` already counted them.
2. Use query tools above before opening large files.
3. Use `--emit-patch` tools before manual repair.

## Rules with teeth

These are the non-obvious ones an agent will get wrong otherwise.

### Zero escape hatches

No `unsafe-*` anything (no `unsafe-nix`, `unsafe-js`, `unsafe-clj`,
`unsafe-py`, `unsafe-rkt`, no `(define-macro unsafe ...)`). No
`nix-ident` or any other verbatim-string-to-target form under any name.
No `''…''`-as-raw-passthrough on bnix.

When you hit a gap:
1. Missing stdlib function → add a one-line typed entry to
   `stdlib-nix.rkt` (or `stdlib-portable.rkt`).
2. Missing surface form → add AST struct + parse case + emit case +
   infer case + lint traversal + test, same as every other form.
3. Genuinely untypable target snippet → write a sibling `.nix` file
   next to the `.bnix` and import it. The filesystem boundary is
   auditable; an inline backdoor is not.

Every typed language that shipped an escape hatch regretted it
(TypeScript `any`, Java `Object`-cast, Python `Any`-as-bailout,
Rust `unsafe`). The discipline of "no escape" forces the stdlib to
mature and makes hallucinations show up as compile errors.

### Test tiering during surface iteration

`bin/beagle-test` runs the **active tier only** by default — Nix-target
tests and the target-agnostic infrastructure. Non-Nix target tests and
behavioral/oracle suites are gated; opt in with `BEAGLE_ALL_TARGETS=1`
or per-suite env vars (`BEAGLE_ORACLE=1`, `BEAGLE_NIX_EVAL_CHECK=1`).

- Active failures: fix until green.
- Demoted / gated failures during surface iteration: **leave alone.**
  The tiering exists so dormant-target test churn doesn't slow the
  Nix loop. The reflex to "just fix the small thing" is locally cheap
  and globally expensive across drops.

Fixture migrations are not test code — they're test inputs and **must**
be migrated when surface changes break them.

### Where papers and plans live

Long-form design papers (role-locality, public-contracts, quarantine,
etc.) live in `~/code/life-os/threads/` with YAML front matter per the
threads/CLAUDE.md spec. **Do not** recreate `~/code/beagle/docs/` — it
was deliberately deleted. In-repo prose belongs under
`lab/journal/synthesis/` if anywhere.

## Conventions

Phase-stable and easy to get wrong:

- `ANY` is `(type-prim 'Any)` — the universal escape type
- `MAP-TAG` and `SET-TAG` are `'#%map` and `'#%set` (well-known
  symbols, NOT gensyms — gensyms break across Racket phase boundaries)
- Reader runs at phase 0, parser at phase 1 — shared symbols must be
  phase-stable
- Params can be `param`, `map-destructure`, or `seq-destructure`
  structs — always check the predicate before calling `(param-name p)`
- `emit-form` handles top-level forms; `emit-expr` handles everything
  else. `check-form` does top-level checking; `infer-expr` is
  expression-level
- **Maps/vectors/sets evaluate. Keys are keywords. `{:enable true}`.** (Rule. Closed. Do not reopen.)
- Current surface uses bare vectors for structural slots: `[x y]` for
  params/fields/binding-zones (no `(params …)` wrapper). `'` is the
  inert marker for lists only: `'(a b c)` for paths/code-as-data.
  Containers `[…]` / `{…}` / `#{…}` are never quote-prefixed.

## What changed recently — read the git log, not this file

Anything beyond the rules-with-teeth is in `git log` and the
life-os threads. If the surface looks different from what you expect,
`git log --since="1 week" CLAUDE.md beagle-lib/private/parse.rkt` will
tell you why.
