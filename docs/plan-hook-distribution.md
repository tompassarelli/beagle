# Plan: Hook Distribution + Agent Mode Separation

## Problem

The beagle daemon + repair agent loop works in `~/code/beagle` because
hooks are manually configured. Anyone who `raco pkg install`s beagle and
starts Claude Code in a new project gets nothing — no syntax checking,
no type feedback, no repair agents.

Also: the current hook (`post_edit_check.py`) bundles simple error
reporting with a 668-line agent pool manager. These should be separate
modes with cost tracking.

## Deliverables

### Phase 1: Portable hook script

**Goal:** `beagle init` scaffolds a working `.claude/` directory in any
project.

1. **Portable `post-edit-check.sh`** — resolve beagle tools via `$PATH`
   (after `raco pkg install`, `beagle-syntax`/`beagle-daemon` are on
   path). No hardcoded `/home/tom/code/beagle`. Falls back to
   `$BEAGLE_PATH` env var if set.

2. **Simple mode hook** (~50 lines) — the default. On every Edit/Write
   to a beagle file:
   - Auto-start daemon if not running
   - Run `beagle-syntax --json FILE` → report structural errors
   - Query daemon `check-enriched FILE` → report type errors
   - Print errors to hook stdout (Claude sees them immediately)
   - No subagent spawning. Primary agent fixes its own errors.

3. **`beagle init --hooks`** (extend existing init) — writes:
   - `.claude/settings.json` with PostToolUse hook config
   - `.claude/hooks/post-edit-check.sh` (simple mode)
   - `.claude/hooks/post_edit_check.py` (simple mode worker)
   - Prints instructions to stdout

4. **Global hook option** — for power users, document how to add the
   hook to `~/.claude/settings.json` so it fires in every project
   (matcher checks file extension, script checks beagle is installed).

### Phase 2: Pool mode (opt-in)

**Goal:** Pool mode is available but not default.

5. **Extract pool logic** from current `post_edit_check.py` into
   `post_edit_check_pool.py`. Same interface (reads hook JSON from
   stdin, prints messages to stdout), but spawns repair subagents.

6. **Mode switch** — `.beagle/pool.json` with `"mode": "simple"` or
   `"mode": "pool"`. Hook script reads this and delegates to the right
   worker. Default: `"simple"`.

7. **Cost tracking** — both modes log to `.beagle/hook-log.jsonl`:
   - `{ts, event: "check", file, syntax_errors, type_errors, wall_ms}`
   - Pool mode adds: `{ts, event: "agent_spawn", agent_id, model, ...}`
   - Pool mode adds: `{ts, event: "agent_done", agent_id, wall_s, ...}`

### Phase 3: Experiment (simple vs pool)

**Goal:** Data-driven default.

8. **Experiment E16: simple vs pool repair** — use existing E8 bug
   corpus (10 seeded bugs across beagle source files).

   | Arm | Setup |
   |-----|-------|
   | Simple | Hook reports errors, single Claude session fixes them |
   | Pool | Hook spawns repair agents (1-3), primary coordinates |

   Metrics per bug:
   - Wall time to zero errors
   - Total API cost (tokens in/out × model price)
   - Fix quality: regressions introduced? (run test suite after)
   - Context requests: how often did pool agent need help?

9. **Run 3 trials per arm** (30 total bug fixes). Report in
   `experiments/report.md` as E16.

10. **Deliver opinionated default** — winner becomes the default in
    `beagle init`. Loser stays available via `pool.json` config.

## Order of operations

```
Phase 1 (1-4)  →  commit + test in nixos-config
Phase 2 (5-7)  →  commit
Phase 3 (8-10) →  run experiment, write devlog, update default
```

## Files touched

- `bin/beagle-init` (or extend existing init in parse.rkt)
- `.claude/hooks/post-edit-check.sh` (rewrite, portable)
- `.claude/hooks/post_edit_check.py` (rewrite, simple mode)
- `.claude/hooks/post_edit_check_pool.py` (extract from current)
- `.claude/settings.json` (template for init)
- `.beagle/pool.json` (mode config)
- `docs/cheatsheet-consumer.md` (document init --hooks)
- `experiments/` (E16 setup)
