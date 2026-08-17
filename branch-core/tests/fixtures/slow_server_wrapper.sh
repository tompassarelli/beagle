#!/usr/bin/env bash
# Test-only fixture (NOT production code): wraps bin/fram-server with an
# injected pre-exec delay so readiness tests can deterministically reproduce
# a cold boot that exceeds a fixed poll window, without depending on the
# host machine's actual JVM startup variance and without touching
# server.clj / bin/fram-server.
#
#   FRAM_TEST_BOOT_DELAY_S=8 tests/fixtures/slow_server_wrapper.sh <port> <log>
set -euo pipefail
sleep "${FRAM_TEST_BOOT_DELAY_S:-8}"
exec "$(cd "$(dirname "$0")/../.." && pwd)/bin/fram-server" "$@"
