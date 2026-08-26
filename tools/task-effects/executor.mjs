import {
  lstat,
  mkdir,
  mkdtemp,
  open,
  readdir,
  realpath,
  rename,
  rm,
} from "fs/promises";
import { constants } from "fs";
import { tmpdir } from "os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "path";

export const PLAN_SCHEMA = "task-effect-plan/v1";
export const RECEIPT_SCHEMA = "task-effect-receipt/v1";

export class PlanContractError extends Error {
  constructor(message) {
    super(`task-effect contract: ${message}`);
    this.name = "PlanContractError";
  }
}

function contract(message) {
  throw new PlanContractError(message);
}

function object(value, label) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    contract(`${label} must be an object`);
  }
  return value;
}

function closed(value, fields, label) {
  object(value, label);
  const actual = Object.keys(value).sort();
  const expected = [...fields].sort();
  if (actual.length !== expected.length || actual.some((field, index) => field !== expected[index])) {
    contract(`${label} fields must be exactly ${expected.join(",")}; received ${actual.join(",")}`);
  }
  return value;
}

function tag(value, expected, label) {
  if (value._tag !== expected) contract(`${label} kind must be ${expected}`);
}

function string(value, label) {
  if (typeof value !== "string") contract(`${label} must be a string`);
  return value;
}

function nonempty(value, label) {
  string(value, label);
  if (value.length === 0) contract(`${label} must not be empty`);
  return value;
}

function integer(value, label, minimum = 0, maximum = Number.MAX_SAFE_INTEGER) {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    contract(`${label} must be a safe integer from ${minimum} through ${maximum}`);
  }
  return value;
}

function array(value, label) {
  if (!Array.isArray(value)) contract(`${label} must be an array`);
  return value;
}

function unique(values, label) {
  if (new Set(values).size !== values.length) contract(`${label} must be unique`);
}

function safeRelative(value, label) {
  string(value, label);
  if (value === "") contract(`${label} must not be empty`);
  if (isAbsolute(value)) contract(`${label} must be relative`);
  const segments = value.split(/[\\/]/);
  if (segments.some((segment) => segment === ".." || segment === "")) {
    contract(`${label} contains an escaping or empty path segment`);
  }
}

function validatePath(path, label) {
  object(path, label);
  switch (path._tag) {
    case "RepoPathV1":
      closed(path, ["_tag", "relative"], label);
      safeRelative(path.relative, `${label}.relative`);
      break;
    case "TempPathV1":
      closed(path, ["_tag", "relative", "tempdirId"], label);
      nonempty(path.tempdirId, `${label}.tempdirId`);
      safeRelative(path.relative, `${label}.relative`);
      break;
    default:
      contract(`${label} has unsupported path kind ${String(path._tag)}`);
  }
}

function validateArtifact(artifact, label) {
  closed(
    artifact,
    ["_tag", "artifactId", "artifactKind", "digestWhen", "expectedDigest", "path"],
    label,
  );
  tag(artifact, "ArtifactV1", label);
  nonempty(artifact.artifactId, `${label}.artifactId`);
  if (artifact.artifactKind !== "file" && artifact.artifactKind !== "directory") {
    contract(`${label}.artifactKind is unsupported`);
  }
  validatePath(artifact.path, `${label}.path`);
  if (artifact.expectedDigest !== null) {
    string(artifact.expectedDigest, `${label}.expectedDigest`);
    if (!/^[a-f0-9]{64}$/.test(artifact.expectedDigest)) contract(`${label}.expectedDigest is invalid`);
  }
  if (!["before", "after", "both"].includes(artifact.digestWhen)) {
    contract(`${label}.digestWhen is unsupported`);
  }
}

function validateDependencies(effect, label) {
  array(effect.dependsOn, `${label}.dependsOn`).forEach((id, index) =>
    nonempty(id, `${label}.dependsOn[${index}]`),
  );
  unique(effect.dependsOn, `${label}.dependsOn`);
}

function validateArg(arg, label) {
  object(arg, label);
  switch (arg._tag) {
    case "LiteralArgV1":
      closed(arg, ["_tag", "value"], label);
      string(arg.value, `${label}.value`);
      break;
    case "PathArgV1":
      closed(arg, ["_tag", "path"], label);
      validatePath(arg.path, `${label}.path`);
      break;
    default:
      contract(`${label} has unsupported argument kind ${String(arg._tag)}`);
  }
}

