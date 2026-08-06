# Racket / Beagle: one pinned racket, fresh bytecode by machinery

Two failure modes used to make Beagle bugs look unfixable. Both are now enforced
by `beagle:bin/_beagle-racket`, which every `bin/*` entrypoint sources.

**Version skew.** The system racket (nixos-config) and a Beagle project's
flake-pinned racket are DIFFERENT versions (e.g. system 9.2 vs flake 9.1). `.zo`
bytecode is version-specific: load 9.1-compiled `.zo` under 9.2 and racket dies
with `body of .../raco.rkt`.

**Stale bytecode.** Racket's loader checks `.zo` freshness per file by timestamp
and never transitively, so an unchanged dependent keeps loading bytecode built
against an old dependency — `reference to a variable that is not exported:
foo62.1`, a struct field-count mismatch, or an opaque `raco.rkt` death. The fix
"doesn't take" and you debug code that never ran.

## What the machinery does

`_beagle-racket` resolves the flake-pinned racket (falling back to the canonical
`~/code/beagle` pin in a git worktree, which has no allowed `.direnv`), prepends
it to `PATH`, scopes the `beagle` collection to THIS checkout, and then gates on
the compiled closure: if any tracked `.rkt` is newer than the last successful
build, or the resolved racket changed, it runs `raco make` over every tracked
`.rkt` before the entrypoint proceeds. `raco make` is the only transitive check
— it compares the SHA-1 recorded in `compiled/*.dep`.

The trigger is a filesystem scan, not an edit event, so a merge, rebase,
checkout, worktree add, or stash pop is caught the same as an edit. A failed
compile stops the entrypoint instead of letting it run against a broken closure.
Cost is ~6 ms when nothing changed.

## Rules that are still yours

1. **Never run bare `racket`/`raco`** in a Beagle/Racket project — bare tools get
   the system version and unlinked collections, and they bypass the gate.
   `source bin/_beagle-racket` then use `$RACKET` / `$RACO`, or
   `direnv exec . raco …`.
2. **Keep the SAME pinned racket for build AND test** in a worktree; collection
   links and `.zo` are per-racket.

`BEAGLE_NO_ZO_GATE=1` skips the freshness gate, for the rare case where you
deliberately want the bytecode left alone. Setting it makes any resulting
phantom bug your own.
