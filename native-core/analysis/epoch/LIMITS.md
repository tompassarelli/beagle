# affordance.clj v2 — honest limits (delta over the phase-1 base, appended below)

Everything in the phase-1 base (second half of this file) still applies
unless amended below. The
conservatism direction is unchanged: when unsure the analyzer says ESCAPES,
never INTERIOR. Gate: all 12 phase-1 fixtures plus 8 v2 fixtures pass
(20/20) before any corpus use; the v1 analyzer fails every v2 fixture on
exactly the machinery it tests.

## Defect fixes (phase-1 report §4/§6.1)

1. **Hole 1 closed — swap! updater returns.** Any tracked store-builtin call
   node (swap!/reset!/compare-and-set!) now applies the atom-store rule
   before being treated as an expression value, so callback-collected
   updater returns are connected to the cell (`step` interception). The
   site-assembly special case is deleted — the engine rule subsumes it.
   Corpus check: store.bgl:205/:217 now ESCAPES/stored (v1: INTERIOR).
2. **Builtin tables**: `spit` consume-only (scalar table), `slurp` fresh,
   `fact`/`text-id` fresh (the let-bound fixture-builder lambdas in
   native/lower.bclj; they hit the builtin fallthrough only when no defn of
   that name is in scope — a same-named defn still resolves as :defn first).
   Risk: any future let-bound `fact`/`text-id` lambda that RETAINS its
   argument would be missed; these two names are vouched for by hand.
3. **Field-sensitive record taint (log_codec re-taint).** A value entering a
   record ctor at arg i is tagged with that field; accessor/kw reads of a
   DIFFERENT field no longer re-taint. The tag survives only value-preserving
   moves (binding uses, branches, value positions, recur carry, call-site
   re-entry, with-target) and is stripped to whole-value taint everywhere
   else, so suppression is exact and everything else stays conservative.
   Param summaries remain field-INsensitive. Corpus check:
   log_codec.bgl:537/:538 now INTERIOR (v1: ESCAPES via container re-taint).
4. **Summary default.** Every (defn,param) is explicitly seeded before the
   fixpoint (:interior named / :unknown unnamed); `summary-of` on a MISSING
   key now defaults to :escapes (out-of-universe = unsound to assume
   interior). Fixpoint cap raised 50 -> 500 with a stderr warning on
   non-convergence instead of silent under-approximation.

## Boundary v2

5. **Detector V — fram-vocabulary brackets.** Open/close defn pairs by
   vocabulary shape in one module: `open-X!`/`close-X!` (also unbanged) and
   `open`/`commit!`. A defn reaching BOTH members through direct calls or
   ONE level of callee is a store-generation-scope (whole-defn region).
   Found without seeding: fram.store/open-fold!…close-fold!,
   open-fold-state…close-fold-state, fram.txn/open…commit! (through the
   schema.bgl wrapper), fram.rotation/open-bucket-build…close-bucket-build.
   Limits: whole-defn approximation (same as detectors B/bracket); bracket
   chains deeper than one callee level are missed (log_codec's
   open-at-388/close-in-successful-boot! family); pair members themselves
   are excluded from being scopes.
6. **Dispatch-entry vocabulary.** A defn whose name carries the dispatch
   vocabulary (dispatch*/handle*/serve*/commit-*) taking a `*Request`-typed
   param and returning a `*Response`-typed result is a
   request-dispatch-scope root even when its discriminant cond is not
   keyword-shaped. Type-shape only — no flow proof that the cond dispatches.
7. **Caller-ownership attribution (class-none).** A defn with no root, no
   ownership, and no generation scope inherits its callers' epochs: the flow
   region becomes the union of every DIRECT caller's defn-level region plus
   the defn itself; the boundary is labeled by the dominant caller (most
   call sites, deterministic tie-break). One level only — caller regions
   come from the boundary model/generation scopes, never from another
   attribution. Region union can only remove spurious escapes, never add
   interior claims the flow does not prove: a value that still leaves a
   caller's region escapes exactly as before (fixture 16). Module-level
   call sites remain outside every region. Class-none survivors are defns
   with no callers (or only module-level/self callers).
   Note the honest side effect seen on fram-store-kernel: v1 credited a
   shared helper's own return as a boundary "crossing"; v2 traces the value
   into the callers, where much of it is stored into the store atom —
   crossing counts DROP where v1 was flattering.

