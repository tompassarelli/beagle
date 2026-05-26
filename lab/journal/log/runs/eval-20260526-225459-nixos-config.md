# eval-roundtrip — nixos-config @ 89f420b

- timestamp:   2026-05-26T22:54:59+07:00
- beagle-sha:  acaa508
- corpus:      /home/tom/code/nixos-config
- corpus-sha:  89f420b

## twin build

| metric | count |
|---|---|
| nix files     | 216 |
| convert-fail  | 0 |
| build-fail    | 0 |

## per-host drvPath equivalence (primary signal)

| metric | count |
|---|---|
| hosts total       | 2 |
| PASS              | 1 |
| FAIL-DIVERGE      | 1 |
| FAIL-TWIN-EVAL    | 0 |
| FAIL-ORIG-EVAL    | 0 |

### FAIL-DIVERGE hosts (drvPath strings differ — real semantic divergence)

- whiterabbit

#### diagnostic-cmp reports

```
--- whiterabbit ---
diagnostic-cmp: primary signal differed for host=whiterabbit
  orig=/home/tom/code/nixos-config
  twin=/tmp/beagle-eval-N7vbj79Z/twin
  (v1 stub — diagnostic leaves curated when first real failure lands)
```

