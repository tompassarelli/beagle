# 029 — eval-eq harness first run: firnos prediction-outcome

The eval-equivalence harness (committed `574d676`) produced its first
measurement against firnos @ `914251f`. This entry resolves the firnos
half of the prediction logged in 028 against the measured outcome. The
Misterio77 half is pending and will get its own entry — keeping them
separate so each can disagree with the other if remediation between
them changes the interpretation.

The outcome is being recorded **before** any remediation, because the
finding is at maximum clarity at this moment in the timeline. Bundling
outcome with the fix commit would lose the dated-artifact discipline
that makes prediction-outcome a real epistemic claim rather than
post-hoc storytelling.

---

## Prediction (from 028)

> **Headline:** drvPath-eq pass rate, both corpora at ~95%+
>
> **Distribution:** ~80% of failures localize to `with`-resolution
> divergences; rest long-tail
>
> **If headline misses:** byte-residual was correctness bugs
> masquerading as normalization; scope tracking is more central than
> thought, *and* there are likely other correctness gaps in the
> converter not yet identified.

## Outcome (firnos only)

| metric         | value                |
|----------------|----------------------|
| corpus         | firnos @ `914251f`   |
| beagle         | `574d676`            |
| hosts          | 2                    |
| PASS           | 0                    |
| FAIL-DIVERGE   | 0                    |
| FAIL-TWIN-EVAL | 2                    |
| FAIL-ORIG-EVAL | 0                    |

**Headline missed.** 0% pass against a ~95% prediction. The miss is on
the "byte-residual was correctness bugs" branch.

**Distribution prediction not applicable to this measurement.** All
failures are FAIL-TWIN-EVAL — the twin doesn't evaluate at all. The
distribution prediction was about how FAIL-DIVERGE cases would
localize across `with`-resolution vs other shapes. When the twin can't
evaluate, semantic divergence is unreachable; the diagnostic-cmp stub
correctly didn't fire.

## What surfaced

Both hosts produce the same captured eval error:

> error: access to absolute path '/home' is forbidden in pure
> evaluation mode (use '--impure' to override)

The converter resolves relative paths to absolute during conversion:
- source `./modules` → twin `/home/tom/code/nixos-config/modules`
- source `./hosts/X/configuration.nix` → twin
  `/home/tom/code/nixos-config/hosts/X/configuration.nix`
- source `./bundles-darwin` → twin
  `/home/tom/code/nixos-config/bundles-darwin`

This is per-file and pervasive throughout the firnos flake — most files
reference paths relative to their own location, most of those are
converted, most of those then violate pure-mode.

## What byte-id was masking

byte-identity reported firnos at 95.7% clean for the entire converter
project history (~2 weeks). The reason byte-id couldn't see this:
`nix-instantiate --parse` normalizes path literals to absolute during
canonicalization. byte-id was comparing two ASTs that both contained
the same absolute path string — identical at the parse-AST level,
semantically different at eval time.

This sharpens the metric-reframe critique. The original framing was
that byte-identity is sensitive to "paren-normalization and stdlib
emit conventions that don't affect semantics." The bigger principle
now visible: byte-identity is also **blind to semantic-preserving
syntactic normalization that masks real bugs**. Eval-eq surfaced this
on the first measurement.

This is the same class of phenomenon that the metric reframe was
arguing against in general — the right test for a compiler is
semantic-on-the-target, not syntactic-on-the-source. The first real
measurement validated the frame shift on a concrete case.

## Structural-debt note (decision deferred)

The surface fix is likely in `beagle-import-nix`'s path-token handler:
preserve source form instead of resolving paths during conversion. A
small change.

The structural question, speculating from the failure shape rather
than from reading the code: does beagle's IR distinguish **path
literals** (Nix value type, where relative-vs-absolute is a semantic
property) from **path strings** (regular String values)? If the IR
collapses these, the tokenizer reaches for Racket's path normalization
because there's no other layer where the distinction can live, and
the surface fix is a band-aid that will recur:
- on path-typed operations (`builtins.readDir`, `builtins.fetchurl`,
  path interpolation in strings)
- on the JS/Clojure backends if they ever need to reason about path
  semantics

The cheap-vs-structural decision belongs in the remediation entry,
not here. This entry records that the observation exists; the
investigation that informs the decision happens after Misterio77 is
measured.

## What this implies for next steps

1. **Run Misterio77 before remediation.** The current converter state
   is informationally privileged: Misterio77's failure-mode
   distribution at the current state shows which other bugs (if any)
   the path-resolution bug was masking. Fixing first collapses any
   Misterio77 failures that depend on the path bug into pass status,
   destroying signal that can't be recovered.

2. **Cheap-vs-structural decision deferred.** Misterio77 evidence
   informs whether the path-token handler fix is sufficient or
   whether the IR-level path-literal representation is the right
   target. Either way, the remediation entry records the decision
   and the trade-off — including, honestly, whether the cheap fix
   leaves a known structural debt.

3. **Two-entry discipline.** Misterio77 outcome gets its own
   prediction-outcome entry (likely 030). The remediation gets a
   third entry. The discipline that's been working — log the
   prediction, log the outcome against the prediction, keep
   remediation separate — suggests each artifact should be dated and
   independently disagreeable.

## What survived first contact (harness-level)

The FAIL-TWIN-EVAL vs FAIL-DIVERGE category distinction in the
harness was load-bearing on the very first run. The first buggy
iteration of the harness reported "drvPath differs" for what was
actually "twin won't even evaluate" — completely different debug
paths, only one of them actionable for converter work. Without the
distinction the journal would have read as a semantic divergence
finding and the actual signal (evaluability collapse) would have
been buried.

The "evaluator must not realize derivations" invariant docstring is
unused so far — no contributor has had occasion to attempt the
substitution it warns against. Recorded as hygiene against the
future, not because it earned its keep yet.

The diagnostic-cmp stub correctly didn't fire — when twin fails to
evaluate, there's nothing to localize. The decision to leave the leaf
list uncurated until a real failing case demanded it remains right;
pre-curating would have produced leaves that don't match this kind of
failure.

The four-field adapter struct has had no contact with a second
backend yet — the "did the shape survive contact with the second
adapter" prediction stays open until clj/js/py work begins. First
adapter (nix) implemented cleanly against the shape; no friction
during the build that would suggest the abstraction was wrong.

— Claude
