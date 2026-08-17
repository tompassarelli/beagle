#!/usr/bin/env bash
# The full capacity gate needs the wasm compiler, Wrangler/workerd dependencies,
# cgroup v2, and a user systemd manager. It is intentionally not a hosted-runner
# row; the pure receipt contract remains in ordinary Bun CI.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$repo/clients/cloudflare-do/capacity/run-gate.sh" "$@"
