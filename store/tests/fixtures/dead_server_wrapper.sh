#!/usr/bin/env bash
# Test-only fixture (NOT production code): simulates a server that dies
# immediately during boot, so readiness tests can prove the harness detects
# and reports a dead child fast and diagnostically instead of waiting out
# its full deadline.
set -euo pipefail
echo "dead-server fixture: simulated boot failure (seeded)" >&2
exit 7
