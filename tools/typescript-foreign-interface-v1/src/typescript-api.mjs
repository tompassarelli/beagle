import { createHash } from "node:crypto";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { SourceTextModule } from "node:vm";

const BRIDGE_SOURCE_URL = typeof __BEAGLE_TYPESCRIPT_API_SOURCE_URL__ === "string"
  ? __BEAGLE_TYPESCRIPT_API_SOURCE_URL__
  : import.meta.url;
const BRIDGE_SOURCE_PATH = realpathSync(fileURLToPath(BRIDGE_SOURCE_URL));
const BRIDGE_ROOT = realpathSync(resolve(dirname(BRIDGE_SOURCE_PATH), ".."));
const TYPESCRIPT_SOURCE_PATH = realpathSync(resolve(BRIDGE_ROOT, "node_modules/typescript/lib/typescript.js"));
const PROJECT_LOCKFILES = ["bun.lock", "bun.lockb", "package-lock.json", "pnpm-lock.yaml", "yarn.lock"];
const BEAGLE_RUNTIME_MODULE = /^beagle\/([A-Za-z0-9._-]+\.js)$/;

const sha256Bytes = (bytes) => createHash("sha256").update(bytes).digest("hex");
const ownedBytes = (bytes) => Buffer.from(bytes);
const canonicalPath = (path) => realpathSync(path);
const sameBytes = (left, right) => left.length === right.length && left.equals(right);

const bindFileBytes = (path, label, suppliedBytes = null) => {
  const physicalPath = canonicalPath(path);
  const bytes = ownedBytes(suppliedBytes ?? readFileSync(physicalPath));
  const identity = sha256Bytes(bytes);
  const assertUnchanged = () => {
    let currentPath;
    let currentBytes;
    try {
      currentPath = canonicalPath(path);
      currentBytes = readFileSync(currentPath);
    } catch (error) {
      throw new Error(`${label} changed after snapshot: ${physicalPath}`, { cause: error });
    }
    if (currentPath !== physicalPath || !sameBytes(bytes, currentBytes)) {
      throw new Error(`${label} changed after snapshot: ${physicalPath}`);
    }
  };
  return Object.freeze({
    path: physicalPath,
    sha256: identity,
    bytes: () => ownedBytes(bytes),
    assertUnchanged,
  });
};

const typescriptSource = bindFileBytes(TYPESCRIPT_SOURCE_PATH, "TypeScript compiler");
typescriptSource.assertUnchanged();
const typescriptCommonJs = { exports: {} };
const executeTypeScript = Function(
  "require",
  "module",
  "exports",
  "__filename",
  "__dirname",
  typescriptSource.bytes().toString("utf8"),
);
executeTypeScript(
  createRequire(TYPESCRIPT_SOURCE_PATH),
  typescriptCommonJs,
  typescriptCommonJs.exports,
  TYPESCRIPT_SOURCE_PATH,
  dirname(TYPESCRIPT_SOURCE_PATH),
);
const ts = typescriptCommonJs.exports;
typescriptSource.assertUnchanged();

const TYPE_KINDS = new Map([
  [ts.TypeFlags.Any, "any"], [ts.TypeFlags.Unknown, "unknown"],
  [ts.TypeFlags.Never, "never"], [ts.TypeFlags.Void, "void"],
  [ts.TypeFlags.Undefined, "undefined"], [ts.TypeFlags.Null, "null"],
  [ts.TypeFlags.String, "string"], [ts.TypeFlags.Number, "number"],
  [ts.TypeFlags.Boolean, "boolean"], [ts.TypeFlags.BigInt, "bigint"],
  [ts.TypeFlags.ESSymbol, "symbol"], [ts.TypeFlags.StringLiteral, "literal"],
  [ts.TypeFlags.NumberLiteral, "literal"], [ts.TypeFlags.BooleanLiteral, "literal"],
  [ts.TypeFlags.BigIntLiteral, "literal"], [ts.TypeFlags.TypeParameter, "type-parameter"],
]);

