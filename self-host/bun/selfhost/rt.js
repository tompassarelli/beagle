import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";
import {
  get as beagleGet,
  property_key as propertyKey,
  property_value as propertyValue,
} from "beagle/core.js";

function sha256Bytes(bytes) {
  return `sha256:${new Bun.CryptoHasher("sha256").update(bytes).digest("hex")}`;
}

function fromJsonValue(value) {
  if (Array.isArray(value)) {
    return value.map(fromJsonValue);
  }
  if (value !== null && typeof value === "object") {
    const result = Object.create(null);
    for (const [key, child] of Object.entries(value)) {
      result[propertyKey(key)] = fromJsonValue(child);
    }
    return result;
  }
  return value;
}

function jsonObjectEntries(value) {
  return Object.keys(value).map((encodedKey) => [
    String(propertyValue(encodedKey)),
    value[encodedKey],
  ]);
}

function canonicalJsonValue(value) {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJsonValue).join(",")}]`;
  }
  if (value !== null && typeof value === "object") {
    return `{${jsonObjectEntries(value).sort(([left], [right]) =>
      left < right ? -1 : left > right ? 1 : 0
    ).map(([key, child]) =>
      `${JSON.stringify(key)}:${canonicalJsonValue(child)}`
    ).join(",")}}`;
  }
  return JSON.stringify(value);
}

function withoutProperty(value, key) {
  const omitted = propertyKey(key);
  return Object.fromEntries(
    Object.entries(value).filter(([candidate]) => candidate !== omitted),
  );
}

export function slurp_file(path) {
  return readFileSync(path, "utf8");
}

export function read_source_snapshot(path) {
  const bytes = readFileSync(path);
  return fromJsonValue({
    text: new TextDecoder("utf-8", { fatal: true }).decode(bytes),
    sourceSha256: sha256Bytes(bytes),
  });
}

export function read_stdin() {
  return readFileSync(0, "utf8");
}

export function file_exists_p(path) {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

export function abs_path(path) {
  return resolve(path);
}

export function source_id(path) {
  const source = realpathSync(path);
  let directory = dirname(source);
  while (true) {
    if (existsSync(resolve(directory, ".git"))) {
      return relative(directory, source);
    }
    const parent = dirname(directory);
    if (parent === directory) {
      return source;
    }
    directory = parent;
  }
}

export function getenv(name) {
  return process.env[name] ?? null;
}

export function canonical_json(value) {
  return canonicalJsonValue(value);
}

export function parse_json(text) {
  return fromJsonValue(JSON.parse(text));
}

export function to_json(value) {
  return canonicalJsonValue(value);
}

export function source_sha256(sourceText) {
  return sha256Bytes(new TextEncoder().encode(sourceText));
}

export function projection_sha256(projectionWithoutDigest) {
  return sha256Bytes(new TextEncoder().encode(canonical_json(projectionWithoutDigest)));
}

export function valid_sha256_p(value) {
  return typeof value === "string" && /^sha256:[0-9a-f]{64}$/.test(value);
}

export function valid_projection_sha256_p(projection) {
  if (projection === null || typeof projection !== "object" || Array.isArray(projection)) {
    return false;
  }
  const projectionSha256 = beagleGet(projection, "projectionSha256");
  const withoutDigest = withoutProperty(projection, "projectionSha256");
  return valid_sha256_p(projectionSha256)
    && projectionSha256 === projection_sha256(withoutDigest);
}

export function exit(code) {
  process.exit(code);
}

export function eprint(text) {
  process.stderr.write(text);
  return null;
}