function validateEnvironment(environment, label) {
  closed(environment, ["_tag", "entries", "policy"], label);
  tag(environment, "ProcessEnvironmentV1", label);
  if (environment.policy !== "replace") contract(`${label}.policy must be replace`);
  array(environment.entries, `${label}.entries`).forEach((entry, index) => {
    const entryLabel = `${label}.entries[${index}]`;
    closed(entry, ["_tag", "name", "value"], entryLabel);
    tag(entry, "EnvEntryV1", entryLabel);
    nonempty(entry.name, `${entryLabel}.name`);
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(entry.name)) contract(`${entryLabel}.name is invalid`);
    string(entry.value, `${entryLabel}.value`);
  });
  unique(environment.entries.map((entry) => entry.name), `${label}.entry names`);
}

function validateEffect(effect, label) {
  object(effect, label);
  switch (effect._tag) {
    case "TempdirAllocateV1":
      closed(effect, ["_tag", "dependsOn", "effectId", "prefix", "tempdirId"], label);
      nonempty(effect.effectId, `${label}.effectId`);
      validateDependencies(effect, label);
      nonempty(effect.tempdirId, `${label}.tempdirId`);
      if (!/^[a-z0-9][a-z0-9-]*-$/.test(effect.prefix)) {
        contract(`${label}.prefix must be a closed safe prefix ending in -`);
      }
      break;
    case "AtomicCopyV1":
      closed(effect, ["_tag", "dependsOn", "effectId", "source", "target"], label);
      nonempty(effect.effectId, `${label}.effectId`);
      validateDependencies(effect, label);
      validatePath(effect.source, `${label}.source`);
      validatePath(effect.target, `${label}.target`);
      if (effect.target._tag !== "TempPathV1") contract(`${label}.target must be a temp path`);
      break;
    case "AtomicReplaceExactV1":
      closed(
        effect,
        ["_tag", "dependsOn", "effectId", "expectedCount", "newText", "oldText", "source", "target"],
        label,
      );
      nonempty(effect.effectId, `${label}.effectId`);
      validateDependencies(effect, label);
      validatePath(effect.source, `${label}.source`);
      validatePath(effect.target, `${label}.target`);
      if (effect.target._tag !== "TempPathV1") contract(`${label}.target must be a temp path`);
      nonempty(effect.oldText, `${label}.oldText`);
      string(effect.newText, `${label}.newText`);
      integer(effect.expectedCount, `${label}.expectedCount`, 1, 1000000);
      break;
    case "ProcessRunV1":
      closed(
        effect,
        [
          "_tag",
          "acceptedStatuses",
          "argv",
          "cwd",
          "deadlineSeconds",
          "dependsOn",
          "effectId",
          "environment",
          "killGraceSeconds",
          "maxStderrBytes",
          "maxStdoutBytes",
          "stderrArtifactId",
          "stdinMode",
          "stdoutArtifactId",
          "terminationSignal",
        ],
        label,
      );
      nonempty(effect.effectId, `${label}.effectId`);
      validateDependencies(effect, label);
      array(effect.argv, `${label}.argv`).forEach((arg, index) => validateArg(arg, `${label}.argv[${index}]`));
      if (effect.argv.length === 0) contract(`${label}.argv must include an executable`);
      validatePath(effect.cwd, `${label}.cwd`);
      validateEnvironment(effect.environment, `${label}.environment`);
      if (effect.stdinMode !== "null") contract(`${label}.stdinMode must be null`);
      nonempty(effect.stdoutArtifactId, `${label}.stdoutArtifactId`);
      nonempty(effect.stderrArtifactId, `${label}.stderrArtifactId`);
      integer(effect.maxStdoutBytes, `${label}.maxStdoutBytes`, 1, 67108864);
      integer(effect.maxStderrBytes, `${label}.maxStderrBytes`, 1, 67108864);
      integer(effect.deadlineSeconds, `${label}.deadlineSeconds`, 1, 86400);
      integer(effect.killGraceSeconds, `${label}.killGraceSeconds`, 1, 300);
      if (!["SIGTERM", "SIGINT", "SIGHUP"].includes(effect.terminationSignal)) {
        contract(`${label}.terminationSignal is unsupported`);
      }
      array(effect.acceptedStatuses, `${label}.acceptedStatuses`).forEach((status, index) =>
        integer(status, `${label}.acceptedStatuses[${index}]`, 0, 255),
      );
      unique(effect.acceptedStatuses, `${label}.acceptedStatuses`);
      break;
    default:
      contract(`${label} has unsupported operation kind ${String(effect._tag)}`);
  }
}

