# E23 — SQL Schema ROI

**Hypothesis:** authoring SQL against a project-typed schema (beagle/sql with
`.beagle-cache/sql-schema.json`) shortens agent time-to-correct vs writing
raw SQL, by turning column/table typos into compile errors instead of
runtime errors caught only after seeding + querying a DB.

**Task:** Implement a query that returns, for a given user's username, the
titles and view counts of their top 5 most-viewed *published* posts,
ordered by view count descending. The schema (`users` / `posts` / `comments`)
is in `.beagle-cache/sql-schema.json`.

**Trap surface:** Columns include `author_id` (not `user_id`),
`view_count` (not `views`), and `published` (Bool). Agents fed only
the task description tend to guess `user_id` / `views` because those
are conventional. The schema makes these guesses fail at compile time
with "did you mean: author_id?" / "did you mean: view_count?" hints.

## Setups

- **With beagle:** write `.bsql` in this directory. Compiles against
  the cached schema. Typos become compile errors. Run `make
  with-beagle` (see harness.sh).
- **Without beagle:** write raw `.sql` against the same logical schema,
  no help from a checker beyond what `sqlite3` gives at run time.
  Run `make without-beagle`.

## Scoring

- **Time to correct output** (wall clock from task issue → first run
  whose output matches `expected.txt`).
- **Number of attempts** (compile/run cycles before success).
- **Number of distinct typo classes encountered** (`user_id` vs
  `author_id`, `views` vs `view_count`, etc.).

A statistically meaningful comparison needs ≥5 runs per setup with
fresh agent sessions. This directory provides the harness; the actual
A/B experiment is a separate sustained effort.

## Files

- `task.md` — this file.
- `.beagle-cache/sql-schema.json` — project schema (cross-file cache).
- `reference.bsql` — competent beagle/sql solution.
- `reference.sql` — equivalent hand-written raw SQL.
- `expected.txt` — expected query output against `seed.sql`-populated DB.
- `seed.sql` — DDL + sample data to populate sqlite for verification.
- `harness.sh` — runs reference solution end-to-end (compile → seed
  sqlite → run query → diff against expected).
