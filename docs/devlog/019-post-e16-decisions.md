# 019 — Post-E16 decisions: what to do next

**Date:** 2026-05-21

After F3-corrected established the 24% velocity finding, two
independent reviews (Claude online and ChatGPT) analyzed the result
and proposed next steps. This entry records the decisions.

## What's settled

E16 answered the original question: **types help agents build features
faster when integration is right.** Specifically:

- P2 (structural types + exhaustive match) is the sweet spot.
- P1 (false positives) is actively harmful (3.4× slower). Quarantine.
- P3 (effects) is neutral on bug-fixing, untested on features. Leave
  opt-in, don't expand.
- Integration surface determines outcome more than type system depth.
  Same tool: +76% penalty when noisy → -24% advantage when clean.
- Correctness gap didn't emerge at 800 LOC. Both P0 and P2 hit 8/8.
- Speed advantage scales with coordination complexity (45% on hardest
  feature, negative on simplest).

## Decisions

### 1. Type feature freeze

Both reviews agree. Phases 1-4 are done. No new type features until a
real consumer project exposes a concrete gap. Aliases and literal types
stay deferred.

The type system is not the active frontier. The integration surface is.

### 2. Daemon as default agent path — HIGH PRIORITY

The 6s Racket startup per `beagle check` invocation is the single
biggest practical barrier to adoption. The daemon already exists and
does ~100ms re-checks via inotify. But the experiment harness used
cold CLI invocations, and so will every agent that follows the README.

Make the daemon the primary path:
- `beagle init --claude-code` should generate daemon-first workflow
- PostToolUse hook should read from daemon, not spawn `beagle check`
- CLI cold-start stays for CI and one-shot use

This also resolves the README contradiction (claims ~100ms re-check
while the experiment paid ~6s per invocation).

### 3. Diagnostics as routing signals

ChatGPT's strongest insight: reframe error output as *routing*, not
*explanation*. The value of exhaustive-match errors isn't teaching the
agent about types — it's pointing to the exact lines that need updating.

Current: `exhaustive match: missing case GroupFailure in (match ...)`
Better: `errors.bgl:47 — missing match arm for GroupFailure`

The agent needs a file, a line, and a noun. Not a type theory lecture.
This applies to `--agent` output format specifically.

### 4. Lightweight F3 instrumentation

Claude's review correctly identified the evidence gap: we claim
exhaustive-match errors act as routing signals, but we never logged
whether the agent actually invoked the checker or what diagnostics it
received. The mechanism is plausible but unobserved.

Scope it tight:
- Add checker invocation logging to `run-feature-experiment` (timestamp,
  exit code, stderr line count)
- Post-trial: record whether agent's CLAUDE.md mentions running the
  checker and what it reported
- Do NOT build an edit-event correlation system or routing-hits metric

This is 20-30 lines of shell. Run it on 2-3 reps of features A and E
(largest P2 advantage) to confirm the mechanism fires.

### 5. Harness symmetry audit — CHEAP

Quick diff of P0 vs P2 generated CLAUDE.md templates to verify no
asymmetry beyond the intended checker/no-checker difference. One hour.
Avoids a second confound embarrassment.

### 6. Skip integration ablation

Three non-code fixes (suppress noise, reposition workflow, clarify
framing) were applied simultaneously. Claude's review suggests
ablating them individually. Skip it — you'd always apply all three,
and 12+ additional trials for marginal attribution insight isn't worth
it. The combined effect is the finding.

### 7. Skip F4 (large-codebase synthetic experiment) — for now

Claude proposed a 20+ file synthetic codebase with incomplete oracle
and "type-shaped holes" to test whether types provide a correctness
gap at scale. The design is sound but premature.

The right next test of types-at-scale is a **real consumer project**,
not another synthetic benchmark. If a real project surfaces a
correctness gap, design F4 around that specific failure mode. Building
synthetic complexity to prove something we don't have a consumer for
is academic.

### 8. Frame the thesis as "coordination velocity"

Not "correctness" (identical at this scale). Not "types" (sounds
academic). The public story:

> Types help agents coordinate structural changes faster. The
> advantage scales with how many sites need to stay in sync.

Both reviews converged on this independently.

### 9. P2 is the public story

Don't expose profile numbers to users. The documentation should say
"Beagle checks your types" with a note that the effect system is
opt-in (`--profile 3`). Users don't need to know about P0 or P1.

## TODO

Ordered by priority. Items above the line are worth doing before
moving to other Beagle work. Items below are deferred until triggered.

### Do now

- [ ] **Daemon-first agent workflow.** Update `beagle init --claude-code`
      to generate PostToolUse hook that reads from daemon instead of
      spawning cold `beagle check`. Update README "Agent integration"
      section to match.

- [ ] **Routing-style diagnostics.** Reformat `--agent` output to lead
      with `file:line — noun` instead of type-system terminology. Touch
      `check.rkt` `--agent` formatting path only.

- [ ] **Harness symmetry audit.** Diff the P0 and P2 CLAUDE.md templates
      generated by `run-feature-experiment` to verify no unintended
      asymmetry. Document the diff.

- [ ] **F3 instrumentation (light).** Add checker invocation logging
      (timestamp, exit code, stderr lines) to `run-feature-experiment`.
      Run 2-3 reps on features A and E. Confirm that P2 agents invoke
      the checker and receive exhaustive-match diagnostics.

### Do when triggered

- [ ] **F4 large-codebase experiment.** Design when a real consumer
      project surfaces a correctness gap at scale. Not before.

- [ ] **P3 effects evaluation.** Test effects on feature building if/when
      a consumer project uses `deferror`/`check`/`rescue` and reports
      friction. Current evidence: neutral on bugs, untested on features.

- [ ] **Type aliases.** Revisit when nested parametric types reach 3+
      levels in real consumer code.

- [ ] **Literal types.** Revisit when API-client codegen demands
      distinguishing string variants.

- [ ] **Statistical replication.** Run 3-5 reps per cell on features
      A and E if presenting E16 results to an external audience that
      cares about p-values. Current n=1 is directionally clear (3/4
      features, consistent pattern) but not publishable.

## What not to do

- Don't add more type features. The surface is sufficient.
- Don't build more synthetic benchmarks. Use real projects.
- Don't ablate the integration fixes individually.
- Don't expose checker profiles in user-facing docs.
- Don't instrument beyond what's needed to confirm the mechanism.