function validateCheck(check, label) {
  object(check, label);
  switch (check._tag) {
    case "ProcessAcceptedCheckV1":
      closed(check, ["_tag", "effectId"], label);
      nonempty(check.effectId, `${label}.effectId`);
      break;
    case "ArtifactContainsCheckV1":
      closed(check, ["_tag", "artifactId", "needle"], label);
      nonempty(check.artifactId, `${label}.artifactId`);
      nonempty(check.needle, `${label}.needle`);
      break;
    case "ArtifactChangedLineCountCheckV1":
      closed(check, ["_tag", "leftArtifactId", "maximum", "rightArtifactId"], label);
      nonempty(check.leftArtifactId, `${label}.leftArtifactId`);
      nonempty(check.rightArtifactId, `${label}.rightArtifactId`);
      integer(check.maximum, `${label}.maximum`, 0, 1000000);
      break;
    default:
      contract(`${label} has unsupported check kind ${String(check._tag)}`);
  }
}

export function validatePlan(plan) {
  closed(plan, ["_tag", "artifacts", "authority", "cases", "effects", "planKind", "schemaVersion"], "plan");
  tag(plan, "TaskEffectPlanV1", "plan");
  if (plan.schemaVersion !== PLAN_SCHEMA) contract(`unsupported plan schema ${String(plan.schemaVersion)}`);
  nonempty(plan.planKind, "plan.planKind");
  closed(plan.authority, ["_tag", "attemptRef", "authorizationRef", "intentRef"], "plan.authority");
  tag(plan.authority, "EffectAuthorityV1", "plan.authority");
  nonempty(plan.authority.intentRef, "plan.authority.intentRef");
  nonempty(plan.authority.authorizationRef, "plan.authority.authorizationRef");
  if (!plan.authority.authorizationRef.startsWith("local-test:")) {
    contract("plan.authority.authorizationRef must name explicit local-test authority");
  }
  nonempty(plan.authority.attemptRef, "plan.authority.attemptRef");

  array(plan.artifacts, "plan.artifacts").forEach((artifact, index) =>
    validateArtifact(artifact, `plan.artifacts[${index}]`),
  );
  unique(plan.artifacts.map((artifact) => artifact.artifactId), "artifact ids");
  const artifacts = new Map(plan.artifacts.map((artifact) => [artifact.artifactId, artifact]));

  array(plan.effects, "plan.effects").forEach((effect, index) => validateEffect(effect, `plan.effects[${index}]`));
  unique(plan.effects.map((effect) => effect.effectId), "effect ids");
  const effects = new Map(plan.effects.map((effect) => [effect.effectId, effect]));
  const tempAllocations = new Map();
  const seenEffects = new Set();
  for (const effect of plan.effects) {
    for (const dependency of effect.dependsOn) {
      if (!seenEffects.has(dependency)) contract(`${effect.effectId} depends on non-prior effect ${dependency}`);
    }
    if (effect._tag === "TempdirAllocateV1") {
      if (tempAllocations.has(effect.tempdirId)) contract(`duplicate tempdir allocation ${effect.tempdirId}`);
      tempAllocations.set(effect.tempdirId, effect.effectId);
    }
    const paths = [];
    if (effect.source) paths.push(effect.source);
    if (effect.target) paths.push(effect.target);
    if (effect.cwd) paths.push(effect.cwd);
    if (effect.argv) {
      for (const arg of effect.argv) if (arg._tag === "PathArgV1") paths.push(arg.path);
    }
    for (const path of paths) {
      if (path._tag === "TempPathV1") {
        const allocation = tempAllocations.get(path.tempdirId);
        if (allocation === undefined || !effect.dependsOn.includes(allocation)) {
          contract(`${effect.effectId} must depend on tempdir allocation for ${path.tempdirId}`);
        }
      }
    }
    if (effect._tag === "ProcessRunV1") {
      for (const field of ["stdoutArtifactId", "stderrArtifactId"]) {
        const artifact = artifacts.get(effect[field]);
        if (artifact === undefined || artifact.artifactKind !== "file" || artifact.path._tag !== "TempPathV1") {
          contract(`${effect.effectId}.${field} must reference a declared temp file artifact`);
        }
        const allocation = tempAllocations.get(artifact.path.tempdirId);
        if (allocation === undefined || !effect.dependsOn.includes(allocation)) {
          contract(`${effect.effectId} must depend on capture tempdir ${artifact.path.tempdirId}`);
        }
      }
    }
    seenEffects.add(effect.effectId);
  }
  for (const artifact of plan.artifacts) {
    if (artifact.path._tag === "TempPathV1" && !tempAllocations.has(artifact.path.tempdirId)) {
      contract(`artifact ${artifact.artifactId} references undeclared tempdir ${artifact.path.tempdirId}`);
    }
  }

  array(plan.cases, "plan.cases").forEach((semanticCase, caseIndex) => {
    const label = `plan.cases[${caseIndex}]`;
    closed(semanticCase, ["_tag", "caseId", "checks", "claim"], label);
    tag(semanticCase, "SemanticCaseV1", label);
    nonempty(semanticCase.caseId, `${label}.caseId`);
    nonempty(semanticCase.claim, `${label}.claim`);
    array(semanticCase.checks, `${label}.checks`).forEach((check, checkIndex) => {
      validateCheck(check, `${label}.checks[${checkIndex}]`);
      if (check._tag === "ProcessAcceptedCheckV1" && effects.get(check.effectId)?._tag !== "ProcessRunV1") {
        contract(`${label} references undeclared process ${check.effectId}`);
      }
      for (const field of ["artifactId", "leftArtifactId", "rightArtifactId"]) {
        if (check[field] !== undefined && !artifacts.has(check[field])) {
          contract(`${label} references undeclared artifact ${check[field]}`);
        }
      }
    });
  });
  unique(plan.cases.map((semanticCase) => semanticCase.caseId), "case ids");
  return plan;
}

