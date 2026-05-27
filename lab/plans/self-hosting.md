---
status: done
priority: —
---

# Self-hosting (JS/Bun PoC): beagle compiles itself, runs on Bun

**This plan is the JS/Bun proof-of-concept self-host. It is NOT the
production end state — that is `cyclone-self-host.md` (Cyclone Scheme,
Racket-free).**

## What's done

**Complete as of v0.13.0.** 12 components, ~12K lines, bootstrap
fixed-point proven, 11/11 Heist emission parity (byte-identical).

The self-hosted compiler lives in `self-host/*.bjs` — beagle source
files written in `#lang beagle/js`. They compile to JS, and a Bun
runtime runs the compiled compiler. See `self-host/build.sh` and
`self-host/verify-bootstrap.sh`.

## Relationship to cyclone-self-host.md

The JS/Bun self-host proved bootstrap closure works (compiler can
compile itself). The production destination switches the runtime from
Bun to **Cyclone Scheme**:

- Long-term, the planned default target for `.bgl` (currently Clojure)
  becomes `beagle/scheme` (Cyclone).
- `self-host/*.bjs` modules will be ported to `.bgl` (Cyclone) per
  Phase 2 of `cyclone-self-host.md`.
- Once Cyclone-beagle is verified equivalent to Racket-beagle, end
  users install Cyclone (not Racket, not Bun) to bootstrap beagle.

So: this plan = JS/Bun PoC (done). `cyclone-self-host.md` = production
destination (active, priority 1).

Remaining open item moved to targets.md:
- Oracle CI integration — raco make cross-check on Bun compiler output
