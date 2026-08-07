Source: `~/code/fram/main` revision `d633a2840faabebfc4d1eb1f45b01e75fb876e5e`
(checked 2026-08-07).

This is the exact 7-module plus 12-fixture input corpus declared by
`~/code/fram/main/tests/resolve_golden.sh`. It is vendored here so Beagle's
facts-roundtrip parity certification is hermetic and catches every source shape
consumed by Fram's resolve golden gate. Fram's remaining engine modules are
`.bgl` Native Core and are not that gate's input, so they are not vendored.

Fram and its codegraph directory are licensed `MIT OR Apache-2.0`; the
corresponding license texts are included beside this file.