const UNSUPPORTED_CODES = new Map([
  [ts.TypeFlags.Conditional, "TS_OPEN_CONDITIONAL"],
  [ts.TypeFlags.TemplateLiteral, "TS_TEMPLATE_LITERAL"],
  [ts.TypeFlags.StringMapping, "TS_STRING_MAPPING"],
  [ts.TypeFlags.Enum, "TS_ENUM"], [ts.TypeFlags.EnumLiteral, "TS_ENUM"],
  [ts.TypeFlags.UniqueESSymbol, "TS_UNIQUE_SYMBOL"],
  [ts.TypeFlags.Index, "TS_INDEX_TYPE"],
  [ts.TypeFlags.IndexedAccess, "TS_INDEXED_ACCESS"],
  [ts.TypeFlags.Substitution, "TS_SUBSTITUTION"],
  [ts.TypeFlags.NonPrimitive, "TS_NON_PRIMITIVE"],
]);

const declaration = (symbol) => symbol.valueDeclaration ?? symbol.declarations?.[0];
const exactFlag = (type, flag) => type.flags === flag;
const hasFlag = (value, flag) => (value & flag) !== 0;
const SUPPORTED_OBJECT_FLAGS = ts.ObjectFlags.Class | ts.ObjectFlags.Interface
  | ts.ObjectFlags.Reference | ts.ObjectFlags.Anonymous | ts.ObjectFlags.Mapped
  | ts.ObjectFlags.Instantiated | ts.ObjectFlags.ObjectLiteral;
let activeRuntime = null;
const logicalCanonical = (rootReal, pathReal, label) => {
  const value = relative(rootReal, pathReal).split(sep).join("/");
  if (!value || isAbsolute(value) || value === ".." || value.startsWith("../")) {
    throw new Error(`${label} is outside its authority root: ${pathReal} (root ${rootReal})`);
  }
  return value;
};
const digestSnapshot = (root, snapshot, label, prefix = "") => ({
  path: `${prefix}${logicalCanonical(root, snapshot.path, label)}`,
  sha256: snapshot.sha256,
});
const maybeLogicalCanonical = (root, path) => {
  try { return logicalCanonical(root, path, "file"); } catch { return null; }
};
const enclosingPackage = (file) => {
  let directory = dirname(file);
  while (true) {
    const candidate = resolve(directory, "package.json");
    if (existsSync(candidate)) return candidate;
    const parent = dirname(directory);
    if (parent === directory) throw new Error(`resolved declaration has no enclosing package.json: ${file}`);
    directory = parent;
  }
};

const createReadLedger = (baseDirectory) => {
  const byRequest = new Map();
  const byCanonical = new Map();
  const requestPath = (path) => isAbsolute(path) ? resolve(path) : resolve(baseDirectory, path);
  const readText = (path) => {
    const request = requestPath(path);
    const prior = byRequest.get(request);
    if (prior) return prior.text;
    let physicalPath;
    let before;
    let text;
    let after;
    try {
      physicalPath = canonicalPath(request);
      before = readFileSync(physicalPath);
      text = ts.sys.readFile(physicalPath);
      after = readFileSync(physicalPath);
    } catch {
      return undefined;
    }
    if (text === undefined || !sameBytes(before, after)) {
      throw new Error(`compiler input changed while being snapshotted: ${physicalPath}`);
    }
    let snapshot = byCanonical.get(physicalPath);
    if (snapshot) {
      if (!sameBytes(snapshot.bytes, before)) {
        throw new Error(`compiler input changed between reads: ${physicalPath}`);
      }
    } else {
      const copy = ownedBytes(before);
      snapshot = {
        path: physicalPath,
        bytes: copy,
        sha256: sha256Bytes(copy),
        text,
        requests: new Set(),
      };
      byCanonical.set(physicalPath, snapshot);
    }
    snapshot.requests.add(request);
    byRequest.set(request, snapshot);
    return snapshot.text;
  };
  const required = (path, label) => {
    if (readText(path) === undefined) throw new Error(`${label} is unreadable: ${path}`);
    return record(path, label);
  };
  const record = (path, label = "compiler input") => {
    const request = requestPath(path);
    const direct = byRequest.get(request);
    if (direct) return direct;
    let physicalPath;
    try { physicalPath = canonicalPath(request); } catch {
      throw new Error(`${label} was not snapshotted: ${path}`);
    }
    const snapshot = byCanonical.get(physicalPath);
    if (!snapshot) throw new Error(`${label} was not snapshotted: ${physicalPath}`);
    return snapshot;
  };
  const assertStable = () => {
    for (const snapshot of byCanonical.values()) {
      let currentBytes;
      try { currentBytes = readFileSync(snapshot.path); } catch (error) {
        throw new Error(`compiler input changed after snapshot: ${snapshot.path}`, { cause: error });
      }
      if (!sameBytes(snapshot.bytes, currentBytes)) {
        throw new Error(`compiler input changed after snapshot: ${snapshot.path}`);
      }
      for (const request of snapshot.requests) {
        let currentPath;
        try { currentPath = canonicalPath(request); } catch (error) {
          throw new Error(`compiler input changed after snapshot: ${request}`, { cause: error });
        }
        if (currentPath !== snapshot.path) {
          throw new Error(`compiler input changed after snapshot: ${request}`);
        }
      }
    }
  };
  return Object.freeze({
    assertStable,
    readText,
    record,
    records: () => [...byCanonical.values()],
    required,
  });
};

