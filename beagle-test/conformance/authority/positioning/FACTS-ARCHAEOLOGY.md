# Code-as-facts archaeology

## Bottom line

The system was real and reached an end-to-end, guarded authoring loop. Beagle could project source into lossless facts, Fram could store and structurally edit those facts, regenerate and check source, and North could provision the sealed MCP capability to an agent. The failure was principally operational rather than one identified semantic error in fact projection: authoring depended on a large, multi-process configuration chain whose failures often looked like an empty graph, a dead coordinator, or absent tools. One known bad corpus made an edit take more than 20 minutes. The default was therefore not flipped on; the write-authority policy was explicitly withdrawn on 2026-08-05 and Beagle source became text-authoritative.

This record keeps that system distinct from the later Beagle Store allocation work. Store Stage 2 and the Stage 3 revision-generation slice are landed, but their adversarial review records three open design items; they are not evidence that the old graph-authoring mode was made dependable.

## Evidence inspected

- Transcript search was run for code as facts, fact store, bgl promote, fact-GC, Phase 3 boundary discovery, and bgl/promote ergonomics, then narrowed with codegraph/graph-authoring terms. The most useful session records are convo session 019f86d7-6557-78a3-8348-11723aeac1af (tool exposure gap) and convo session 1deac7c4-a47f-4292-8a36-43ff18f7ec34 (the 24 protected files and the operational risk assessment).
- Read-only history was inspected in Beagle, Fram, and North. The decisive commit messages below are stronger evidence than retrospective summaries.
- beagle:beagle-test/conformance/authority/positioning/ADVERSARIAL-REVIEW-6-EXTERNAL.md and ALLOCATION-THESIS.md supplied the later Store/arena status. The review explicitly reads landed code and tests at Beagle revision 4f9c6f874157e3e7746e7e5f47c8748260511f25.

## What was built

1. Lossless program-to-facts projection and rendering. Beagle:beagle-lib/private/facts-roundtrip.rkt and bin/beagle facts-roundtrip project a program into a verbose, lossless fact form and render it again. Beagle:bin/test/code-as-facts/README.md records two proofs: datum identity through the real Store and compiler-output identity modulo source-location metadata. The active regression anchors include Beagle commits d2d17698 (real Store gate), 039307d1 (mint/render round-trips), and 768590a0 (current Fram rename proof).

