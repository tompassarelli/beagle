// SPDX-License-Identifier: MIT OR Apache-2.0

export const CAPACITY_RUNTIME_CONFIGURATION = Object.freeze({
  schema: "store-cloudflare-capacity-runtime/v1",
  engineMemoryBudgetBytes: 64 * 1024 * 1024,
  guestArenaInitialPages: 8,
  guestArenaGrowPages: 8,
});
