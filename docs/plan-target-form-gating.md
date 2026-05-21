# Plan: target-form gating

Enforce the portability boundary at check time. Target-specific forms
(`await` for JS, `inh`/`fn-set`/etc. for Nix) currently parse and
type-check on any target, then blow up at emit time with generic errors.
The stdlib side already has `stdlib-for-target` / `target-excludes-for`.
Forms need the same discipline.

## 1. Add `TARGET-ONLY-FORMS` registry in `private/check.rkt`

After `current-check-target` (line 40), add a hash mapping AST predicates
to their required target:

```racket
(define TARGET-ONLY-FORMS
  (hash
   await-form?              'js
   nix-inherit?             'nix
   nix-inherit-from?        'nix
   nix-with?                'nix
   nix-rec-attrs?           'nix
   nix-assert?              'nix
   nix-get-or?              'nix
   nix-has-attr?            'nix
   nix-search-path?         'nix
   nix-interpolated-string? 'nix
   nix-multiline-string?    'nix
   nix-path?                'nix
   nix-fn-set?              'nix
   nix-pipe?                'nix
   nix-impl?                'nix))
```

## 2. Add `check-target-form` validation function

Map each predicate to its user-facing form name. Error format:

```
"inh is only supported in beagle/nix (current target: clj) at file.bgl:42"
```

Form names: `await`, `inh`, `inh-from`, `with-do`, `rec-att`, `assert-do`,
`get-or`, `has`, `spath`, `s`, `ms`, `p`, `fn-set`, `pipe-to/pipe-from`, `impl`.

## 3. Call `check-target-form` from `infer-expr`

Add `(check-target-form e)` as the first line of `infer-expr`, before the
`cond` dispatch. Every expression gets checked; wrong-target forms error
before any type inference runs.

## 4. Fix `emit-nix.rkt` silent `await` handling

Line 359-361 currently emits the inner expression silently. Change to:

```racket
[(await-form? e)
 (error 'beagle-nix "await is only supported in beagle/js")]
```

With step 3 this is unreachable in normal flow, but it's the correct
safety net.

## 5. Tests in `tests/check.rkt`

Cross-target rejection tests (~8-10):

- `(await ...)` in `beagle/clj` → error `"await is only supported in beagle/js"`
- `(await ...)` in `beagle/nix` → same
- `(inh x y)` in `beagle/clj` → error `"inh is only supported in beagle/nix"`
- `(inh x y)` in `beagle/js` → same
- `(fn-set ...)` in `beagle/clj` → error
- `(pipe-to ...)` in `beagle/js` → error
- `(with-do ...)` in `beagle/clj` → error
- `(s "hello" x)` in `beagle/js` → error

Verify existing happy-path tests still pass: `raco test tests/`

## 6. Add portability rule to `CLAUDE.md`

After "Design decisions", before "Setup". ~25 lines covering:

- The one-line rule: portable if Beagle owns the concept, target-specific
  if the host owns it
- Decision procedure (4 questions: ownership, honest lowering, desugaring,
  absurdity test)
- Enforcement pointers (`TARGET-ONLY-FORMS` in check.rkt,
  `stdlib-for-target` in stdlib-types.rkt)
- Table of current target-specific forms

## What NOT to do

- Don't move parsing to per-target modules. Global parse is fine; gate at check time.
- Don't use warnings. Hard errors only.
- Don't refactor emitter `else` branches — check-time gating makes them unreachable.
- Don't touch `stdlib-types.rkt` — that system already works.

## Run order

1. `check.rkt` — registry + validation + call from `infer-expr`
2. `emit-nix.rkt` — fix await
3. `tests/check.rkt` — rejection tests
4. `raco test tests/` — full suite
5. `CLAUDE.md` — portability rule section
