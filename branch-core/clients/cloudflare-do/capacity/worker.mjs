// SPDX-License-Identifier: MIT OR Apache-2.0
// A deployment-shaped Worker used only by the repeatable capacity gate.
import framModule from "../lib/libfram.wasm";
import { FramDurableObjectBase, hex } from "../src/adapter.mjs";
import { CAPACITY_RUNTIME_CONFIGURATION } from "./config.mjs";

const OBJECT_NAME = "fram-wiki-capacity-v1";
const SPACE_ID = "fram-wiki-capacity-v1";

function json(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export class CapacityFram extends FramDurableObjectBase {
  constructor(state, env) {
    super(state, env, framModule, {
      spaceId: SPACE_ID,
      logLabel: "cloudflare-capacity",
      instance: {
        nowMs: () => 1700000000000,
        memoryBudgetBytes:
          CAPACITY_RUNTIME_CONFIGURATION.engineMemoryBudgetBytes,
        arena: {
          initialPages:
            CAPACITY_RUNTIME_CONFIGURATION.guestArenaInitialPages,
          growPages: CAPACITY_RUNTIME_CONFIGURATION.guestArenaGrowPages,
        },
      },
    });
  }

  async fetch(request) {
    const url = new URL(request.url);
    try {
      if (url.pathname === "/exchange") {
        const entry = request.headers.get("x-fram-entry");
        if (!new Set(["q", "t", "s"]).has(entry)) {
          return json({ error: "x-fram-entry must be q, t, or s" }, 400);
        }
        const frame = new Uint8Array(await request.arrayBuffer());
        const result =
          entry === "t"
            ? await this.transact(frame)
            : entry === "s"
              ? await this.snapshot(frame)
              : await this.query(frame);
        return json({
          status: result.status,
          message: result.message,
          released: result.released,
          responseBytes: result.response.length,
          responseHex: hex(result.response),
        });
      }
      if (url.pathname === "/stats") {
        const instance = await this.fram();
        return json({
          engine: instance.stats(),
          storage: this.store.stats(),
          runtimeConfiguration: CAPACITY_RUNTIME_CONFIGURATION,
        });
      }
      if (url.pathname === "/recycle") {
        const before = this.instance?.stats() ?? null;
        const closed = await this.recycle();
        return json({ before, closed });
      }
    } catch (error) {
      return json({ error: `${error.message}` }, 500);
    }
    return json({ error: "capacity harness route not found" }, 404);
  }
}

export default {
  fetch(request, env) {
    return env.FRAM.getByName(OBJECT_NAME).fetch(request);
  },
};
