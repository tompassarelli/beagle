// SPDX-License-Identifier: MIT OR Apache-2.0
// The Durable Object under test: one FRAMLOG plus its snapshot image per
// object, in real DurableObjectStorage, driven by the published adapter.
import framModule from "../../lib/libfram.wasm";
import framesBin from "../bundle/frames.bin";
import framesJson from "../bundle/frames.json";
import { DurableObject } from "cloudflare:workers";
import {
  ChunkedRange,
  FramDurableObjectBase,
  framAdminEntrypoint,
  framDataPlaneEntrypoint,
  hex,
} from "../../src/adapter.mjs";

const catalogue = JSON.parse(framesJson);
const blob = new Uint8Array(framesBin);
const SPACE = "fram-wasm-embed";

function frame(name) {
  const entry = catalogue.table[name];
  return blob.subarray(entry.offset, entry.offset + entry.length);
}

function manifest(which) {
  const found = catalogue.manifests.find((m) => m.manifest === which);
  if (!found) throw new Error(`no such manifest: ${which}`);
  return found.rows;
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

class FramHarness {
  constructor(state, env) {
    this.state = state;
    this.base = new FramDurableObjectBase(state, env, framModule, {
      spaceId: SPACE,
      logLabel: "in-memory",
      instance: {
        nowMs: () => 1700000000000,
        arena: { initialPages: 128 },
      },
    });
  }

  fram() {
    return this.base.fram();
  }

  recycle() {
    return this.base.recycle();
  }

  query(frame) {
    return this.base.query(frame);
  }

  transact(frame) {
    return this.base.transact(frame);
  }

  checkpoint(frame) {
    return this.base.checkpoint(frame);
  }

  exchange(frame, options) {
    return this.base.exchange(frame, options);
  }

  exportFramlog() {
    return this.base.exportFramlog();
  }

  restoreFramlog(backup, options) {
    return this.base.restoreFramlog(backup, options);
  }

  get openResult() {
    return this.base.openResult;
  }

  get store() {
    return this.base.store;
  }

  async fetch(request) {
    const url = new URL(request.url);
    try {
      if (url.pathname === "/pass") return await this.pass(url);
      if (url.pathname === "/dump") return await this.dump(url);
      if (url.pathname === "/grow") return await this.grow(url);
      if (url.pathname === "/keys") return await this.keys(url);
      if (url.pathname === "/delete-batches") return await this.deleteBatches(url);
      if (url.pathname === "/concurrent-boot") return await this.race(url);
      if (url.pathname === "/ready") return json({ ready: true });
    } catch (error) {
      return json(
        { fatal: `${error.message}`, code: error.code ?? null, stack: error.stack },
        500,
      );
    }
    return json({ fatal: `no such route: ${url.pathname}` }, 404);
  }

  /** One transcript pass: a fresh instance over the same storage. */
  async pass(url) {
    const label = url.searchParams.get("label") ?? "open";
    const which = url.searchParams.get("manifest") ?? "manifest.txt";
    const out = [];
    let failures = 0;
    let fatal = null;

    await this.recycle();
    const instance = await this.fram();
    const opened = this.openResult;
    out.push(`${label} ${opened.status} "${opened.message}"`);

    for (const { entry, name, declared } of manifest(which)) {
      const bytes = frame(name);
      if (bytes.length !== declared) {
        out.push(`frame ${name} READ-MISMATCH`);
        failures += 1;
        continue;
      }
      let result;
      try {
        if (name === "14-space-mismatch.bin") {
          // Preserve the engine-oracle row for its canonical mismatch reply;
          // the checked exchange boundary refuses this before guest entry.
          result = await this.query(bytes);
        } else if (name === "27-checkpoint.bin") {
          // Checkpoint is an operator capability, not a data-plane exchange.
          result = await this.checkpoint(bytes);
        } else {
          const response = await this.exchange(bytes, {
            entry: entry === "t" ? "transact" : entry === "s" ? "snapshot" : "query",
            space: SPACE,
          });
          result = { status: 0, response, released: true };
        }
      } catch (error) {
        fatal = `frame ${name}: ${error.message}`;
        break;
      }
      out.push(`frame ${name} ${result.status} ${hex(result.response)}`);
      if (result.status !== 0) failures += 1;
      if (!result.released) {
        out.push(`frame ${name} RELEASE-DID-NOT-CLEAR`);
        failures += 1;
      }
    }

    const stats = instance.stats();
    const storage = this.store.stats();
    if (!fatal) {
      const closed = await this.recycle();
      out.push(`close ${closed.status} "${closed.message}"`);
    }
    return json({ label, fatal, failures, out, stats, storage });
  }

  /** The durable bytes of one range, read back through a fresh reader. */
  async dump(url) {
    const which = url.searchParams.get("range") ?? "log";
    const prefix = which === "image" ? "framimage/" : "framlog/";
    const bytes = await new ChunkedRange(this.state.storage, { prefix }).load();
    return new Response(bytes, {
      headers: { "content-type": "application/octet-stream" },
    });
  }

  /** Transact a cycle of frames until the durable log passes `bytes`. */
  async grow(url) {
    const target = Number(url.searchParams.get("bytes") ?? 96 * 1024);
    const limit = Number(url.searchParams.get("limit") ?? 400);
    const names = (
      url.searchParams.get("frames") ??
      "30-batch-bulk-a.bin,30-batch-bulk-b.bin,30-batch-bulk-c.bin"
    ).split(",");
    const instance = await this.fram();
    let rounds = 0;
    let failures = 0;
    while (instance.log.length < target && rounds < limit) {
      const result = await this.transact(frame(names[rounds % names.length]));
      if (result.status !== 0) failures += 1;
      rounds += 1;
    }
    return json({
      rounds,
      failures,
      guestLogBytes: instance.log.length,
      reached: instance.log.length >= target,
      storage: this.store.stats(),
    });
  }

  /** The live key inventory, which is how multi-chunk coverage is observed. */
  async keys(url) {
    const prefix = url.searchParams.get("prefix") ?? "framlog/";
    const listed = await this.state.storage.list({ prefix });
    const meta = await this.state.storage.get(`${prefix}meta`);
    return json({
      prefix,
      keys: [...listed.keys()].sort(),
      meta: meta ?? null,
    });
  }

  /** Exercise a stale range larger than one DurableObjectStorage batch. */
  async deleteBatches(url) {
    const chunks = Number(url.searchParams.get("chunks") ?? 130);
    const range = new ChunkedRange(this.state.storage, {
      prefix: "delete-batch/",
      chunkBytes: 1,
      batchKeys: 256,
    });
    await range.load();
    const bytes = new Uint8Array(chunks).fill(11);
    let plan = range.plan(bytes, bytes.length, 0);
    await this.state.storage.transaction((txn) => range.applyTo(txn, plan));
    range.settle(plan);
    const before = await this.state.storage.list({ prefix: "delete-batch/" });

    plan = range.plan(bytes, 0, 0);
    await this.state.storage.transaction((txn) => range.applyTo(txn, plan));
    range.settle(plan);
    const after = await this.state.storage.list({ prefix: "delete-batch/" });
    const reread = await range.load();
    return json({
      chunks,
      before: before.size,
      after: after.size,
      deleteCalls: range.deletes,
      reread: reread.length,
    });
  }

  /**
   * Two boots demanded in one turn. The memo must answer both with the same
   * instance; two instances over one storage would mean two divergent images.
   */
  async race(url) {
    const width = Number(url.searchParams.get("width") ?? 8);
    await this.recycle();
    const demands = [];
    for (let i = 0; i < width; i++) demands.push(this.fram());
    const settled = await Promise.all(demands);
    const distinct = new Set(settled).size;
    const answered = await Promise.all(
      settled.map(() => this.query(frame("02-status.bin"))),
    );
    return json({
      width,
      distinct,
      identical: settled.every((one) => one === settled[0]),
      statuses: answered.map((one) => one.status),
      guestLogBytes: settled[0].log.length,
      storage: this.store.stats(),
    });
  }
}

// Distinct namespaces isolate harness scenarios while every object is still
// addressed by the one exact SpaceId carried in its frames.
class FramHarnessObject extends DurableObject {
  #fram;

  constructor(state, env) {
    super(state, env);
    this.#fram = new FramHarness(state, env);
  }

  fetch(request) {
    return this.#fram.fetch(request);
  }

  exchange(frame, options) {
    return this.#fram.exchange(frame, options);
  }

  exportFramlog() {
    return this.#fram.exportFramlog();
  }

  restoreFramlog(backup, options) {
    return this.#fram.restoreFramlog(backup, options);
  }
}

export class FramWarm extends FramHarnessObject {}
export class FramMatrix extends FramHarnessObject {}
export class FramRestored extends FramHarnessObject {}
export class FramDepth extends FramHarnessObject {}
export class FramMultichunk extends FramHarnessObject {}
export class FramRace extends FramHarnessObject {}
export class FramClient extends DurableObject {
  #fram;

  constructor(state, env) {
    super(state, env);
    this.#fram = new FramDurableObjectBase(state, env, framModule, {
      spaceId: SPACE,
      logLabel: "in-memory",
      instance: {
        nowMs: () => 1700000000000,
        arena: { initialPages: 128 },
      },
    });
  }

  exchange(frame, options) {
    return this.#fram.exchange(frame, options);
  }
}

