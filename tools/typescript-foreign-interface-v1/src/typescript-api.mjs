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
const TYPESCRIPT_RUNTIME_ROOT = realpathSync(
  typeof __BEAGLE_TYPESCRIPT_RUNTIME_ROOT__ === "string"
    ? __BEAGLE_TYPESCRIPT_RUNTIME_ROOT__
    : BRIDGE_ROOT,
);
const TYPESCRIPT_SOURCE_PATH = realpathSync(resolve(
  TYPESCRIPT_RUNTIME_ROOT,
  "node_modules/typescript/lib/typescript.js",
));
const PROJECT_LOCKFILES = ["bun.lock", "bun.lockb", "package-lock.json", "pnpm-lock.yaml", "yarn.lock"];
const BEAGLE_RUNTIME_MODULE = /^beagle\/([A-Za-z0-9._-]+\.js)$/;
const TYPESCRIPT_RUNTIME_PRIMITIVES = new Map([
  ["ArrayBuffer", "js-array-buffer"],
]);
const BUILTIN_AMBIENT_MODULES = new Map([
  ["bun:test", Object.freeze({
    logicalPath: "builtins/bun-test.d.ts",
    source: [
      'declare module "bun:test" {',
      "  interface BeagleBoolExpectation {",
      "    toBe(expected: boolean): void;",
      "    toEqual(expected: boolean): void;",
      "  }",
      "  interface BeagleStringExpectation {",
      "    toBe(expected: string): void;",
      "    toEqual(expected: string): void;",
      "  }",
      "  interface BeagleStringVectorExpectation {",
      "    toBe(expected: readonly string[]): void;",
      "    toEqual(expected: readonly string[]): void;",
      "  }",
      "  export function expect(actual: boolean): BeagleBoolExpectation;",
      "  export function expect(actual: string): BeagleStringExpectation;",
      "  export function expect(actual: readonly string[]): BeagleStringVectorExpectation;",
      "  export function test(name: string, body: () => void): void;",
      "}",
      "",
    ].join("\n"),
  })],
]);

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
  [ts.TypeFlags.StringMapping, "TS_STRING_MAPPING"],
  [ts.TypeFlags.Enum, "TS_ENUM"], [ts.TypeFlags.EnumLiteral, "TS_ENUM"],
  [ts.TypeFlags.UniqueESSymbol, "TS_UNIQUE_SYMBOL"],
  [ts.TypeFlags.Index, "TS_INDEX_TYPE"],
  [ts.TypeFlags.IndexedAccess, "TS_INDEXED_ACCESS"],
  [ts.TypeFlags.Substitution, "TS_SUBSTITUTION"],
]);

const declaration = (symbol) => symbol?.valueDeclaration ?? symbol?.declarations?.[0];
const exactFlag = (type, flag) => type.flags === flag;
const hasFlag = (value, flag) => (value & flag) !== 0;
const canonicalNodeKind = (node) => {
  if (!node) return "Missing";
  const predicates = [
    [ts.isSourceFile, "SourceFile"],
    [ts.isImportDeclaration, "ImportDeclaration"],
    [ts.isImportSpecifier, "ImportSpecifier"],
    [ts.isTypeAliasDeclaration, "TypeAliasDeclaration"],
    [ts.isInterfaceDeclaration, "InterfaceDeclaration"],
    [ts.isPropertySignature, "PropertySignature"],
    [ts.isMethodSignature, "MethodSignature"],
    [ts.isFunctionDeclaration, "FunctionDeclaration"],
    [ts.isVariableStatement, "VariableStatement"],
    [ts.isVariableDeclaration, "VariableDeclaration"],
    [ts.isParameter, "Parameter"],
    [ts.isBlock, "Block"],
    [ts.isReturnStatement, "ReturnStatement"],
    [ts.isIfStatement, "IfStatement"],
    [ts.isExpressionStatement, "ExpressionStatement"],
    [ts.isForOfStatement, "ForOfStatement"],
    [ts.isBreakStatement, "BreakStatement"],
    [ts.isIdentifier, "Identifier"],
    [ts.isStringLiteral, "StringLiteral"],
    [ts.isNumericLiteral, "NumericLiteral"],
    [ts.isRegularExpressionLiteral, "RegularExpressionLiteral"],
    [ts.isNoSubstitutionTemplateLiteral, "NoSubstitutionTemplateLiteral"],
    [ts.isTemplateExpression, "TemplateExpression"],
    [ts.isTemplateSpan, "TemplateSpan"],
    [ts.isArrowFunction, "ArrowFunction"],
    [ts.isAwaitExpression, "AwaitExpression"],
    [ts.isCallExpression, "CallExpression"],
    [ts.isPropertyAccessExpression, "PropertyAccessExpression"],
    [ts.isElementAccessExpression, "ElementAccessExpression"],
    [ts.isBinaryExpression, "BinaryExpression"],
    [ts.isPrefixUnaryExpression, "PrefixUnaryExpression"],
    [ts.isConditionalExpression, "ConditionalExpression"],
    [ts.isObjectLiteralExpression, "ObjectLiteralExpression"],
    [ts.isPropertyAssignment, "PropertyAssignment"],
    [ts.isShorthandPropertyAssignment, "ShorthandPropertyAssignment"],
    [ts.isArrayLiteralExpression, "ArrayLiteralExpression"],
    [ts.isSpreadElement, "SpreadElement"],
    [ts.isAsExpression, "AsExpression"],
    [ts.isNonNullExpression, "NonNullExpression"],
    [ts.isParenthesizedExpression, "ParenthesizedExpression"],
    [ts.isObjectBindingPattern, "ObjectBindingPattern"],
    [ts.isArrayBindingPattern, "ArrayBindingPattern"],
    [ts.isBindingElement, "BindingElement"],
  ];
  for (const [predicate, name] of predicates) if (predicate(node)) return name;
  if (node.kind === ts.SyntaxKind.TrueKeyword) return "TrueKeyword";
  if (node.kind === ts.SyntaxKind.FalseKeyword) return "FalseKeyword";
  if (node.kind === ts.SyntaxKind.NullKeyword) return "NullKeyword";
  if (node.kind === ts.SyntaxKind.UndefinedKeyword) return "UndefinedKeyword";
  return ts.SyntaxKind[node.kind];
};

