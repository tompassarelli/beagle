# Greywrought terrain-authority split — dispatch order for F2 / W5

This is a planning-only order. It is written against the read-only current
checkout `greywrought:main` at `e64289ba4ab7cc7901c0cccb1d5dff450bf1cae0`
(clean, `main...origin/main`). The implementation worker owns one new lane
only after the barrier and disjointness checks below pass.

## Dispatch preconditions and disjointness

Do not create a lane, edit a file, or begin F2 while any of these is true:

1. The W0 ordering barrier is unresolved. Its exact current state is the
   parked playable redeploy at detached `45d60a0f60b8bf6f294bf52b613e4a50f30a00a9`
   in `greywrought:worktrees/playable`, with the detached read-only
   adjudication checkout at the same revision in
   `greywrought:worktrees/w0-adjudicate`; the durable W0 record is
   `todo:w0-adjudication-evidence.md`, whose state is `active`/`planned`.
   Adjudicate that redeploy and land or reject it first. W0 is clear only when
   that decision is terminal and its 45-path impact is either on current main
   or explicitly rejected. A parked or merely tested W0 lane is not clear.
2. The earlier ordered quality waves have not settled. W1/R1 currently has
   clean commit `71c67c9` in `greywrought:worktrees/quality-r1` and is not on
   main. W2/R2 currently has clean commit `6701d8b` in
   `greywrought:worktrees/quality-r2`, is blocked on the native-only cutover,
   and is not on main. W3/R3 is still waiting for its R1 signal. F2 must wait
   for W1, W2, W3, and W4 to reach their plan-defined terminal landing/reject
   decisions and for F2's base to contain any landing they make. In
   particular, do not rebase or land F2 across an unlanded R1/R2/R3 or F1
   change.
3. A read-only path check from the then-current main finds an intersection
   between the proposed F2 owned set and any live lane's committed diff or
   working-tree diff. The F2 owned set is the current terrain module, its
   three extracted modules, the direct importers, the direct focused tests,
   and package metadata listed below. Re-run:

   ```sh
   git -C greywrought: worktree list --porcelain
   base=$(git -C greywrought: rev-parse HEAD)
   for wt in greywrought:worktrees/*; do
     test -d "$wt/.git" || continue
     git -C "$wt" diff --name-only "$base" --
     git -C "$wt" diff --name-only --
   done
   ```

   Stop on any owned-path intersection. `src/game/terrain-contract.bjs`,
   `src/game/terrain-interest.bjs`, `src/game/volume.bjs`, and
   `src/net/terrain-codec.bjs` are F2 read-only dependencies, not F2-owned
   paths; an earlier rename or W0 change must already be landed before this
   worker starts.

## Current seam inventory and line-count reality check

Counts are from the current `e64289ba…` tree, measured with `wc -l`; they are
not estimates. The 1,904-line authority module is the only current source
implementation. Direct consumers and focused verification surfaces total
14,506 lines including `package.json`.

| role | current path | lines | F2 treatment |
|---|---|---:|---|
| authority source | `src/server/terrain.bjs` | 1,904 | split; retain the narrow public authority seam |
| runtime consumer | `tools/authority-game-adapter.mjs` | 2,154 | update imports/API only |
| runtime consumer | `tools/authority-host.mjs` | 1,740 | update imports/API only |
| runtime consumer | `tools/authority-terrain-service.mjs` | 1,248 | update imports/API only |
| acceptance fixture | `acceptance/fixtures/world-render-browser.mjs` | 845 | update generated authority import/API only |
| focused test | `tests/authority-terrain-service.test.mjs` | 1,445 | preserve behavior; update imports/API |
| focused test | `tests/authority-terrain.test.mjs` | 793 | preserve behavior; update imports/API |
| focused test | `tests/terrain-authority.test.mjs` | 951 | preserve behavior; update imports/API |
| focused test | `tests/terrain-runtime.test.mjs` | 2,409 | preserve behavior; update imports/API |
| focused test | `tests/terrain-scoped-server.test.mjs` | 982 | preserve behavior; update imports/API |
| package scripts | `package.json` | 35 | no script broadening; only adjust paths if extraction requires it |

The four read-only source dependencies are also measured: `src/game/terrain-
contract.bjs` 332 lines, `src/game/terrain-interest.bjs` 380 lines,
`src/game/volume.bjs` 1,149 lines, and `src/net/terrain-codec.bjs` 965 lines.
They are imported by the current module but are not part of this worker's
edit set.

## Split and rebuild map

This is a behavior-preserving extraction, not a terrain-authority redesign.
Keep the current `TerrainAuthority` state and result records as the narrow
typed seam. Keep one orchestration entry point and preserve fail-closed
ordering, canonical bytes, request IDs, durable revisions, scope tokens,
budgets, and publication behavior.

- `src/authority/terrain-policy.bjs`: request/wire shape admission,
  request identity and fingerprinting, brush/reach/surface/support proofs,
  candidate construction, and preparation rejection. The logic comes from
  the admission/candidate regions around current lines 548-1,450, without
  moving durable receipt validation into policy.