2. A real fact store, not a sidecar map. The round-trip suite sends the facts through the shipped term store. Fram:codegraph/src/*.bclj modules represented source structure, references, renames, jurisdiction, and round-trip behavior; the first graph-native pilot was 2ce51eb0, and the occurrence-store port was 4f5dbf50.

3. Structured, fact-level authoring. Fram:src/fram/tools.bclj exposed top-level upsert, body replacement, rename, insertion, sub-definition replacement, and multi-module atomic edit transactions. The important capability anchors are 34f14525 (replace-in-body, explicitly removing the mega-definition limitation) and 0ae7da66 (atomic transactions). The Beagle scripts bin/test/code-as-facts/{rename,delete,authoring,authoring-verbs}.sh tested the corresponding operations.

4. A one-command activation and a reasoning side. Fram:bin/fram-code-on, fram-code-off, and fram-code-status ingested a source tree, started a code coordinator, wired MCP configuration, and reported the flip level. Commit fbda5281 introduced the flip; 1ce87d9d added the resolved-program/callgraph corpus, so the intended flip covered both authoring and code reasoning.

5. Guarded source authority. The graph-upstream registry plus @upstream:graph markers caused text edits to protected files to be denied. The implementation remains visible in Beagle:integrations/north/hooks/code-upstream-guard.sh and the associated code-as-facts skill, although these are historical/support artifacts, not proof that write mode is currently enabled.

6. Managed agent capability composition. North added a sealed graph-authoring.fram MCP grant with exact tools and tests in North:sdk/src/fram-graph-authoring.ts and North:sdk/test/fram-graph-authoring.test.ts (9791c280). The intent was that a managed lane received the same graph edit surface rather than an unauthenticated local command.

7. Commit-time verification and materialized program views. Fram added a sealed edit verifier, graph-control MCP, and program-inspection reads. Commit 124ff2ea is a useful boundary anchor: it fixed six advertised read tools that were not dispatched and made a committed edit advance the program view read by the next request.

8. Later durable allocation substrate. Beagle Store Stage 2 added branch CAS, watch, reseal, and segment reachability collection; the focussed Stage 3 slice added an authored revision-generation boundary. The review anchors these at Store aggregate a6b42feb, reachability collector 1c5b2d09, and Stage 3 slice 7fa36f95. This was durable-storage/allocation work supporting the broader direction, not a restoration of the old source-authoring default.

## How far it got

By late July, this was beyond a prototype. The project had a lossless projection, live-store round-trip gate, resolver-aware rename and deletion, new-definition and body-authoring verbs, transaction support, a warm code coordinator, reasoning corpus, MCP wiring, a protected-file guard, and managed lane integration. The 2026-07-29 session recorded 24 fact-native files whose text edits were denied in favour of Fram MCP authoring.

The system was nevertheless not a safe global default. Its own operations had to cross the source selector, Store/corpus, daemon, log identity, MCP configuration, provider adapter, managed-lane preflight, and guard/registry seams. The record shows those seams failing independently.

## Observed gaps when it was enabled

1. Reads could falsely say that the graph was empty. Fram-code-on emitted FRAM_CODE_LOG for edits but omitted FRAM_LOG, which normal read verbs used. The result was a silent zero-fact fold, not an error: the same runtime observed 175,462 facts with FRAM_LOG and zero without it. Fixed by Fram a068f67d; before that, an agent had no reliable indication that it was querying the wrong log.

2. The source selector swallowed private scratch and made the loop unusable. A whole-tree glob included docs/private/, including a vendored Beagle recovery dump: 280 inputs instead of 51 real modules. The graph grew to 1,026,707 facts / 264 MiB; one upsert-form --no-commit exceeded 20 minutes before it was killed, while the same action on a 36 MiB clone finished in under a minute. coord_write_def_test also exceeded roughly nine minutes on that checkout. This is the clearest recorded reason development slowed. Fixed by Fram 389a5b39.

3. A granted capability could arrive with no usable tools. Transcript 019f86d7-6557-78a3-8348-11723aeac1af records that a nested graph-authoring session exposed no Fram tool names even though the coordinator was live; another record says North had not mounted the verbs. On Codex, the preflight initially rejected a correct extra Fram server because it demanded an inventory of exactly North, making graph authoring provider-specific. North edca5b75 repaired the sealed-grant/inventory logic.

4. Managed lanes were pointed at impossible or empty endpoints. North hard-coded a port, resolved the code log under a temporary worktree where the ignored .fram/ directory could not exist, and omitted FRAM_LOG and FRAM_THREADS. Thus a lane could show all ten tools but have an empty fallback, nonexistent log, and dead port. North 3f68d53b corrected the roots, log, and port derivation. This is separate from item 1: here the entire managed endpoint was wrong.

5. Moving the repository silently unprotected most of the claimed source. After the container-layout migration, 24 of 25 graph-upstream registry rows named old paths; both realpath and git-provenance matching missed them. The guard no longer enforced the intended source authority. North d669ac31 added a repair that re-adopts only files still carrying the sentinel and retires the rest.

6. Daemon/protocol drift made every graph lane look dead. The lane booted a Fram command that had been removed, and its readiness check spoke old EDN to a binary FRAMRPC v1 service, yielding silence until timeout. The same North d669ac31 repair updated migration, boot, SpaceId, and readiness handling. This is why reports of a dead coordinator could be a launch-contract failure rather than a crashed fact engine.

7. The graph surface was incomplete or stale after a successful edit. Six advertised program-inspection tools fell through to unknown-tool, and the service never set the program corpus, so the materialized view could not advance beyond the last fram-code-on output. Fram 124ff2ea fixed both. The same commit records that adding a third fixture definition pushed a sealed Level-3 preflight beyond its 70-second cap (21/21 to 20/21), another concrete latency warning.

8. Whole-corpus fact projections multiplied work and memory. The wider fact coordinator rebuilt the full EDB/index on every page, stratum, and concurrent cold reader. A 142k-fact corpus made a paged derived relation O(corpus x pages) and concurrent readers reached a 9.15 GiB RSS crash. Fram d3c3b375 added version-keyed single-flight projection caching. This is not a source-projection semantic defect, but it was a fact-platform cost on which the authoring ecosystem depended.

The record is silent on an additional, single compiler-semantic defect that made the authoring model impossible. It does not support blaming recursive fact identity, the source/fact round-trip, or the edit verbs themselves. It also does not give one measured aggregate developer-slowdown number or a single transcript saying shelve it now; the withdrawal commits below are the reliable evidence of the decision.

## Why it slowed development, and why it was shelved

Each source change first depended on the graph corpus being selected correctly, then on a live correctly addressed daemon, a matching read/edit log, a complete MCP grant, current lane roots, and an active registry. Several broken states returned a plausible empty result or a timeout rather than an actionable failure. The guard then prohibited the ordinary text-edit escape hatch exactly when one of those dependencies was unhealthy. Coupling everyday editing to Fram health was explicitly assessed as risky in the 2026-07-29 transcript.

The policy reversal is explicit, not inferred: Fram c1fcfd38 removed @upstream:graph markers and states that source is authoritative; Fram 19a0187b removed graph-upstream enforcement; Beagle 09a363cd made Beagle source text-authoritative. Later cleanup retained only current round-trip paths (52d969b9). The prior default flip was recorded as parked, rather than being restored after the individual fixes.

## Work that was never finished

- A reliable default authoring mode. The protected-file, graph-write path was withdrawn before it became a trustworthy default. Historical test and skill artifacts remain, but they do not establish a live, end-to-end default.
- Complete sealed tool coverage. The August doctor repair deliberately left a Fram-side gap: the service advertised 12 verbs while the guard could mount only five (d669ac31).
- Expansion-fact production integration. EXPFACTS-SPIKE-FINDINGS.md proves a standalone macro-expansion/invalidation probe. It identifies missing macro-definition source identity in production parser registration; that production tap was proposed, not landed.
- Structural survivor promotion. The current bgl/promote copies one complete supported typed value; authors must first build the smaller survivor. No structural projection/fused copy plan shipped. The adversarial review marks this NEEDS-DESIGN (W6-G7).
- General automatic arena-boundary discovery. Stage 3 proves one authored hydration boundary, not inference from arbitrary control flow and durability. The proposed ARENA-BOUNDARY-UNDECIDABLE diagnostic plus bounded explicit fallback is NEEDS-DESIGN (W6-G8).
- A budgeted, scalable fact-GC maintenance path. Stage 2 segment GC is semantically correct and explicit, but decodes every segment for every root, repeats shared-history work, and holds store/control authority. The review measured about 0.85 s / 3.91 s / 8.02 s for 10k / 50k / 100k facts and marks the absent operating budget/cache or incremental mark plan REAL-OPEN-COST (FACT-GC-MAINTENANCE-BUDGET).

## Counts

- Components built: 8.
- Concrete enabled-mode operational gaps: 8.
- Explicit later allocation/design gaps still open: 3.

FACTS-ARCH-DONE components=8 observed_gaps=8 open_design_gaps=3
