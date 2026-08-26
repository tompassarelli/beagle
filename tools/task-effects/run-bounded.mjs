import { access, chmod, copyFile, mkdir, readFile, rename, rm } from "fs/promises";
import { constants } from "fs";
import { homedir } from "os";
import { isAbsolute, join, resolve } from "path";

const SOURCE_PATHS = ["Cargo.toml", "Cargo.lock", "src/main.rs"];
const BUILD_OUTPUT_LIMIT = 1024 * 1024;

function unavailable(message) {
  throw new Error(`run-bounded resolver: ${message}`);
}

async function isExecutable(path) {
  try {
    await access(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

async function boundedText(stream, processHandle) {
  const chunks = [];
  let size = 0;
  for await (const chunk of stream) {
    size += chunk.byteLength;
    if (size > BUILD_OUTPUT_LIMIT) {
      processHandle.kill("SIGKILL");
      unavailable(`cargo output exceeded ${BUILD_OUTPUT_LIMIT} bytes`);
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

async function sourceKey(sourceRoot) {
  const hasher = new Bun.CryptoHasher("sha256");
  for (const relativePath of SOURCE_PATHS) {
    hasher.update(relativePath);
    hasher.update("\0");
    hasher.update(await readFile(join(sourceRoot, relativePath)));
    hasher.update("\0");
  }
  return hasher.digest("hex");
}

export async function resolveRunBounded(repositoryRoot) {
  const override = process.env.BEAGLE_RUST_SUPERVISOR;
  if (override !== undefined && override !== "") {
    if (!isAbsolute(override) || !(await isExecutable(override))) {
      unavailable("BEAGLE_RUST_SUPERVISOR must name an executable absolute path");
    }
    return resolve(override);
  }

  const sourceRoot = join(resolve(repositoryRoot), "tools", "run-bounded");
  const key = await sourceKey(sourceRoot);
  const cacheRoot = join(
    process.env.XDG_CACHE_HOME || join(homedir(), ".cache"),
    "beagle",
    "tools",
  );
  const binary = join(cacheRoot, `run-bounded-${key}`);
  if (await isExecutable(binary)) return binary;

  const cargo = Bun.which("cargo");
  if (cargo === null) unavailable("cargo is unavailable; enter the Beagle development shell");
  await mkdir(cacheRoot, { recursive: true });
  const targetRoot = join(cacheRoot, `run-bounded-target-${key}`);
  const child = Bun.spawn(
    [
      cargo,
      "build",
      "--release",
      "--locked",
      "--offline",
      "--manifest-path",
      join(sourceRoot, "Cargo.toml"),
      "--target-dir",
      targetRoot,
    ],
    { cwd: sourceRoot, env: process.env, stdin: "ignore", stdout: "pipe", stderr: "pipe" },
  );
  const [stdout, stderr, status] = await Promise.all([
    boundedText(child.stdout, child),
    boundedText(child.stderr, child),
    child.exited,
  ]);
  if (status !== 0) {
    unavailable(`cargo build failed with status ${status}: ${(stderr || stdout).trim()}`);
  }

  const built = join(targetRoot, "release", "run-bounded");
  if (!(await isExecutable(built))) unavailable("cargo completed without an executable");
  const staging = `${binary}.tmp-${process.pid}`;
  try {
    await copyFile(built, staging);
    await chmod(staging, 0o755);
    await rename(staging, binary);
  } finally {
    await rm(staging, { force: true });
  }
  if (!(await isExecutable(binary))) unavailable("cached executable is unavailable after publication");
  return binary;
}
