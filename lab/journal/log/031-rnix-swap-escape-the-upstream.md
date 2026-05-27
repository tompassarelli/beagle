# 031 — bnix converter: swap nix-instantiate for rnix-parser

The converter is now at 100% semantic correctness on both test corpora
(9/9 hosts: 7 Misterio77 + 2 firnos, all DIVERGE-but-equivalent except
one firnos PASS). Up from 7/9 (78%) at the previous session boundary.
The work that moved the needle was a single structural change: stop
using `nix-instantiate --parse` to normalize source, start using
`rnix-parser` (a lossless Nix parser, via a small Rust binary) to
parse it instead.

This entry records the decision, the result, and the methodological
lesson — because the lesson is the part most likely to compound on
future work and the part most easily forgotten.

---

## Where we were

`beagle-import-nix` had been built on `nix-instantiate --parse`: take
the source, pipe it through nix's own parser, get back a normalized
form, tokenize and re-parse that normalized form into beagle's IR.
The appeal was simplicity — nix-instantiate handles all the messy
parts (operator precedence, comments, string-vs-multi-line-string,
etc.) and what we get back is single-line, fully-parenthesized,
semantically equivalent Nix.

The problem turned out to be the word "semantically equivalent."
nix-instantiate's normalization is **lossy at the source level** in
ways that matter for round-trip:

- `2.0` becomes `2` (fractional part stripped). Breaks NixOS options
  expecting floats (monitor scale, etc.).
- `"${X}"` becomes bare `X` (string-context wrapper stripped). Changes
  semantics on non-string values (paths→store, drvs→outPath, numbers
  →toString).
- `./pkgs` becomes `/abs/path/pkgs` (relative paths resolved against
  source-file dir). Breaks pure-mode eval in the twin, which can't
  reference absolute paths outside the store.

Each loss prompted a source-pre-processing workaround:

1. `encode-floats` — walk source, swap float literals for marker
   strings `"__BNIX_FLOAT_X_Y__"`, run nix-instantiate, recognize
   the markers in the output and emit as floats. (~80 lines.)
2. `path->source-relative` + `current-source-dir` parameter — track
   the source dir during conversion, restore absolute paths to
   `./X` / `../X` form on emit. (~30 lines.)
3. `"${X}"` preservation — *not implemented*. The blocker for the
   last 2/9 hosts at session boundary. Would have required
   tokenizing source while tracking string-context state (single-line,
   multi-line, antiquote nesting, comments) and stashing markers
   around bare interpolations.

