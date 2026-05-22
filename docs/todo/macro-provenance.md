---
status: active
priority: 2
---

# Macro expander provenance

Thread source location and expansion context through the macro expander
so errors past the contract boundary carry useful diagnostics.

## Problem

The contract boundary (input/output type checking on `define-macro`)
reports well: macro name, parameter position, expected vs actual type.
Past that boundary — inside expansion, at depth, in recursive macros —
it's `raise` with a bare string. Specific gaps:

- Depth-64 recursion cap: no macro name, no input form in error
- Body errors: macro name but no source location, no expansion chain
- `beagle-expand` halts at first error with no partial output
- One test covers macro error messages

## Why now

The self-hosted expander (`self-host/macros.bjs`) and the Racket
expander (`private/macros.rkt`) both lack provenance threading.
Retrofitting gets harder as more code depends on current expander
internals. Better to land this before more proc macros are written.

## Design sketch

- [ ] Expansion context struct: `{macro-name, source-loc, parent-ctx, depth}`
- [ ] Thread context through `expand-macros` / `apply-macro` / `macro-eval`
- [ ] Depth-cap error includes macro name + chain: "in foo, called from bar at line 12"
- [ ] Body errors include input form summary (first ~80 chars)
- [ ] `beagle-expand --trace` shows expansion steps, not just final output
- [ ] Mirror changes in both Racket and self-hosted expanders

## Validation

- [ ] Test: recursive macro hitting depth cap shows full chain
- [ ] Test: contract violation 2 expansions deep shows both macro names
- [ ] Test: `beagle-expand --trace` on nested macro shows intermediate forms
