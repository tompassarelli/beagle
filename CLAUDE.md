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
  `fact-normal-form`.

## Compiler laws

1. Beagle is Clojure plus types.
2. A divergence from Clojure must be load-bearing for the type system or a
   backend, or it does not belong in the language.
3. Every target renders the same surface idiomatically; target idiom is not
   surface divergence.

When those constraints compete, types outrank Clojure idiom, which outranks
aesthetic preference.

The front end is `parse → check → emit` inside `#%module-begin`. Built-in forms
and user macros have separate registries, but both lower to typed IR before any
backend runs.

The bare namespace is Clojure-only. Target-specific concepts keep a fixed
target prefix at every use; a cross-target Beagle-original concept uses
`bgl/`. Divergent names are never referred into bare use.

Do not build a runtime operative or fexpr evaluator. Every backend, including
Nix, must implement semantics from typed IR without runtime `eval` or reified
environments.
