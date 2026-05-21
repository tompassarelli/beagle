# Structural repair loop

Beagle's structural repair (pass 0) runs **before** parse on every file
change in the daemon watcher loop and on every `check`/`check-enriched`
command. It fixes delimiter structure so agents never see "unbalanced
paren" errors from the parser.

## Pipeline

```
file changed (inotify)
    │
    ▼
try-structural-repair!          ← NEW: pass 0
    │  read file as string
    │  repair-structure(source)
    │  if high confidence: write back, invalidate cache
    │  if low confidence: return diagnostics only
    ▼
read-beagle-syntax(path)        ← now reads repaired file
    ▼
parse-program(stxs)
    ▼
type-check-with-locs!(prog)
    ▼
result includes repair info
```

## Confidence policy

| confidence | action | rationale |
|---|---|---|
| `high` | write repaired file, re-parse | parinfer produced balanced output; safe |
| `low` | diagnostics only, don't modify | unclosed string or too many errors; agent should inspect |
| (unchanged) | no-op | file was already balanced |

## Repair strategies (in order)

1. **Parinfer Indent Mode** — infer closing delimiters from indentation.
   Handles ~95% of agent errors (missing closers at EOF, truncated forms).
   If the parinfer result is balanced, use it.

2. **Heuristic repair** — fallback. Fix wrong closer types (`)` → `]`),
   remove extra closers, infer positions for unclosed openers based on
   indentation scope.

## Daemon commands

```
repair <file>       fix delimiters in-place, return edits
check <file>        runs repair pass 0 automatically before check
check-enriched <f>  same, with enriched diagnostics
latest-results      includes repair info in each result
```

## Response format

Every `check-enriched` / `latest-results` response now includes a
`repair` field:

```json
{
  "file": "path/to/file.bgl",
  "error_count": 0,
  "repair": {
    "repaired": true,
    "confidence": "high",
    "edits": [...]
  }
}
```

`repair` is `null` when no structural issues were found.

## Watcher double-fire

Writing the repaired file triggers another watcher event. The second
check finds balanced code, repair is a no-op, and the loop stabilizes.
The semaphore (`check-sema`) serializes checks so they don't interleave.

## CLI

```bash
beagle syntax --repair file.bgl        # preview repair
beagle syntax --repair --write file.bgl # apply in-place
beagle syntax --check file.bgl         # validate only
beagle syntax --edits --json file.bgl   # machine-readable edits
```