const canonicalTokenKind = (node) => {
  if (!node) return "";
  const names = new Map([
    [ts.SyntaxKind.EqualsToken, "EqualsToken"],
    [ts.SyntaxKind.PlusToken, "PlusToken"],
    [ts.SyntaxKind.MinusToken, "MinusToken"],
    [ts.SyntaxKind.AsteriskToken, "AsteriskToken"],
    [ts.SyntaxKind.SlashToken, "SlashToken"],
    [ts.SyntaxKind.BarToken, "BarToken"],
    [ts.SyntaxKind.PlusEqualsToken, "PlusEqualsToken"],
    [ts.SyntaxKind.MinusEqualsToken, "MinusEqualsToken"],
    [ts.SyntaxKind.AsteriskEqualsToken, "AsteriskEqualsToken"],
    [ts.SyntaxKind.SlashEqualsToken, "SlashEqualsToken"],
    [ts.SyntaxKind.LessThanToken, "LessThanToken"],
    [ts.SyntaxKind.LessThanEqualsToken, "LessThanEqualsToken"],
    [ts.SyntaxKind.GreaterThanToken, "GreaterThanToken"],
    [ts.SyntaxKind.GreaterThanEqualsToken, "GreaterThanEqualsToken"],
    [ts.SyntaxKind.EqualsEqualsToken, "EqualsEqualsToken"],
    [ts.SyntaxKind.EqualsEqualsEqualsToken, "EqualsEqualsEqualsToken"],
    [ts.SyntaxKind.ExclamationEqualsToken, "ExclamationEqualsToken"],
    [ts.SyntaxKind.ExclamationEqualsEqualsToken, "ExclamationEqualsEqualsToken"],
    [ts.SyntaxKind.AmpersandAmpersandToken, "AmpersandAmpersandToken"],
    [ts.SyntaxKind.BarBarToken, "BarBarToken"],
    [ts.SyntaxKind.QuestionQuestionToken, "QuestionQuestionToken"],
    [ts.SyntaxKind.QuestionQuestionEqualsToken, "QuestionQuestionEqualsToken"],
    [ts.SyntaxKind.ExclamationToken, "ExclamationToken"],
  ]);
  return names.get(node.kind) ?? ts.SyntaxKind[node.kind];
};
const nodeEffectful = (node) => {
  let effectful = false;
  const visit = (current) => {
    if (!current || effectful) return;
    if (
      (ts.isBinaryExpression(current)
        && current.operatorToken.kind >= ts.SyntaxKind.FirstAssignment
        && current.operatorToken.kind <= ts.SyntaxKind.LastAssignment)
      || ((ts.isPrefixUnaryExpression(current) || ts.isPostfixUnaryExpression(current))
        && (current.operator === ts.SyntaxKind.PlusPlusToken
          || current.operator === ts.SyntaxKind.MinusMinusToken))
      || ts.isBreakStatement(current)
      || ts.isContinueStatement(current)
    ) {
      effectful = true;
      return;
    }
    ts.forEachChild(current, visit);
  };
  visit(node);
  return effectful;
};
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

