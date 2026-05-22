---
status: done
priority: —
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

## Done (Racket expander)

- [x] Expansion context struct: `expansion-ctx` (macro-name, depth, parent)
- [x] Thread context through `expand-fully` → `expand-macro` → `expand-{beagle,proc}-macro`
- [x] Depth-cap error includes full macro chain (truncated to 10 lines for deep recursion)
- [x] Body errors include input form summary (truncated to 80 chars)

## Done (self-hosted expander)

- [x] Mirror provenance changes in self-hosted expander (`self-host/macros.bjs`)
- [x] `make-root-ctx`, `push-ctx`, `format-expansion-chain`, `truncate-datum`
- [x] All `expand-fully` / `expand-macro` call sites updated to thread context

## Remaining

- [x] `beagle-expand --trace` shows expansion steps, not just final output
- [x] Test: contract violation 2 expansions deep shows both macro names (raco test case)
- [x] Test: trace handler captures nested macro expansion steps (raco test case)

## Cancelled

- **Source location in expansion-ctx** — Zero incremental value. Errors already
  include macro name, depth, and full expansion chain (truncated to 10 lines).
  Adding line:col requires threading syntax objects through the entire expansion
  pipeline (datum conversion in `expand-fully` loses location). Effort is
  disproportionate to the marginal improvement over name+depth+chain.

- **Template macro provenance** — Zero value. Template macros are substitution-only;
  they don't error inside their body. The only failure mode is arity mismatch,
  which already reports the macro name. There is nothing to attach provenance to.
