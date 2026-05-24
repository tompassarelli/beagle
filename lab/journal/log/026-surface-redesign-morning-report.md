# 026 — Morning report: surface redesign night

Hey Tom — here's where things stand.

**TL;DR**: Surface redesign landed but smaller than originally scoped.
The bigger architectural insight is the SRFI/runtime-library realization
for Cyclone self-host — that should reshape the next phase. Tests
green at 1387 (was 1401; net -14, all from deleted tests for dropped
forms). No broken state; everything is shippable.

The honest version: I didn't do a transformational redesign. I did a
careful audit, dropped what had no defenders, and deferred what needed
more deliberation than overnight allows. You may want to push harder
on the deferred items in a follow-up session — they're real but they
need a separate energy budget.

---

## What landed

### Surface drops (parser, stdlib, tests, corpus all updated)

| Form | Why dropped |
|---|---|
| `defmulti` / `defmethod` | 0 corpus usage outside one fixture. Use defprotocol + extend-type instead. |
| `as->` / `cond->` / `cond->>` / `some->` / `some->>` | 0 corpus usage. Threading-macro family narrowed from 5 to 2. |
| `when-not` / `if-not` | Sugar; 2 lines of corpus usage. Use `(when (not c))` / `(if (not c) t e)`. |
| `inc` / `dec` | Sugar over `(+ x 1)` / `(- x 1)`. |
| `not=` | Sugar over `(not (= a b))`. |

### Drops I started then reversed (empirical data overruled the plan)

- **`loop` / `recur`**: Day 0 task 4 showed I reach for it reflexively.
  That's the *canonical* signal, not a redundancy signal. Beagle's
  `let` doesn't support named-let, so there was no actual duplication
  to remove. Adding named-let just to drop loop/recur would have
  *added* idiom count.
- **`->Name` constructor**: I assumed bare `(Name args)` was supported
  too (which would make it a 2-idiom situation). Audit showed beagle
  only supports `(->Name args)`. No redundancy to drop.

### What didn't land (deferred to future passes)

These were on the Day 0 friction list but need more thought + more
migration cost than overnight allowed:

1. **Record field access** still has 3 forms (`(field r)`, `(:field r)`,
   `(.-field r)`). Picking one canonical would touch ~100 files. Real
   friction in Day 0 task 1.
2. **Sequence processing** still has 3 forms (for / threading /
   let-chain). Picking one canonical for the filter+map+reduce case
   needs empirical data on usage patterns first.
3. **Vec indexing** still has 3 forms (`nth` / `get` / fn-call). Same
   pattern.
4. **`deferror` vs `defunion #:throwable`**: structurally identical,
   should unify but the migration is non-trivial.
5. **`deftype` vs `defrecord`**: deftype is "record with protocol
   impls"; if always paired with defrecord+extend-type, could combine.
   Needs usage audit.
6. **Macro DSL**: 3 kinds (`safe`/`unsafe`/`beagle`). `unsafe` should
   go per CLAUDE.md's "zero escape hatches" principle but the macro
   system warrants its own audit.

---

## The big architectural insight

Mid-session you (well, the relay-agent you used as oracle) flagged
that emit-scheme.rkt was about to make a wrong architectural call:
emitting raw Scheme primitives means user programs depend on Cyclone's
SRFI ecosystem directly. The right shape is **beagle's stdlib as the
abstraction boundary**: users reach for `first`/`count`/`empty?`,
beagle's runtime library (implemented in beagle, compiled to Cyclone)
provides those names, the runtime handles SRFI navigation once.

This reframes the Cyclone self-host plan. I added a **Phase 0:
runtime library** that blocks Phase 1 (emit-scheme). The
emit-scheme.rkt I wrote earlier in the session is now noted as a
sketch that needs rewriting against the runtime architecture.

This is a more important shift than the surface drops. It changes
beagle from "compiles to Scheme" (which exposes ecosystem mess) to
"compiles to a beagle runtime hosted on Cyclone" (which hides it).
That's the difference between "yet another typed Lisp emitting
Scheme" and "self-hosted typed authoring language with a stable
substrate boundary."