function canonicalValue(value) {
  if (value === null || typeof value === "boolean" || typeof value === "string") return value;
  if (typeof value === "number" && Number.isSafeInteger(value)) return value;
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype) {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalValue(value[key])]));
  }
  contract(`non-canonical ${typeof value} value`);
}

export function canonicalJson(value) {
  return `${JSON.stringify(canonicalValue(value))}\n`;
}

function sha256(bytes) {
  const hasher = new Bun.CryptoHasher("sha256");
  hasher.update(bytes);
  return hasher.digest("hex");
}

function contained(root, candidate, label) {
  const rootPath = resolve(root);
  const candidatePath = resolve(candidate);
  const remainder = relative(rootPath, candidatePath);
  if (remainder === ".." || remainder.startsWith(`..${sep}`) || isAbsolute(remainder)) {
    contract(`${label} escapes its declared root`);
  }
  return candidatePath;
}

async function rejectSymlinkSegments(root, candidate, allowMissing, label) {
  const remainder = relative(root, candidate);
  let current = root;
  for (const segment of remainder.split(sep).filter((part) => part !== "" && part !== ".")) {
    current = join(current, segment);
    try {
      const info = await lstat(current);
      if (info.isSymbolicLink()) contract(`${label} traverses symlink ${current}`);
    } catch (error) {
      if (error.code === "ENOENT" && allowMissing) return;
      throw error;
    }
  }
}

async function rootFor(path, state, label) {
  if (path._tag === "RepoPathV1") return state.repositoryRoot;
  const root = state.tempdirs.get(path.tempdirId);
  if (root === undefined) contract(`${label} references unallocated tempdir ${path.tempdirId}`);
  return root;
}

async function resolvedPath(path, state, label, allowMissing = false) {
  const root = await rootFor(path, state, label);
  const candidate = contained(root, join(root, path.relative), label);
  await rejectSymlinkSegments(root, candidate, allowMissing, label);
  return { root, candidate };
}

async function readContainedFile(path, state, label) {
  const { root, candidate } = await resolvedPath(path, state, label);
  const handle = await open(candidate, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const actual = await realpath(`/proc/self/fd/${handle.fd}`);
    contained(root, actual, label);
    return await handle.readFile();
  } finally {
    await handle.close();
  }
}

