# Wave 1 seams safe to start before the release train lands

## Included

Only **W1.4 — superseded native-decode lane closure** is conservatively drain-safe.

Its mutation boundary is limited to the superseded lane/branch and exact todo or coordination references to `native_stage_decode_gate.sh`. It explicitly forbids edits to compiler, expander, Store, gate, and Grey files. Its Native compilation and cache-gate runs are verification only; they do not widen its file boundary.

## Excluded

- W1.1 touches Store pin, flake, CI, and release-artifact surfaces.
- W1.2, W1.3, and W1.5 touch compiler/expander or gate surfaces.
- W1.6, W1.7, and W1.8 are already dispatched North seams and are not part of this new dispatch set; W1.8 also touches Store protocol fixtures.
- W1.9 and W1.10 touch Grey files.

Drain-safe count: **1** of the seven newly dispatchable Wave 1 work orders.
