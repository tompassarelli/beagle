# Adversarial review 4 — claims falsifier

Verdict: the thesis is materially more honest than the underlying program state, especially
about Stage 4/5 being unlanded. It is not yet safe to present its receipt ledger as a
proof ledger. The completion draft reviewed was `c56fa27dca42983ce54dfcf66f87a4b3a0b8b169cfc26bbd49433188ec523088`, ending in `TURTLES-DONE`.

Git-only evidence check: all cited Beagle objects, all five cited Greywrought objects,
and the cited Firn and North objects resolve. Beagle `a6b42feb`, `7fa36f95`, and
`c5316ad1` are ancestors of its current `main`; Greywrought `a149cd96`, `26d3cf9`,
and `dc0c3b7` are not ancestors of Greywrought `main`, consistent with their
commit-only/scaffold labels. The annotated `v0.22.0` tag names `4aaf833c…` and embeds
the exact-commit preflight assertion. This check did not rerun product gates.

1. **CRITICAL — the landed Stage 5 “driver” cannot perform the advertised proof.**
   The cutover gate requires one Beagle source edit with its exact invalidated cone and
   affected singleton compilation (thesis lines 310–317). But `c5316ad1` accepts only
   `sourceEdit=comment-layout`; it asserts that `semanticUnitsChanged` is zero and
   compiles `foundation` as an “affected singleton” despite no affected semantic unit.
   The Greywrought scaffold hard-codes the same `comment-layout` story and placeholder
   hashes. This is a useful no-op provenance harness, not evidence for semantic cone
   invalidation, live admission, or a cold compile of an affected definition.

   Smallest repair: call the landed piece a **comment-only Stage 5 wire harness** in
   the ledger and remove it as evidence for bets 2 and 5. Before calling it the Stage 5
   driver, add one declared semantic edit with a non-empty expected cone, identity
   checks for every unaffected unit, and a committed driver test that fails when the
   chosen singleton is not in that cone.

2. **HIGH — “Stage 3 landed” has ancestry, but not the stated acceptance-gate receipt.**
   `7fa36f95` exists and is on Beagle `main`; its focused 7/7, 5/5, 10/10, and sanitizer
   work are real focused evidence. The recorded Stage 3 handoff also says the exact
   active-tier run produced no verdict and the required `slice-store` command exposed
   an incompatibility before compilation. Therefore main ancestry proves only the
   document’s narrow definition of “landed,” not that the Stage 3 acceptance claim
   passed end to end. The row’s word “receipt” lets the focused result wear the stronger
   gate’s costume.

   Smallest repair: change the row to **“reachable on main; focused Stage 3 receipt”**
   and name the missing acceptance receipt. Restore **“Stage 3 landed”** only with one
   exact-commit, supervised gate record that includes the full command, exit status,
   test count, and input revision; otherwise remove any claim that requires the
   unavailable `slice-store` proof.

3. **HIGH — the Stage 4 “real history” language still describes a staged history.**
   The thesis correctly says a real-history integration receipt remains required (line
   69), but mechanism reason 19 calls the candidate’s input “bounded real history.” In
   `26d3cf9`, the purported real-history test builds two entries through the test-local
   `HistoricalRevisions` class and `appendNativeHistory`; it is a freshly generated
   fixture, not a retained authoritative production journal. Its `effectAttempts` are
   asserted on that harness, not independently observed at the process/capability
   boundary. A skeptic can rightly call this a rehearsed shadow replay.

   Smallest repair: label reasons 18–19 **commit-only synthetic native-harness
   evidence** until a signed/retained journal window from the authority is replayed.
   The required receipt must bind the source journal digest, `asOf` revision, candidate
   and incumbent artifacts, and an independently checked denial trace for network,
   persistence, and gameplay effects.

4. **HIGH — most receipt counts are assertions, not independently replayable receipts.**
   The Stage 2 and W1–W4 rows provide commit IDs and pass counts, but no immutable
   receipt location that binds the command, exact tree, environment/toolchain, output,
   and exit code. A commit proves code was written; it does not prove that a named gate
   passed. The v0.22.0 tag annotation is the exception: it records the exact preflight
   claim. Mutable coordination prose is useful provenance, not a replay artifact.

   Smallest repair: add a compact receipt manifest beside the thesis. Each ledger row
   needs `commit`, `command`, input/lockfile/compiler identities, exit status, summary,
   and digest/path of retained stdout (or an explicit “focused only” scope). Link the
   row to that manifest. Do not promote a count into a product fact without one.

5. **MAJOR — several kill-conditions cannot make a deterministic decision.**
   The opening gates are promising, but bets 3, 8, 9, and 10 use terms such as
   “require,” “hidden,” “repeatedly,” “pervasive,” and “can report success” without a
   test observation or decision owner. Bet 10 can survive indefinitely by arguing that
   each awkward shape was not yet “repeated”; bet 8 can hide a target fork behind a
   shared spelling; bet 9 can discover a missing input only after a disputed failure.
   Those are cautionary prose, not kill switches.

   Smallest repair: give each of those bets one named negative fixture and a binary
   disposition. For example: an unrepresentable required program/domain relation kills
   bet 10; same definition ID plus divergent browser/native result kills bet 8; a
   deliberately omitted output-affecting input that still verifies kills bet 9. A red
   required case must mark the corresponding bet `DEAD` (or explicitly narrowed), not
   merely create follow-up work.

6. **MAJOR — the “one typed Lisp across targets” bet has coverage, not a shared-closure receipt.**
   The v0.22.0, Greywrought, Firn, and North references show multiple consumers and
   targets. They do not yet bind browser game logic, native authority, store, compiler,
   and system generation to one definition closure or compare their canonical behavior.
   The proposed Mother-of-All-Demos says it will link artifacts, but the current kill
   condition can be evaded by target-specific implementation forks that retain familiar
   names.

   Smallest repair: make the W7 release artifact contain one source/definition closure
   ID, per-target materialization IDs and ABI/compiler identities, and equal canonical
   result digests for the named cross-target operation. Reject a target-specific source
   fork or a missing closure edge before the bet can be claimed.

7. **MEDIUM — “all five boundaries” needs a refusal rule for a staged video.**
   The thesis says the Mother-of-All-Demos is one linked receipt graph, but it does not
   specify which external verifier replays it, where the journal/artifacts live, or how
   the player-continuity and no-external-effect observations are independently derived.
   Without that, a successful-looking recording can be assembled from valid individual
   components that never coexisted.

   Smallest repair: require one read-only verifier command, a manifest of every object
   digest and chronological event, and a negative test that swaps any source, journal,
   parity, CAS, or player-continuity edge. Any disconnected or substituted edge must
   make the verifier fail before publication.

PANEL-FALSIFIER-DONE