Plan updated: `lab/plans/cyclone-self-host.md` now starts with Phase 0.

---

## State of the repo

### Tests

```
1401 → 1387 (-14)
```

The -14 is exactly the count of tests for forms I dropped (defmulti
parse/emit/check, as-> parse, when-not/if-not parse, when-not/if-not
emit, the defmethod-ok fixture). Everything else passes.

### Commits (in order)

1. `surface-redesign: Day 0 observation pass complete` — friction
   data + verdicts
2. `surface-redesign Phase 2: drop redundant/zero-usage forms` —
   parser/stdlib/test changes
3. `surface-redesign Phase 3: migrate corpus to new surface` — 6
   fixtures + self-host/parse.bjs

### Worktree state

Clean. All changes committed.

### emit-scheme.rkt status

Disabled in `beagle-lib/private/emit.rkt` (commented out require).
The file exists but produces raw-Scheme calls which is the wrong
architecture per the SRFI insight. Don't ship it as-is. Rewrite
after the runtime-library Phase 0 lands.

---

## What needs your call before resuming

### 1. Cyclone runtime architecture (Phase 0)

The big one. Do you agree with the "beagle stdlib as abstraction
boundary" framing? If yes, the next session's work is:
- Write `beagle-lib/runtime/base.bgl` (beagle source for stdlib)
- Bootstrap path: Racket-beagle compiles base.bgl → Scheme, ship
  the output as `runtime/base.scm`
- Rewrite emit-scheme.rkt to call into `(beagle base)` not raw Scheme

This is a multi-day push. Decide whether to commit to it or whether
Cyclone self-host is now lower priority than other things on the
roadmap.

### 2. The deferred surface items

Six items deferred (listed above). Do you want a follow-up surface
session to tackle them, or are they "fine as they are; bigger fish
to fry"? I lean toward: do them once-and-done in a focused 2-3 day
push *before* the Cyclone work begins. The whole point of
"the surface you self-host into is the surface you have for years"
suggests not leaving these as bloat.

### 3. The unsafe macro kind

Should be dropped per CLAUDE.md's "zero escape hatches" principle.
Quick win. I didn't tackle it tonight because the macro system warrants
its own audit and I didn't want to half-do it. Want me to do the drop
in isolation, or hold for the full macro-system audit?

### 4. The .bgl extension default

Earlier in the session we decided `.bgl` should default to Cyclone
Scheme (since that's beagle's native runtime). I implemented this
then reverted it because emit-scheme isn't ready. So right now `.bgl`
is still "target-neutral, defaults to Clojure." When Cyclone runtime
ships, flip the default. Documented in
`beagle-lib/private/extensions.rkt`.

---

## Empirical verification (added post-hoc)

After writing the spec I authored two representative tasks under the
new surface to confirm friction reduction is real:

**Conditional pipeline (Day 0 task 5):**
```clj
(defn build-request [(token : String) (agent : String) (json? : Bool)]
                    : (Map Keyword String)
  (let [base {}
        with-auth (if (= token "") base
                    (assoc base :Authorization (str "Bearer " token)))
        with-agent (if (= agent "") with-auth
                     (assoc with-auth :User-Agent agent))
        with-json (if json?
                    (assoc with-agent :Content-Type "application/json")
                    with-agent)]
    with-json))
```
Zero internal "should I use cond->?" debate — the form doesn't exist.
The let-chain IS the canonical. Compiles cleanly. **Friction win
confirmed.**

**Recursive sum (Day 0 task 4):**
```clj
(defn sum-to [(n : Int)] : Int
  (loop [i 0 acc 0]
    (if (>= i n) acc (recur (+ i 1) (+ acc i)))))
```
Identical to Day 0 (loop/recur kept). No friction change. **Reversal
verdict confirmed.**

## The meta-learning (worth more than the surface drops)

