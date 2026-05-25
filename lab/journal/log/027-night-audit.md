# 027 — Night audit: the rest of the morning-report deferred list

Continuation pass on the deferred items from
`026-surface-redesign-morning-report.md`. The morning report flagged
six items as "didn't land tonight, need more thought." This is the
follow-up pass that resolves each. Three drops/cleanups happened;
three audits ended in "no drop — these are distinct concepts."

Tests green throughout: 1183 active-tier (down 7 from 1190 baseline,
all 7 from removed `deftype` fixtures and test cases). Demoted-tier
debt counter advanced by 6 entries (deftype-pattern behavioral tests
in `emit-clj-behavioral.rkt`).

---

## What landed

### Drop: `deftype`

The shaped surface change: bundling data-shape declaration and
protocol-impl attachment into one form. The decomposition into
`(defrecord Name [fields])` + `(extend-type Name Protocol (method
...))` is the canonical idiom — two distinct concepts, two distinct
forms. Same logic that kept `cond` distinct from `match`.

Corpus survey: 0 production uses, 4 fixture uses, 5 demoted-tier
behavioral test uses (now logged in `lab/surface-debt.md`). The
"category 4 — bundles two concepts" classification from
design-principle.md applies.

Migration error:
```
beagle: deftype removed — use (defrecord Name [fields]) for the data
shape and (extend-type Name Protocol (method ...)) for protocol impls
```

### Cleanup: stale examples directory

Three example files in `examples/` were profoundly out of date,
documenting surface that has been gone for months:

- `examples/full.rkt` — `Long` instead of `Int`, `(unsafe ...)` inline
  escape, `define-macro unsafe`, `when` form
- `examples/hello.rkt` — `Long` instead of `Int`, `cond` shape but
  using old type names
- `examples/macros.rkt` — `define-macro unsafe`, comments documenting
  the dropped `safe`/`unsafe` distinction

All three deleted. Remaining examples (`demo.bclj`, `nix-*.bnix`) are
current. The `unsafe` macro kind has been parser-rejected since the
"all template macros are now type-checked end-to-end" change; these
example files weren't tested in CI, so the surface error was invisible
until this audit grepped for it.

### Documentation: CLAUDE.md

Multiple stale references corrected:

- Macros line at top: `safe/unsafe/procedural` → `safe template +
  procedural with typed AST contracts; no unsafe kind`
- `macros.rkt` description: `template macros (safe/unsafe)` → `safe
  kind only; unsafe rejected at registration`
- Confident-decisions table: "Safe / unsafe macro distinction" →
  "Template macros are always type-checked end-to-end" (with a note
  on the 2026-05 change)
- Dropped-forms section: added `deftype`, `when`, `when-let`,
  `if-let`, `dotimes`, `case`, `(:keyword target)`, `unsafe` macro
  kind. Each with one-line rationale and replacement.
- Kept-after-audit list: added `->>` (low-usage but canonical for
  threading concept), `cond` (distinct from match), `do`
  (multi-expression sequencing). Also added an "audited and confirmed
  as distinct concepts" subsection for the nth/get, for/doseq/map,
  and record-vs-map-vs-JS-interop audits — these were flagged as
  "redundancy" in the morning report but the post-audit verdict was
  "three concepts, three forms."
- Lint warnings list: removed `(unsafe-{js,clj,py,nix,rkt} "...")
  inline escape` (those are parse-time errors now, not warnings)

### Plan update: surface-redesign-sequence.md

Status snapshot added at top. Step 9 (`when-let`/`if-let`) marked done
with reversal-rationale: the "blocked on nil-semantics" verdict was
itself the trap — keeping the names around as a placeholder risks the
typed form inheriting them. Drop now + name-reuse-prohibition message
in the parse error solves that.

---

## What was audited and NOT dropped

These were flagged as "needs audit" in the morning report. The audit
verdict is "distinct concepts, not redundancy." Each gets a row in the
CLAUDE.md "audited and confirmed as distinct concepts" subsection so
future sessions don't re-audit the same questions.

### `nth` vs `get` (vec indexing audit)

Morning report claim: "still has 3 forms (`nth`, `get`, fn-call)."

Corpus reality:
- `nth`: 523 callsites — positional-int into vector
- `get`: 2313 callsites — keyed lookup on map (string or keyword keys)
- vec-as-fn call: doesn't exist in beagle. The grep "false positives"
  in the morning-report investigation turned out to be JS interop
  strings like `"new Set([" ... "])"`.

Two forms for two concepts. Same predictability test as `cond` vs
`match`: each form has a distinct shape that signals its dispatch
mechanism. Keep both.

### `for` vs `doseq` vs `map`/`filter`/`reduce` (sequence processing audit)

Morning report claim: "still has 3 forms (for / threading /
let-chain)."

Corpus reality:
- `for`: 19 callsites — collection comprehension (yields a sequence)
- `doseq`: 4 callsites — side-effect iteration (returns nil)
- `->>`: 1 callsite — threading
- `map`/`filter`/`reduce`: 210 callsites combined — higher-order
  function pipeline (typically inside let-bindings)

