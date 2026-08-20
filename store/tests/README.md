# tests/

## How to run (IMPORTANT: from the repo ROOT)

```
bb -cp out tests/<file>.clj
```

For a batch, timeout, or any test that can start `bin/beagle-store-server` or
`bin/beagle-store-native-build`, use the hosted runner so interruption cannot orphan a
server or build:

```bash
tests/run_hosted_test.sh 240s bb -cp out tests/<file>.clj
```

Run from the repository root, not from inside `tests/`; several tests load
root-level implementation files by relative path.

## What stays at the root (do NOT move)

- `database.clj` — SpaceId + STORELOG database.
- `server.clj` — STORERPC server implementation.
