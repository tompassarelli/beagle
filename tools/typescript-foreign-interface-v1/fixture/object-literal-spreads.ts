type JsonObject = Record<string, unknown>;

interface HookRow {
  eventName: string;
  enabled: boolean;
}

export function sessionConfig(
  projectRoot: string,
  inherited: JsonObject,
): JsonObject {
  const expected: JsonObject = {
    mode: "managed",
    ...inherited,
    projects: { [projectRoot]: { trust_level: "untrusted" } },
  };
  return expected;
}

export function fingerprintRows(
  rows: Array<JsonObject>,
) {
  return rows.map((row) => ({
    name: row.name,
    ...row,
    environment_id: "local",
  }));
}

export function expectedHooks(): Array<HookRow> {
  return [{ eventName: "Start", enabled: true }];
}

export function unknownValue(value: unknown): unknown {
  return value;
}

export function opaqueValue(value: object): object {
  return value;
}