async function ensureContainedParent(root, target, label) {
  const parent = dirname(target);
  contained(root, parent, label);
  let current = root;
  for (const segment of relative(root, parent).split(sep).filter((part) => part !== "" && part !== ".")) {
    current = join(current, segment);
    try {
      await mkdir(current);
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
    }
    const info = await lstat(current);
    if (!info.isDirectory() || info.isSymbolicLink()) contract(`${label} parent is not a physical directory`);
  }
  const handle = await open(parent, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  try {
    const actual = await realpath(`/proc/self/fd/${handle.fd}`);
    contained(root, actual, label);
    return handle;
  } catch (error) {
    await handle.close();
    throw error;
  }
}

async function atomicWrite(path, bytes, state, label) {
  const { root, candidate } = await resolvedPath(path, state, label, true);
  const parent = await ensureContainedParent(root, candidate, label);
  const stagingName = `.task-effect-${process.pid}-${crypto.randomUUID()}`;
  const parentFdPath = `/proc/self/fd/${parent.fd}`;
  const staging = join(parentFdPath, stagingName);
  const target = join(parentFdPath, basename(candidate));
  try {
    const handle = await open(
      staging,
      constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | constants.O_NOFOLLOW,
      0o600,
    );
    try {
      const actual = await realpath(`/proc/self/fd/${handle.fd}`);
      contained(root, actual, label);
      await handle.writeFile(bytes);
      await handle.sync();
    } finally {
      await handle.close();
    }
    try {
      if ((await lstat(target)).isSymbolicLink()) contract(`${label} target became a symlink`);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    await rename(staging, target);
    contained(root, await realpath(target), label);
  } finally {
    await rm(staging, { force: true });
    await parent.close();
  }
}

async function digestArtifact(artifact, state) {
  if (artifact.artifactKind === "file") {
    return sha256(await readContainedFile(artifact.path, state, `artifact ${artifact.artifactId}`));
  }
  const { root, candidate } = await resolvedPath(artifact.path, state, `artifact ${artifact.artifactId}`);
  const info = await lstat(candidate);
  if (!info.isDirectory()) contract(`artifact ${artifact.artifactId} is not a directory`);
  const manifest = [];
  async function walk(directory, prefix) {
    const entries = await readdir(directory, { withFileTypes: true });
    entries.sort((left, right) => left.name.localeCompare(right.name));
    for (const entry of entries) {
      const relativePath = prefix === "" ? entry.name : `${prefix}/${entry.name}`;
      const fullPath = join(directory, entry.name);
      contained(root, fullPath, `artifact ${artifact.artifactId}`);
      if (entry.isSymbolicLink()) contract(`artifact ${artifact.artifactId} contains symlink ${relativePath}`);
      if (entry.isDirectory()) await walk(fullPath, relativePath);
      else if (entry.isFile()) {
        const pathRef = artifact.path._tag === "RepoPathV1"
          ? { _tag: "RepoPathV1", relative: relative(state.repositoryRoot, fullPath) }
          : { _tag: "TempPathV1", tempdirId: artifact.path.tempdirId, relative: relative(root, fullPath) };
        manifest.push({ path: relativePath, sha256: sha256(await readContainedFile(pathRef, state, relativePath)) });
      } else contract(`artifact ${artifact.artifactId} contains unsupported entry ${relativePath}`);
    }
  }
  await walk(candidate, "");
  return sha256(canonicalJson(manifest));
}

async function observeArtifacts(plan, state, phase) {
  for (const artifact of plan.artifacts) {
    if (artifact.digestWhen !== phase && artifact.digestWhen !== "both") continue;
    const digest = await digestArtifact(artifact, state);
    if (artifact.expectedDigest !== null && artifact.expectedDigest !== digest) {
      contract(`artifact ${artifact.artifactId} digest mismatch: expected ${artifact.expectedDigest}, observed ${digest}`);
    }
    state.artifactObservations.push({ algorithm: "sha256", artifactId: artifact.artifactId, digest, phase });
  }
}

async function capture(stream, limit, stop) {
  const chunks = [];
  let observedBytes = 0;
  let storedBytes = 0;
  let exceeded = false;
  for await (const chunk of stream) {
    const bytes = Buffer.from(chunk);
    observedBytes += bytes.byteLength;
    const remaining = limit - storedBytes;
    if (remaining > 0) {
      const kept = bytes.subarray(0, remaining);
      chunks.push(kept);
      storedBytes += kept.byteLength;
    }
    if (observedBytes > limit && !exceeded) {
      exceeded = true;
      stop();
    }
  }
  return { bytes: Buffer.concat(chunks), exceeded, observedBytes };
}

function parseCompletionReceipt(text) {
  const match = /^subtree-reaped-v0 (exit|timeout) status=([0-9]+)\n$/.exec(text);
  if (match === null) contract("Rust supervisor emitted a malformed completion receipt");
  return { completionKind: match[1], status: Number.parseInt(match[2], 10) };
}

export async function runSupervised({
  supervisor,
  argv,
  cwd,
  env,
  deadlineSeconds,
  killGraceSeconds,
  terminationSignal,
  maxStdoutBytes,
  maxStderrBytes,
  completionReceiptPath,
}) {
  const child = Bun.spawn(
    [supervisor, String(deadlineSeconds), String(killGraceSeconds), "--", ...argv],
    {
      cwd,
      env: { ...env, BEAGLE_BOUNDED_COMPLETION_RECEIPT: completionReceiptPath },
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    },
  );
  let stopped = false;
  const stop = () => {
    if (!stopped) {
      stopped = true;
      child.kill(terminationSignal);
    }
  };
  const [stdout, stderr, status] = await Promise.all([
    capture(child.stdout, maxStdoutBytes, stop),
    capture(child.stderr, maxStderrBytes, stop),
    child.exited,
  ]);
  let completionText;
  try {
    completionText = await Bun.file(completionReceiptPath).text();
  } catch {
    contract(`Rust supervisor exited ${status} without a subtree-reaped receipt: ${stderr.bytes.toString("utf8")}`);
  }
  const completion = parseCompletionReceipt(completionText);
  if (completion.status !== status) contract("Rust supervisor status disagrees with its completion receipt");
  return { ...completion, stdout, stderr };
}

function artifactById(plan, id) {
  const artifact = plan.artifacts.find((candidate) => candidate.artifactId === id);
  if (artifact === undefined) contract(`unknown artifact ${id}`);
  return artifact;
}

function argumentValue(arg, state) {
  if (arg._tag === "LiteralArgV1") return arg.value;
  return resolvedPath(arg.path, state, "process argument").then(({ candidate }) => candidate);
}

async function executeProcess(effect, plan, state) {
  const argv = [];
  for (const arg of effect.argv) argv.push(await argumentValue(arg, state));
  const { candidate: cwd } = await resolvedPath(effect.cwd, state, `${effect.effectId}.cwd`);
  if (!(await lstat(cwd)).isDirectory()) contract(`${effect.effectId}.cwd is not a directory`);
  const env = Object.fromEntries(effect.environment.entries.map((entry) => [entry.name, entry.value]));
  const completionReceiptPath = join(state.controlRoot, `${effect.effectId}.receipt`);
  const outcome = await runSupervised({
    supervisor: state.supervisor,
    argv,
    cwd,
    env,
    deadlineSeconds: effect.deadlineSeconds,
    killGraceSeconds: effect.killGraceSeconds,
    terminationSignal: effect.terminationSignal,
    maxStdoutBytes: effect.maxStdoutBytes,
    maxStderrBytes: effect.maxStderrBytes,
    completionReceiptPath,
  });
  await atomicWrite(
    artifactById(plan, effect.stdoutArtifactId).path,
    outcome.stdout.bytes,
    state,
    `${effect.effectId}.stdout`,
  );
  await atomicWrite(
    artifactById(plan, effect.stderrArtifactId).path,
    outcome.stderr.bytes,
    state,
    `${effect.effectId}.stderr`,
  );
  const captureExceeded = outcome.stdout.exceeded || outcome.stderr.exceeded;
  return {
    accepted:
      outcome.completionKind === "exit" &&
      !captureExceeded &&
      effect.acceptedStatuses.includes(outcome.status),
    captureExceeded,
    completionKind: outcome.completionKind,
    effectId: effect.effectId,
    kind: "process",
    status: outcome.status,
    stderrBytes: outcome.stderr.observedBytes,
    stderrDigest: sha256(outcome.stderr.bytes),
    stdoutBytes: outcome.stdout.observedBytes,
    stdoutDigest: sha256(outcome.stdout.bytes),
    subtreeReaped: true,
  };
}

async function executeEffect(effect, plan, state) {
  switch (effect._tag) {
    case "TempdirAllocateV1": {
      const path = await mkdtemp(join(tmpdir(), effect.prefix));
      state.tempdirs.set(effect.tempdirId, await realpath(path));
      return { accepted: true, effectId: effect.effectId, kind: "tempdir-allocate", tempdirId: effect.tempdirId };
    }
    case "AtomicCopyV1": {
      const bytes = await readContainedFile(effect.source, state, `${effect.effectId}.source`);
      await atomicWrite(effect.target, bytes, state, `${effect.effectId}.target`);
      return { accepted: true, digest: sha256(bytes), effectId: effect.effectId, kind: "atomic-copy" };
    }
    case "AtomicReplaceExactV1": {
      const source = (await readContainedFile(effect.source, state, `${effect.effectId}.source`)).toString("utf8");
      const parts = source.split(effect.oldText);
      const count = parts.length - 1;
      if (count !== effect.expectedCount) {
        contract(`${effect.effectId} expected ${effect.expectedCount} occurrences, observed ${count}`);
      }
      const bytes = Buffer.from(parts.join(effect.newText), "utf8");
      await atomicWrite(effect.target, bytes, state, `${effect.effectId}.target`);
      return { accepted: true, digest: sha256(bytes), effectId: effect.effectId, kind: "atomic-replace-exact" };
    }
    case "ProcessRunV1":
      return executeProcess(effect, plan, state);
    default:
      contract(`unsupported operation ${String(effect._tag)}`);
  }
}

function changedLineCount(leftText, rightText) {
  const left = leftText.split("\n");
  const right = rightText.split("\n");
  const previous = new Uint32Array(right.length + 1);
  for (let leftIndex = 1; leftIndex <= left.length; leftIndex += 1) {
    const current = new Uint32Array(right.length + 1);
    for (let rightIndex = 1; rightIndex <= right.length; rightIndex += 1) {
      current[rightIndex] = left[leftIndex - 1] === right[rightIndex - 1]
        ? previous[rightIndex - 1] + 1
        : Math.max(previous[rightIndex], current[rightIndex - 1]);
    }
    previous.set(current);
  }
  const common = previous[right.length];
  return left.length - common + right.length - common;
}

async function evaluateCheck(check, plan, state) {
  switch (check._tag) {
    case "ProcessAcceptedCheckV1": {
      const observation = state.effectObservations.find((effect) => effect.effectId === check.effectId);
      return { effectId: check.effectId, kind: "process-accepted", passed: observation.accepted };
    }
    case "ArtifactContainsCheckV1": {
      const artifact = artifactById(plan, check.artifactId);
      const text = (await readContainedFile(artifact.path, state, `artifact ${check.artifactId}`)).toString("utf8");
      return { artifactId: check.artifactId, kind: "artifact-contains", needle: check.needle, passed: text.includes(check.needle) };
    }
    case "ArtifactChangedLineCountCheckV1": {
      const left = (await readContainedFile(artifactById(plan, check.leftArtifactId).path, state, check.leftArtifactId)).toString("utf8");
      const right = (await readContainedFile(artifactById(plan, check.rightArtifactId).path, state, check.rightArtifactId)).toString("utf8");
      const observed = changedLineCount(left, right);
      return {
        kind: "artifact-changed-line-count",
        leftArtifactId: check.leftArtifactId,
        maximum: check.maximum,
        observed,
        passed: observed <= check.maximum,
        rightArtifactId: check.rightArtifactId,
      };
    }
    default:
      contract(`unsupported check ${String(check._tag)}`);
  }
}

function validateReceiptObservation(observation, label) {
  object(observation, label);
  const shapes = {
    "tempdir-allocate": ["accepted", "effectId", "kind", "tempdirId"],
    "atomic-copy": ["accepted", "digest", "effectId", "kind"],
    "atomic-replace-exact": ["accepted", "digest", "effectId", "kind"],
    process: [
      "accepted", "captureExceeded", "completionKind", "effectId", "kind", "status",
      "stderrBytes", "stderrDigest", "stdoutBytes", "stdoutDigest", "subtreeReaped",
    ],
  };
  if (shapes[observation.kind] === undefined) contract(`${label}.kind is unsupported`);
  closed(observation, shapes[observation.kind], label);
  nonempty(observation.effectId, `${label}.effectId`);
  if (typeof observation.accepted !== "boolean") contract(`${label}.accepted must be boolean`);
  if (observation.kind === "process") {
    if (typeof observation.captureExceeded !== "boolean") contract(`${label}.captureExceeded must be boolean`);
    if (!["exit", "timeout"].includes(observation.completionKind)) contract(`${label}.completionKind is unsupported`);
    integer(observation.status, `${label}.status`, 0, 255);
    integer(observation.stdoutBytes, `${label}.stdoutBytes`);
    integer(observation.stderrBytes, `${label}.stderrBytes`);
    if (!/^[a-f0-9]{64}$/.test(observation.stdoutDigest)) contract(`${label}.stdoutDigest is invalid`);
    if (!/^[a-f0-9]{64}$/.test(observation.stderrDigest)) contract(`${label}.stderrDigest is invalid`);
    if (observation.subtreeReaped !== true) contract(`${label}.subtreeReaped must be true`);
  }
}

function validateReceiptCheck(check, label) {
  object(check, label);
  switch (check.kind) {
    case "process-accepted":
      closed(check, ["effectId", "kind", "passed"], label);
      nonempty(check.effectId, `${label}.effectId`);
      break;
    case "artifact-contains":
      closed(check, ["artifactId", "kind", "needle", "passed"], label);
      nonempty(check.artifactId, `${label}.artifactId`);
      nonempty(check.needle, `${label}.needle`);
      break;
    case "artifact-changed-line-count":
      closed(check, ["kind", "leftArtifactId", "maximum", "observed", "passed", "rightArtifactId"], label);
      nonempty(check.leftArtifactId, `${label}.leftArtifactId`);
      nonempty(check.rightArtifactId, `${label}.rightArtifactId`);
      integer(check.maximum, `${label}.maximum`);
      integer(check.observed, `${label}.observed`);
      break;
    default:
      contract(`${label}.kind is unsupported`);
  }
  if (typeof check.passed !== "boolean") contract(`${label}.passed must be boolean`);
}

export function validateReceipt(receipt) {
  closed(
    receipt,
    ["artifacts", "attemptRef", "authorizationRef", "cases", "effects", "finalVerdict", "intentRef", "planDigest", "planKind", "schemaVersion"],
    "receipt",
  );
  if (receipt.schemaVersion !== RECEIPT_SCHEMA) contract("receipt schema is unsupported");
  if (!/^[a-f0-9]{64}$/.test(receipt.planDigest)) contract("receipt.planDigest is invalid");
  for (const field of ["planKind", "intentRef", "authorizationRef", "attemptRef"]) nonempty(receipt[field], `receipt.${field}`);
  array(receipt.effects, "receipt.effects").forEach((effect, index) => validateReceiptObservation(effect, `receipt.effects[${index}]`));
  array(receipt.artifacts, "receipt.artifacts").forEach((artifact, index) => {
    const label = `receipt.artifacts[${index}]`;
    closed(artifact, ["algorithm", "artifactId", "digest", "phase"], label);
    if (artifact.algorithm !== "sha256") contract(`${label}.algorithm is unsupported`);
    nonempty(artifact.artifactId, `${label}.artifactId`);
    if (!/^[a-f0-9]{64}$/.test(artifact.digest)) contract(`${label}.digest is invalid`);
    if (!["before", "after"].includes(artifact.phase)) contract(`${label}.phase is unsupported`);
  });
  array(receipt.cases, "receipt.cases").forEach((semanticCase, index) => {
    const label = `receipt.cases[${index}]`;
    closed(semanticCase, ["caseId", "checks", "claim", "verdict"], label);
    nonempty(semanticCase.caseId, `${label}.caseId`);
    nonempty(semanticCase.claim, `${label}.claim`);
    array(semanticCase.checks, `${label}.checks`).forEach((check, checkIndex) =>
      validateReceiptCheck(check, `${label}.checks[${checkIndex}]`),
    );
    if (!["pass", "fail"].includes(semanticCase.verdict)) contract(`${label}.verdict is unsupported`);
  });
  if (!["pass", "fail"].includes(receipt.finalVerdict)) contract("receipt.finalVerdict is unsupported");
  return receipt;
}

export async function executeCanonicalPlan(planBytes, repositoryRoot, supervisor) {
  const planText = typeof planBytes === "string" ? planBytes : Buffer.from(planBytes).toString("utf8");
  let parsed;
  try {
    parsed = JSON.parse(planText);
  } catch (error) {
    contract(`plan is not JSON: ${error.message}`);
  }
  if (canonicalJson(parsed) !== planText) contract("plan bytes are not canonical JSON with one trailing newline");
  const plan = validatePlan(parsed);
  const root = await realpath(resolve(repositoryRoot));
  const state = {
    repositoryRoot: root,
    supervisor,
    controlRoot: await mkdtemp(join(tmpdir(), "beagle-task-effect-control-")),
    tempdirs: new Map(),
    artifactObservations: [],
    effectObservations: [],
  };
  try {
    await observeArtifacts(plan, state, "before");
    for (const effect of plan.effects) {
      state.effectObservations.push(await executeEffect(effect, plan, state));
    }
    await observeArtifacts(plan, state, "after");
    const cases = [];
    for (const semanticCase of plan.cases) {
      const checks = [];
      for (const check of semanticCase.checks) checks.push(await evaluateCheck(check, plan, state));
      cases.push({
        caseId: semanticCase.caseId,
        checks,
        claim: semanticCase.claim,
        verdict: checks.every((check) => check.passed) ? "pass" : "fail",
      });
    }
    const receipt = {
      artifacts: state.artifactObservations,
      attemptRef: plan.authority.attemptRef,
      authorizationRef: plan.authority.authorizationRef,
      cases,
      effects: state.effectObservations,
      finalVerdict: cases.every((semanticCase) => semanticCase.verdict === "pass") ? "pass" : "fail",
      intentRef: plan.authority.intentRef,
      planDigest: sha256(planText),
      planKind: plan.planKind,
      schemaVersion: RECEIPT_SCHEMA,
    };
    return validateReceipt(receipt);
  } finally {
    for (const path of state.tempdirs.values()) await rm(path, { recursive: true, force: true });
    await rm(state.controlRoot, { recursive: true, force: true });
  }
}
