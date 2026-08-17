# FRAM repository instructions

## External resources and licenses

Before using any external resource or repository under `~/code/resources/`, re-check its
current revision and license files. Record the check date, exact revision,
license identifier, and practical implication for FRAM. A dated record applies
only to the revision checked; never treat it as evergreen.

- 2026-07-22 — Datahike revision
  `7dd5324781ee8454608418c7e7d7b26c48b5fe2e` is EPL-1.0; FRAM revision
  `b45f6bb7ae2b75140dff069b4558737c7e4008ea` is MIT OR Apache-2.0. Use
  Datahike for ideas and mechanisms only: copy or derive no source expression
  without a fresh license-compatibility review.

- 2026-07-29 — Beagle revision
  `0d6e712f5b829545bb82cb3a9e0b77853a9521a0` is MIT OR Apache-2.0. FRAM
  uses this compatible local revision as its compiler and coherent-world
  checker oracle; compiler output and protocol integration may be consumed by
  FRAM under either offered license.

- 2026-08-15 — Beagle packaged-input revision
  `b4f3081420a3be73d730802d2f4608d78d0c6cf4` is MIT OR Apache-2.0. It is
  the current `beagle-pin.txt` native compiler and `flake.nix` graph-authoring
  runtime pin and is license-compatible with FRAM; update this dated record
  when the package pin advances.

  A compiler-pin advance is one coherent change: update `beagle-pin.txt`, the
  `flake.nix` input and lock, every CI/release Beagle checkout ref, and this
  dated license record together. Run the existing native build-cache and
  native/Cloudflare release-artifact gates against exactly that revision.
  Never inherit Beagle main silently.

- 2026-08-11 — TypeScript npm package `6.0.3`, source revision
  `050880ce59e30b356b686bd3144efe24f875ebc8`, is Apache-2.0. FRAM uses it
  only as the pinned CI compiler for the packed Bun declaration-surface gate;
  it is not a shipped or runtime dependency.

- 2026-08-11 — Bun `1.3.13` and `bun-types` `1.3.13`, source revision
  `bf2e2cecf27e800962b1e7f03d66278f9d5d2e79`: Bun itself and `bun-types`
  are MIT. Bun's official license also records statically linked
  JavaScriptCore/WebKit under LGPL-2 and separately licensed linked libraries.
  FRAM uses the pinned Bun binary as the official JavaScript-client runtime,
  package tool, and test runner, and its type package only in the packed-client
  CI gate; neither is shipped with `@tompassarelli/framrpc`. Do not vendor Bun
  components without reviewing the applicable component license.

- 2026-08-11 — `oven-sh/setup-bun` revision
  `0c5077e51419868618aeaa5fe8019c62421857d6` is MIT. FRAM uses it only in
  GitHub Actions to install the exact Bun toolchain; it is not a shipped or
  runtime dependency.
- 2026-08-12 — Wrangler npm package `4.121.0` and Miniflare npm package
  `5.20260804.1-alpha`, source revision
  `15fc56824836570ca291aa148be72d2d62f59566` in Cloudflare's workers-sdk,
  are respectively MIT OR Apache-2.0 and MIT. FRAM uses these exact packages
  only as development gates: Wrangler produces the deployment-shaped dry-run
  bundle and Miniflare launches the workerd functional harness. Neither is
  shipped by `@tompassarelli/fram-cloudflare-do`, and no Cloudflare source is
  copied into FRAM.

- 2026-08-12 — workerd npm package `1.20260804.1`, source revision
  `abd3d71c2d9a3bd6f27072091d9368fd18ca02e6`, is Apache-2.0. Wrangler
  `4.121.0` selects this exact runtime build. FRAM invokes it indirectly through
  Miniflare for local capacity evidence only; local workerd plus a Linux cgroup
  is a conservative process-tree proxy, not an observation of Cloudflare's
  production isolate accounting.

- 2026-08-12 — `cachix/install-nix-action` revision
  `630ae543ea3a38a9a4166f03376c02c50f408342` is Apache-2.0. FRAM uses it only
  in the GitHub release workflow to resolve the flake-locked Wasm build
  toolchain; it is not a shipped or runtime dependency.