- `src/authority/terrain-commit.bjs`: candidate material validation,
  durable resolution envelopes/outcomes, receipt matching, verified volume
  commit, replayable outcome ACK construction, and state promotion. The
  logic comes from current lines 780-1,050 and 1,263-1,642.
- `src/authority/terrain-scope.bjs`: peer identity/interest transitions,
  scope tokens and budgets, scoped manifest/baseline/repair handling,
  publication selection, and wire result construction. The logic comes from
  current lines 384-780 and 1,642-1,904.
- `src/server/terrain.bjs`: retain the records, authority construction/state
  access, compatibility exports, and a thin orchestration facade delegating to
  the three authority modules. Do not leave duplicate implementations or
  compatibility shims behind.
- Direct consumers and the five focused tests: change only import paths and
  calls required by the extracted exports. Do not widen the migration into
  the four read-only terrain contract/interest/volume/codec modules.

## Migration order

1. Re-read the then-current `src/server/terrain.bjs` and regenerate the
   inventory/path intersection check. Freeze the public record shapes and
   exported function list before moving code.
2. Extract `terrain-policy` first, preserving its input validation and
   fail-closed preparation result. Leave the facade calling the extracted
   implementation and keep the old public exports alive only through direct
   re-exports, never duplicate bodies.
3. Extract `terrain-commit` second. Wire it to the same state atom and
   candidate records; prove that an invalid receipt cannot mutate state or
   release a publication.
4. Extract `terrain-scope` third. Wire peer transitions, scoped reads, repair
   streaming, and publication through the same authority state and result
   records.
5. Reduce `server/terrain.bjs` to the facade and update the three tools, the
   world-render fixture, the five focused tests, and only necessary package
   paths. Keep all wire spellings and generated build paths stable.
6. Run the focused gates below, then `bun run build`. Commit the coherent F2
   change in its lane. Landing is allowed only at the plan row's bar.

## Lowest-layer verification per step

Run from `greywrought:worktrees/<f2-lane>` after each step; stop at the first
failure and preserve its output.

| step | lowest-layer command | proves |
|---|---|---|
| preflight | `git diff --check && git status --short` | clean starting lane and whitespace integrity |
| policy extraction | `bun -e 'import { checkAll } from "./tools/beagle.mjs"; const r = await checkAll(["src/authority/terrain-policy.bjs", "src/server/terrain.bjs"]); process.exit(r.failed.length ? 1 : 0)'` | typed policy/facade seam compiles |
| commit extraction | `bun -e 'import { checkAll } from "./tools/beagle.mjs"; const r = await checkAll(["src/authority/terrain-commit.bjs", "src/authority/terrain-policy.bjs", "src/server/terrain.bjs"]); process.exit(r.failed.length ? 1 : 0)'` | typed durability seam and cross-seam imports compile |
| scope extraction | `bun -e 'import { checkAll } from "./tools/beagle.mjs"; const r = await checkAll(["src/authority/terrain-scope.bjs", "src/authority/terrain-commit.bjs", "src/authority/terrain-policy.bjs", "src/server/terrain.bjs"]); process.exit(r.failed.length ? 1 : 0)'` | typed scope/publication seam compiles |
| focused behavior | `bun test tests/authority-terrain.test.mjs tests/terrain-authority.test.mjs` | admission, candidate, receipt, and commit behavior |
| service/scoped behavior | `bun test tests/authority-terrain-service.test.mjs tests/terrain-scoped-server.test.mjs tests/terrain-runtime.test.mjs` | service, scoped streaming, runtime integration |
| plan-row gate | `bun run test:hostile-client` | hostile-client and terrain authority boundary |
| plan-row build | `bun run build` | full Beagle type-check and Vite build |

The plan row's named pre-landing verification is the terrain authority,
terrain service, scoped-server, and codec tests plus `bun run build`. Use the
focused commands above for those surfaces; do not replace them with a green
compile alone. The repository's existing final `bun run test` remains the
release gate after the focused seam gate; no remote CI result gates landing.

## Landing bar

Land only when the exact F2 commit has:

- the focused terrain authority/service/scoped-server/codec tests green;
- `bun run build` green;
- no owned-path overlap with a live lane and a clean working tree; and
- the W0 decision and W1-W4 predecessor landings/rejections recorded, with
  any landed predecessor contained by the F2 base.

Use the repository landing procedure from the lane: commit coherent changes,
run `safe-push --to main`, pull `--ff-only` in main, and reap the F2 lane and
branch. Do not wait on remote CI; classify any later remote result
asynchronous to landing.

## Rollback

Before landing, rollback is simply discard the F2 lane after recording the
failed check; do not touch `greywrought:main`. After landing, revert the one
F2 commit with a new normal commit, preserving the previous main history;
then rerun the focused terrain gate and `bun run build`. If a predecessor
landing caused a conflict, stop and rebase the F2 lane from current main;
never force-push, mutate a protected checkout, or repoint an extracted module
in place.

## Completion receipt

The worker must report the exact landed commit, focused test result, build
result, path-disjointness result, and lane/branch cleanup. If W0 or a named
predecessor remains unresolved, report the blocker without creating an F2
lane.