const bindProjectLocks = (projectRoot) => {
  const presentNames = () => PROJECT_LOCKFILES.filter((name) => existsSync(resolve(projectRoot, name)));
  const names = presentNames();
  const snapshots = names.map((name) => bindFileBytes(resolve(projectRoot, name), `project lockfile ${name}`));
  return Object.freeze({
    files: snapshots,
    assertUnchanged() {
      const current = presentNames();
      if (current.length !== names.length || current.some((name, index) => name !== names[index])) {
        throw new Error(`project lockfile set changed after snapshot: ${projectRoot}`);
      }
      snapshots.forEach((snapshot) => snapshot.assertUnchanged());
    },
  });
};

const canonicalDigestFiles = (files) => {
  const byPath = new Map();
  for (const file of files) {
    const prior = byPath.get(file.path);
    if (prior && prior.sha256 !== file.sha256) {
      throw new Error(`provenance path has conflicting byte identities: ${file.path}`);
    }
    byPath.set(file.path, file);
  }
  return [...byPath.values()].sort((left, right) => left.path < right.path ? -1 : left.path > right.path ? 1 : 0);
};

export function bindProducerInputs({ adapterRoot, runnerBytes = null, bridgeBytes = null }) {
  const root = canonicalPath(adapterRoot);
  if (root !== BRIDGE_ROOT) {
    throw new Error(`Compiler API bridge authority root mismatch: ${root} (expected ${BRIDGE_ROOT})`);
  }
  const runner = bindFileBytes(resolve(root, "src/run.mjs"), "TypeScript adapter runner", runnerBytes);
  const bridge = bindFileBytes(resolve(root, "src/typescript-api.mjs"), "TypeScript Compiler API bridge", bridgeBytes);
  runner.assertUnchanged();
  bridge.assertUnchanged();
  return Object.freeze({
    assertUnchanged() {
      runner.assertUnchanged();
      bridge.assertUnchanged();
    },
    files: Object.freeze([
      digestSnapshot(root, runner, "TypeScript adapter runner", "adapter/"),
      digestSnapshot(root, bridge, "TypeScript Compiler API bridge", "adapter/"),
    ]),
  });
}

