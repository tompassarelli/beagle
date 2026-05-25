---
status: active
priority: 1
depends-on: —
blocks: nix-discourse-launch
created: 2026-05-25
---

# Typed flake-input access + dockerTools stdlib + nix-ident removal

## Why

The README claims "zero escape hatches." That claim is currently a
slight overstatement. Beagle has a built-in form, `nix-ident`, which
takes a string literal and emits it verbatim into Nix output — the
exact shape an escape hatch takes. It's been hiding under a name that
doesn't have `unsafe` in it.

There are five `(nix-ident ...)` call sites in firnos, all doing the
same thing: dynamic flake-input attribute-path access with
`${pkgs.stdenv.hostPlatform.system}` interpolated. The pattern is
specific and bounded; it deserves a typed primitive.

Plus one unported module (`modules/containers/claude-sandbox.nix`,
`pkgs.dockerTools.buildLayeredImage`) — stdlib gap, not an escape
hatch, but in the same hygiene pass.

After this work lands, the no-escape-hatches claim matches reality.
That's a precondition for the Nix Discourse launch post (next
workstream): the artifact should not invite "actually, what about
nix-ident" responses on first impression.

## Current state — the five `nix-ident` sites

```
modules/firefox/palefox.bnix:8
  (nix-ident "inputs.nur.legacyPackages.${pkgs.stdenv.hostPlatform.system}.repos.rycee.firefox-addons.sidebery")

modules/quickshell/default.bnix:13
  (nix-ident "inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default")

modules/quickshell/default.bnix:17
  (nix-ident "inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default")
  ; nested inside (s ... "/bin/qs") for systemd ExecStart path construction

modules/zen-browser/zen-browser.bnix:5
  (nix-ident "inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default")

modules/gjoa/gjoa.bnix:5
  (nix-ident "inputs.gjoa.packages.${pkgs.stdenv.hostPlatform.system}.gjoa")
```

The shape is identical across all five: `inputs.<flake>.<output-tree>`
where the output tree is either `packages.<system>.X` or
`legacyPackages.<system>.X`. The `<system>` axis is implicit (every
flake follows this convention).

## Proposed surface form

```clojure
(flake-input :flake-name attribute-path-symbol-or-keyword ...)
```

Examples (covering all five sites):

```clojure
; quickshell.packages.${system}.default
(flake-input :quickshell :packages :default)

; nur.legacyPackages.${system}.repos.rycee.firefox-addons.sidebery
(flake-input :nur :legacyPackages :repos :rycee :firefox-addons :sidebery)

; zen-browser.packages.${system}.default
(flake-input :zen-browser :packages :default)

; gjoa.packages.${system}.gjoa
(flake-input :gjoa :packages :gjoa)
```

The first keyword names the flake input; the second names the output
namespace (`:packages` or `:legacyPackages`); the system axis is
implicit and emitted as `${pkgs.stdenv.hostPlatform.system}`;
remaining path segments are appended verbatim.

### Why this shape

- **`:keyword` for flake name and namespace.** Beagle uses
  `:keyword` for symbolic identifiers throughout (`:throwable`
  on defunion, `:where` on defscalar, `:as` on require). The flake
  name is symbolic — not a string literal, not a runtime value —
  so it takes a keyword.
- **System axis collapsed.** All real flake-input access at module
  level uses `<output>.<system>.X`. Exposing the system as a
  parameter every site would have to repeat would add noise without
  catching errors that aren't already caught (the system substitution
  is mechanical and never wrong).
- **Path segments after the namespace are keywords or symbols.** The
  parser accepts both. Mostly keywords for readability; symbols for
  identifiers that already exist as symbols in context.
- **No explicit type annotation on the form.** The result type is
  `NixType` (opaque). The Nix runtime resolves the path; if it
  doesn't exist, that's an eval-time error like raw Nix has today.
  Beagle isn't beating Nix on attribute-path-typo detection in this
  phase.

### Why NOT a schema cache (yet)

A flake-schema-cache analogous to `.beagle-cache/schema.json` for
NixOS would let the checker verify that `quickshell.packages.default`
actually exists at compile time. That's strictly better. It's also
strictly more work, and the cost of skipping it is "compile-time error
becomes eval-time error for one specific bug class that's already
eval-time in raw Nix."

