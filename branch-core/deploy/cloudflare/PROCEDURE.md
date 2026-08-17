# Fram from Cloudflare Workers

The Worker is stateless. It sends authenticated JSON to the shim; the shim
validates a closed request, converts tagged JSON Terms to FRAMRPC v2 (wire
version 2.0), and opens one private socket to the durable Fram server.

```text
Worker -- HTTPS + bearer + JSON --> shim -- private FRAMRPC --> Fram server
```

Only the shim is public. Never publish the Fram server port 7977: FRAMRPC delegates
authentication to the gateway.

This procedure is the **container route**: the engine is a server process the
Worker talks to over the network. Fram also links as a wasm module an isolate
embeds directly, with no server and no socket; that shape and its host contract
are in
[`../../docs/isolation-and-deployment.md`](../../docs/isolation-and-deployment.md).
The two are alternatives, not layers — nothing here applies to the embedded
shape except the closed JSON boundary an edge chooses to keep.

## Boundary

There is one edge format: `application/json`. Configure the client with the
space identity explicitly:

```js
const fram = framClient({
  url: env.SHIM_URL,
  token: env.SHIM_TOKEN,
  space: env.FRAM_SPACE_ID,
});
```

Every Term is an exact tagged array:

```json
["string", "Alice"]
["integer", "1842"]
["float64", "3ff0000000000000"]
["boolean", true]
["keyword", "kernel/type"]
["instant", "1785580282", "123000000"]
["triple", ["string", "Alice"], ["keyword", "contactable_at"], ["string", "alice@example.com"]]
```

Integers use canonical decimal strings. Float values use exact lowercase
IEEE-754 bits. Requests, pagination, errors, and responses reject unknown keys.
Neither the Worker nor the shim accepts EDN or an untyped raw escape hatch.

## Start the backend

The Fram server image is one static native executable on `scratch` — no JVM, no
dynamic loader, no shell. It is packaged from a completed content-addressed
`fram-native-build` artifact, so the image tag names the exact artifact it
carries. The separate shim image remains Babashka.

From `fram:deploy/cloudflare`:

```sh
export FRAM_SERVER_IMAGE="$(./build-native-image.sh)"
export SHIM_TOKEN=$(openssl rand -hex 32)
export FRAM_SPACE_ID=my-production-space
docker compose up -d --build
docker compose ps
```

`build-native-image.sh` compiles the artifact from this checkout and prints its
image tag; compose consumes that tag and never builds the server itself.
Deploying a different revision means re-running the script and exporting the new
tag, so a running deployment is always traceable to one artifact hash.

The Fram server persists database history at `/data/history.framlog`.

## How the server image is built

A `scratch` image has no dynamic loader, so the artifact must be linked static.
`FRAM_NATIVE_STATIC=1` is what does that: it appends `-static` to the server
link line and records `link=static` in the artifact's input manifest, so a
static and a dynamic build are different cache entries. It is unset by default,
so an ordinary checkout build is still a dynamic host-libc link. The compiler is
a static musl toolchain realized from the nixpkgs revision this repo's
`flake.lock` already pins, rooted by `--out-link` so nix GC cannot orphan it
between builds. Those are the two steps `build-native-image.sh` performs:

```sh
artifact="$(FRAM_NATIVE_CC="$cc" FRAM_NATIVE_STATIC=1 \
  bin/fram-native-build --host server "${sources[@]}")"
bin/fram-cloudflare-native-image --artifact "$artifact" --tag "fram-server-native:${artifact##*/}"
```

The packaging helper requires an absolute artifact path, verifies that its
directory hash and `READY` receipt agree, rejects any executable that still
requests a program interpreter, and uses that artifact directory as the complete
Docker build context. `Dockerfile.native` checks the same receipt before
producing the `scratch` runtime image, and sets `FRAM_BIND=0.0.0.0` because
loopback inside the container network namespace is unreachable through any port
mapping — publication stays governed by Docker networking, and port 7977 stays
private. That privacy guarantee rests entirely on the `docker -p` binding:
publishing with `-p 0.0.0.0:7977:7977` exposes unauthenticated plaintext
FRAMRPC, so bind loopback or a private network only. The server process runs
as numeric uid/gid `65534:65534`, so a bind-mounted (rather than named) `/data`
must be pre-owned by that uid on the host.

## Smoke the shim

```sh
curl -sS http://127.0.0.1:8080/q \
  -H "Authorization: Bearer $SHIM_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"space":"my-production-space","op":"rpc/version","payload":["keyword","rpc/unit"]}'
```

Expected shape:

```json
{"space":"my-production-space","op":"rpc/version","servedVersion":"0","payload":["keyword","rpc/unit"]}
```

An assertion request contains the native typed write record. Applications
normally use `worker-client.js` rather than constructing that record by hand.
The shim exposes reads on `POST /q` and mutations on `POST /assert`; sending an
operation to the wrong path is rejected before Fram server contact.

## Deploy the Worker

Set `SHIM_URL` and `FRAM_SPACE_ID` in `fram:deploy/cloudflare/wrangler.toml`,
then install the same bearer token as a secret:

```sh
cd deploy/cloudflare
npx wrangler secret put SHIM_TOKEN
npx wrangler deploy
```

Smoke the example:

```sh
W=https://fram-bench.example.workers.dev
curl -sS "$W/health"
curl -sS -X POST "$W/fact" \
  -H 'Content-Type: application/json' \
  -d '{"t1":"@bench1","t2":"title","t3":"hello"}'
curl -sS "$W/facts?t2=title"
curl -sS "$W/bench?n=20&t2=title"
```

## Operational properties

- The 1 MiB limit applies independently to request JSON, FRAMRPC bodies, and
  response JSON. A FRAMRPC frame adds its 26-byte header, for an exact maximum
  of 1,048,602 bytes.
- Authentication runs before body parsing and uses a constant-time token
  comparison.
- `Request.space` is the database identity. Filesystem paths never cross the
  public boundary.
- `expectedVersion` is a non-negative logical sequence carried as an i64; the
  Worker client serializes it as canonical JSON decimal text when needed. It is
  not a transaction-coordinate Triple or a wall-clock timestamp, and every data
  operation may supply it.
- Container restart replays `history.framlog`; Workers keep no cache or session.
- TLS terminates at the reverse proxy or tunnel in front of port 8080. A plain
  Internet-facing bearer-token endpoint is not a production deployment.

Snapshot/reload administration, deployment cutovers, graph authoring, and
enforcement remain sealed-control operations. They are intentionally absent
from the public Worker client and shim allow-list.