## Retaining-type classifier (replaces rollup.clj's defn-name regex)

8. Every ESCAPES site reports `retainingType` + `identity`:
   - retainingType = the record the value most recently entered (ctor walk,
     the flow engine's `held` label), else the declared `(Atom T)` contents
     annotation for atom stores, else the boundary root's declared return
     type for crossing escapes, else the module def's annotation, else null.
     `held` is best-effort: it survives callee `:returns` summaries and
     collections, and is a LABEL ONLY — verdicts never depend on it.
   - identity = domain | incidental | unknown per the type table emitted in
     every report under `classifier`: domain iff a base type is a
     record/union declared in a domain namespace (fram.types/txn/store/
     query/rotation/datalog/schema, native.core/stages, any ns ending
     `.types`), or a frozen-stage/stage-value record, or a curated stage
     product (C11Artifact, QbeArtifact, SliceMaterializedV0, SliceFactV0,
     SliceProjectionV0, TermGraphV0, ObligationVerdictV0, C11Materialization)
     — minus bookkeeping-named records
     (error|diagnostic|refused|measure|replayresult|loadresult|framesresult|control).
     Scalars and known non-domain records are incidental; unresolved types
     are unknown (never guessed). Direction: unknown is common on
     "escapes via callee" routes where no retaining structure was observed —
     report it as unknown, do not impute.
9. The adversarial fixture (18) pins the failure mode the phase-1 audit
   caught: a decode/generation/frame-named defn whose escape retains into an
   (Atom (Vec Int)) cursor must read incidental; the old regexes read domain.

## Verification run (v2)

- 20/20 fixtures (12 phase-1 verbatim + 8 new), graded structurally with
  retaining_type/identity checks added to the grade surface.
- v1 analyzer run on the 8 new fixtures fails each on the intended axis
  (v1-*.json reports in the phase-1 measurement archive).
- Corpus spot-checks (not a full re-run): fram-store-kernel (Hole-1 twins
  flip to ESCAPES/stored, retaining (Atom t/TermStore) domain; 10
  generation scopes vs 1 in all of phase 1), fram-codecs (interior 10 -> 25;
  log_codec atoms flip to INTERIOR), native.slice (spit family flips to
  INTERIOR; interior+crossing 64.4% -> 69.9%). The full-corpus re-run and
  rollup replacement are the next lane, gated behind this fixture gate.

---

# Base: affordance.clj phase-1 — honest limits

Companion to `affordance.clj` (the v2 delta above amends this base).
The analyzer is a pure fold over `bin/beagle-ast` JSON: it never executes
analyzed code. Its conservatism direction is fixed: **when unsure it says
ESCAPES (route `unknown`), never INTERIOR** — every rule below states which
side of that line it errs on.

## Verdict semantics

- `INTERIOR` — the analyzer traced every syntactic flow of the site's value
  inside the boundary region and found no path that returns it past the
  boundary, stores it into anything binding-visible outside, or captures it
  in a closure that could outlive the boundary.
- `ESCAPES` + `crossing: true` (route `returned`) — the value leaves through
  the boundary's OWN crossing set as defined by the boundary rules: the
  boundary root's return value, a loop's recur-carried accumulator or loop
  result, a callback's collected return. These are the escapes the
  hypothesis legitimizes (domain identities).
- `ESCAPES` + `crossing: false` — stored into a non-local atom / module def,
  captured, passed to a callee whose summary escapes, raised inside an
  error, or any flow the analyzer could not classify (`unknown`).
- `PROMOTED` + `crossing: true` — the fixtures-manifest's promotion verdict:
  the value crosses its allocating boundary through that boundary's OWN
  crossing set yet is provably interior to the enclosing defn-level
  boundary. Two detected shapes: (a) a legitimized structural crossing
  (loop back edge / loop result / callback collection) whose value the
  defn-level flow then proves interior — the site is re-flowed at the
  defn-level boundary and reported against it; (b) an INTERIOR defn-region
  flow that crossed an owned non-root defn's return (phase A returns, the
  driver consumes). `escapesFrom` names what was crossed (the allocating
  defn when the return was crossed, else the structural boundary).
  PROMOTED sites count in `boundaryCrossing`/`interiorOrCrossingRate`, not
  in `interior` — reports generated before this verdict existed folded
  shape (b) into INTERIOR (native.stages: 50 interior + 2 crossing then,
  39 interior + 11 promoted + 2 crossing now; same 100% combined).