export function bindProducerInputs({
  adapterRoot,
  runnerBytes = null,
  bridgeBytes = null,
  runnerName = "src/run.mjs",
}) {
  const root = canonicalPath(adapterRoot);
  if (root !== BRIDGE_ROOT) {
    throw new Error(`Compiler API bridge authority root mismatch: ${root} (expected ${BRIDGE_ROOT})`);
  }
  const runner = bindFileBytes(resolve(root, runnerName), "TypeScript adapter runner", runnerBytes);
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

export function createSourceContext({ projectRoot, sourceFile }) {
  const canonicalProjectRoot = canonicalPath(projectRoot);
  const canonicalSourceFile = canonicalPath(sourceFile);
  logicalCanonical(canonicalProjectRoot, canonicalSourceFile, "TypeScript source file");
  const compilerOptions = {
    allowImportingTsExtensions: true,
    module: ts.ModuleKind.ESNext,
    moduleResolution: ts.ModuleResolutionKind.Bundler,
    noEmit: true,
    skipLibCheck: true,
    strict: true,
    target: ts.ScriptTarget.ESNext,
  };
  const projectLocks = bindProjectLocks(canonicalProjectRoot);
  const reads = createReadLedger(canonicalProjectRoot);
  reads.required(canonicalSourceFile, "TypeScript source file");
  const host = ts.createCompilerHost(compilerOptions, true);
  host.getCurrentDirectory = () => canonicalProjectRoot;
  host.readFile = (path) => reads.readText(path);
  const getSourceFile = host.getSourceFile.bind(host);
  host.getSourceFile = (fileName, ...arguments_) => {
    const parsed = getSourceFile(fileName, ...arguments_);
    if (!parsed) return parsed;
    const snapshot = reads.record(fileName, "parsed Program source input");
    if (parsed.text !== snapshot.text) {
      throw new Error(`Program parsed bytes outside the shared input snapshot: ${snapshot.path}`);
    }
    return parsed;
  };
  const program = ts.createProgram([canonicalSourceFile], compilerOptions, host);
  const source = program.getSourceFile(canonicalSourceFile);
  if (!source) throw new Error(`TypeScript source is absent from Program: ${canonicalSourceFile}`);
  const diagnostics = ts.getPreEmitDiagnostics(program, source);
  if (diagnostics.length) {
    throw new Error(ts.formatDiagnosticsWithColorAndContext(diagnostics, {
      getCanonicalFileName: (path) => path,
      getCurrentDirectory: () => canonicalProjectRoot,
      getNewLine: () => "\n",
    }));
  }
  const programInputs = program.getSourceFiles().map((programSource) => reads.record(
    programSource.fileName,
    "Program source input",
  ));
  return {
    checker: program.getTypeChecker(), compilerOptions, program, programInputs,
    projectLocks, projectRoot: canonicalProjectRoot, reads, source,
  };
}

export function createContext({ projectRoot, containingFile, moduleSpecifier, ambientNames = [], conditions }) {
  const canonicalProjectRoot = canonicalPath(projectRoot);
  const canonicalContainingFile = canonicalPath(containingFile);
  const ambientProvider = ambientNames.length > 0;
  const compilerOptions = {
    customConditions: [...conditions].sort(),
    module: ts.ModuleKind.ESNext,
    moduleResolution: ts.ModuleResolutionKind.Bundler,
    noEmit: true,
    skipLibCheck: true,
    strict: true,
    target: ts.ScriptTarget.ESNext,
  };
  if (BUILTIN_AMBIENT_MODULES.has(moduleSpecifier) || ambientProvider) compilerOptions.types = [];
  logicalCanonical(canonicalProjectRoot, canonicalContainingFile, "containing file");
  const projectLocks = bindProjectLocks(canonicalProjectRoot);
  const reads = createReadLedger(canonicalProjectRoot);
  reads.required(canonicalContainingFile, "containing file");
  const builtinAmbient = BUILTIN_AMBIENT_MODULES.get(moduleSpecifier) ?? null;
  const builtinPath = builtinAmbient
    ? resolve(canonicalProjectRoot, ".beagle-typescript-builtins", builtinAmbient.logicalPath)
    : null;
  const host = ts.createCompilerHost(compilerOptions, true);
  host.getCurrentDirectory = () => canonicalProjectRoot;
  const fileExists = host.fileExists.bind(host);
  host.fileExists = (path) => (
    builtinPath && resolve(path) === builtinPath ? true : fileExists(path)
  );
  host.readFile = (path) => (
    builtinPath && resolve(path) === builtinPath
      ? builtinAmbient.source
      : reads.readText(path)
  );
  const getSourceFile = host.getSourceFile.bind(host);
  host.getSourceFile = (fileName, ...arguments_) => {
    if (builtinPath && resolve(fileName) === builtinPath) {
      return ts.createSourceFile(
        builtinPath,
        builtinAmbient.source,
        arguments_[0] ?? compilerOptions.target,
        true,
        ts.ScriptKind.TS,
      );
    }
    const sourceFile = getSourceFile(fileName, ...arguments_);
    if (!sourceFile) return sourceFile;
    const snapshot = reads.record(fileName, "parsed Program source input");
    if (sourceFile.text !== snapshot.text) {
      throw new Error(`Program parsed bytes outside the shared input snapshot: ${snapshot.path}`);
    }
    return sourceFile;
  };
  const typescriptLibraryMatch = ambientProvider
    ? /^typescript:(lib\.[A-Za-z0-9.-]+)$/.exec(moduleSpecifier)
    : null;
  const typescriptLibraryPath = typescriptLibraryMatch
    ? canonicalPath(resolve(
      TYPESCRIPT_RUNTIME_ROOT,
      "node_modules/typescript/lib",
      `${typescriptLibraryMatch[1]}.d.ts`,
    ))
    : null;
  let resolved = typescriptLibraryPath
    ? { resolvedFileName: typescriptLibraryPath }
    : ts.resolveModuleName(
      moduleSpecifier,
      canonicalContainingFile,
      compilerOptions,
      host,
    ).resolvedModule;
  if (!resolved && ambientProvider && moduleSpecifier.startsWith("@types/")) {
    const directiveName = moduleSpecifier.slice("@types/".length);
    const directive = ts.resolveTypeReferenceDirective(
      directiveName,
      canonicalContainingFile,
      compilerOptions,
      host,
    ).resolvedTypeReferenceDirective;
    if (directive) resolved = { resolvedFileName: directive.resolvedFileName };
  }
  let program;
  let checker;
  let source;
  let moduleSymbol;
  let packagePath;
  if (resolved) {
    packagePath = enclosingPackage(resolved.resolvedFileName);
    const rootNames = typescriptLibraryPath
      ? [
        canonicalPath(resolve(
          TYPESCRIPT_RUNTIME_ROOT,
          "node_modules/typescript/lib/lib.esnext.d.ts",
        )),
        resolved.resolvedFileName,
      ]
      : [resolved.resolvedFileName];
    program = ts.createProgram(rootNames, compilerOptions, host);
    checker = program.getTypeChecker();
    source = program.getSourceFile(resolved.resolvedFileName);
    if (!source) throw new Error(`resolved declaration is absent from Program: ${resolved.resolvedFileName}`);
    moduleSymbol = ambientProvider ? null : checker.getSymbolAtLocation(source);
    if (!ambientProvider && !moduleSymbol) {
      throw new Error(`resolved declaration has no module symbol: ${resolved.resolvedFileName}`);
    }
  } else {
    if (ambientProvider) {
      throw new Error(`cannot resolve TypeScript ambient provider ${moduleSpecifier} from ${containingFile}`);
    }
    const typeDirectiveFiles = builtinPath
      ? [builtinPath]
      : ts.getAutomaticTypeDirectiveNames(compilerOptions, host)
        .sort()
        .map((name) => ts.resolveTypeReferenceDirective(
          name,
          canonicalContainingFile,
          compilerOptions,
          host,
        ).resolvedTypeReferenceDirective?.resolvedFileName)
        .filter(Boolean);
    program = ts.createProgram(typeDirectiveFiles, compilerOptions, host);
    checker = program.getTypeChecker();
    moduleSymbol = checker.getAmbientModules().find((symbol) => (
      symbol.getName().replace(/^"|"$/g, "") === moduleSpecifier
    ));
    if (!moduleSymbol) {
      throw new Error(`cannot resolve physical or ambient TypeScript module ${moduleSpecifier} from ${containingFile}`);
    }
    source = declaration(moduleSymbol)?.getSourceFile();
    if (!source) throw new Error(`ambient TypeScript module ${moduleSpecifier} has no declaration source`);
    packagePath = builtinPath
      ? enclosingPackage(canonicalContainingFile)
      : enclosingPackage(source.fileName);
  }
  const canonicalPackagePath = canonicalPath(packagePath);
  if (!maybeLogicalCanonical(canonicalProjectRoot, canonicalPackagePath)
      && !maybeLogicalCanonical(TYPESCRIPT_RUNTIME_ROOT, canonicalPackagePath)) {
    throw new Error(`resolved package is outside project and TypeScript runtime authority roots: ${canonicalPackagePath}`);
  }
  const packageSnapshot = reads.required(packagePath, "resolved package");
  const diagnostics = ts.getPreEmitDiagnostics(program);
  if (diagnostics.length) {
    throw new Error(ts.formatDiagnosticsWithColorAndContext(diagnostics, {
      getCanonicalFileName: (path) => path,
      getCurrentDirectory: () => canonicalProjectRoot,
      getNewLine: () => "\n",
    }));
  }
  const programInputs = program.getSourceFiles()
    .filter((programSource) => !builtinPath || resolve(programSource.fileName) !== builtinPath)
    .map((programSource) => reads.record(
      programSource.fileName,
      "Program source input",
    ));
  const virtualInputs = builtinPath
    ? [{
      path: `adapter/${builtinAmbient.logicalPath}`,
      physicalPath: builtinPath,
      sha256: sha256Bytes(Buffer.from(builtinAmbient.source)),
    }]
    : [];
  const ambientDeclarationAllowed = (symbol) => {
    if (!ambientProvider || !symbol) return false;
    return (symbol.declarations ?? []).some((node) => {
      const declarationSource = node.getSourceFile?.();
      if (!declarationSource) return false;
      if (typescriptLibraryPath) {
        return canonicalPath(declarationSource.fileName) === typescriptLibraryPath;
      }
      return !program.isSourceFileDefaultLibrary(declarationSource);
    });
  };
  return {
    ambientDeclarationAllowed, checker, compilerOptions,
    conditions: [...conditions].sort(), moduleSpecifier, moduleSymbol,
    packagePath: packageSnapshot.path, program, programInputs, projectLocks,
    projectRoot: canonicalProjectRoot, reads, resolved, virtualInputs,
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

export function sourceImporterBuilder(module) {
  const candidates = [
    module["import-typescript-source-v1!"],
    module.import_typescript_source_v1_bang,
  ].filter((value) => typeof value === "function");
  if (candidates.length !== 1) {
    throw new Error("compiled importer must expose exactly one import-typescript-source-v1! implementation");
  }
  return candidates[0];
}

export function createCompilerBridge({
  adapterRoot,
  compiledAdapter,
  producerInputs = null,
  adapterSourceName = "src/adapter.bjs",
  typescriptRuntimeRoot = TYPESCRIPT_RUNTIME_ROOT,
}) {
  const root = canonicalPath(adapterRoot);
  if (root !== BRIDGE_ROOT) {
    throw new Error(`Compiler API bridge authority root mismatch: ${root} (expected ${BRIDGE_ROOT})`);
  }
  const canonicalTypescriptRuntimeRoot = canonicalPath(typescriptRuntimeRoot);
  if (canonicalTypescriptRuntimeRoot !== TYPESCRIPT_RUNTIME_ROOT) {
    throw new Error(`TypeScript runtime authority root mismatch: ${canonicalTypescriptRuntimeRoot} (expected ${TYPESCRIPT_RUNTIME_ROOT})`);
  }
  const own = (name) => resolve(root, name);
  const adapterSource = bindFileBytes(own(adapterSourceName), "typed adapter source");
  const adapterLock = bindFileBytes(own("bun.lock"), "adapter lockfile");
  const producer = producerInputs ?? bindProducerInputs({ adapterRoot: root });
  const typescriptRoot = canonicalPath(resolve(
    canonicalTypescriptRuntimeRoot,
    "node_modules/typescript",
  ));
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
  const typeParameterDeclarationOwner = (context, parameter) => {
    const owners = new Map();
    for (const declarationNode of parameter.symbol?.declarations ?? []) {
      const owner = declarationNode.parent;
      const source = owner?.getSourceFile?.();
      if (!owner || !source?.fileName) continue;
      const snapshot = context.reads.record(
        source.fileName,
        "Type parameter declaration owner identity",
      );
      const input = compilerInputDigest(context, snapshot);
      const identity = `${input.path}#${canonicalNodeKind(owner)}@${owner.pos}:${owner.end}@sha256:${input.sha256}`;
      owners.set(identity, owner);
    }
    if (owners.size === 0) {
      throw new Error(
        `TypeScript type parameter ${parameter.symbol?.getName?.() ?? "<anonymous>"} has no lexical declaration owner identity`,
      );
    }
    const identities = [...owners.keys()].sort();
    return identities.length === 1
      ? identities[0]
      : `typescript-merged-declaration-owner@sha256:${sha256Bytes(Buffer.from(JSON.stringify(identities)))}`;
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
  const runtimePrimitiveKind = (type) => {
    const symbol = type.aliasSymbol ?? type.symbol;
    const kind = TYPESCRIPT_RUNTIME_PRIMITIVES.get(symbol?.getName());
    const declarations = symbol?.declarations ?? [];
    if (!kind || declarations.length === 0) return null;
    const standardLibraryDeclaration = (item) => {
      const source = item.getSourceFile?.();
      if (!source) return false;
      const logical = maybeLogicalCanonical(typescriptRoot, canonicalPath(source.fileName));
      return Boolean(logical && /^lib\/lib\..+\.d\.ts$/.test(logical));
    };
    // A project @types package may augment a standard global declaration.
    // The standard declaration anchors runtime identity; a module-local
    // counterfeit is a different symbol and therefore has no such anchor.
    return declarations.some(standardLibraryDeclaration) ? kind : null;
  };
  const signatureTypeParameterGroups = (signature) => {
    const declarationNode = signature.declaration;
    const enclosingClass = declarationNode
      && ts.isConstructorDeclaration(declarationNode)
      && (ts.isClassDeclaration(declarationNode.parent)
          || ts.isClassExpression(declarationNode.parent))
      ? declarationNode.parent
      : null;
    const local = [];
    const captured = [];
    const syntheticLocalOwnerKinds = new Set([
      ts.SyntaxKind.ArrowFunction,
      ts.SyntaxKind.CallSignature,
      ts.SyntaxKind.ConstructSignature,
      ts.SyntaxKind.Constructor,
      ts.SyntaxKind.ConstructorType,
      ts.SyntaxKind.FunctionDeclaration,
      ts.SyntaxKind.FunctionExpression,
      ts.SyntaxKind.FunctionType,
      ts.SyntaxKind.MethodDeclaration,
      ts.SyntaxKind.MethodSignature,
    ]);
    const syntheticCapturedOwnerKinds = new Set([
      ts.SyntaxKind.ClassDeclaration,
      ts.SyntaxKind.ClassExpression,
      ts.SyntaxKind.InterfaceDeclaration,
      ts.SyntaxKind.TypeAliasDeclaration,
    ]);
    for (const parameter of signature.getTypeParameters?.() ?? []) {
      const declarations = parameter.symbol?.declarations ?? [];
      const ownerKinds = declarations.map((item) => item.parent?.kind);
      if (declarationNode && declarations.some((item) => item.parent === declarationNode)) {
        local.push(parameter);
      } else if (enclosingClass && declarations.some((item) => item.parent === enclosingClass)) {
        captured.push(parameter);
      } else if (!declarationNode
                 && ownerKinds.length > 0
                 && ownerKinds.every((kind) => syntheticLocalOwnerKinds.has(kind))) {
        local.push(parameter);
      } else if (ownerKinds.length > 0
                 && ownerKinds.every((kind) => syntheticCapturedOwnerKinds.has(kind))) {
        captured.push(parameter);
      } else {
        const declarationKind = declarationNode
          ? ts.SyntaxKind[declarationNode.kind]
          : "<synthetic>";
        const parameterOwners = declarations
          .map((item) => ts.SyntaxKind[item.parent?.kind] ?? "<none>")
          .join(", ");
        const targetKind = signature.target?.declaration
          ? ts.SyntaxKind[signature.target.declaration.kind]
          : "<synthetic>";
        throw new Error(
          `TypeScript ${declarationKind} signature (target ${targetKind}) type parameter ${parameter.symbol?.getName?.() ?? "<anonymous>"} has no exact lexical signature or enclosing-class owner; declaration parents: ${parameterOwners || "<none>"}`,
        );
      }
    }
    return { captured, local };
  };
  const explicitTypeParameterPart = (type, part) => {
    const declarations = type.symbol?.declarations ?? [];
    return declarations.some((item) => (
      ts.isTypeParameterDeclaration(item) && item[part]
    ));
  };
  const declarationTypeParameters = (type) => {
    // Alias arguments are use-site substitutions, not lexical declarations.
    // An uninstantiated generic alias is the one exception: the compiler
    // exposes its own declaration parameters through aliasTypeArguments.
    // Require exact parent identity with the alias declaration so a use such
    // as Readonly<T> cannot steal the surrounding signature's T.
    const direct = type.typeParameters ?? [];
    if (direct.length > 0) {
      return direct.every((candidate) => hasFlag(candidate.flags, ts.TypeFlags.TypeParameter))
        ? direct
        : [];
    }
    const aliasDeclarations = new Set(type.aliasSymbol?.declarations ?? []);
    const aliasArguments = type.aliasTypeArguments ?? [];
    return aliasArguments.length > 0
      && aliasArguments.every((candidate) => (
        hasFlag(candidate.flags, ts.TypeFlags.TypeParameter)
        && (candidate.symbol?.declarations ?? [])
          .some((item) => aliasDeclarations.has(item.parent))
      ))
      ? aliasArguments
      : [];
  };
  const builtinAwaitedArgument = (context, type) => {
    const symbol = type.aliasSymbol;
    const arguments_ = type.aliasTypeArguments ?? [];
    if (symbol?.getName() !== "Awaited" || arguments_.length !== 1) return null;
    const declarations = symbol.declarations ?? [];
    if (declarations.length !== 1 || !ts.isTypeAliasDeclaration(declarations[0])) return null;
    const source = declarations[0].getSourceFile?.();
    if (!source?.fileName) return null;
    try {
      const snapshot = context.reads.record(
        source.fileName,
        "Builtin Awaited alias identity",
      );
      const input = compilerInputDigest(context, snapshot);
      return input.path === "adapter/node_modules/typescript/lib/lib.es5.d.ts"
        ? arguments_[0]
        : null;
    } catch {
      return null;
    }
  };
  const enumMemberValue = (context, type) => {
    const symbol = type.aliasSymbol ?? type.symbol;
    if (!symbol) return undefined;
    const member = declaration(symbol);
    if (!member || !ts.isEnumMember(member)) return undefined;
    const initializer = member.initializer;
    if (ts.isStringLiteral(initializer)) return initializer.text;
    if (ts.isNumericLiteral(initializer)) return Number(initializer.text);
    if (ts.isPrefixUnaryExpression(initializer)
        && initializer.operator === ts.SyntaxKind.MinusToken
        && ts.isNumericLiteral(initializer.operand)) {
      return -Number(initializer.operand.text);
    }
    return undefined;
  };
  const typeKind = (context, type) => {
    if (forcedCodes.has(type)) return "unsupported";
    if (builtinAwaitedArgument(context, type)) return "awaited";
    let kind;
    if (exactFlag(type, ts.TypeFlags.IndexedAccess)) kind = "indexed-access";
    else if (exactFlag(type, ts.TypeFlags.NonPrimitive)
        || context.checker.typeToString(type) === "object") kind = "non-primitive-object";
    else if (brand(context, type)) kind = "brand";
    else if (context.checker.isTupleType(type)) kind = "tuple";
    else if (context.checker.isArrayType(type)) kind = "array";
    else if (enumMemberValue(context, type) !== undefined) kind = "literal";
    else if (exactFlag(type, ts.TypeFlags.TemplateLiteral)) kind = "template-literal";
    else if (hasFlag(type.flags, ts.TypeFlags.Boolean)) kind = "boolean";
    else {
      const primitive = TYPE_KINDS.get(type.flags);
      if (primitive) kind = primitive;
      else if (hasFlag(type.flags, ts.TypeFlags.Enum | ts.TypeFlags.EnumLiteral | ts.TypeFlags.UniqueESSymbol)) kind = "unsupported";
      else if (type.isUnion?.()) kind = "union";
      else if (type.isIntersection?.()) kind = "intersection";
      else if (!exactFlag(type, ts.TypeFlags.Object)) kind = "unsupported";
      else if (hasFlag(type.objectFlags, ts.ObjectFlags.Reference) && type.target !== type) kind = "reference";
      else if (type.getCallSignatures().length > 0 && type.getProperties().length === 0) kind = "function";
      else {
        const shape = type.objectFlags & ts.ObjectFlags.ObjectTypeKindMask;
        kind = shape !== 0 && (shape & ~SUPPORTED_OBJECT_FLAGS) === 0 ? "object" : "unsupported";
      }
    }
    // ForeignInterfaceV1 gives lexical type-parameter ownership to object and
    // function nodes. A generic alias whose root is a union, tuple, array,
    // reference, or another non-owner shape cannot be represented without
    // leaking free type variables into the graph. Preserve that boundary as
    // one explicit obligation on the alias root instead of emitting an
    // invalid orphan parameter node.
    if (kind !== "unsupported"
        && kind !== "object"
        && kind !== "function"
        && type.aliasSymbol
        && declarationTypeParameters(type).length > 0
    ) {
      forcedCodes.set(type, "TS_GENERIC_ALIAS_ROOT");
      return "unsupported";
    }
    return kind;
  };
  return {
    ambientValues(context, names, required = false) {
      this.context = context;
      return [...new Set(names)].sort().map((name) => {
        const symbol = context.checker.resolveName(
          name,
          undefined,
          ts.SymbolFlags.Value,
          false,
        );
        if (required && (!symbol || !context.ambientDeclarationAllowed(symbol))) {
          throw new Error(`TypeScript ambient provider ${context.moduleSpecifier} does not declare requested global value ${name}`);
        }
        return symbol;
      }).filter(Boolean);
    },
    array: () => [],
    arrayElementType(type) { return this.context.checker.getElementTypeOfArrayType(type); },
    baseConstraint(type) { return this.context.checker.getBaseConstraintOfType(type) ?? null; },
    brandBase: (type) => type.types.find((member) => !exactFlag(member, ts.TypeFlags.Object)) ?? type.types[0],
    brandName(type) { return brand(this.context, type); },
    callSignatures: (type) => type.getCallSignatures(),
    constructSignatures: (type) => type.getConstructSignatures(),
    contextualRecordName(context, node) {
      const contextual = context.checker.getContextualType(node);
      if (!contextual) return null;
      const actual = context.checker.getTypeAtLocation(node);
      const candidates = contextual.isUnion?.() ? contextual.types : [contextual];
      const names = candidates.flatMap((candidate) => {
        if (hasFlag(candidate.flags, ts.TypeFlags.Null | ts.TypeFlags.Undefined)) return [];
        const symbol = candidate.aliasSymbol ?? candidate.symbol;
        const source = declaration(symbol)?.getSourceFile();
        if (!symbol || source !== context.source) return [];
        return context.checker.isTypeAssignableTo(actual, candidate) ? [symbol.getName()] : [];
      });
      return names.length === 1 ? names[0] : null;
    },
    declaredType(node) {
      const symbol = this.context.checker.getSymbolAtLocation(node.name ?? node);
      const declared = declaration(symbol);
      return symbol && declared
        ? this.context.checker.getTypeOfSymbolAtLocation(symbol, declared)
        : null;
    },
    equal: Object.is,
    exportType(symbol) {
      const context = this.context;
      const type = hasFlag(symbol.flags, ts.SymbolFlags.Value)
        ? context.checker.getTypeOfSymbolAtLocation(symbol, declaration(symbol))
        : context.checker.getDeclaredTypeOfSymbol(symbol);
      return type;
    },
    "flowAscriptionType?"(type) {
      const kind = typeKind(this.context, type);
      if (["string", "number", "boolean", "bigint", "literal", "array", "tuple", "reference"].includes(kind)) {
        return true;
      }
      if (kind === "union") return type.types.every((member) => this["flowAscriptionType?"](member));
      if (kind !== "object") return false;
      if (this.context.checker.getIndexInfosOfType(type).length > 0) return true;
      const name = type.aliasSymbol?.getName() ?? type.symbol?.getName();
      return Boolean(name && name !== "anonymous" && name !== "__type");
    },
    indexInfos(type) { return this.context.checker.getIndexInfosOfType(type); },
    indexKeyType: (index) => index.keyType,
    indexValueType: (index) => index.type,
    indexedAccessObjectType: (type) => type.objectType ?? null,
    literalKind(type) {
      const enumValue = enumMemberValue(this.context, type);
      return typeof enumValue === "string" ? "string"
        : typeof enumValue === "number" ? "number"
        : hasFlag(type.flags, ts.TypeFlags.StringLiteral) ? "string"
        : hasFlag(type.flags, ts.TypeFlags.NumberLiteral) ? "number"
        : hasFlag(type.flags, ts.TypeFlags.BooleanLiteral) ? "boolean" : "bigint";
    },
    literalValue(type) {
      const enumValue = enumMemberValue(this.context, type);
      if (enumValue !== undefined) return enumValue;
      return hasFlag(type.flags, ts.TypeFlags.BooleanLiteral)
        ? type.intrinsicName === "true"
        : typeof type.value === "object" ? String(type.value.base10Value) : type.value;
    },
    moduleExports(context) { this.context = context; return context.checker.getExportsOfModule(context.moduleSymbol); },
    moduleMapping(mappings, specifier) { return mappings.get(specifier) ?? null; },
    relativeModuleNamespace(namespace, specifier) {
      if (!specifier.startsWith(".")) return null;
      const segments = namespace.split(".");
      segments.pop();
      for (const segment of specifier.split("/")) {
        if (segment === "." || segment === "") continue;
        if (segment === "..") {
          if (segments.length === 0) return null;
          segments.pop();
        } else {
          segments.push(segment.replace(/\.(?:d\.)?[cm]?[jt]sx?$/, ""));
        }
      }
      return segments.length > 0 ? segments.join(".") : null;
    },
    localTypeByName(context, name) {
      const statement = context.source.statements.find((candidate) => candidate.name?.getText?.() === name);
      return statement?.name ? context.checker.getTypeAtLocation(statement.name) : null;
    },
    "nominalReference?": (type) => Boolean(type.symbol?.valueDeclaration && ts.isClassDeclaration(type.symbol.valueDeclaration)),
    declarationTypeParameters,
    "optionalSymbol?": (symbol) => hasFlag(symbol.flags, ts.SymbolFlags.Optional),
    "optionalParameter?": (signature, symbol) => {
      const index = signature.getParameters().indexOf(symbol);
      if (index < 0) {
        throw new Error("parameter symbol is absent from its owning signature");
      }
      if (declaration(symbol)?.dotDotDotToken) return false;
      return hasFlag(symbol.flags, ts.SymbolFlags.Optional)
        || index >= signature.minArgumentCount;
    },
    partialBaseType(type) {
      return type.aliasSymbol?.getName() === "Partial"
        ? type.aliasTypeArguments?.[0] ?? null
        : null;
    },
    partialRecordTypeArguments(type) {
      const base = this.partialBaseType(type);
      return base?.aliasSymbol?.getName() === "Record"
        ? base.aliasTypeArguments ?? []
        : [];
    },
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
      const virtualByPath = new Map(
        (context.virtualInputs ?? []).map((input) => [input.physicalPath, input]),
      );
      for (const source of context.program.getSourceFiles()) {
        if (virtualByPath.has(resolve(source.fileName))) continue;
        const snapshot = context.reads.record(source.fileName, "Program source input");
        if (!programPaths.has(snapshot.path)) {
          throw new Error(`Program source escaped the snapshotted input set: ${snapshot.path}`);
        }
      }
      const files = canonicalDigestFiles([
        ...producer.files,
        ...compiledAdapter.runtimeFiles(),
        ...(context.virtualInputs ?? []).map(({ path, sha256 }) => ({ path, sha256 })),
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
          path: logicalCanonical(
            canonicalTypescriptRuntimeRoot,
            typescriptSource.path,
            "TypeScript compiler",
          ),
          sha256: typescriptSource.sha256,
        },
        compilerOptions: {
          customConditions: [...conditions].sort(), module: "NodeNext", moduleResolution: "NodeNext",
          noEmit: true, skipLibCheck: true, strict: true, target: "ESNext",
        },
        moduleSpecifier,
        conditions: [...conditions].sort(),
        package: compilerInputDigest(context, packageSnapshot),
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
    signatureCapturedTypeParameters: (signature) => signatureTypeParameterGroups(signature).captured,
    signatureMinimumArgumentCount: (signature) => signature.minArgumentCount,
    signatureReturnType(signature) { return this.context.checker.getReturnTypeOfSignature(signature); },
    signatureTypeParameters: (signature) => signatureTypeParameterGroups(signature).local,
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
      // ForeignInterfaceV1 can faithfully project an enum's runtime object
      // and literal-valued members today.  Do not advertise the distinct enum
      // type space until the wire can carry a separate type node.
      if (symbol.declarations?.some(ts.isEnumDeclaration)) return "value";
      return value && type ? "both" : value ? "value" : "type";
    },
    tupleElementName: (element) => element.label,
    "tupleElementOptional?": (element) => hasFlag(element.flag, ts.ElementFlags.Optional),
    "tupleElementRest?": (element) => hasFlag(element.flag, ts.ElementFlags.Rest),
    tupleElementType: (element) => element.elementType,
    tupleElements(type) { return tupleElements(this.context, type); },
    templateLiteralTexts: (type) => [...type.texts],
    templateLiteralTypes: (type) => [...type.types],
    awaitedArgument(type) { return builtinAwaitedArgument(this.context, type); },
    typeArguments(type) {
      const referenceArguments = this.context.checker.getTypeArguments?.(type) ?? [];
      return referenceArguments.length > 0
        ? referenceArguments
        : type.aliasTypeArguments ?? type.typeArguments ?? [];
    },
    typeDisplay(type) { return this.context.checker.typeToString(type, undefined, ts.TypeFormatFlags.NoTruncation); },
    typeIdentity(type) {
      const symbol = type.aliasSymbol ?? type.symbol;
      if (!symbol) return null;
      const source = declaration(symbol)?.getSourceFile();
      if (!source || !source.fileName) return null;
      let snapshot;
      try {
        snapshot = this.context.reads.record(source.fileName, "Type declaration identity");
      } catch {
        return null;
      }
      const input = compilerInputDigest(this.context, snapshot);
      return `${input.path}#${symbol.getName()}@sha256:${input.sha256}`;
    },
    foreignTypeKind(type) { return runtimePrimitiveKind(type) ?? typeKind(this.context, type); },
    typeImportSpecifier(context, type) {
      const symbol = type.aliasSymbol ?? type.symbol;
      if (!symbol) return null;
      const typeSource = declaration(symbol)?.getSourceFile();
      if (!typeSource || typeSource === context.source) return null;
      for (const statement of context.source.statements) {
        if (!ts.isImportDeclaration(statement) || !ts.isStringLiteral(statement.moduleSpecifier)) continue;
        const importedModule = context.checker.getSymbolAtLocation(statement.moduleSpecifier);
        if (importedModule?.declarations?.some((item) => item.getSourceFile() === typeSource)) {
          return statement.moduleSpecifier.text;
        }
      }
      return null;
    },
    typeKind(type) { return typeKind(this.context, type); },
    typeMembers: (type) => type.types,
    typeName: (type) => type.aliasSymbol?.getName() ?? type.symbol?.getName() ?? "anonymous",
    typeParameterDeclarationOwner(type) {
      return typeParameterDeclarationOwner(this.context, type);
    },
    typeParameterConstraint: (type) => explicitTypeParameterPart(type, "constraint")
      ? type.getConstraint?.() ?? type.constraint ?? null
      : null,
    typeParameterArrayElementType(type) {
      const constraint = type.getConstraint?.() ?? type.constraint ?? null;
      return constraint && this.context.checker.isArrayLikeType(constraint)
        ? this.context.checker.getIndexTypeOfType(constraint, ts.IndexKind.Number)
        : null;
    },
    typeParameterDefault: (type) => explicitTypeParameterPart(type, "default")
      ? type.getDefault?.() ?? type.default ?? null
      : null,
    unsupportedCode,
    weakMap: () => new WeakMap(),
    sourceFile(context) { this.context = context; return context.source; },
    nodeKind: canonicalNodeKind,
    nodeField: (node, field) => node?.[field] ?? null,
    nodeList: (node, field) => [...(node?.[field] ?? [])],
    nodeName: (node) => node?.name?.getText?.() ?? node?.getText?.() ?? "",
    nodeText: (node) => node?.text ?? node?.getText?.() ?? "",
    numericLiteralNumberSource(node) {
      const value = Number(node.text);
      return Number.isInteger(value) ? `${value}.0` : String(value);
    },
    nodeTokenKind: canonicalTokenKind,
    metaPropertyKeywordKind: (node) => ts.SyntaxKind[node?.keywordToken] ?? "",
    prefixOperatorKind: (node) => canonicalTokenKind({ kind: node.operator }),
    "nodeExported?": (node) => Boolean(node?.modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword)),
    "nodeAsync?": (node) => Boolean(node?.modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.AsyncKeyword)),
    "nodeAwait?": (node) => Boolean(node?.awaitModifier),
    "nodeGenerator?": (node) => Boolean(node?.asteriskToken),
    "nodeOptional?": (node) => Boolean(
      node?.questionToken
      || node?.questionDotToken
      || (node?.flags & ts.NodeFlags.OptionalChain),
    ),
    "nodeReadonly?": (node) => Boolean(
      node?.modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.ReadonlyKeyword)
    ),
    "nodeEffectful?": nodeEffectful,
    "nodeParameterProperty?": (node) => Boolean(
      node?.parent && ts.isParameterPropertyDeclaration(node, node.parent)
    ),
    "classFieldMutable?": (type, fieldName) => {
      const symbol = type.getProperty?.(fieldName);
      const member = declaration(symbol);
      if (!member) return false;
      return !member.modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.ReadonlyKeyword);
    },
    "classMethodEffectful?": (type, methodName) => {
      const symbol = type.getProperty?.(methodName);
      const member = declaration(symbol);
      return nodeEffectful(member?.body ?? member);
    },
    "nodeRest?": (node) => Boolean(node?.dotDotDotToken),
    "nodeMutable?": (node) => Boolean(node?.parent?.flags & ts.NodeFlags.Let),
    literalJson: (node) => JSON.stringify(node.text),
    jsonString: (value) => JSON.stringify(value),
    regexPattern(node) {
      const text = node.getText();
      const lastSlash = text.lastIndexOf("/");
      return text.slice(1, lastSlash);
    },
    regexFlags(node) {
      const text = node.getText();
      return text.slice(text.lastIndexOf("/") + 1);
    },
    location(context, node) {
      const anchor = node ?? context.source;
      const point = context.source.getLineAndCharacterOfPosition(anchor.getStart(context.source));
      return {
        file: logicalCanonical(context.projectRoot, context.source.fileName, "TypeScript source file"),
        line: point.line + 1,
        column: point.character + 1,
      };
    },
    typeAt(node) { return this.context.checker.getTypeAtLocation(node); },
    contextualType(node) { return this.context.checker.getContextualType(node) ?? null; },
    returnType(node) {
      const signature = this.context.checker.getSignatureFromDeclaration(node);
      return signature ? this.context.checker.getReturnTypeOfSignature(signature) : null;
    },
    getSignatureFromDeclaration(node) {
      return this.context.checker.getSignatureFromDeclaration(node) ?? null;
    },
    "typeLocal?"(type) {
      const symbol = type.aliasSymbol ?? type.symbol;
      return Boolean(symbol?.declarations?.some((item) => item.getSourceFile() === this.context.source));
    },
    typeProperties(type) { return this.context.checker.getPropertiesOfType(type); },
    sourceProvenance(context) {
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
      return {
        adapter: {
          source: logicalCanonical(root, adapterSource.path, "adapter source"),
          sourceSha256: adapterSource.sha256,
          compiledSha256: compiledAdapter.sha256,
        },
        typescript: {
          version: ts.version,
          path: logicalCanonical(
            canonicalTypescriptRuntimeRoot,
            typescriptSource.path,
            "TypeScript compiler",
          ),
          sha256: typescriptSource.sha256,
        },
        source: compilerInputDigest(context, context.reads.record(context.source.fileName)),
        consultedFiles: canonicalDigestFiles([
          ...producer.files,
          ...compiledAdapter.runtimeFiles(),
          ...context.reads.records().map((snapshot) => compilerInputDigest(context, snapshot)),
          ...context.projectLocks.files.map((snapshot) => ({
            path: `project/${logicalCanonical(context.projectRoot, snapshot.path, "project lockfile")}`,
            sha256: snapshot.sha256,
          })),
        ]),
      };
    },
  };
}

export function createSourceCompilerBridge(options) {
  return createCompilerBridge({ ...options, adapterSourceName: "src/importer.bjs" });
}