Defer the schema cache. Build it if/when a future user (you or
someone else) hits a real typo-debugging session on a `flake-input`
path. That signal validates the work; building it absent the signal
designs it for hypothetical use.

## Implementation

### Parser (`beagle-lib/private/parse.rkt`)

Add a parse case for `flake-input`. AST node:
`(flake-input-form input-name namespace path-segments src-loc)`.

```racket
[(list 'flake-input (? keyword-sym? input-name)
                    (? keyword-sym? namespace)
                    rest ...)
 (flake-input-form input-name namespace
                   (map ->datum (or (stx-tail subs 3) rest))
                   loc)]
```

Validation: input-name and namespace are keywords; rest segments
are keywords or symbols.

### AST (`beagle-lib/private/ast.rkt`)

```racket
(struct flake-input-form (input-name namespace path-segments) #:transparent)
```

Add to provide list.

### Check (`beagle-lib/private/check.rkt`)

```racket
[(flake-input-form _ _ _) (type-prim 'NixType)]
```

Result type opaque. Future schema-cache version would resolve the
exact type; for now it's `NixType`.

### Emit (`beagle-lib/private/emit-nix.rkt`)

```racket
[(flake-input-form input-name namespace path-segments)
 (define ns-str (symbol->string namespace))
 (define path-str (string-join
                   (map (lambda (s) (symbol->string s))
                        path-segments) "."))
 (format "inputs.~a.~a.${pkgs.stdenv.hostPlatform.system}.~a"
         (symbol->string input-name)
         ns-str
         path-str)]
```

### Drop `nix-ident`

After flake-input lands and the 5 sites migrate, `nix-ident` has zero
legitimate uses. Convert the parser case to an explicit error:

```racket
[(list 'nix-ident _ ...)
 (error 'beagle
   "nix-ident removed — use (flake-input :NAME :NAMESPACE :path ...) for flake-input access. nix-ident was an undocumented escape hatch.")]
```

This is the work that turns the "no escape hatches" claim from
overstatement into truth.

### Tests

Active-tier additions in `beagle-test/tests/`:
- Parse: `(flake-input :quickshell :packages :default)` produces
  `flake-input-form` AST with correct fields.
- Emit: same input produces
  `inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default`.
- Check: result type is `NixType`.
- Parse error: `(nix-ident "...")` errors with migration message.

Add a fixture covering each of the 5 firnos shapes (one per site
pattern) to lock the migration shape in.

### Corpus migration (firnos)

Five hand edits, mechanical:

| File | Before | After |
|---|---|---|
| `modules/firefox/palefox.bnix` | `(nix-ident "inputs.nur.legacyPackages.${pkgs.stdenv.hostPlatform.system}.repos.rycee.firefox-addons.sidebery")` | `(flake-input :nur :legacyPackages :repos :rycee :firefox-addons :sidebery)` |
| `modules/quickshell/default.bnix:13` | `(nix-ident "inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default")` | `(flake-input :quickshell :packages :default)` |
| `modules/quickshell/default.bnix:17` | (same, inside `(s ... "/bin/qs")`) | `(flake-input :quickshell :packages :default)` (string-concat surrounds it; nothing changes structurally) |
| `modules/zen-browser/zen-browser.bnix:5` | `(nix-ident "inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default")` | `(flake-input :zen-browser :packages :default)` |
| `modules/gjoa/gjoa.bnix:5` | `(nix-ident "inputs.gjoa.packages.${pkgs.stdenv.hostPlatform.system}.gjoa")` | `(flake-input :gjoa :packages :gjoa)` |

Then `firn-build`, `firn-validate`, `nix build --no-link` to verify
no emit regression.

## dockerTools coverage

Add to `beagle-lib/private/stdlib-nix.rkt`:

```racket
;; pkgs.dockerTools — image-building derivations
(hash-set! catalog 'pkgs.dockerTools.buildLayeredImage
  (fn-of '(NixType) 'NixType))
(hash-set! catalog 'pkgs.dockerTools.buildImage
  (fn-of '(NixType) 'NixType))
(hash-set! catalog 'pkgs.dockerTools.pullImage
  (fn-of '(NixType) 'NixType))
(hash-set! catalog 'pkgs.dockerTools.streamLayeredImage
  (fn-of '(NixType) 'NixType))
```

