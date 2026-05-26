# 030 — eval-eq harness Misterio77 first run: prediction-outcome

Companion to 029. Resolves the Misterio77 half of 028's prediction
against the measured outcome, before any remediation. Captured at
beagle `c3b955d` (post the `--accept-flake-config` + orig-stderr-
capture harness fixes that were prerequisites to getting a real
Misterio77 measurement), corpus pinned at `e2de142`.

Two harness gaps surfaced before the substantive measurement landed —
both worth naming because they speak to whether the harness is honest
about what it's measuring:

1. Untrusted-substituter eval failures had been masquerading as
   FAIL-ORIG-EVAL when the actual cause was nix refusing to trust the
   flake's declared `nixConfig.extra-substituters`. Fixed by adding
   `--accept-flake-config`. Trust boundary is consistent: corpus is
   already pinned by commit + flake.lock, so trusting its nixConfig
   is the same scope.
2. FAIL-ORIG-EVAL was reporting host names without the captured
   stderr — opposite shape to FAIL-TWIN-EVAL which did. The error IS
   the signal for that category; capturing it is hygiene, not a
   feature.

Both fixes landed before the run that produced this entry. The earlier
failed-iteration artifact was discarded — only the post-fix
measurement is durable.

---

## Prediction (from 028, applicable to Misterio77 specifically)

> **Headline:** drvPath-eq pass rate, both corpora at ~95%+
>
> **Distribution:** ~80% of failures localize to `with`-resolution
> divergences; rest long-tail
>
> **If headline misses:** byte-residual was correctness bugs
> masquerading as normalization; scope tracking is more central than
> thought, *and* there are likely other correctness gaps in the
> converter not yet identified.

## Outcome

| metric         | value                |
|----------------|----------------------|
| corpus         | Misterio77 @ `e2de142` |
| beagle         | `c3b955d`            |
| hosts          | 7                    |
| PASS           | 0                    |
| FAIL-DIVERGE   | 0                    |
| FAIL-TWIN-EVAL | 7                    |
| FAIL-ORIG-EVAL | 0                    |

**Headline missed.** 0% pass against ~95% predicted. Same branch as
firnos: "byte-residual was correctness bugs masquerading as
normalization." Same direction, sharper magnitude — Misterio77 was the
externally-meaningful corpus, and the prediction missed there
identically.

**Distribution prediction still not applicable.** Same shape as firnos:
all failures are FAIL-TWIN-EVAL — the twin doesn't evaluate. The
diagnostic-cmp stub correctly didn't fire.

## What surfaced — universality of the path-resolution bug

All 7 hosts produce the **same** captured eval error, originating at
`flake.nix:201`:

> error: access to absolute path '/tmp' is forbidden in pure
> evaluation mode (use '--impure' to override)

The exact line in the twin's flake.nix:

```
packages = forEachSystem (pkgs: import /tmp/nix-config/pkgs { ... })
```

The original source had `import ./pkgs`. The converter, running with
the source at `/tmp/nix-config/flake.nix`, resolved `./pkgs` against
that source location and baked `/tmp/nix-config/pkgs` into the IR.
The emitter then wrote the absolute path verbatim into the twin's
flake.nix.

Comparing the two corpora confirms the mechanism:

| corpus      | source location                        | twin error           |
|-------------|----------------------------------------|----------------------|
| firnos      | `/home/tom/code/nixos-config`          | `'/home'` forbidden  |
| Misterio77  | `/tmp/nix-config`                      | `'/tmp'` forbidden   |

The absolute-path prefix tracks the source corpus location — confirming
the resolution happens during `beagle-import-nix` against the source
file's directory, not during emit and not against the twin's location.
The IR holds an absolute path; the emitter is faithfully writing what
the IR contains. The structural-debt observation from 029 (IR's
representation of path literals) is now confirmed mechanism, not
speculation.

## A sharper version of the "byte-id was masking" finding