const NAMESPACE = Object.freeze({
  warm: "FRAM_WARM",
  matrix: "FRAM_MATRIX",
  "matrix-restored": "FRAM_RESTORED",
  depth: "FRAM_DEPTH",
  multichunk: "FRAM_MULTICHUNK",
  race: "FRAM_RACE",
  "official-client": "FRAM_CLIENT",
});

function namespace(env, scenario) {
  const binding = NAMESPACE[scenario];
  if (!binding) throw new Error(`no namespace for scenario ${scenario}`);
  return env[binding];
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/rpc") {
      const space = request.headers.get("x-fram-space");
      const dataPlane = framDataPlaneEntrypoint(env.FRAM_CLIENT, SPACE);
      const frame = new Uint8Array(await request.arrayBuffer());
      const response = await dataPlane.exchange(frame, {
        entry: request.headers.get("x-fram-entry"),
        space,
      });
      return new Response(response, {
        headers: { "content-type": "application/vnd.framrpc" },
      });
    }
    if (url.pathname === "/admin/export") {
      const source = url.searchParams.get("id") === "matrix-restored"
        ? env.FRAM_RESTORED
        : env.FRAM_MATRIX;
      const admin = framAdminEntrypoint(source, SPACE);
      const backup = await admin.exportFramlog();
      return new Response(backup.bytes, {
        headers: {
          "content-type": "application/octet-stream",
          "x-fram-backup-format": backup.format,
          "x-fram-byte-length": String(backup.byteLength),
          "x-fram-served-version": backup.servedVersion,
          "x-fram-sha256": backup.sha256,
          "x-fram-space-id": backup.spaceId,
        },
      });
    }
    if (url.pathname === "/admin/restore") {
      const admin = framAdminEntrypoint(env.FRAM_RESTORED, SPACE);
      const bytes = new Uint8Array(await request.arrayBuffer());
      const backup = {
        format: request.headers.get("x-fram-backup-format"),
        spaceId: request.headers.get("x-fram-space-id"),
        servedVersion: request.headers.get("x-fram-served-version"),
        byteLength: Number(request.headers.get("x-fram-byte-length")),
        sha256: request.headers.get("x-fram-sha256"),
        bytes,
      };
      return json(await admin.restoreFramlog(backup));
    }
    const scenario = url.searchParams.get("id") ?? "matrix";
    return namespace(env, scenario).getByName(SPACE).fetch(request);
  },
};