## Soundness caveats (ways INTERIOR could still be wrong)

1. **No alias tracking through container reads.** A tracked value stored
   into container C is modeled as "C is tainted"; reads (`get`/`nth`/
   `first`/accessors/`kw-access`) on a tainted container re-taint the
   result, which covers re-extraction. But a value stored into container C
   in one binding and extracted through a DIFFERENT untracked alias of C
   established *before* the store (e.g. two let-names for the same
   collection) is missed. Beagle Core's persistent-value semantics makes
   pre-store aliases observationally immune to the store (updates copy), so
   this is believed not to produce false INTERIOR for `.bgl`; for hosted
   `.bclj` with mutable host interop it could.
2. **Fresh-copy builtin table.** Text/codec ops (`str`, `subs`, `pr-str`,
   `str/*`, `utf8-*`, `sha256-bytes`) are treated as producing fresh storage
   that does not reference their arguments. Justified by the taxonomy
   (TextConcat/TextSlice/ValueToText/TextBuiltin/CodecPrimitive copy into
   the arena; core.bclj:668 — no interior borrow). If a future lowering
   introduces borrowing text slices, these become unsound.
3. **Scalar-builtin table.** Predicates/arithmetic/printers are assumed not
   to retain arguments. `println` is assumed to render, not retain.
4. **Loop recur into shadowed names** and sequential-let rebinding are
   handled; `match` clause bodies are over-approximated (uses in ALL clause
   bodies are considered, not just the matching clause) — errs to ESCAPES.
5. **Exceptions:** values reaching `ex-info`/`throw` are ESCAPES
   (route `returned`, crossing false — "carried by a raised error"). `try`
   nodes are walked conservatively (`unsupported-try` catch bodies flow to
   the try value).
6. **Capture at fn-rooted use scopes.** A binding whose only visible-use
   root is itself a non-callback `fn` node (the closure IS the let body,
   e.g. `(let [row ...] (fn [i] (nth row i)))`) is route `captured`; the
   between-use-and-root walk alone would miss the root fn and fall through
   to `unknown`. Same ESCAPES verdict either way — this is a route-label
   precision fix, found by the golden-fixture gate (fixture 05).

## Precision caveats (ways ESCAPES/unknown over-fires)

1. **Callee spellings not in the builtin tables** make their argument
   positions ESCAPES/unknown. The analyzer prints every unclassified
   spelling with counts to stderr per run — inspect that list before
   trusting an item's escape numbers. Host interop (`method-call`,
   `static-call`) is always ESCAPES/unknown.
2. **Param summaries** are per-(defn,param) with a 3-point lattice
   (interior < returns < escapes): a callee that returns its argument only
   under one branch still poisons all call sites with `returns`; a callee
   that stores one element of a vector poisons the whole argument.
   Variadic/destructured params are `unknown`.
3. **Indirect calls** (empty callee spelling) are ESCAPES/unknown; in the
   Core dialect the native lowering refuses them anyway.
4. **Set-equality temporaries** (`= s1 s2`) are only recognized when an
   argument is a set literal or a ref whose *annotation* is `(Set _)` —
   unannotated set-typed bindings are missed (site under-count, not a false
   verdict).

## Boundary-detection approximations

1. **Ownership ("D and its callees").** A defn F belongs to boundary root
   R's region iff every direct caller of F is R or a defn already owned by
   R (module-level call sites break ownership). Shared helpers
   (`canonical-record`, `error-response` shapes) stay class `none` — their
   sites are judged against the single defn only, so class-`none` `returned`
   escapes may in truth be interior to every caller's boundary. This
   under-claims, never over-claims.
2. **Dispatch scopes** are found by keyword-discriminant conds anywhere in
   the defn body (the written rule's spine-descent generalized: real
   dispatchers nest the keyword cond under guard clauses). The handler set
   is spine-end calls of keyword clauses that pass the discriminant's
   underlying param; handlers are seeded into the dispatch region even when
   they have other callers — sound for verdicts (escape checks are
   flow-based, not ownership-based) but the class label can attribute a
   shared response-constructor to one dispatch root.
