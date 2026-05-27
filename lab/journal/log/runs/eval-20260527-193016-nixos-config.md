# eval-roundtrip — nixos-config @ 89f420b

- timestamp:   2026-05-27T19:30:16+07:00
- beagle-sha:  c77a8d1
- corpus:      /home/tom/code/nixos-config
- corpus-sha:  89f420b

## twin build

| metric | count |
|---|---|
| nix files     | 217 |
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
diagnostic-cmp for host=whiterabbit
  6 MATCH / 0 DIFFER (of 6 curated leaves)
    MATCH   hostName
    MATCH   stateVersion
    MATCH   timeZone
    MATCH   kernelVersion
    MATCH   systemPackages
    MATCH   enabledSystemdServices
  VERDICT: DIVERGE-but-equivalent — all curated leaves match;
           divergence is non-user-facing (likely flake-source-hash
           cascade from self-referencing config like sops).
```