The morning report was conflating "three forms" when the actual
concepts are:
- Comprehension that yields (`for`)
- Side-effect iteration (`doseq`)
- Higher-order function pipeline (`map`/`filter`/`reduce`)
- Threading (`->>` — keeps it nominally separate even at 1 usage,
  because it's the canonical form in its concept space)

Four distinct concepts. The "redundancy" was an illusion driven by
the surface friction of "many ways to write a pipeline" — but the
ways aren't equivalent. Keep all.

### `unsafe` macro kind

Morning report claim: "Should be dropped per CLAUDE.md zero-escape
hatches."

Audit reality: already dropped. The parser's `register-macro!`
rejects any kind that isn't `'safe` with an explicit message:

```
macro NAME: kind must be 'safe (escape-hatch 'unsafe kind has been
removed — all template macros are now type-checked end-to-end)
```

The morning report missed this because the `unsafe` shape still
appeared in stale example files (`examples/full.rkt`,
`examples/macros.rkt`). Those files are now deleted; the only
remaining references to `unsafe` macro kind are the two tests that
verify the parser rejection (`beagle-test/tests/parse.rkt:213-215`
and `beagle-test/tests/emit.rkt:97-101`), which is the correct
shape — negative tests of dropped surface.

CLAUDE.md updated to reflect that the `unsafe` macro kind is gone,
not just discouraged.

---

## Test impact

Active tier:
```
1190 → 1183 (-7 from removed deftype tests + fixtures)
```

Demoted tier (NOT FIXED per tiering discipline, logged to
surface-debt.md):
```
+6 failures in emit-clj-behavioral.rkt (deftype-pattern tests).
emit-js-behavioral.rkt unchanged (it errored on deftype already).
```

Surface-debt counter: 11 → 17.

---

## Pattern that emerged from this audit

The morning report's "3 forms for X" diagnostics overestimated
redundancy because the diagnostician was confusing similar-shaped
forms with semantically-equivalent forms. This is the same trap noted
in the morning report itself (the "meta-learning" section). The audit
ratio for this pass:

| Verdict | Count |
|---|---|
| Drop (was actually redundant or escape-hatch shape) | 2 (`deftype`, `unsafe` macro kind — though the latter was a parser-already-done discovery, not a new drop) |
| Keep (distinct concepts despite surface similarity) | 3 audits (`nth` vs `get`, sequence-processing trio, record-access trio confirmed from morning report) |
| Cleanup (stale corpus, not surface) | 1 (`examples/` cleanup) |

The pattern: when the friction-list says "3 ways to do X," the
correct first question is "are these all doing the same X, or are
they doing 3 different Xs that happen to look similar?" Often it's
the latter.

This is consistent with morning report's reversed verdicts on
`loop`/`recur` (not redundant with named-let — named-let doesn't
exist) and `->Name` (not redundant with bare-constructor — bare
constructor doesn't exist). Pattern: empirical audit reverses
theoretical-redundancy diagnoses more often than it confirms them.

---

## What's left from the morning report

Of the original 6 "deferred" items:

| Item | Verdict |
|---|---|
| 1. Record field access (3 forms) | Resolved earlier (0b10115 dropped `(:foo m)`; remaining `(field r)` and `(.-field obj)` are distinct concepts). |
| 2. Sequence processing (3 forms) | Audited: 4 forms but 4 concepts. No drop. |
| 3. Vec indexing (3 forms) | Audited: 2 forms (nth, get), 2 concepts. No drop. |
| 4. `deferror` vs `defunion #:throwable` | Resolved (7058bcf merged into defunion). |
| 5. `deftype` vs `defrecord` | **Resolved this pass: deftype dropped.** |
| 6. Macro DSL audit | `unsafe` kind discovered to be already-dropped. `proc` and `beagle` kinds kept — `proc` is in active use, `beagle` is dormant with HOLD-WHY note. Full audit blocked on Cyclone self-host per surface-redesign-sequence.md step 10. |

All six items addressed. The surface is now in the state the morning
report was working toward: tight, no escape hatches, distinct
concepts have distinct forms, redundancy is removed where redundancy
actually existed.

---

## Recommendation for next session

The surface work for this cycle is at a natural endpoint. The
remaining "open" surface decisions are blocked on external
prerequisites:

- **Nil-semantics design** (drives the typed nullable-narrowing form
  that replaces interim `(let [x v] (if x ...))` patterns)
- **Cyclone self-host Phase 0** (runtime library + emit-scheme
  rewrite — blocks macro-DSL final audit per
  surface-redesign-sequence step 10)

Either of those could be the next-cycle target. The morning report
nominated Cyclone Phase 0 as the architectural high-value move. That
recommendation still stands, with the surface redesign now actually
done rather than "mostly done with deferred items."

Worktree clean. Tests green. Plans updated.

— Claude