3. **Stage functions**: the three-step type-shape rule is implemented in
   full (frozen-stage records, stage-value records, result unions carrying
   frozen stages). Stage DRIVERS use a weaker rule than written: "calls >= 2
   distinct stage functions" without checking that stage k's accessor feeds
   stage k+1's argument.
4. **Generation scopes**: detector A (counter bracket) marks only the
   let-bindings strictly between paired counter reads as the region —
   flow leaving those bindings is ESCAPES even when it dies later in the
   same defn (conservative). Detector B (session fork) and the paired
   open/close bracket detector mark the WHOLE defn (approximation noted in
   each report's `boundaries.generationScopes.why`).
5. **Module entrypoints** are public defns with in-degree 0 *relative to
   the item + its dependency closure*. An item whose callers live outside
   that closure (e.g. `types.bgl` accessors in a kernel-only item) shows
   more entrypoints than the whole-program truth.
6. A defn qualifying for several classes is labeled by precedence:
   generation > dispatch > stage > entrypoint.

## Scope limits

1. **Taxonomy-only site enumeration.** Only the 29-construct taxonomy is
   enumerated. Hosted-dialect (`.bclj`) allocators outside it (`merge`,
   `update`, `group-by`, `hash-map`, lazy seqs, `cons`, host interop) are
   NOT sites — they still participate in flow (flow-through/unknown).
   `record-box-into-recursive-union` is type-driven with no syntactic node
   and is not enumerated. `(vec v)` of a vector is identity at lowering but
   still counted (`allocates: "always"` per taxonomy entry).
2. **Conditional constructs** (`reduce`/`reduce-kv` temporaries, `swap!`
   updates, set equality) carry `allocates: "conditional"`; the summary's
   `alwaysAllocating` block excludes them.
3. **Program universe = manifest item files (`--ast`) + require-closure
   context (`--context`,** resolved only into `~/code/fram/main/src/**` and
   `~/code/beagle/main/native-core/src/native/**`). Context modules resolve
   calls and contribute param summaries and in-degree, but their own sites
   are not reported.

## Line numbers are best-effort

`bin/beagle-ast` emits no source locations (the src table is only attached
to js-quote nodes in `beagle-lib/private/ast-json.rkt`), so `file:line` is
reconstructed textually: the defn's start line is found by name, then the
site's callee token (or `#{`/`{` for set/map literals) is matched by ordinal
within the defn's line range on comment/string-stripped text.
`lineConfidence` per site: `token` (ordinal match), `token-first` /
`anchor` (first occurrence / nearest named ancestor — may be a nearby line),
`defn-start` (vector literals and other unanchored sites fall back to the
defn's first line). Threading macros (`->`) reorder pre-order vs text order
and can shift ordinals by one or two lines. Verdicts and boundaries never
depend on line numbers; only the `site` label does.

## Other

- `=`-discriminant dispatch tests, counter reads and canonical argument
  matching resolve refs through let bindings by name with a depth cap of 6.
- The flow engine has an 8000-step budget per site; exhaustion reports
  ESCAPES/unknown ("flow budget exceeded").
- The param-summary fixpoint is monotone over a finite lattice and runs to
  stability (cap 50 iterations).
- Verification run: probe.bgl (8 sites hand-checked — all 8 verdicts
  correct), native.stages (52 sites; the two ESCAPES are exactly the
  canonical-encoding string and the content digest — the stage identities;
  sorted temporaries and byte accumulators verify INTERIOR by hand),
  socket-byte-sink (both sites hand-checked: module-def frame vector
  ESCAPES/stored; the codec bytes handle consumed by
  `host.socket/write-bounded` is INTERIOR).
- Known honest outliers in the full run: `native.obligations` reads 14.6%
  interior+crossing because 252 of its 295 sites are top-level `def` test
  fixtures (module lifetime by construction, class `module-def`);
  `fram-*` items report low bare-interior but high crossing because fram
  allocates almost exclusively into the values its boundaries exist to
  produce (RpcResponse trees, triples, loop accumulators).