export function createContext({ projectRoot, containingFile, moduleSpecifier, conditions }) {
  const canonicalProjectRoot = canonicalPath(projectRoot);
  const canonicalContainingFile = canonicalPath(containingFile);
  const compilerOptions = {
    customConditions: [...conditions].sort(),
    module: ts.ModuleKind.NodeNext,
    moduleResolution: ts.ModuleResolutionKind.NodeNext,
    noEmit: true,
    skipLibCheck: true,
    strict: true,
    target: ts.ScriptTarget.ESNext,
  };
  logicalCanonical(canonicalProjectRoot, canonicalContainingFile, "containing file");
  const projectLocks = bindProjectLocks(canonicalProjectRoot);
  const reads = createReadLedger(canonicalProjectRoot);
  reads.required(canonicalContainingFile, "containing file");
  const host = ts.createCompilerHost(compilerOptions, true);
  host.getCurrentDirectory = () => canonicalProjectRoot;
  host.readFile = (path) => reads.readText(path);
  const getSourceFile = host.getSourceFile.bind(host);
  host.getSourceFile = (fileName, ...arguments_) => {
    const sourceFile = getSourceFile(fileName, ...arguments_);
    if (!sourceFile) return sourceFile;
    const snapshot = reads.record(fileName, "parsed Program source input");
    if (sourceFile.text !== snapshot.text) {
      throw new Error(`Program parsed bytes outside the shared input snapshot: ${snapshot.path}`);
    }
    return sourceFile;
  };
  const resolved = ts.resolveModuleName(
    moduleSpecifier,
    canonicalContainingFile,
    compilerOptions,
    host,
  ).resolvedModule;
  if (!resolved) throw new Error(`cannot resolve TypeScript module ${moduleSpecifier} from ${containingFile}`);
  const packagePath = enclosingPackage(resolved.resolvedFileName);
  logicalCanonical(canonicalProjectRoot, canonicalPath(packagePath), "resolved package");
  const packageSnapshot = reads.required(packagePath, "resolved package");
  const program = ts.createProgram([resolved.resolvedFileName], compilerOptions, host);
  const diagnostics = ts.getPreEmitDiagnostics(program);
  if (diagnostics.length) {
    throw new Error(ts.formatDiagnosticsWithColorAndContext(diagnostics, {
      getCanonicalFileName: (path) => path,
      getCurrentDirectory: () => canonicalProjectRoot,
      getNewLine: () => "\n",
    }));
  }
  const checker = program.getTypeChecker();
  const source = program.getSourceFile(resolved.resolvedFileName);
  if (!source) throw new Error(`resolved declaration is absent from Program: ${resolved.resolvedFileName}`);
  const moduleSymbol = checker.getSymbolAtLocation(source);
  if (!moduleSymbol) throw new Error(`resolved declaration has no module symbol: ${resolved.resolvedFileName}`);
  const programInputs = program.getSourceFiles().map((programSource) => reads.record(
    programSource.fileName,
    "Program source input",
  ));
  return {
    checker, compilerOptions, conditions: [...conditions].sort(), moduleSymbol,
    packagePath: packageSnapshot.path, program, programInputs, projectLocks,
    projectRoot: canonicalProjectRoot, reads, resolved,
  };
}

export function bindCompiledAdapter(path) {
  const snapshot = bindFileBytes(path, "compiled adapter");
  const runtimeSnapshots = new Map();
  let runtime = null;
  return Object.freeze({
    sha256: snapshot.sha256,
    runtimeFiles() {
      if (!runtime) throw new Error("compiled adapter has not bound a Beagle runtime");
      return [...runtimeSnapshots.values()].map((runtimeSnapshot) => {
        runtimeSnapshot.assertUnchanged();
        return {
          path: `runtime/${logicalCanonical(runtime.root, runtimeSnapshot.path, "Beagle runtime module")}`,
          sha256: runtimeSnapshot.sha256,
        };
      });
    },
    async load(runtimeRoot) {
      const canonicalRuntimeRoot = canonicalPath(runtimeRoot);
      if (activeRuntime && activeRuntime.root !== canonicalRuntimeRoot) {
        throw new Error(`compiled adapter process is already bound to Beagle runtime ${activeRuntime.root}`);
      }
      if (!activeRuntime) {
        activeRuntime = { modules: new Map(), root: canonicalRuntimeRoot };
      }
      runtime = activeRuntime;
      const runtimeModule = (specifier, referencingModule) => {
        const bare = BEAGLE_RUNTIME_MODULE.exec(specifier);
        const relativeRuntimeImport = (specifier.startsWith("./") || specifier.startsWith("../"))
          && maybeLogicalCanonical(runtime.root, referencingModule.identifier) !== null;
        if (!bare && !relativeRuntimeImport) {
          throw new Error(`compiled adapter import is outside the bound Beagle runtime: ${specifier}`);
        }
        const requestedPath = bare
          ? resolve(runtime.root, bare[1])
          : resolve(dirname(referencingModule.identifier), specifier);
        const physicalPath = canonicalPath(requestedPath);
        let record = runtime.modules.get(physicalPath);
        if (!record) {
          const runtimeSnapshot = bindFileBytes(
            physicalPath,
            `Beagle runtime module ${specifier}`,
          );
          logicalCanonical(runtime.root, runtimeSnapshot.path, "Beagle runtime module");
          record = {
            snapshot: runtimeSnapshot,
            source: new SourceTextModule(runtimeSnapshot.bytes().toString("utf8"), {
              identifier: runtimeSnapshot.path,
            }),
          };
          runtime.modules.set(runtimeSnapshot.path, record);
        }
        runtimeSnapshots.set(record.snapshot.path, record.snapshot);
        return record.source;
      };
      const adapter = new SourceTextModule(snapshot.bytes().toString("utf8"), {
        identifier: snapshot.path,
      });
      await adapter.link(runtimeModule);
      await adapter.evaluate();
      return adapter.namespace;
    },
  });
}

