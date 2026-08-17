#!/usr/bin/env bash
# Test-only fixture (NOT production code): wraps bin/beagle-store-server with an
# injected pre-exec delay so readiness tests can deterministically reproduce
# a cold boot that exceeds a fixed poll window, without depending on the
# host machine's actual JVM startup variance and without touching
# server.clj / bin/beagle-store-server.
#
#   BEAGLE_STORE_TEST_BOOT_DELAY_S=8 tests/fixtures/slow_server_wrapper.sh <port> <log>
set -euo pipefail
sleep "${BEAGLE_STORE_TEST_BOOT_DELAY_S:-8}"
exec "$(cd "$(dirname "$0")/../.." && pwd)/bin/beagle-store-server" "$@"
