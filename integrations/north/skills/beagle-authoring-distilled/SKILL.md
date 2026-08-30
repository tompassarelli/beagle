---
name: beagle-authoring-distilled
description: >-
  Use whenever writing, editing, or debugging Beagle source in any project:
  files with a current Beagle extension (`beagle langs --view extensions`),
  files beginning with `#lang beagle`, or anything under ~/code/beagle.
  Establishes proportional authoring-loop health, typed-Lisp semantic
  leverage, strict foreign boundaries, compiler-first repair, canonical typed
  syntax, and the pinned Racket route for cold bootstrap or direct `.rkt`
  maintenance. For primarily relational code analysis, use codegraph instead.
---

# Beagle authoring

Read the checkout's `AGENTS.md`; use its source and compiler, not remembered
syntax, profiles, targets, or standard-library inventories, as authority.
Query the live profile registry with `beagle langs --json` and
`beagle langs --view extensions` before choosing a source profile or extension.

## Minimum workflow

1. Do not manufacture a pre-edit ritual. Use an existing green signal or let
   the first applicable compiler or hook result establish loop health.
2. After each edit, read the PostToolUse result. Fix syntax before types and
   let `beagle syntax` diagnose delimiters; never count them manually.
3. Use the narrowest compiler query or check. Format with `beagle fmt --write`,
   then prove layout with `beagle fmt --check`.
4. Run the nearest existing relevant check once and report the observed result.

## Semantic leverage

Before settling any non-trivial Beagle change, perform a lightweight leverage
audit. Map repeated semantic cases, parallel authorities, expected next-change
sites, and target variation; seek the strongest typed-Lisp abstraction that
materially reduces them versus a direct host-language implementation. In the
handoff, name the concrete before/after result: semantic cases removed, one
authority replacing parallel cases, change sites reduced, or one source
abstraction serving multiple targets. If no candidate improves that baseline
without violating the safeguards below, keep explicit source and report the
comparison; never manufacture a macro to satisfy the audit.

Optimize semantic compression, not visible macro count. A hygienic macro,
explicitly typed combinator, or data-driven form earns its place only when it
eliminates structural duplication or a class of code while preserving explicit
types, hygienic binding, source-located diagnostics, inspectable deterministic
expansion with meaningful names, backend-neutral typed IR, and bounded compiler
and runtime cost. Reject code golf, phase magic, hidden effects, opaque
generated names, gratuitous embedded DSLs, and expansions harder to reason
about than the repeated source.

Count the relevant baseline and result so the evidence can support an honest
maintainability comparison. Never claim a multiplier, including 10x, without a
measured, reproducible comparison.

Diagnose concrete infrastructure failure once with `beagle doctor --deep`; use
`--revive` only for a diagnosed daemon failure. Source rejection is feedback.

Treat emitted host code as generated output, not source authority. A required
typed boundary that Beagle cannot express is upstream compiler work, not a
blocker. The current Beagle work owner owns reproducing the gap, repairing and
landing the upstream compiler support, and re-running the dependent task. If
that run's enforced repository, path, or topology authority cannot include the
repair, it must escalate the exact gap to its accountable parent. The parent
must obtain acknowledgment from a concrete compiler-repair owner and remains
accountable for resuming the dependent work. A gap report without acknowledged
repair ownership and an exact resume condition is not completion. Pause only
work that depends on the missing capability; unrelated authoring continues. Do
not evade a compiler gap with source reshaping, generated patches, target glue,
raw passthrough, escape hatches, or hypothetical compatibility.

Keep semantics in typed Beagle over normalized Store triples. Limit host code to
cold bootstrap and irreducible OS/foreign edges. When the owner controls
greenfield domain logic, raw host code is not a workaround: implement that logic
in the appropriate typed Beagle profile and repair any missing compiler support
upstream.

## Typed boundaries and migrations

Quarantine `Any` at irreducible dynamic edges. Validate or decode each foreign
value once at ingress, immediately return an explicit Beagle type, and never
default a domain type to `Any` or propagate it inward. If Beagle cannot express
or check the required result, repair the compiler or import tooling rather than
widening the program.

For JVM/Clojure-hosted work, decode foreign values into explicit Beagle records,
unions, collections, and options before domain code consumes them. Drive
repeated Clojure migrations through deterministic parser-, compiler-, or
schema-backed conversion that emits reviewable typed Beagle; use AI only for an
explicitly identified residual ambiguity, never as the conversion mechanism.

For JavaScript/TypeScript-hosted work, treat published declarations and schemas
as versioned foreign inputs. Transform them into Beagle-native types while
preserving representable unions, optionals, nullability, enums, records, and
generics. Regenerate when the pinned input changes; never maintain a host shape
and its Beagle mirror by hand.

Use pinned Racket only for bootstrap verification or `.rkt` maintenance after
reading its procedure completely.

For command selection, profile details, syntax examples, and the pinned Racket
procedure, resolve and read `agents path beagle-authoring-reference`.