export function foreignInterfaceBuilder(module) {
  const candidates = [
    module["build-foreign-interface-v1!"],
    module.build_foreign_interface_v1_bang,
  ].filter((value) => typeof value === "function");
  if (candidates.length !== 1) {
    throw new Error("compiled adapter must expose exactly one build-foreign-interface-v1! implementation");
  }
  return candidates[0];
}

export function createCompilerBridge({ adapterRoot, compiledAdapter, producerInputs = null }) {
  const root = canonicalPath(adapterRoot);
  if (root !== BRIDGE_ROOT) {
    throw new Error(`Compiler API bridge authority root mismatch: ${root} (expected ${BRIDGE_ROOT})`);
  }
  const own = (name) => resolve(root, name);
  const adapterSource = bindFileBytes(own("src/adapter.bjs"), "typed adapter source");
  const adapterLock = bindFileBytes(own("bun.lock"), "adapter lockfile");
  const producer = producerInputs ?? bindProducerInputs({ adapterRoot: root });
  const typescriptRoot = canonicalPath(own("node_modules/typescript"));
  const compilerInputDigest = (context, snapshot) => {
    const typescriptPath = maybeLogicalCanonical(typescriptRoot, snapshot.path);
    if (typescriptPath) {
      return { path: `adapter/node_modules/typescript/${typescriptPath}`, sha256: snapshot.sha256 };
    }
    const projectPath = maybeLogicalCanonical(context.projectRoot, snapshot.path);
    if (projectPath) return { path: `project/${projectPath}`, sha256: snapshot.sha256 };
    const adapterPath = maybeLogicalCanonical(root, snapshot.path);
    if (adapterPath) return { path: `adapter/${adapterPath}`, sha256: snapshot.sha256 };
    throw new Error(`compiler input is outside project and adapter authority roots: ${snapshot.path}`);
  };
  const forcedCodes = new WeakMap();
  const brand = (context, type) => {
    if (!type.isIntersection?.()) return null;
    const marker = context.checker.getPropertiesOfType(type).find((property) => property.getName() === "__brand");
    if (!marker) return null;
    const markerType = context.checker.getTypeOfSymbolAtLocation(marker, declaration(marker));
    return exactFlag(markerType, ts.TypeFlags.StringLiteral) ? markerType.value : marker.getName();
  };
  const tupleElements = (context, type) => {
    const args = context.checker.getTypeArguments(type);
    const labels = type.target?.labeledElementDeclarations ?? [];
    const flags = type.target?.elementFlags ?? [];
    return args.map((elementType, index) => ({
      elementType,
      flag: flags[index] ?? 0,
      label: labels[index]?.name?.getText() ?? null,
    }));
  };
  const unsupportedCode = (type) => {
    const forced = forcedCodes.get(type);
    if (forced) return forced;
    if (hasFlag(type.flags, ts.TypeFlags.Enum | ts.TypeFlags.EnumLiteral)) return "TS_ENUM";
    if (hasFlag(type.flags, ts.TypeFlags.UniqueESSymbol)) return "TS_UNIQUE_SYMBOL";
    return UNSUPPORTED_CODES.get(type.flags) ?? `TS_UNSUPPORTED_TYPE_FLAGS_${type.flags}`;
  };
  const typeKind = (context, type) => {
    if (forcedCodes.has(type)) return "unsupported";
    if (brand(context, type)) return "brand";
    if (context.checker.isTupleType(type)) return "tuple";
    if (context.checker.isArrayType(type)) return "array";
    const primitive = TYPE_KINDS.get(type.flags);
    if (primitive) return primitive;
    if (hasFlag(type.flags, ts.TypeFlags.Enum | ts.TypeFlags.EnumLiteral | ts.TypeFlags.UniqueESSymbol)) return "unsupported";
    if (type.isUnion?.()) return "union";
    if (type.isIntersection?.()) return "intersection";
    if (!exactFlag(type, ts.TypeFlags.Object)) return "unsupported";
    if (hasFlag(type.objectFlags, ts.ObjectFlags.Reference) && type.target !== type) return "reference";
    if (type.getCallSignatures().length > 0 && type.getProperties().length === 0) return "function";
    const shape = type.objectFlags & ts.ObjectFlags.ObjectTypeKindMask;
    return shape !== 0 && (shape & ~SUPPORTED_OBJECT_FLAGS) === 0 ? "object" : "unsupported";
  };
  return {
    array: () => [],
    arrayElementType(type) { return this.context.checker.getElementTypeOfArrayType(type); },
    brandBase: (type) => type.types.find((member) => !exactFlag(member, ts.TypeFlags.Object)) ?? type.types[0],
    brandName(type) { return brand(this.context, type); },
    callSignatures: (type) => type.getCallSignatures(),
    constructSignatures: (type) => type.getConstructSignatures(),
    equal: Object.is,
    exportType(symbol) {
      const context = this.context;
      const type = hasFlag(symbol.flags, ts.SymbolFlags.Value)
        ? context.checker.getTypeOfSymbolAtLocation(symbol, declaration(symbol))
        : context.checker.getDeclaredTypeOfSymbol(symbol);
      if (symbol.declarations?.some(ts.isEnumDeclaration)) forcedCodes.set(type, "TS_ENUM");
      return type;
    },
    indexInfos(type) { return this.context.checker.getIndexInfosOfType(type); },
    indexKeyType: (index) => index.keyType,
    indexValueType: (index) => index.type,
    literalKind: (type) => exactFlag(type, ts.TypeFlags.StringLiteral) ? "string"
      : exactFlag(type, ts.TypeFlags.NumberLiteral) ? "number"
      : exactFlag(type, ts.TypeFlags.BooleanLiteral) ? "boolean" : "bigint",
    literalValue: (type) => exactFlag(type, ts.TypeFlags.BooleanLiteral)
      ? type.intrinsicName === "true"
      : typeof type.value === "object" ? String(type.value.base10Value) : type.value,
    moduleExports(context) { this.context = context; return context.checker.getExportsOfModule(context.moduleSymbol); },
    "nominalReference?": (type) => Boolean(type.symbol?.valueDeclaration && ts.isClassDeclaration(type.symbol.valueDeclaration)),
    objectTypeParameters: (type) => type.typeParameters ?? [],
    "optionalSymbol?": (symbol) => hasFlag(symbol.flags, ts.SymbolFlags.Optional),
    pad: (value, width) => String(value).padStart(width, "0"),
    parameterType(signature, parameter) { return this.context.checker.getTypeOfSymbolAtLocation(parameter, declaration(parameter) ?? signature.declaration); },
    propertiesOfType(type) { return this.context.checker.getPropertiesOfType(type); },
    propertyType(owner, property) { return this.context.checker.getTypeOfSymbolAtLocation(property, declaration(property) ?? owner.symbol?.declarations?.[0]); },
    push: (values, value) => values.push(value),
    provenance(context, moduleSpecifier, conditions) {
      context.reads.assertStable();
      context.projectLocks.assertUnchanged();
      producer.assertUnchanged();
      adapterSource.assertUnchanged();
      adapterLock.assertUnchanged();
      typescriptSource.assertUnchanged();
      const programPaths = new Set(context.programInputs.map((snapshot) => snapshot.path));
      for (const source of context.program.getSourceFiles()) {
        const snapshot = context.reads.record(source.fileName, "Program source input");
        if (!programPaths.has(snapshot.path)) {
          throw new Error(`Program source escaped the snapshotted input set: ${snapshot.path}`);
        }
      }
      const files = canonicalDigestFiles([
        ...producer.files,
        ...compiledAdapter.runtimeFiles(),
        ...context.reads.records().map((snapshot) => compilerInputDigest(context, snapshot)),
        ...context.projectLocks.files.map((snapshot) => ({
          path: `project/${logicalCanonical(context.projectRoot, snapshot.path, "project lockfile")}`,
          sha256: snapshot.sha256,
        })),
      ]);
      const packageSnapshot = context.reads.record(context.packagePath, "resolved package");
      return {
        adapter: {
          source: logicalCanonical(root, adapterSource.path, "adapter source"),
          sourceSha256: adapterSource.sha256,
          compiled: `compiled/${compiledAdapter.sha256}.mjs`,
          compiledSha256: compiledAdapter.sha256,
          version: "1.0.0",
        },
        typescript: {
          version: ts.version,
          path: logicalCanonical(root, typescriptSource.path, "TypeScript compiler"),
          sha256: typescriptSource.sha256,
        },
        compilerOptions: {
          customConditions: [...conditions].sort(), module: "NodeNext", moduleResolution: "NodeNext",
          noEmit: true, skipLibCheck: true, strict: true, target: "ESNext",
        },
        moduleSpecifier,
        conditions: [...conditions].sort(),
        package: {
          path: `project/${logicalCanonical(context.projectRoot, packageSnapshot.path, "resolved package")}`,
          sha256: packageSnapshot.sha256,
        },
        lockfile: digestSnapshot(root, adapterLock, "adapter lockfile"),
        consultedFiles: files,
      };
    },
    "readonlyArray?": (type) => Boolean(type.target?.readonly),
    "readonlyIndex?": (index) => index.isReadonly,
    "readonlyProperty?": (_owner, symbol) => {
      const declared = declaration(symbol)?.modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.ReadonlyKeyword) ?? false;
      return declared || hasFlag(ts.getCheckFlags(symbol), ts.CheckFlags.Readonly);
    },
    referenceTarget: (type) => type.target && type.target !== type ? type.target : null,
    resolveAlias(symbol) { return hasFlag(symbol.flags, ts.SymbolFlags.Alias) ? this.context.checker.getAliasedSymbol(symbol) : symbol; },
    "restParameter?": (symbol) => Boolean(declaration(symbol)?.dotDotDotToken),
    signatureParameters: (signature) => signature.getParameters(),
    signatureReturnType(signature) { return this.context.checker.getReturnTypeOfSignature(signature); },
    signatureTypeParameters: (signature) => signature.getTypeParameters?.() ?? [],
    sort(values) {
      return [...values].sort((a, b) => {
        const key = (value) => typeof value === "string" ? value
          : typeof value.id === "string" ? value.id
          : String(value.name ?? value.getName?.() ?? "");
        const left = key(a);
        const right = key(b);
        return left < right ? -1 : left > right ? 1 : 0;
      });
    },
    state: () => new Map(),
    symbolName: (symbol) => symbol.getName(),
    symbolSpace(symbol) {
      const value = hasFlag(symbol.flags, ts.SymbolFlags.Value);
      const type = hasFlag(symbol.flags, ts.SymbolFlags.Type);
      return value && type ? "both" : value ? "value" : "type";
    },
    tupleElementName: (element) => element.label,
    "tupleElementOptional?": (element) => hasFlag(element.flag, ts.ElementFlags.Optional),
    "tupleElementRest?": (element) => hasFlag(element.flag, ts.ElementFlags.Rest),
    tupleElementType: (element) => element.elementType,
    tupleElements(type) { return tupleElements(this.context, type); },
    typeArguments(type) { return this.context.checker.getTypeArguments?.(type) ?? type.typeArguments ?? []; },
    typeDisplay(type) { return this.context.checker.typeToString(type, undefined, ts.TypeFormatFlags.NoTruncation); },
    typeKind(type) { return typeKind(this.context, type); },
    typeMembers: (type) => type.types,
    typeName: (type) => type.aliasSymbol?.getName() ?? type.symbol?.getName() ?? "anonymous",
    typeParameterConstraint: (type) => type.getConstraint?.() ?? type.constraint ?? null,
    typeParameterDefault: (type) => type.getDefault?.() ?? type.default ?? null,
    unsupportedCode,
    weakMap: () => new WeakMap(),
  };
}
