# beagle — session anchor

This is the small always-loaded Beagle policy layer. Do not put command,
target, form, type, standard-library, health, or test inventories here: use
`README.md`, `AGENTS.md`, and the compiler as their current sources of truth.

## Route procedures

- Repository edits, commits, landing, and pushes use `repo-safety`.
- Beagle authoring uses `beagle-authoring`; it owns proportional loop health,
  compiler queries and repair, typed syntax, source profiles, and the pinned
  Racket path. There is no unconditional session-start daemon or doctor step.
- Checks and proof claims use `verification`; `AGENTS.md` owns Beagle's local
  gate commands and verdict meanings.
- Facts, Triples, relations, vocabularies, and persisted semantic models use
  `fact-modeling`.

## Semantic laws

1. A sealed, admitted semantic world owns native program meaning. Source files,
   syntax trees, paths, spans, renderings, and emitted artifacts are optional
   projections or transaction proposals, never native authority.
2. Native relations, propositions, modes, strategies, goals, judgments, and
   provenance remain explicit until a checked planner selects an operational
   orientation. Do not erase them into a Lisp application AST first.
3. An oriented executable plan lowers to validated Native Core. Materializers
   execute that typed plan under explicit target and capability constraints;
   they do not reconstruct or redefine meaning.
4. Clojure-derived behavior belongs to an explicit hosted or compatibility
   profile. It may remain useful, but it must not constrain the native semantic
   model, planner, identity rules, or execution protocol.

The current file-first Lisp compiler is transition and bootstrap machinery,
not the architecture to extend for new native semantics. New native work takes
the path `admitted world → checked theory → oriented plan → Native Core` and
keeps content identity, assertion occurrence, world revision, proof, plan,
artifact, and effect receipt distinct.

The eventual bare Beagle surface is reserved for proposition-first native
semantics. Until that default flips, existing bare `.bgl` implementation source
remains supported bootstrap material and must not be treated as semantic design
precedent. Target-specific concepts keep a fixed target prefix; compatibility
profiles remain explicit.

Do not build an uncontrolled logic runtime, runtime operative, or fexpr
evaluator. Search is bounded, modes and determinism are checked, strategy
selection is explained, and every backend implements semantics from typed plans
without runtime `eval` or reified environments.
