# Repair tool routing

## Decision tree

```
Error? → beagle syntax FILE
  ├─ Delimiter error → beagle syntax --repair --emit-patch FILE
  └─ Clean → beagle daemon query check-enriched FILE
               ├─ Type error with suggestion → beagle fix .
               ├─ Type error, no suggestion → beagle repair ... --emit-patch
               │    ├─ Still stuck → beagle-trace ... --focus FN
               │    └─ Multiple failures → beagle-cascade ... --from-failures
               └─ Clean → done
```

## Tool summary

### Tier 1: Always try first
- `beagle syntax FILE` — structural check (delimiters, brackets)
- `beagle check FILE` — type check only
- `beagle fix .` — report high-confidence fixes (dry-run by default)

### Tier 2: When Tier 1 doesn't resolve
- `beagle repair FILE --emit-patch` — unified repair pipeline
- `beagle-blame FILE` — semantic property rules + suspicion analysis
- `beagle-specfix FILE` — 9 candidate strategies with oracle verification

### Tier 3: Root cause analysis
- `beagle-trace FILE --focus FN` — per-assertion arithmetic trace
- `beagle-cascade FILE --from-failures` — call graph impact + predictive blame
- `beagle-verify-enriched FILE` — verify + auto-diagnose with trace/cascade

## Fix safety labels

Every repair suggestion now includes a `fix-safety` label:

- **type-directed**: Single unambiguous replacement guided by type checker. Safe to auto-apply.
- **behavior-preserving**: Semantically equivalent change. Safe to auto-apply.
- **local-behavior-change**: Changes behavior in local scope only. Apply with caution.
- **requires-human-review**: Multiple candidates or ambiguous intent. Do not auto-apply.

## Batch operations

- `beagle-check-all DIR...` — 10x vs sequential
- `beagle-build-all DIR...` — 9x vs sequential
- Set `BEAGLE_FIX_PLAN=1` for fix plans in JSON output
