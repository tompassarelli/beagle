Native-dialect (.bzig/.bodin/.bsc) coverage for beagle-repair's resolver.

`resolve_source_file` (moved from `bin/beagle-repair` into `bin/beagle_repair_apply.py`
for unit testing, alongside `insert_match_clauses`) omitted the native-target
source extensions (`.bzig`, `.bodin`, `.bsc`) from both its extension-translation
table and its output-extension table. Fixed by mirroring
`beagle-lib/private/targets.rkt`'s TARGETS list (`bin/beagle langs --view
extensions`).

Run: `bin/test/repair-native-dialects/run.sh` (needs racket + the pinned zig
toolchain reachable via `_beagle-racket`). Unit-level coverage:
`beagle-test/tests/repair_apply_test.py`.

Scope note: the type-checker's fix-plan diagnostics always carry an absolute,
already-existing file path, so `resolve_source_file`'s as-is branch resolved
`.bzig` files even before this fix — the extension tables matter for the
fallback branches (a relative or compiled-output-basename file field, e.g.
future oracle-evidence sources). Both fixtures here exercise the resolver end
to end regardless.
