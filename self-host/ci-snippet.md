# CI wiring — self-host Zig parity gate

One step, in `.github/workflows/test.yml`, next to the other self-host gates
(after the Racket bytecode build and the `bb` install, since the gate drives
both compilers):

```yaml
      # Two Zig implementations may coexist only under a mechanical drift gate:
      # the Racket emitter is the oracle, the self-host must match it byte-for-
      # byte on every fixture not listed in self-host/selfhost-zig-exemptions.txt.
      # Exemptions start at 100% and each port slice's done-bar is deleting lines.
      - name: Self-host Zig parity — drift gate
        run: _BEAGLE_RACKET="$(which racket)" bin/beagle-selfhost-zig-parity
```

Exit codes: `0` no mismatch and every unported fixture exempted; `1` parity
failure (mismatch, unexempted unported row, stale or unknown exemption); `2`
the harness could not run (missing `racket`/`bb`, or the oracle no longer
reproduces a committed golden — a harness bug, not a self-host gap).

The ledger is written to `.lab/selfhost-zig-parity/parity-ledger.tsv`
(gitignored). To keep it after a red run:

```yaml
      - name: Upload parity ledger
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: selfhost-zig-parity-ledger
          path: .lab/selfhost-zig-parity/parity-ledger.tsv
```

Runtime is dominated by one `bb` start per fixture per target (~100 s for the
55-row corpus on the `bb` stage0). A built `self-host/native/beagle-selfhost`
with a matching seed sidecar is picked up automatically and removes that cost.