byte-identity for Misterio77 was at 82.8% clean. Those 82.8% were
"clean" against the **same source-tree absolute paths** present in
both sides of the comparison — because `nix-instantiate --parse`
canonicalizes path literals against the file's location, and that's
the same for source and twin (which the byte-id harness builds in a
work directory but compares via per-file normalization, not whole-tree
context).

If Misterio77 were moved to `/home/user/foo/`, byte-id's pass rate
would not budge — but the absolute paths in the twin would change to
`/home/user/foo/...` and would still pass-through byte-id's
parse-normalization. The metric was **structurally incapable** of
detecting this class of bug. Not "insensitive to it" — incapable, by
construction.

This generalizes: any class of correctness bug where the converter
loses information that nix's parser-level canonicalization happens to
fold away is invisible to byte-id. Path resolution is the visible
instance; whether others exist is open.

## What the "run before fix" strategy bought

The cost was one Misterio77 run (~5 min including substituter fetches
on first eval). The benefit is more uneven than I anticipated when
defending the strategy:

- **Confirmed:** universality of the path-resolution bug. Same shape,
  every host, both corpora. The cheap-fix question now has a clear
  scope: this is one bug, not a class hiding behind a class.
- **Confirmed:** the mechanism (resolution at convert-time against
  source location, baked into IR, faithfully emitted).
- **Did not surface:** any other failure mode. Every host stops at
  the same flake.nix:201 import, so anything downstream of that line
  is invisible.

The third point is the constraint on what "characterizing failure-mode
distribution at current state" could deliver. Once the converter
crashes the twin at line 201 of flake.nix, no other potential
converter bug downstream of that line gets a chance to manifest. If
remediation lands cleanly and the next run shows fresh failure modes,
that's signal that more bugs were hiding behind this one — exactly
the scenario where the run-before-fix strategy *would* have been
informationally privileged, but only after the fix.

The pragmatic re-read: the run-before-fix discipline still paid for
itself by confirming universality and the mechanism on the first
measurement of the third-party corpus. The richer signal (other
failure modes) is now provably waiting to be discovered post-fix.

## What this implies for next steps

1. **Remediation entry next.** The cheap-vs-structural fix decision
   moves out of "deferred" into "deciding now." Misterio77 evidence
   doesn't disambiguate — both corpora show the same path-resolution
   bug at the same severity. The IR-representation question still
   carries forward as the structural shape; the cheap fix in
   `beagle-import-nix`'s path-token handler is sufficient *for this
   specific bug*, but the underlying "does the IR distinguish path
   literals from path strings" question remains open.
2. **Post-fix re-measurement is mandatory.** Both corpora get a third
   eval-eq run after remediation, with predictions logged before the
   run. The new prediction is constrained by what the universal-bug
   finding ruled out: predicting ~95% pass post-fix is now naive,
   because the converter has been silently mis-emitting paths for
   the project's entire history, so other bugs likely lurk
   downstream of the line we couldn't see past.
3. **Two-entry discipline holds.** The remediation entry (when it
   lands) is distinct from this outcome entry. If the fix turns out
   to be more invasive than predicted, or if it surfaces
   second-order bugs, that's the remediation entry's problem to
   record honestly. This entry stays as the dated artifact of
   "where the converter was on the day before the fix."

## What survived first contact (harness-level)

The FAIL-ORIG-EVAL category did its job in the first iteration: the
substituter-trust issue was correctly reported as "corpus/env
problem" rather than misattributed to the converter. The harness fix
was about *enrichment* of the diagnostic, not correction of the
category.

The `--accept-flake-config` change is the kind of thing that wants
revisiting whenever a new external corpus is added — different flakes
have different `nixConfig` declarations, and the trust boundary may
not always be the same. For now: one corpus needed it, the rule
landed, the rule continues to apply because the trust boundary
argument generalizes (a pinned corpus already implies trust of its
declared config).

The four-field adapter struct survived another round of harness
evolution. No friction during the edits; the changes were additive
(error capture, flag addition) rather than structural.

— Claude