Empirical re-evaluation overruled the theoretical Day 0 verdicts in
multiple places. Pattern emerged: the Day 0 friction list often
identified "3 idioms for 1 concept" when the reality was "3 idioms
for 3 related-but-distinct concepts."

Cases where the diagnostic was wrong:

- **`loop`/`recur` vs named-let**: I claimed redundancy. Reality:
  beagle doesn't support named-let; `loop`/`recur` is the singular
  canonical. No redundancy.

- **`->Name` vs `Name` constructor**: I claimed redundancy. Reality:
  beagle only supports `->Name`. No redundancy.

- **Record field access (3 forms)**: I claimed redundancy:
  `(field r)`, `(:field r)`, `(.-field r)`. Reality (audited
  after surface work): these are *3 different concepts*:
  - `(field r)` = beagle-record auto-accessor (typed against record)
  - `(:field r)` = beagle-map keyword-as-fn (typed against map)
  - `(.-field r)` = JS-interop property access (357 occurrences,
    heavily used in self-host)
  No redundancy. Picking "one canonical" would conflate distinct
  semantics.

So the surface is tighter than the friction list suggested. The
*actual* cleanup was small (zero-usage drops + small sugar drops).
The friction Day 0 captured was real but mostly came from me confusing
related concepts mid-authoring, not from genuine surface redundancy.

**Implication for future surface passes**: empirical verification has
to come *before* committing to drops. Theoretical "this looks like
redundancy" can mislead in three different ways:
1. The form is the singular canonical with no alternative (loop/recur).
2. The forms address different concepts despite looking similar (field
   access).
3. The form has zero usage and theoretically-equivalent alternatives,
   so dropping is genuinely safe (multimethods, as->/cond->/some->).

The third case is the only "real" drop. The first two are protected
by the "agent reaches for it reflexively" test or by reading what
the form actually does in context.

This is the conservative-cleanup result: small but principled. A
more ambitious redesign would need: type-aware tooling for the
field-access kind of question (lint that knows record vs map),
empirical usage data on which forms are reflexive vs taught, and a
willingness to do the "3 concepts → 1 form + 1 macro for the others"
kind of redesign which is multi-day work.

## One subtle gotcha worth flagging

Dropped stdlib aliases (inc/dec/not=) don't get an explicit lint
warning at parse time. The parser doesn't reject them; the type
checker just doesn't have signatures for them. Emission produces the
call literally (`(inc 5)` → `(inc 5)`). For Clojure target this still
works at runtime (Clojure has `inc` natively); for Scheme/Cyclone
target it would fail at the target's compile step.

So the "drop" is *documented* but not *enforced*. An agent that types
`(inc 5)` gets no immediate feedback in a Clojure-targeted file. To
fully enforce, we'd need lint to warn on "call to function not in
beagle's stdlib for the current target." That's a small follow-up,
worth doing before agents lean on it.

## What I'd recommend

1. **Skim this report.** Confirm or push back on the conservative-cleanup
   call vs the transformational-redesign expectation.
2. **Bless or reject the SRFI/runtime-library insight.** This affects
   the entire Cyclone trajectory. Worth your judgment.
3. **Decide the deferred-items follow-up.** Do them now-ish in a
   focused session, or defer until they prove painful.
4. **Then resume Cyclone self-host** starting from Phase 0 (runtime
   library), not Phase 1 (emit-scheme).

If you want me to push further tonight rather than stopping here, the
highest-value next moves are (in order):
- Drop `unsafe` macro kind (quick, isolated, principled)
- Unify `deferror` → `defunion #:throwable` (medium, mechanical)
- Start `beagle-lib/runtime/base.bgl` (long, ambitious — would need to
  span into tomorrow)

I went head-down rather than spending the night on the transformational
redesign because the empirical data showed the surface was tighter than
the initial diagnostic suggested. Honest call on my part; you may want
to push harder. Either way, current state is committed and ships clean.

Sleep well. Tests green. Plans updated. Worktree clean.

— Claude
