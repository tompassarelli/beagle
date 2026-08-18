# Native validation gate tiers

The ordinary landing bar remains the focused test suites. The following two
Store validation gates are preflight-tier checks and are not routine landing
loops:

| Gate | Runner | Tier | Bound |
| --- | --- | --- | --- |
| source-freeze | `native-core/validation/slice-types/run.sh` | preflight | 20 minutes |
| full typed-stage | `native-core/validation/slice-types-full/drive.sh` | preflight | 20 minutes |

The 20-minute bound is evidence-based: a prior nice-19 measurement reached 300
seconds without producing an artifact. Both runners compile through the serial
Racket oracle in `bin/beagle-build-all`; that path is the reason these checks
are preflight-tier. The 5–10x speedup for the native/self-host compile path is
future work and is not part of this gate reclassification.

This records tier and bound only. The runners and all other gate semantics are
unchanged.