Each takes a single attrset (typed as `NixType` since the attrset
structure is dockerTools-specific and complex) and returns a
derivation (also `NixType`). Same opacity story as `flake-input`:
the Nix runtime validates the attrset shape; beagle isn't catching
attrset-key typos in this phase.

If a future user hits real typo-debugging pain on dockerTools
attrsets, the answer is a dedicated typed-record (`Defrecord
DockerImage` etc.) and an emit-level shape — same trigger as the
schema-cache decision above.

### Port `claude-sandbox.nix` → `claude-sandbox.bnix`

The file is a function `{ pkgs }: pkgs.dockerTools.buildLayeredImage
{...}` that evaluates to a derivation, not a NixOS module. That's a
different shape from every other file in `modules/` (all of which are
modules). Two options:

**Option 1: leave as a derivation file, give it a .bnix wrapper.**
The .bnix exports a function returning the derivation. Closest to
the existing shape.

```clojure
#lang beagle/nix
(ns containers.claude-sandbox)

(fn [(pkgs : Any)] : NixType
  (pkgs.dockerTools.buildLayeredImage
    {:name "claude-sandbox"
     :tag "latest"
     :contents (with pkgs [bashInteractive coreutils gnused ...])
     :extraCommands (ms "mkdir -p home/dev/.claude" ...)
     :config {:Env [...]
              :WorkingDir "/work"
              :User "dev"}}))
```

**Option 2: make it a real module that conditionally exposes the
image.** Adds the module-system overhead but matches the rest of
the directory. Probably overkill for a single image.

Recommendation: Option 1. The directory `containers/` is a natural
place for non-module derivations; one file with a function shape
isn't worth the bundle plumbing.

## Sequencing within this plan

1. Add `flake-input-form` to AST + parse case + check case + emit-nix case.
2. Add parse-error for `nix-ident` (migration message).
3. Add tests covering all 4 cases + parse error for `nix-ident`.
4. Run `bin/beagle-test` — should be green except the 5 firnos sites
   (which beagle's tests don't see directly; firnos validation happens
   separately).
5. Migrate the 5 firnos sites by hand. Run `cd ~/code/nixos-config &&
   firn-build && firn-validate && nix build .#nixosConfigurations.whiterabbit --no-link`.
6. Add dockerTools stdlib entries.
7. Port `claude-sandbox.nix` → `claude-sandbox.bnix`.
8. Re-run firnos validation.
9. Update README's "no escape hatches" claim to match reality — remove
   any hedge language; the claim is now true.
10. Update CLAUDE.md's no-escape-hatches block similarly.
11. Commit + push beagle changes. Commit + push firnos changes.

## Expected outcome

- Zero `nix-ident` call sites in firnos.
- Zero raw .nix files in `modules/`.
- One typed surface form (`flake-input`) covering the entire
  flake-input-attribute-path pattern.
- README "no escape hatches" claim now reflects code reality.
- dockerTools available in stdlib-nix; image-building works in .bnix.

After this lands, the Nix Discourse launch (separate workstream) has
no skeleton in the closet around the no-escape-hatches claim.

## Time estimate

Evening — maybe two depending on how thorough the test coverage is.

Surface change: 1 new form (`flake-input`), 1 removed form (`nix-ident`),
4 stdlib entries (dockerTools.*). Migration: 5 corpus sites + 1 file port.

## What this does NOT do (deferred)

- **Flake-schema cache.** Punted; build if usage validates need.
- **Typed dockerTools attrsets.** Punted; same trigger.
- **Other escape-hatch audits.** This sweep is specifically the
  `nix-ident` / flake-input pattern. If other escape-hatch-by-other-name
  forms exist in beagle (I haven't found any), they need their own
  sweep.

## What this unblocks

`nix-discourse-launch.md` (next workstream): the public artifact +
post that needs the no-escape-hatches claim to be true rather than
mostly-true.