The pattern by session end: each marker workaround had non-trivial
edge cases (`192.168.1.1` looks like a float in source; paths
that can't be relativized; comments inside string-with-interp). The
next workaround was going to be harder than the last.

## The decision

Two options on the table:

1. **Continue with markers.** Implement `"${X}"` preservation as a
   source pre-process. 1-2 more sessions, then probably the next
   pattern shows up.
2. **Switch to rnix-parser.** Replace nix-instantiate with a
   production-grade lossless parser. ~1 day.

I argued for rnix; user greenlit. The case was: rnix-parser is
actively maintained by the nil LSP / nixpkgs-fmt / statix teams,
tracks Nix language evolution, used in production tooling. The
converter is peripheral infrastructure (one-way ingestion); the
runtime path doesn't depend on it. Outsourcing the parser is exactly
the kind of "buy" that buys real engineering time vs writing our
own lexer/lossless-parser (months, then maintenance forever).

Build vs buy on a one-way tool: buy.

## What landed

`tools/nix-parse-json/` — a small Rust crate (rnix 0.11 + rowan 0.15)
that takes a `.nix` file path on argv and emits an S-expression AST
on stdout. The S-expr shape matches what beagle-import-nix's old
parser produced, so the Racket-side emit code stays unchanged in its
core. Racket's `read` deserializes the output directly.

The Racket-side changes were larger than I expected, but
structurally simpler than the marker workarounds they replaced:

- `~600 lines deleted` — tokenizer, recursive-descent parser,
  string-literal reader, interp-substring parser, float-marker round-
  trip, path-restoration logic, find-nix-instantiate binary lookup.
- `~50 lines added` — find-nix-parse-json binary lookup, subprocess
  call + `read`, denormalize-binding helper to nest dotted paths with
  problem segments.
- Net: −600 lines. Smaller surface, fewer code paths, no more
  workaround-stack to extend on the next loss discovery.

The Rust binary itself is ~600 lines, but that's owned by a
maintained upstream (rnix) wrapped in a thin shim. The maintenance
profile is "track rnix's minor versions and a small set of API
surface."

## What rnix preserved that nix-instantiate lost

Verified on test fixtures + harness re-run:

- Floats: `2.0` stays `2.0`. `192.168.1.1` (string) stays a string.
- String interpolation context: `"${pkgs.foo}"` stays `"${pkgs.foo}"`
  — the wrapper is preserved as a `str-interp` node with one part.
- Paths: `./pkgs`, `../shared/x`, `/etc/nixos/abs.nix` all preserved
  verbatim from source.
- Identifiers with `'`: `mapAttrs'`, `mapAttrs''`, etc., survive
  intact via `|...|` bar-quoting in the S-expr (Racket's reader
  splits at apostrophe otherwise — that detail cost me 30 minutes).

The interp-payload shape changed from raw substring to full sub-AST.
Three Racket-side call sites that previously re-tokenized the
substring now call `emit-expr` on the AST directly. Cleaner.

## What surfaced — beagle compiler bugs

The structural fix exposed beagle compiler bugs that were previously
masked by nix-instantiate's normalization:

1. **`:dotted.key {(inherit a b)}` emits as
   `dotted.key.${inherit a b;} = false;`.** The inner inherit-only
   attrset is mis-parsed as a dynamic-key marker. Pre-existing bug;
   surfaced because rnix preserves the user's dotted-key form rather
   than desugaring it to nested attrsets like nix-instantiate did.
2. **`target."non-ident-string"` reader-splits.** beagle's reader
   tokenizes `target.` followed by `"string"` as two forms; the
   intended dotted access with a quoted segment doesn't work.

Both bugs are real and pre-existing; both are worked around in the
converter (`denormalize-binding` desugars problem paths to nested
attrsets; `emit-select` switches to `builtins.getAttr` for non-ident
keys). The workarounds are debt receipts — they belong in the
language eventually, not the converter — but they're isolated and
don't block anything.

The pattern is worth noting: nix-instantiate's lossy normalization
was *also* masking beagle compiler bugs. The rnix swap didn't create
new bugs; it stopped hiding existing ones. This is a useful corollary
to "lossy upstream is a maintenance graveyard" — lossy upstream is
also a *diagnostic graveyard*. The losses don't just cost correctness;
they cost visibility.

## The generalizable lesson

When patching a lossy upstream becomes a maintenance loop with a
shrinking marginal-fix size and an expanding workaround surface,
the fix is to **escape the category to a lossless upstream**, not
to add another workaround.

Diagnostic that the loop is the wrong loop:

- Each workaround addresses one specific loss.
- The workarounds compose (one is in the source pre-process, another
  in the post-parse normalization, another in the emit layer).
- New losses keep being discovered — not because the upstream is
  broken, but because *of the upstream's design*. Normalization is
  the *purpose* of the upstream tool, not an accident.
- Workarounds start needing each other's edge cases (the float-marker
  has to coexist with string-content recognition; the path-restoration
  has to coexist with the source-dir parameter being propagated
  through the whole call stack).

When you see that pattern, the upstream is wrong for the use case.
Find a lossless alternative or build one. The conversion is one-way
ingestion infrastructure; the choice of upstream is reversible — once.
After enough workarounds accrete, ripping them out becomes a
multi-session migration. Sooner is cheaper than later.

The flip side that justified deferring this for a few sessions:
each individual workaround was small and the next one always looked
small. The "this is a maintenance graveyard" recognition is hard to
have on the inside of the loop. Useful external check: am I writing
markers that need to coexist with other markers? If yes, the loop is
the wrong loop.

## What this implies for next steps

The converter has crossed the "provably correct on two real corpora"
threshold. Continued hardening against synthetic additional corpora
has diminishing returns vs the real signal from public-launch
exposure — which is gated on `typed-flake-inputs.md` closing the
last escape hatch. That's next.

The two beagle compiler bugs surfaced here (`:dotted.key {(inherit
...)}` and `target."non-ident"` reader-split) are filed-as-known but
deferred — the converter workarounds isolate them, and language-
level fixes can sequence after the launch lands. Cyclone self-host
remains priority 1 in the queue but sequences after launch.

— Claude
